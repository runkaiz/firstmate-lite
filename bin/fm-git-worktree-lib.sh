#!/usr/bin/env bash
# Native task copies. Callers hold the existing project allocation/cleanup lock.
# config/worktree-allocator: absent/treehouse (unchanged default), or git.
# config/git-worktree-root: required absolute, private directory outside the
# project and its primary checkout. No pool, recycling, reset, clean or force.
# state/<id>.git-worktree is the sole ownership/reservation record, published
# before git worktree add. A failed/interrupted add retains both reservation and
# copy; a fresh spawn resumes only that exact clean copy at its recorded base.
# Fields (exactly one each): schema, task, home, project, common, root, path,
# base, source_ref. Metadata allocator=git selects this lifecycle permanently;
# absent allocator means legacy Treehouse, independently of current config.
# Removal requires matching identity and no dirt/untracked (including ignored).
# Without a teardown-owned delivery predicate, HEAD must be contained in the
# current recorded source ref or equal the original base. The unchanged-base
# path preserves that commit at refs/firstmate/retained-bases/<base> before
# removal; the original source ref is never rewritten. Teardown owns explicit
# delivery proofs; those predicates run independently of source-ref refresh.
# fm_git_worktree_pin is the only custody-ref writer: create-only, and an
# existing ref must already name the same commit.
# fm_git_worktree_preserve is the only way leftovers leave a copy: it renames
# exactly the named untracked or ignored paths, on the same filesystem and never
# over an existing destination, into a private preservation root, and refuses
# before moving anything when tracked edits exist, a name is tracked, unsafe or
# missing, or any leftover is not covered by a name; a named directory holding
# tracked content expands to its leftover roots. Each path's pre-move
# manifest (relative path, inode, mode, size, sha256 or link target) is journaled
# before the rename and must match after it before the path is receipted, so a
# rerun after interruption verifies and receipts a moved path instead of
# overwriting or losing it. Which leftovers are disposable task-owned generated
# artifacts is the caller's judgment; this primitive only moves, never deletes.
# Remote ancestry checks refresh only the recorded origin branch and refuse on
# fetch failure; local refs are not fetched. Never deletes a branch. Task-record retirement/replay
# in fm-backlog-transition-lib.sh owns final reservation retirement when task
# metadata or a pending-close marker remains after copy removal.

fm_git_worktree_error() { printf 'error: native worktree: %s\n' "$*" >&2; return 1; }

fm_git_worktree_config() { # <config-dir> -> allocator
  local value=treehouse
  if [ -e "$1/worktree-allocator" ] || [ -L "$1/worktree-allocator" ]; then
    [ -f "$1/worktree-allocator" ] && [ ! -L "$1/worktree-allocator" ] || return 1
    value=$(cat "$1/worktree-allocator") || return 1
  fi
  case "$value" in treehouse|git) printf '%s\n' "$value" ;; *) fm_git_worktree_error 'invalid config/worktree-allocator (expected treehouse or git)' ;; esac
}

fm_git_worktree_meta_allocator() { # <meta> <native-reservation> -> pinned allocator
  local count value=treehouse
  count=$(grep -c '^allocator=' "$1" || true)
  case "$count" in
    0) ;;
    1) value=$(sed -n 's/^allocator=//p' "$1") ;;
    *) fm_git_worktree_error 'ambiguous recorded allocator'; return 1 ;;
  esac
  case "$value" in treehouse|git) ;; *) fm_git_worktree_error 'unknown recorded allocator'; return 1 ;; esac
  if [ "$value" != git ] && { [ -e "$2" ] || [ -L "$2" ]; }; then
    fm_git_worktree_error 'recorded allocator conflicts with retained native reservation'; return 1
  fi
  printf '%s\n' "$value"
}

fm_git_worktree_field() { # <record> <key>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  [ "$(awk -F= -v k="$2" '$1==k {n++} END {print n+0}' "$1")" = 1 ] || return 1
  sed -n "s/^$2=//p" "$1"
}

fm_git_worktree_private_dir() { # <existing-dir>
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
  [ -z "$(find "$1" -prune \( -perm -g=w -o -perm -o=w \) -print)" ]
}

fm_git_worktree_identity() { # <state> <id> <home> <project> [<expected-path>]
  local record="$1/$2.git-worktree" key value home project common root container path top linked registered
  for key in schema task home project common root path base source_ref; do
    value=$(fm_git_worktree_field "$record" "$key") && [ -n "$value" ] || {
      fm_git_worktree_error "unreadable ownership field $key in $record"; return 1;
    }
  done
  [ "$(wc -l < "$record" | tr -d ' ')" = 9 ] || return 1
  [ "$(fm_git_worktree_field "$record" schema)" = fm-git-worktree.v1 ] || return 1
  [ "$(fm_git_worktree_field "$record" task)" = "$2" ] || return 1
  home=$(cd "$3" && pwd -P) && project=$(cd "$4" && pwd -P) || return 1
  [ "$(fm_git_worktree_field "$record" home)" = "$home" ] &&
    [ "$(fm_git_worktree_field "$record" project)" = "$project" ] || {
      fm_git_worktree_error 'foreign task/home/project ownership'; return 1;
    }
  common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir) || return 1
  common=$(cd "$common" && pwd -P) || return 1
  [ "$(fm_git_worktree_field "$record" common)" = "$common" ] || return 1
  root=$(fm_git_worktree_field "$record" root)
  path=$(fm_git_worktree_field "$record" path)
  container="$root/$2"
  [ "$path" = "$container/worktree" ] || return 1
  [ -z "${5:-}" ] || [ "$5" = "$path" ] || return 1
  fm_git_worktree_private_dir "$root" || return 1
  if [ -e "$container" ] || [ -L "$container" ]; then
    fm_git_worktree_private_dir "$container" || return 1
  fi
  [ "$(cd "$root" && pwd -P)" = "$root" ] || return 1
  case "$root/" in "$project/"*|"${common%/*}/"*|"$home/"*) return 1 ;; esac
  registered=$(git -C "$project" worktree list --porcelain) || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    if fm_git_worktree_private_dir "$path" &&
      [ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)" ] &&
      ! grep -Fxq "worktree $path" <<< "$registered"; then
      FM_GIT_WORKTREE_PATH=$path
      return 0
    fi
    [ -d "$path" ] && [ ! -L "$path" ] && [ -f "$path/.git" ] && [ ! -L "$path/.git" ] || return 1
    top=$(git -C "$path" rev-parse --show-toplevel) || return 1
    [ "$top" = "$path" ] || return 1
    linked=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir) || return 1
    [ "$(cd "$linked" && pwd -P)" = "$common" ] || return 1
    grep -Fxq "worktree $path" <<< "$registered" || return 1
  elif grep -Fxq "worktree $path" <<< "$registered"; then
    fm_git_worktree_error 'missing copy is still registered; preserving reservation'; return 1
  fi
  FM_GIT_WORKTREE_PATH=$path
}

# Collapse leftovers to their minimal roots (shallowest ancestor holding no
# tracked content) as "<count>\t<root>"; optionally only the NUL-separated
# <paths-file>, and optionally write every leftover to <full-list-file>. Read-only.
fm_git_worktree_leftover_roots() { # <copy> [<paths-file>] [<full-list-file>]
  local copy=$1 paths=${2:-} list=${3:-} tracked own=0 rc=0
  tracked=$(mktemp) || return 1
  if [ -z "$paths" ]; then
    paths=$(mktemp) || { rm -f "$tracked"; return 1; }
    own=1
    git -C "$copy" ls-files -z --others > "$paths" || rc=1
  fi
  [ "$rc" = 0 ] && git -C "$copy" ls-files -z > "$tracked" || rc=1
  if [ "$rc" = 0 ]; then
    perl -e '
      use strict; use warnings;
      my ($tracked, $paths, $list) = @ARGV; my (%dir, %count); local $/ = "\0";
      open(my $t, "<", $tracked) or die "$!\n";
      while (my $p = <$t>) { chomp $p; my @c = split m{/}, $p; pop @c;
        my $pre = ""; for (@c) { $pre .= ($pre eq "" ? "" : "/") . $_; $dir{$pre} = 1 } }
      open(my $in, "<", $paths) or die "$!\n";
      my $out; if ($list ne "") { open($out, ">", $list) or die "$!\n" }
      my %seen;
      while (my $p = <$in>) { chomp $p; $p =~ s{/+$}{}; next if $p eq "" || $seen{$p}++;
        print $out "$p\n" if $out;
        my $root = ""; for (split m{/}, $p) { $root .= ($root eq "" ? "" : "/") . $_; last unless $dir{$root} }
        $count{$root}++ }
      if ($out) { close($out) or die "$!\n" }
      print "$count{$_}\t$_\n" for sort keys %count;
    ' "$tracked" "$paths" "$list" || rc=1
  fi
  rm -f "$tracked"
  [ "$own" = 0 ] || rm -f "$paths"
  return "$rc"
}

fm_git_worktree_print_roots() { # reads "<count>\t<root>" lines; prints a bounded summary to stderr
  awk -F '\t' '
    NR <= 20 { printf "  %s (%d file%s)\n", $2, $1, ($1 == 1 ? "" : "s") }
    END { if (NR > 20) printf "  ... and %d more root(s)\n", NR - 20 }
  ' >&2
}

fm_git_worktree_clean() { # <path> - unknown ignored files are work too
  local status others tracked_changes
  status=$(git -C "$1" status --porcelain --untracked-files=all) || return 1
  others=$(git -C "$1" ls-files --others) || return 1
  if [ -n "$status$others" ]; then
    fm_git_worktree_error "dirty or untracked content at $1; preserving copy"
    tracked_changes=$(printf '%s\n' "$status" | sed -e '/^$/d' -e '/^?? /d')
    if [ -n "$tracked_changes" ]; then
      printf 'Tracked changes (unique work; never preserved):\n' >&2
      printf '%s\n' "$tracked_changes" | head -20 >&2
    fi
    if [ -n "$others" ]; then
      printf 'Untracked or ignored leftovers, by top-level root:\n' >&2
      fm_git_worktree_leftover_roots "$1" | fm_git_worktree_print_roots
    fi
    printf 'Inspect these paths, including ignored session evidence; only task-owned generated artifacts may be preserved through fm-teardown.sh --preserve-untracked.\n' >&2
    return 1
  fi
}

fm_git_worktree_allocate() { # <state> <id> <home> <project> <root> <base-commit> <source-ref>
  local state=$1 id=$2 home=$3 project=$4 root=$5 base=$6 source_ref=$7 record common tmp parent processes
  case "$id" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  for tmp in "$home" "$project" "$root" "$source_ref"; do
    case "$tmp" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  done
  home=$(cd "$home" && pwd -P) && project=$(cd "$project" && pwd -P) || return 1
  record="$state/$id.git-worktree"
  if [ -e "$state/$id.backlog-close" ] || [ -L "$state/$id.backlog-close" ]; then
    fm_git_worktree_error 'task retirement is pending; finish teardown or its recorded replay first'; return 1
  fi
  if [ -e "$state/$id.meta" ] || [ -L "$state/$id.meta" ]; then
    fm_git_worktree_error 'task metadata already exists; use guarded task relaunch'; return 1
  fi
  case "$root" in /*) ;; *) fm_git_worktree_error 'git-worktree-root must be absolute'; return 1 ;; esac
  parent=$(cd "$(dirname "$root")" && pwd -P) || return 1
  root="$parent/$(basename "$root")"
  case "$source_ref" in refs/heads/*|refs/remotes/origin/*) ;; *) return 1 ;; esac
  [ "$(git -C "$project" rev-parse --verify "$source_ref^{commit}")" = "$base" ] || {
    fm_git_worktree_error 'requested base does not match source ref; inspect source before retrying'; return 1;
  }
  if [ -e "$record" ] || [ -L "$record" ]; then
    fm_git_worktree_identity "$state" "$id" "$home" "$project" "$root/$id/worktree" || {
      fm_git_worktree_error "reservation identity cannot be proved; inspect $record and its copy"; return 1;
    }
    # Resume the reservation, never replace/rebase an interrupted copy.
    [ "$(fm_git_worktree_field "$record" source_ref)" = "$source_ref" ] || {
        fm_git_worktree_error 'reserved source changed; preserving copy rather than rebasing recovery'; return 1;
      }
    base=$(fm_git_worktree_field "$record" base) || return 1
    if ! git -C "$project" cat-file -e "$base^{commit}" ||
      ! git -C "$project" merge-base --is-ancestor "$base" "$source_ref"; then
      fm_git_worktree_error 'reserved base is missing or source history was rewritten; inspect reservation before retrying'; return 1
    fi
    if [ -d "$FM_GIT_WORKTREE_PATH" ]; then
      processes=$(lsof -a -d cwd -Fn 2>/dev/null) || {
        fm_git_worktree_error 'cannot prove reserved copy has no live owner (lsof failed); preserving copy'; return 1;
      }
      if printf '%s\n' "$processes" | awk -v path="n$FM_GIT_WORKTREE_PATH" \
        '$0 == path || index($0, path "/") == 1 {found=1} END {exit !found}'; then
        fm_git_worktree_error 'reserved copy has a live process owner; stop its lifecycle before retrying'; return 1
      fi
    fi
  else
    common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir) || return 1
    common=$(cd "$common" && pwd -P) || return 1
    case "$root/" in "$project/"*|"${common%/*}/"*|"$home/"*) fm_git_worktree_error 'root is inside project/primary/home'; return 1 ;; esac
    if [ ! -e "$root" ]; then (umask 077; mkdir "$root") || return 1; fi
    fm_git_worktree_private_dir "$root" || return 1
    [ "$(cd "$root" && pwd -P)" = "$root" ] || return 1
    git -C "$project" cat-file -e "$base^{commit}" || return 1
    if [ -e "$root/$id" ] || [ -L "$root/$id" ]; then
      fm_git_worktree_error 'task path already exists without this reservation'; return 1
    fi
    FM_GIT_WORKTREE_PATH="$root/$id/worktree"
    tmp=$(mktemp "$state/.$id.git-worktree.XXXXXXXX") || return 1
    {
      printf 'schema=fm-git-worktree.v1\ntask=%s\nhome=%s\nproject=%s\ncommon=%s\nroot=%s\npath=%s\nbase=%s\nsource_ref=%s\n' \
        "$id" "$home" "$project" "$common" "$root" "$FM_GIT_WORKTREE_PATH" "$base" "$source_ref"
    } > "$tmp"
    mv "$tmp" "$record" || return 1
  fi
  if [ ! -d "$root/$id" ]; then (umask 077; mkdir "$root/$id") || return 1; fi
  if [ ! -e "$FM_GIT_WORKTREE_PATH/.git" ]; then
    git -C "$project" worktree add --detach "$FM_GIT_WORKTREE_PATH" "$base" || return 1
  fi
  fm_git_worktree_identity "$state" "$id" "$home" "$project" || return 1
  if git -C "$FM_GIT_WORKTREE_PATH" symbolic-ref -q HEAD >/dev/null ||
    [ "$(git -C "$FM_GIT_WORKTREE_PATH" rev-parse HEAD)" != "$base" ] ||
    ! fm_git_worktree_clean "$FM_GIT_WORKTREE_PATH"; then
    fm_git_worktree_error 'interrupted copy changed; preserving it for recovery'; return 1
  fi
}

fm_git_worktree_safe() { # <state> <id> <home> <project> <expected-path> [<landed-function>]
  fm_git_worktree_identity "$@" || return 1
  [ -d "$FM_GIT_WORKTREE_PATH" ] || return 0 # confirmed unregistered removal/reservation recovery
  fm_git_worktree_clean "$FM_GIT_WORKTREE_PATH" || return 1
  fm_git_worktree_landed "$@"
}

fm_git_worktree_pin() { # <project> <ref> <commit> - create-only custody ref
  if ! git -C "$1" show-ref --verify --quiet "$2"; then
    git -C "$1" update-ref "$2" "$3" '' || return 1
  fi
  [ "$(git -C "$1" rev-parse --verify "$2^{commit}")" = "$3" ]
}

# An unchanged copy (HEAD equals the reservation's recorded base) holds no task
# commits, whatever later happened to its source ref. The base stays in Git
# custody at refs/firstmate/retained-bases/<base>. Callers run identity first.
fm_git_worktree_unchanged_base() { # <state> <id> <project>
  local base
  base=$(fm_git_worktree_field "$1/$2.git-worktree" base) || return 1
  [ "$(git -C "$FM_GIT_WORKTREE_PATH" rev-parse HEAD)" = "$base" ] || return 1
  fm_git_worktree_pin "$3" "refs/firstmate/retained-bases/$base" "$base"
}

fm_git_worktree_landed() { # same arguments as safe; landing proof only, no dirt gate
  local ref
  fm_git_worktree_identity "$@" || return 1
  [ -d "$FM_GIT_WORKTREE_PATH" ] || return 0
  ref=$(fm_git_worktree_field "$1/$2.git-worktree" source_ref) || return 1
  case "$ref" in refs/heads/*|refs/remotes/origin/*) ;; *) return 1 ;; esac
  git check-ref-format "$ref" || return 1
  # A ship's explicit delivery predicate owns its publication contract; it may
  # itself accept the unchanged-base proof below (local-only does).
  if [ -z "${6:-}" ] && fm_git_worktree_unchanged_base "$1" "$2" "$4"; then
    return 0
  fi
  if [ -n "${6:-}" ]; then
    if ! declare -F "$6" >/dev/null || ! "$6"; then
      fm_git_worktree_error 'task delivery is not proven landed; preserving copy'; return 1
    fi
    return 0
  fi
  case "$ref" in
    refs/heads/*) ;;
    refs/remotes/origin/*)
      git -C "$4" fetch --no-tags --no-write-fetch-head origin "refs/heads/${ref#refs/remotes/origin/}:$ref" || {
        fm_git_worktree_error 'recorded remote source could not be refreshed; preserving copy'; return 1;
      }
      ;;
    *) return 1 ;;
  esac
  git -C "$4" show-ref --verify --quiet "$ref" || return 1
  if ! git -C "$FM_GIT_WORKTREE_PATH" merge-base --is-ancestor HEAD "$ref"; then
    fm_git_worktree_error "unlanded HEAD is not contained in $ref; preserving copy"; return 1
  fi
}

fm_git_worktree_manifest() { # <path> - sorted custody manifest; unreadable entries fail
  perl -MFile::Find -MDigest::SHA -e '
    use strict; use warnings;
    local $SIG{__WARN__} = sub { die @_ };
    my $root = shift; my @out;
    sub esc { my $s = shift; $s =~ s/([\x00-\x1f\\])/sprintf("\\x%02x", ord $1)/ge; $s }
    sub emit {
      my ($p, $rel) = @_;
      my @s = lstat($p) or die "cannot stat $p: $!\n";
      my $kind = -l _ ? "l:" . esc(readlink($p) // die "cannot read link $p: $!\n")
        : -d _ ? "d" : -f _ ? "f:$s[7]:" . Digest::SHA->new(256)->addfile($p)->hexdigest : "o";
      push @out, join("\t", esc($rel), $s[1], $s[2], $kind);
    }
    if (-d $root && !-l $root) {
      find({ no_chdir => 1, wanted => sub {
        my $rel = substr($File::Find::name, length $root); emit($File::Find::name, ".$rel");
      } }, $root);
    } else { emit($root, ".") }
    print "$_\n" for sort @out;
  ' "$1"
}

fm_git_worktree_preserve() { # <copy> <preservation-root> <relative-path>... - caller proved identity, landing, quiescence
  local copy=$1 root=$2 rel other part prefix entry status=0 status_file others_file uncovered=0 key journal src dst pre post sum
  local roots_out count journaled jfile
  local -a leftovers=() parts=() names=() found=() uncovered_paths=()
  FM_GIT_WORKTREE_UNCOVERED=0
  shift 2
  [ "$#" -gt 0 ] || { fm_git_worktree_error 'no leftover named for preservation'; return 1; }
  [ -d "$copy" ] && [ ! -L "$copy" ] || { fm_git_worktree_error 'copy is missing; nothing preserved'; return 1; }
  case "$root" in /*) ;; *) fm_git_worktree_error 'preservation root must be absolute'; return 1 ;; esac
  # A named directory holding tracked content stands for the leftover roots
  # under it (plus journaled paths an interrupted run moved); each faces the
  # checks below as if named.
  roots_out=
  for rel in "$@"; do
    case "/$rel/" in //*|*//*|*/./*|*/../*) fm_git_worktree_error "unsafe leftover name '$rel'; nothing moved"; return 1 ;; esac
    case "$rel" in *[[:cntrl:]]*) fm_git_worktree_error 'leftover name has control characters; nothing moved'; return 1 ;; esac
    entry=$(git -C "$copy" ls-files -- ":(literal)$rel") || return 1
    if [ -z "$entry" ] || [ ! -d "$copy/$rel" ] || [ -L "$copy/$rel" ]; then
      names+=("$rel"); continue
    fi
    if [ -z "$roots_out" ]; then
      roots_out=$(fm_git_worktree_leftover_roots "$copy") || { fm_git_worktree_error 'cannot read copy leftovers; nothing moved'; return 1; }
      [ -n "$roots_out" ] || roots_out=$'\n'
    fi
    found=()
    while IFS=$'\t' read -r count entry; do
      case "$entry" in "$rel"/*) found+=("$entry") ;; esac
    done <<< "$roots_out"
    for jfile in "$root"/journal/*; do
      [ -f "$jfile" ] || continue
      case "$jfile" in *.tmp) continue ;; esac
      journaled=$(head -n 1 -- "$jfile") || return 1
      journaled=${journaled#path$'\t'}
      case "$journaled" in "$rel"/*) ;; *) continue ;; esac
      [ ! -e "$copy/$journaled" ] && [ ! -L "$copy/$journaled" ] || continue
      for other in ${found[@]+"${found[@]}"}; do
        case "$journaled" in "$other"|"$other"/*) continue 2 ;; esac
      done
      found+=("$journaled")
    done
    [ "${#found[@]}" -gt 0 ] || { fm_git_worktree_error "'$rel' names tracked content and holds no leftovers; nothing moved"; return 1; }
    printf "'%s' holds tracked content; naming its leftover roots instead: %s\n" "$rel" "${found[*]}" >&2
    names+=("${found[@]}")
  done
  set -- "${names[@]}"
  for rel in "$@"; do
    case "/$rel/" in //*|*//*|*/./*|*/../*) fm_git_worktree_error "unsafe leftover name '$rel'; nothing moved"; return 1 ;; esac
    case "$rel" in *[[:cntrl:]]*) fm_git_worktree_error 'leftover name has control characters; nothing moved'; return 1 ;; esac
    for other in "$@"; do
      [ "$other" = "$rel" ] && continue
      case "$rel" in "$other"/*) fm_git_worktree_error "overlapping leftover names '$other' and '$rel'; nothing moved"; return 1 ;; esac
    done
    [ "$(printf '%s\n' "$@" | grep -Fxc -- "$rel")" = 1 ] || { fm_git_worktree_error "duplicate leftover name '$rel'"; return 1; }
    prefix=$copy
    part=${rel%/*}
    if [ "$part" != "$rel" ]; then
      IFS=/ read -ra parts <<< "$part"
      for entry in "${parts[@]}"; do
        prefix=$prefix/$entry
        [ -d "$prefix" ] && [ ! -L "$prefix" ] || {
          fm_git_worktree_error "'$rel' is not under real directories of the copy; nothing moved"; return 1;
        }
      done
    fi
    entry=$(git -C "$copy" ls-files -- ":(literal)$rel") || return 1
    [ -z "$entry" ] || { fm_git_worktree_error "'$rel' names tracked content; nothing moved"; return 1; }
  done
  status_file=$(mktemp) || return 1
  others_file=$(mktemp) || { rm -f "$status_file"; return 1; }
  if ! git -C "$copy" status --porcelain=v1 -z --untracked-files=all > "$status_file" \
     || ! git -C "$copy" ls-files -z --others > "$others_file"; then
    rm -f "$status_file" "$others_file"
    fm_git_worktree_error 'cannot read copy leftovers; nothing moved'; return 1
  fi
  status=0
  while IFS= read -r -d '' entry; do
    case "$entry" in
      '?? '*) leftovers+=("${entry#?? }") ;;
      *) status=1 ;;
    esac
  done < "$status_file"
  while IFS= read -r -d '' entry; do leftovers+=("$entry"); done < "$others_file"
  rm -f "$status_file" "$others_file"
  [ "$status" = 0 ] || { fm_git_worktree_error 'tracked changes are unique work; nothing moved'; return 1; }
  for entry in ${leftovers[@]+"${leftovers[@]}"}; do
    entry=${entry%/}
    for rel in "$@"; do
      case "$entry" in "$rel"|"$rel"/*) continue 2 ;; esac
    done
    uncovered_paths+=("$entry")
    uncovered=$((uncovered + 1))
  done
  if [ "$uncovered" != 0 ]; then
    uncovered=$(printf '%s\n' "${uncovered_paths[@]}" | LC_ALL=C sort -u | wc -l | tr -d ' ')
    FM_GIT_WORKTREE_UNCOVERED=$uncovered
    printf 'Leftovers not covered by any name, by top-level root:\n' >&2
    others_file=$(mktemp) || return 1
    printf '%s\0' "${uncovered_paths[@]}" > "$others_file"
    fm_git_worktree_leftover_roots "$copy" "$others_file" | fm_git_worktree_print_roots
    rm -f "$others_file"
    fm_git_worktree_error "$uncovered leftover(s) above are not named; nothing moved"; return 1
  fi
  mkdir -p -- "$root/files" "$root/journal" || return 1
  case "$(cd "$root" && pwd -P)/" in "$(cd "$copy" && pwd -P)"/*)
    fm_git_worktree_error 'preservation root is inside the copy'; return 1 ;;
  esac
  for rel in "$@"; do
    src=$copy/$rel dst=$root/files/$rel
    key=$(printf '%s' "$rel" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)') || return 1
    if [ -e "$src" ] || [ -L "$src" ]; then
      if [ -e "$dst" ] || [ -L "$dst" ]; then
        fm_git_worktree_error "preserved '$rel' already exists; nothing overwritten or moved"; return 1
      fi
    elif [ ! -e "$dst" ] && [ ! -L "$dst" ] || [ ! -f "$root/journal/$key" ]; then
      fm_git_worktree_error "'$rel' is neither in the copy nor a journaled preservation; nothing moved"; return 1
    fi
  done
  for rel in "$@"; do
    src=$copy/$rel dst=$root/files/$rel
    key=$(printf '%s' "$rel" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)') || return 1
    journal=$root/journal/$key
    if [ -e "$src" ] || [ -L "$src" ]; then
      pre=$(fm_git_worktree_manifest "$src") || { fm_git_worktree_error "cannot read '$rel'; it stays in the copy"; return 1; }
      printf 'path\t%s\n%s\n' "$rel" "$pre" > "$journal.tmp" && mv -- "$journal.tmp" "$journal" || return 1
      mkdir -p -- "$(dirname -- "$dst")" || return 1
      perl -e 'my ($s, $d) = @ARGV; die "destination exists\n" if -e $d || -l $d; rename($s, $d) or die "$!\n"' "$src" "$dst" || {
        fm_git_worktree_error "could not rename '$rel' within one filesystem; it stays in the copy"; return 1;
      }
    fi
    pre=$(tail -n +2 "$journal") || return 1
    post=$(fm_git_worktree_manifest "$dst") || { fm_git_worktree_error "cannot verify preserved '$rel'"; return 1; }
    [ "$pre" = "$post" ] || { fm_git_worktree_error "preserved '$rel' does not match its journaled manifest"; return 1; }
    sum=$(printf '%s\n' "$pre" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)') || return 1
    if ! awk -F '\t' -v s="$sum" -v p="$rel" '$2 == s && $3 == p { found = 1 } END { exit !found }' "$root/receipt" 2>/dev/null; then
      { [ ! -f "$root/receipt" ] || cat -- "$root/receipt"; printf '%s\t%s\t%s\n' "$(date +%s)" "$sum" "$rel"; } > "$root/receipt.tmp" \
        && mv -- "$root/receipt.tmp" "$root/receipt" || return 1
    fi
    printf 'preserved: %s -> %s\n' "$rel" "$dst" >&2
  done
}

fm_git_worktree_remove() { # same arguments as safe; caller proved endpoint gone/no processes
  local container
  fm_git_worktree_safe "$@" || return 1
  container=${FM_GIT_WORKTREE_PATH%/worktree}
  if [ -d "$FM_GIT_WORKTREE_PATH" ]; then
    git -C "$4" worktree remove -- "$FM_GIT_WORKTREE_PATH" || return 1
  fi
  if [ -d "$container" ]; then rmdir -- "$container" || return 1; fi
  if [ ! -e "$1/$2.meta" ] && [ ! -L "$1/$2.meta" ] \
     && [ ! -e "$1/$2.backlog-close" ] && [ ! -L "$1/$2.backlog-close" ]; then
    rm -- "$1/$2.git-worktree" || return 1
  fi
}
