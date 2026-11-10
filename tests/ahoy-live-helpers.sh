#!/usr/bin/env bash
# Shared real-snapshot fixture for opt-in native /ahoy evaluations.

ahoy_live_home() {
  local home=$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  "$ROOT/bin/fm-queue.py" add delivered "Repair the importer retry logic" --kind ship \
    --file "$home/data/backlog.md" >/dev/null || fail "create Ahoy delivery fixture"
  "$ROOT/bin/fm-queue.py" add followup "Publish the importer guide" --kind ship \
    --blocked-by delivered --file "$home/data/backlog.md" >/dev/null || fail "create Ahoy blocked follow-up"
  FM_HOME="$home" "$ROOT/bin/fm-bearings-snapshot.sh" --json --record-look >/dev/null \
    || fail "record Ahoy look before delivery"
  "$ROOT/bin/fm-queue.py" "done" delivered --pr https://github.com/ahoy-lab/example/pull/3 \
    --file "$home/data/backlog.md" >/dev/null || fail "deliver Ahoy fixture"
  cp "$home/data/backlog.md" "$home/queue-before.md"
  cp "$home/state/ahoy-last.json" "$home/look-before.json"
}

ahoy_live_assert() {
  local home=$1 reply=$2
  printf '%s\n' "$reply" | grep -Fq 'https://github.com/ahoy-lab/example/pull/3' \
    || fail "Ahoy omitted the delivered artifact: $reply"
  printf '%s\n' "$reply" | grep -Fq 'Publish the importer guide' \
    || fail "Ahoy omitted the queued follow-up: $reply"
  printf '%s\n' "$reply" | grep -Eiq 'unblock|no longer blocked|blocker.*clear|dependency.*(clear|satisf)' \
    || fail "Ahoy did not describe the existing follow-up becoming unblocked: $reply"
  printf '%s\n' "$reply" | grep -Eiq 'new(ly)? (item.{0,20})?(in the queue|queued)|nothing.{0,30}(in progress|needs.{0,10}(you|decision))|([0-9]+|one) (outside )?contributions?' \
    && fail "Ahoy invented new queued work or emitted empty inventories/counts: $reply"
  cmp -s "$home/queue-before.md" "$home/data/backlog.md" || fail "Ahoy changed the queue"
  cmp -s "$home/look-before.json" "$home/state/ahoy-last.json" && fail "Ahoy did not gather a fresh snapshot"
  jq -e '.rows | any(.key == "next/(main)/followup" and (.value | fromjson) == ["-", "-"])
    and any(.key == "landed/(main)/delivered" and .value == "https://github.com/ahoy-lab/example/pull/3")' \
    "$home/state/ahoy-last.json" >/dev/null || fail "Ahoy did not record current delivery and queue state"
}
