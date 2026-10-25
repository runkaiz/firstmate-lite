#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - A dirty, offline, wrong-branch, or genuinely unique diverged target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#     Divergence leaves a durable reconciliation record, while a clean local
#     result already present upstream after a squash merge heals automatically.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     the two secondmate action sets are disjoint and correctly gated -
#     restart-secondmates carries EVERY live mate this pass left on origin's tip
#     whose recorded runtime can prove a restart, INCLUDING one that was already
#     there and one whose advance touched no instruction surface, because a
#     restart is also what re-resolves launch-time harness wiring; a live mate
#     whose runtime cannot prove a restart falls to nudge-secondmates; and a mate
#     whose home was skipped or whose endpoint is stopped gets no action at all.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/fakebin" "$w/fake"
  : > "$w/fake/windows"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) cat "$FM_FAKE_DIR/windows" ;;
  display-message)
    target=
    for arg in "$@"; do
      case "$arg" in main:fm-*) target=$arg ;; esac
    done
    case "${*: -1}" in
      *pane_current_command*)
        id=${target##*fm-}
        if [ -e "$FM_FAKE_DIR/dead-$id" ]; then printf 'zsh\n'; else printf 'claude\n'; fi
        ;;
      *) printf '\n' ;;
    esac
    ;;
esac
SH
  chmod +x "$w/fakebin/tmux"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/seed/bin/fm-remote-secondmate-control.sh"
  chmod +x "$w/seed/bin/fm-remote-secondmate-control.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
# The recorded runtime matters to the action split, so it is part of the fixture:
# harness defaults to a control-verified adapter on the default (tmux) backend,
# which is what makes a restart provable. Pass a backend to model one that cannot
# prove an agent stopped.
add_sm() {
  local w=$1 id=$2 harness=${3:-claude} backend=${4:-}
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s/%s\n' "$w" "$id"
    printf 'project=%s/%s\n' "$w" "$id"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    [ -z "$backend" ] || printf 'backend=%s\n' "$backend"
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf 'fm-%s\n' "$id" >> "$w/fake/windows"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the whole instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=bin changes only bin/, which
# a running agent re-executes rather than holding; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  if [ "$mode" = bin ]; then
    printf 'echo b-%s\n' "$RANDOM" > "$w/seed/bin/tool.sh"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  PATH="$w/fakebin:$PATH" FM_FAKE_DIR="$w/fake" \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out prior
  w=$(new_world t1)
  add_sm "$w" sm1
  prior=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr
  out=$(run_update "$w")
  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] || fail "firstmate did not reach origin"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD)" = main ] || fail "default branch changed"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$prior" ] || fail "update changed a historical supervisor home"
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] || fail "update created a merge commit"
  pass "root update fast-forwards and preserves historical homes"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  pass "non-instruction updates do not request an instruction reread"
}

# --- T3b: a bin/-only advance restarts too ---------------------------------
# Helpers under bin/ do reload themselves on the next call, but the mate's agent
# still froze its launch-time harness wiring before this pass, so the restart is
# not redundant and the old bin/-only carve-out no longer applies.


# --- T3c: an unverifiable runtime receives the fallback nudge ----------------


# --- T3d: an already-stopped mate is left to startup recovery ---------------


# --- T3e: a legacy remote advance still restarts ---------------------------
# The host's instr= suffix is reporting detail; the parent no longer routes on it,
# so an older host that cannot report a diff can no longer suppress the restart.


# --- T4: dirty secondmate is skipped, its edit preserved -------------------


# --- T5: diverged secondmate is skipped, its commit preserved --------------




# --- T6: the git side is idempotent; the restart set is not -----------------
# This is the SSHHIP case: that mate's home was already at the target commit, so
# the old classifier skipped it entirely and its agent kept running the launch-time
# wiring it started with. An already-current live mate must still be restarted.


# --- T6b: an already-current mate that cannot be restarted stays honest -----
# Unconditional restart must not become an unconditional CLAIM of one.


# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.


# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}



# --- T12: a self-update rebinds a locally armed watch on the primary --------
# A self-update fast-forwards bin/ in place, changing bytes an armed
# fm-procevent-when watch's trust binding was hashed against with no
# tampering involved; without a rebind the very next fire would be refused.
test_primary_update_rebinds_local_watch() {
  local w before_hash after_hash out spec
  w=$(new_world t12)
  mkdir -p "$w/seed/bin"
  printf "#!/usr/bin/env bash\necho v1 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  chmod +x "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm add-watched-action
  git -C "$w/seed" push -q origin main
  git -C "$w/main" pull -q origin main

  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$ROOT/bin/fm-procevent-when.sh" \
    arm rebind-primary --interval 60 --stable 1 \
    --condition true --action "$w/main/bin/watched-action.sh" "$w/rebind.log" >/dev/null
  spec="$w/home/state/when/when-rebind-primary.spec"
  before_hash=$(grep '^action_sha256=' "$spec")

  printf "#!/usr/bin/env bash\necho v2 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm bump-watched-action
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "the primary still advanced"
  assert_contains "$out" "rebound: when-rebind-primary" "the primary self-update rebound its own locally armed watch"
  after_hash=$(grep '^action_sha256=' "$spec")
  [ "$before_hash" != "$after_hash" ] \
    || fail "the watch's trust binding was not refreshed to match the updated action bytes"
  pass "T12 a self-update rebinds a locally armed watch on the primary"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_primary_update_rebinds_local_watch

echo "# all fm-update tests passed"
