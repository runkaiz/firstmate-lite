# Validation scope and remaining live evidence

Validated head: 9631eb1464edb598ae982b1b24d6e29d67b70206.

The focused existing tests ran through bin/fm-test-run.sh with TMPDIR inside the worktree. Both exited successfully. They execute the real Firstmate scripts, but use SSH, Herdr, Claude, and forge stand-ins. Their results are portable behavioral regressions, not a live pegasus pilot.

Additional manual checks ran unmodified public Firstmate executables against a marked disposable FM_HOME and throwaway Git repository inside the worktree, without transport or runtime stand-ins. The CLI transcript shows explicit machine opt-in, rejection of malformed configuration and unsupported delivery/runtime choices, generated remote routing, disconnected task declarations retained as done or parked, queue-only steering, raw-key refusal, and pending-journal recovery before a local resolved event. The crash journal and disconnected-link records were disposable persisted protocol inputs, not an actual lost network connection. An initial driver assertion expected blocked for an open decision; the actual correct state is parked, and the assertion was corrected before continuing.

The recorded operator decision requests a final-code pilot in pegasus's own Herdr default session, using a test-only saved machine profile, SSH alias, remote repository, Claude trust, at least ten minutes of connection isolation, commit/status catch-up, steering, local landing, and two-sided cleanup. The current invocation forbids intentional writes outside this worktree, except evidence here. That prevents creating the remote repository/channel/trust state on pegasus and modifying this machine's user-level SSH/Herdr configuration. A workspace-local SSH configuration could avoid the SSH-config write, but cannot avoid the required pegasus writes. A disposable local Herdr/SSH server cannot establish the specifically required pegasus pilot and is explicitly excluded as a substitute by the recorded decision. No live remote launch or remote lifecycle mutation was attempted, and no historical pilot evidence is claimed as evidence from this run.

To finish the required live scenarios, supply a current explicit exception to this invocation's workspace boundary covering only the already approved pegasus pilot artifacts, its test-only local saved Herdr profile/SSH alias, remote Claude trust/session artifacts, and cleanup. Alternatively, provide a test execution environment whose allowed workspace encompasses that disposable remote setup and explicitly permits use of the named personal Herdr session. This is an execution-authority conflict, not a missing CLI or claimed login failure: herdr, ssh, claude, and tmux are on PATH. The Herdr lab helper's machine-add help was inspected read-only; no profile or server was created.

Direct-PR publication remains portable-only under the operator's explicit decision to first exercise live publication on the later slice-2 task. No real push or PR was attempted.

Evidence is CLI output and persisted protocol state. No UI implementation changed; pegasus focus/Claude trust proofs could not be driven, and the accepted pilot also prohibits host screenshots.

No source or test files changed. The disposable manual home, repository, and test temporary directories were removed after validation. No other pipeline phase was executed.
