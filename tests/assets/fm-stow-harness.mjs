// Provider-free public extension interface tests against installed Pi.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { writeFileSync, rmSync, readFileSync } from "node:fs";
import { AgentSession, SessionManager } from "@earendil-works/pi-coding-agent";
import install from "./fm-stow.ts";

const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const run = promisify(execFile);
const hooks = new Map(), commands = new Map(), tools = new Map();
const branch = [], messages = [], prompts = [], notices = [];
let settings = {}, usage, pending = false, idle = true, sid = "test-session", waits = 0;
let onWait = () => {}, compactCalls = 0, budgetFailure = false;
let sdkSession;
const pi = {
  on: (name, callback) => hooks.set(name, callback),
  registerCommand: (name, command) => commands.set(name, command),
  registerTool: tool => tools.set(tool.name, tool),
  events: { on() {} },
  appendEntry: (customType, data) => sdkSession
    ? sdkSession.appendCustomEntry(customType, structuredClone(data))
    : branch.push({ type: "custom", customType, data: structuredClone(data) }),
  getSettings: () => settings,
  sendMessage: (message, options) => messages.push({ message, options }),
  sendUserMessage: (text, options) => prompts.push({ text, options }),
  exec: async (cmd, args) => {
    if (budgetFailure) return { code: 2, stdout: "", stderr: "budget unreadable" };
    const result = await run(cmd, args, { env: process.env });
    return { code: 0, ...result };
  },
};
const ctx = {
  hasUI: true, ui: { notify: text => notices.push(text) },
  model: { provider: "test", id: "model" },
  sessionManager: { getSessionId: () => sdkSession?.getSessionId() ?? sid, getBranch: () => sdkSession?.getBranch() ?? branch },
  getContextUsage: () => usage,
  hasPendingMessages: () => pending, isIdle: () => idle,
  waitForIdle: async () => { waits++; onWait(); },
  compact: () => { compactCalls++; throw new Error("forced compact forbidden"); },
};
install(pi);
const fire = (name, event = {}) => hooks.get(name)?.(event, ctx);
const turn = { message: { role: "assistant", stopReason: "stop" }, toolResults: [{ toolCallId: "one" }, { toolCallId: "two" }] };
const latest = () => ctx.sessionManager.getBranch().findLast(entry => entry.customType === "firstmate-stow-state")?.data;
const receipt = (overrides = {}) => tools.get("fm_stow_complete").execute("receipt", {
  episode: latest()?.id, complete: true, owners: ["data/learnings.md"], pending: [],
  openRecords: "all current open records filed; no others held", memoryActions: "learnings.md unchanged, captain files absent",
  ...overrides,
}, undefined, undefined, ctx);
writeFileSync(`${home}/data/learnings.md`, "fixture learning\n");

// Reproduce why waitForIdle + compact cannot promise idle-only dispatch using
// Pi's actual manual entry point. Throw at abort to prohibit any summarizer.
await ctx.waitForIdle();
let input = "user input arrived after idle";
let abortedInput;
await assert.rejects(AgentSession.prototype.compact.call({
  abort: async () => { abortedInput = input; throw new Error("fixture stops before compaction"); },
}), /fixture stops before compaction/);
assert.equal(abortedInput, input);
console.log("ok - installed Pi manual compact aborts input arriving after idle; forced dispatch remains disabled");

await fire("session_start");
await commands.get("ahoy").handler("detail", ctx);
await commands.get("bearings").handler("detail", ctx);
assert.deepEqual(prompts[0], prompts[1]);
assert.equal(prompts[0].text, "/skill:ahoy detail");
assert.equal(prompts[0].options.expandPromptTemplates, true);
console.log("ok - ahoy and bearings use one command owner and mode expansion");
for (const argument of ["", "on", "off", "status"]) {
  await commands.get("proactive").handler(argument, ctx);
  assert.equal(prompts.at(-1).text, `/skill:proactive ${argument}`);
  assert.equal(prompts.at(-1).options.expandPromptTemplates, true);
  assert.equal(prompts.at(-1).options.deliverAs, "followUp");
}
const proactivePromptCount = prompts.length;
await commands.get("proactive").handler("maybe", ctx);
assert.equal(prompts.length, proactivePromptCount);
writeFileSync(`${home}/state/.lock`, "1\n");
await commands.get("proactive").handler("on", ctx);
assert.equal(prompts.length, proactivePromptCount);
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
console.log("ok - proactive command routes toggle, on, off and status to its skill owner only from the owning session");
prompts.splice(proactivePromptCount - 4);

usage = { contextWindow: 200000, tokens: null };
assert.equal(await fire("turn_end", turn), undefined);
settings = { compaction: { enabled: false } }; usage.tokens = 190000;
assert.equal(await fire("turn_end", turn), undefined);
settings = { compaction: { modelOverrides: { "test/model": { reserveTokens: 40000, keepRecentTokens: 40000 } } } };
usage.tokens = 110000;
assert.equal(await fire("turn_end", turn), undefined);
usage.tokens = 125000;
pending = true; assert.equal(await fire("turn_end", turn), undefined); pending = false;
writeFileSync(`${home}/state/.afk-contract`, "posture sentinel");
assert.equal(await fire("turn_end", turn), undefined); rmSync(`${home}/state/.afk-contract`);
writeFileSync(`${home}/state/.lock`, "1\n");
assert.equal(await fire("turn_end", turn), undefined); writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const first = await fire("turn_end", turn);
assert.equal(first.continue, true); assert.equal(first.entries.length, 1);
assert.match(first.entries[0].content, /^\u2063FIRSTMATE_OP: v1 stow:/);
assert.equal(first.entries[0].type, "custom_message");
assert.equal(await fire("turn_end", turn), undefined);
assert.equal(prompts.length, 2); // no competing synthetic user turn
assert.equal((await receipt()).isError, false);
assert.equal(latest().phase, "saved");
assert.equal((await receipt()).isError, true);
await fire("session_compact_failed", { reason: "threshold", aborted: true });
assert.match(notices.at(-1), /^Saved; native compaction failed/);
assert.equal(latest().phase, "saved");
await fire("session_compact", { reason: "threshold", willRetry: false });
assert.equal(latest().phase, "compacted");
assert.equal(messages.length, 0); assert.equal(compactCalls, 0);
console.log("ok - early model-aware stow is one native boundary continuation; verified save and compact failure remain distinct");

// Oversized result/overflow must retain native retry ownership; no cancellation
// hook and no manual resume message exists in this extension.
const next = await fire("turn_end", turn); assert.equal(next.continue, true);
await fire("session_compact", { reason: "overflow", willRetry: true });
assert.equal(latest().phase, "requested");
assert.equal(hooks.has("session_before_compact"), false);
assert.equal(await fire("turn_end", turn), undefined);
assert.equal(messages.length, 0); assert.equal(compactCalls, 0);
await fire("agent_settled", { aborted: true });
assert.equal(latest().phase, "incomplete");
console.log("ok - overflow keeps native retry and queued input ownership; incomplete save does not retry");

await commands.get("stow").handler("save-only", ctx);
assert.equal(messages.length, 1); assert.equal(latest().saveOnly, true);
assert.equal(messages[0].options.triggerTurn, true);
await commands.get("stow").handler("", ctx);
assert.equal(messages.length, 1);
budgetFailure = true;
assert.equal((await receipt()).isError, true); budgetFailure = false;
assert.equal(latest().phase, "incomplete");
await commands.get("stow").handler("", ctx);
assert.equal(messages.length, 2);
assert.equal((await receipt({ pending: ["unreachable memory tier"] })).isError, true);
assert.equal(latest().phase, "incomplete");
await commands.get("stow").handler("", ctx);
writeFileSync(`${home}/config/startup-memory-budget`, "1\n");
assert.equal((await receipt()).isError, true);
writeFileSync(`${home}/config/startup-memory-budget`, "18000\n");
await commands.get("stow").handler("", ctx);
assert.equal((await receipt({ owners: ["missing-file"] })).isError, true);
console.log("ok - save-only, duplicate request, unreachable tier, unreadable/over budget and missing owners fail safely");

onWait = () => { pending = true; };
const count = messages.length;
await commands.get("stow").handler("", ctx);
assert.equal(messages.length, count); pending = false; onWait = () => {};
await commands.get("stow").handler("", ctx);
const oldReceipt = latest().id;
await fire("session_start", { reason: "resume" });
assert.equal((await receipt({ episode: oldReceipt })).isError, true);
assert.equal(await fire("turn_end", turn), undefined);
// A fresh session and fork do not inherit an old request as permission.
sid = "fork-session";
await fire("session_start", { reason: "fork" });
usage.tokens = null;
assert.equal(await fire("turn_end", turn), undefined);
await commands.get("stow").handler("", ctx);
await fire("agent_settled", { aborted: true });
assert.equal(latest().phase, "incomplete");
assert.equal(await fire("turn_end", turn), undefined);
// Branch navigation within one session also invalidates a receipt whose
// request is no longer on the active branch.
await commands.get("stow").handler("", ctx);
const abandoned = branch.splice(0);
assert.equal((await receipt({ episode: abandoned.at(-1).data.id })).isError, true);
branch.push(...abandoned);
assert.equal((await receipt()).isError, false);
await fire("turn_end", { ...turn, toolResults: [{ isError: true }] });
assert.equal(latest().phase, "incomplete");
await fire("session_shutdown", { reason: "new" });
assert.equal((await receipt()).isError, true);
assert.equal(compactCalls, 0);
assert.equal(prompts.length, 2);
assert.ok(waits > 1);
console.log("ok - input race defers stow, resume/fork reject stale receipts, aborted run retains incomplete work, no invented resume");

// Model the observed ordering with Pi's real in-memory entry tree. This is a
// simulated success event, not a summarizer or a live compaction/model call.
const compactDuringSave = async (reason = "threshold", willRetry = false) => {
  sdkSession = SessionManager.inMemory(home);
  install(pi);
  await fire("session_start");
  usage.tokens = 125000;
  const request = await fire("turn_end", turn);
  assert.equal(request.continue, true);
  const requested = latest();
  const kept = sdkSession.appendMessage({ role: "user", content: "fixture recent input", timestamp: Date.now() });
  const id = sdkSession.appendCompaction("fixture summary", kept, 125000);
  const compactionEntry = sdkSession.getEntry(id);
  assert.ok(sdkSession.getBranch().some(entry => entry.data?.id === requested.id));
  assert.ok(!sdkSession.buildContextEntries().some(entry => entry.data?.id === requested.id));
  await fire("session_compact", { compactionEntry, reason, willRetry, fromExtension: false });
  return requested.id;
};

for (const [reason, willRetry] of [["threshold", false], ["overflow", true]]) {
  const before = [messages.length, prompts.length];
  const id = await compactDuringSave(reason, willRetry);
  assert.equal(latest().phase, "requested");
  pending = true; // Input remains owned by Pi's existing queue.
  const accepted = await receipt({ episode: id });
  assert.equal(accepted.isError, false);
  assert.match(accepted.content[0].text, /Native compaction already occurred during this save/);
  assert.equal(latest().phase, "saved");
  assert.equal((await receipt({ episode: id })).isError, true);
  assert.equal(await fire("turn_end", turn), undefined);
  assert.equal(latest().phase, "compacted");
  assert.deepEqual([messages.length, prompts.length], before);
  assert.equal(await fire("turn_end", turn), undefined);
  pending = false;
  // Retirement permits the next early-save cycle without a second compact.
  assert.equal((await fire("turn_end", turn)).continue, true);
  assert.notEqual(latest().id, id);
}
console.log("ok - same-run threshold/overflow compaction preserves the pending receipt across the real Pi tree, retires after the batch, and queues no replay");

for (const overrides of [{ complete: false }, { pending: ["unfiled capture"] }, { owners: ["missing-file"] }]) {
  await compactDuringSave();
  assert.equal((await receipt(overrides)).isError, true);
  assert.equal(latest().phase, "incomplete");
  assert.equal((await receipt()).isError, true);
}
await compactDuringSave();
budgetFailure = true;
assert.equal((await receipt()).isError, true);
budgetFailure = false;
assert.equal(latest().phase, "incomplete");
await compactDuringSave();
assert.equal((await receipt()).isError, false);
await fire("turn_end", { ...turn, toolResults: [{ isError: true }] });
assert.equal(latest().phase, "incomplete");
assert.equal((await receipt()).isError, true);
console.log("ok - compaction alone verifies nothing; incomplete capture, owner, budget and sibling failures still refuse completion");

const stale = await compactDuringSave();
await fire("session_start", { reason: "resume" });
assert.equal((await receipt({ episode: stale })).isError, true);
const owned = await compactDuringSave();
writeFileSync(`${home}/state/.lock`, "1\n");
assert.equal((await receipt({ episode: owned })).isError, true);
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const ownedSession = sdkSession;
sdkSession = SessionManager.inMemory(home);
assert.equal((await receipt({ episode: owned })).isError, true);
sdkSession = ownedSession;
await fire("agent_settled", { aborted: true });
assert.equal(latest().phase, "incomplete");
assert.equal((await receipt({ episode: owned })).isError, true);
assert.equal(compactCalls, 0);
console.log("ok - compacted requests still reject resumed, foreign-session, foreign-lock and settled receipts");
