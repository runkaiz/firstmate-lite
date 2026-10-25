// Pi preservation workflow. The stow skill owns filing and the receipt contract.
// Deliberately uses early save + native compaction: manual compact aborts work
// and Pi has no atomic idle-only compact-and-resume API (see command review).
import { randomUUID } from "node:crypto";
import { existsSync, lstatSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { SettingsManager, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { lockOwnership } from "./fm-primary-turnend-guard.ts";
import { registerFirstmateTool } from "./lib/fm-native-contract.ts";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";

const root = process.env.FM_ROOT_OVERRIDE || resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${home}/state`;
const entryType = "firstmate-stow-state";
type Episode = {
  id: string;
  session: string;
  phase: "requested" | "saved" | "incomplete" | "compacted";
  automatic: boolean;
  saveOnly: boolean;
  compactedDuringSave?: boolean;
};

export default function (pi: ExtensionAPI) {
  let episode: Episode | undefined;
  let generation = 0;
  let receiving = false;
  const eligible = () => lockOwnership() === "owned";
  const parked = () => [".afk", ".afk-contract", ".afk-return-catchup"].some(name => {
    try { lstatSync(`${state}/${name}`); return true; } catch (error) {
      return (error as NodeJS.ErrnoException).code !== "ENOENT";
    }
  });
  const persist = () => { if (episode) pi.appendEntry(entryType, { ...episode }); };
  const matches = (ctx: ExtensionContext) => episode?.session === ctx.sessionManager.getSessionId() &&
    ctx.sessionManager.getBranch().some(entry => entry.type === "custom" && entry.customType === entryType &&
      (entry.data as Episode | undefined)?.id === episode?.id);
  const notice = (ctx: ExtensionContext, text: string) => {
    if (ctx.hasUI) ctx.ui.notify(text, "info");
  };
  const request = (ctx: ExtensionContext, automatic: boolean, saveOnly: boolean) => {
    episode = { id: randomUUID(), session: ctx.sessionManager.getSessionId(), phase: "requested", automatic, saveOnly };
    persist();
    return {
      customType: "firstmate-stow-request",
      content: encodeFirstmateOperationalInput("stow", `Internal preservation request ${episode.id}. Read .agents/skills/stow/SKILL.md and perform its ordinary filing procedure with normal tools and existing authority. This is not a user return, new task, or approval. After the complete receipt, call fm_stow_complete with this episode id, authoritative owner paths, open-record accounting, memory actions, and every unresolved exception. Never report complete with pending captures or budget exceptions. ${automatic ? "After saving, continue only unfinished authorized work from before this request through the current native run; do not submit a separate resume prompt." : "Finish with a short save receipt; do not invent work."} ${saveOnly ? "Save-only requested." : "Safe scheduling fallback: save now; Pi owns subsequent compaction and continuation. Do not call /compact or manually compact from a tool or hook."}`),
      display: false,
      details: { episode: episode.id },
    };
  };

  // Bare commands have real Pi handlers; skill invocation remains available on
  // other harnesses. Both dashboard spellings dispatch the SAME skill owner.
  for (const name of ["ahoy", "bearings"]) {
    pi.registerCommand(name, {
      description: "Catch up on current local work, conversation continuity, and decisions",
      handler: async (args, ctx) => {
        if (!eligible()) { notice(ctx, "Ahoy requires the owning Firstmate session."); return; }
        pi.sendUserMessage(`/skill:ahoy ${args}`, { expandPromptTemplates: true, deliverAs: "followUp" });
      },
    });
  }
  pi.registerCommand("stow", {
    description: "Save current knowledge and work; native Pi compaction follows when needed",
    handler: async (args, ctx) => {
      if (!eligible() || parked()) { notice(ctx, "Stow requires the owning, attended Firstmate session."); return; }
      if (args.trim() && args.trim() !== "save-only") { notice(ctx, "Usage: /stow [save-only]"); return; }
      // Waiting here is command-only. Recheck after waiting; never borrow this
      // context from a lifecycle callback or abort a user's active operation.
      const token = generation;
      await ctx.waitForIdle();
      if (token !== generation || !eligible() || parked() || !ctx.isIdle() || ctx.hasPendingMessages()) {
        notice(ctx, "Stow deferred; pending input and current work keep their native order.");
        return;
      }
      if (matches(ctx) && episode?.phase === "requested") { notice(ctx, "Stow already pending; no second pass queued."); return; }
      pi.sendMessage(request(ctx, false, args.trim() === "save-only"), { triggerTurn: true, deliverAs: "followUp" });
    },
  });

  pi.on("session_start", (_event, ctx) => {
    generation++;
    receiving = false;
    episode = undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "compaction") episode = undefined;
      if (entry.type !== "custom" || entry.customType !== entryType) continue;
      const value = entry.data as Episode | undefined;
      if (value?.session === ctx.sessionManager.getSessionId() && typeof value.id === "string" &&
          ["requested", "saved", "incomplete", "compacted"].includes(value.phase)) episode = { ...value };
    }
    // A restored request is ambiguous, not permission to replay tools.
    if (episode?.phase === "requested") episode.phase = "incomplete";
    if (episode?.phase === "compacted") episode = undefined;
  });
  pi.on("session_shutdown", () => { generation++; episode = undefined; });

  pi.on("turn_end", (event, ctx) => {
    if (eligible() && matches(ctx) && episode?.phase === "saved" && event.toolResults.some(result => result.isError)) {
      episode.phase = "incomplete";
      persist();
      notice(ctx, "A tool in the completed stow batch failed; full save is not verified.");
    }
    if (eligible() && matches(ctx) && episode?.phase === "saved" && episode.compactedDuringSave) {
      // Retire only after sibling results have passed the existing failure
      // check. Do not enqueue another stow from this receipt's own turn.
      episode.phase = "compacted";
      persist();
      episode = undefined;
      return;
    }
    if (!eligible() || parked() || ctx.hasPendingMessages() || episode) return;
    const usage = ctx.getContextUsage();
    if (!ctx.model || !usage || usage.tokens === null || !Number.isFinite(usage.tokens)) return;
    if (event.message.role !== "assistant" || ["aborted", "error", "length"].includes(event.message.stopReason)) return;
    const settings = SettingsManager.inMemory(pi.getSettings()).getCompactionSettings(ctx.model);
    // Extra reserve is a heuristic, not a proven bound on stow's cost. Native
    // overflow recovery is never cancelled when a result jumps this margin.
    const margin = Math.max(settings.reserveTokens, settings.keepRecentTokens);
    const threshold = usage.contextWindow - settings.reserveTokens - margin;
    if (!settings.enabled || !Number.isFinite(threshold) || threshold <= 0 || usage.tokens < threshold) return;
    const message = request(ctx, true, false);
    // Pi processes this boundary only after the complete sibling tool batch.
    // One continuation stays in its scheduler, including pending user input and
    // automatic threshold/overflow recovery; no second send/resume is issued.
    return { entries: [{ type: "custom_message" as const, ...message }], continue: true };
  });

  registerFirstmateTool(pi, {
    name: "fm_stow_complete",
    label: "Stow receipt",
    description: "Record the stow skill's completed receipt; verifies local owner existence and current memory budget. Never grants new authority or forces compaction.",
    parameters: Type.Object({
      episode: Type.String(), complete: Type.Boolean(),
      owners: Type.Array(Type.String()), pending: Type.Array(Type.String()),
      openRecords: Type.String(), memoryActions: Type.String(),
    }),
    async execute(_id, params, _signal, _update, ctx) {
      const reply = (text: string, isError = false) => ({ content: [{ type: "text" as const, text }], isError, details: {} });
      if (!eligible() || !matches(ctx) || !episode || episode.id !== params.episode || episode.phase !== "requested" || receiving) {
        return reply("Receipt is stale, duplicated, or not owned; no work replayed.", true);
      }
      const active = episode;
      const token = generation;
      receiving = true;
      try {
        const report = await pi.exec("bash", [resolve(root, "bin/fm-startup-memory-budget.sh"), "report"], { timeout: 10000 });
        if (token !== generation || episode !== active || !eligible() || !matches(ctx)) return reply("Session changed; receipt ignored.", true);
        const owners = params.owners.map(path => resolve(home, path));
        const valid = params.complete && params.pending.length === 0 &&
          params.openRecords.trim() && params.memoryActions.trim() && owners.length > 0 && owners.every(path => existsSync(path)) &&
          report.code === 0 && /^budget_status=within-budget$/m.test(report.stdout);
        episode.phase = valid ? "saved" : "incomplete";
        persist();
        return reply(valid
          ? `Saved and budget verified. ${active.compactedDuringSave ? "Native compaction already occurred during this save." : active.saveOnly ? "Save-only complete." : "Native compaction follows Pi settings; immediate compaction was not requested because safe idle dispatch is unproven."} No separate resume request queued.`
          : "Save incomplete; compaction not requested. Preserve pending captures, exceptions and partial work; do not claim reset-safe or retry automatically.", !valid);
      } catch {
        if (token === generation && episode === active) {
          episode.phase = "incomplete";
          persist();
        }
        return reply("Save incomplete: budget verification failed; captures retained, no compaction requested.", true);
      } finally { if (token === generation) receiving = false; }
    },
  });
  pi.on("agent_settled", (_event, ctx) => {
    if (!eligible() || !matches(ctx) || episode?.phase !== "requested") return;
    episode.phase = "incomplete";
    persist();
    notice(ctx, "Stow ended without a verified receipt; partial work retained, no automatic retry.");
  });
  pi.on("session_compact", (_event, ctx) => {
    if (!eligible() || !matches(ctx) || !episode) return;
    if (episode.phase === "requested") {
      // Native between-turn compaction can overtake the early-save margin.
      // It preserves this runtime and branch; filing may still finish in the
      // existing run. Keep requiring its one receipt, never replay the work.
      episode.compactedDuringSave = true;
      persist();
      notice(ctx, "Native compaction ran while stow was pending; full save still requires its receipt. No automatic replay.");
      return;
    }
    episode.phase = episode.phase === "saved" ? "compacted" : "incomplete";
    persist();
    if (episode.phase === "incomplete") notice(ctx, "Native compaction ran before a verified stow receipt; captures may be incomplete. No automatic replay.");
    if (episode.phase === "compacted") episode = undefined;
    // Never enqueue stow/resume here: native willRetry and user queues own it.
  });
  pi.on("session_compact_failed", (_event, ctx) => {
    if (eligible() && matches(ctx) && episode) notice(ctx,
      episode.phase === "saved" ? "Saved; native compaction failed or was cancelled. No automatic stow retry." : "Compaction failed; full stow was not verified. Partial work is retained.");
  });
}
