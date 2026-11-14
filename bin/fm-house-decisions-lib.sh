#!/usr/bin/env bash
# fm-house-decisions-lib.sh - the home's house-decision record (one owner).
#
# WHY. A worker files anything above its own authority as a keyed
# `needs-decision` line, and firstmate answers it. Some of those asks are the
# captain's (a product choice, a scope change). Others are firstmate's own: the
# home already has a rule that settles them, such as who gets the next
# full-test-suite slot or GPU window. Without a record saying which is which,
# the supervision session can only guess, and a guess that holds a routine ask
# "for the captain" stalls the fleet for as long as the captain is away.
#
# CONTRACT.
#   - Record: <config>/house-decisions, home-local and gitignored. Absent means
#     the home has registered no house decision and every caller behaves as it
#     did before this record existed.
#   - Format: one rule per line, "<key>: <rule>". <key> is the decision key a
#     worker uses in `needs-decision [key=<key>]` (characters A-Z a-z 0-9 . _ -)
#     and <rule> is the non-empty sentence firstmate applies. Blank lines and
#     lines starting with "#" are ignored.
#   - A registered key is firstmate's to answer in every posture, by either
#     supervision actor, exactly as the rule says. It grants nothing else: no
#     merge, landing, spawn, or captain authority reads this record, and a key
#     that is not registered keeps its ordinary decision handling.
#   - `default` (the keyless decision) can never be registered, because a
#     keyless ask cannot be told apart from any other keyless ask.
#   - A malformed record (an invalid or reserved key, an empty rule, a line
#     with no ": " separator, or a key registered twice) registers nothing at
#     all: every lookup fails closed with status 2 and one diagnostic line.
#
# CONSUMERS. bin/fm-send.sh lets the supervision branch answer a registered
# key while attended; bin/fm-wake-drain.sh prints the rule beside an open
# decision that carries a registered key. bin/fm-branch-prompt.sh "House
# decisions" owns how the supervision session applies a rule.
#
# Sourced by those scripts and by tests. No side effects on source.

# fm_house_decisions_file <config-dir>: the record's path.
fm_house_decisions_file() {  # <config-dir>
  printf '%s/house-decisions\n' "$1"
}

# fm_house_decision_rule <config-dir> <key>: print the registered rule for
# <key>. Status 0 when registered, 1 when not (including no record), 2 when the
# record is malformed, with the reason on stderr.
fm_house_decision_rule() {  # <config-dir> <key>
  local file key=$2 line lineno=0 k rule found='' seen=' '
  file=$(fm_house_decisions_file "$1")
  [ -e "$file" ] || return 1
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    echo "error: house-decision record $file is not a readable regular file; no key is treated as a house decision" >&2
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *': '*) ;;
      *)
        echo "error: house-decision record $file line $lineno has no '<key>: <rule>' separator; no key is treated as a house decision" >&2
        return 2
        ;;
    esac
    k=${line%%': '*}
    rule=${line#*': '}
    case "$k" in
      ''|default|*[!A-Za-z0-9._-]*)
        echo "error: house-decision record $file line $lineno has an invalid or reserved key; no key is treated as a house decision" >&2
        return 2
        ;;
    esac
    case "$rule" in
      *[![:space:]]*) ;;
      *)
        echo "error: house-decision record $file line $lineno has an empty rule; no key is treated as a house decision" >&2
        return 2
        ;;
    esac
    case "$seen" in
      *" $k "*)
        echo "error: house-decision record $file registers key '$k' twice; no key is treated as a house decision" >&2
        return 2
        ;;
    esac
    seen="$seen$k "
    [ "$k" != "$key" ] || found=$rule
  done < "$file"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}
