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
# Removal requires matching identity, no dirt/untracked (including ignored),
# and HEAD contained in the current recorded source ref. Never deletes a branch.

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
  local record="$1/$2.git-worktree" key value home project common root container path top linked
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
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -d "$path" ] && [ ! -L "$path" ] && [ -f "$path/.git" ] && [ ! -L "$path/.git" ] || return 1
    top=$(git -C "$path" rev-parse --show-toplevel) || return 1
    [ "$top" = "$path" ] || return 1
    linked=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir) || return 1
    [ "$(cd "$linked" && pwd -P)" = "$common" ] || return 1
    git -C "$project" worktree list --porcelain | grep -Fxq "worktree $path" || return 1
  elif git -C "$project" worktree list --porcelain | grep -Fxq "worktree $path"; then
    fm_git_worktree_error 'missing copy is still registered; preserving reservation'; return 1
  fi
  FM_GIT_WORKTREE_PATH=$path
}

fm_git_worktree_clean() { # <path> - unknown ignored files are work too
  local status others
  status=$(git -C "$1" status --porcelain --untracked-files=all) || return 1
  others=$(git -C "$1" ls-files --others) || return 1
  [ -z "$status$others" ] || { fm_git_worktree_error "dirty or untracked content at $1; preserving copy"; return 1; }
}

fm_git_worktree_allocate() { # <state> <id> <home> <project> <root> <base-commit> <source-ref>
  local state=$1 id=$2 home=$3 project=$4 root=$5 base=$6 source_ref=$7 record common tmp parent
  case "$id" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  for tmp in "$home" "$project" "$root" "$source_ref"; do
    case "$tmp" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  done
  home=$(cd "$home" && pwd -P) && project=$(cd "$project" && pwd -P) || return 1
  record="$state/$id.git-worktree"
  if [ -e "$record" ] || [ -L "$record" ]; then
    fm_git_worktree_identity "$state" "$id" "$home" "$project" || return 1
    # Resume the reservation, never replace/rebase an interrupted copy.
    [ "$(fm_git_worktree_field "$record" base)" = "$base" ] &&
      [ "$(fm_git_worktree_field "$record" source_ref)" = "$source_ref" ] || {
        fm_git_worktree_error 'reserved source changed; preserving copy rather than rebasing recovery'; return 1;
      }
    base=$(fm_git_worktree_field "$record" base) || return 1
  else
    case "$root" in /*) ;; *) fm_git_worktree_error 'git-worktree-root must be absolute'; return 1 ;; esac
    parent=$(cd "$(dirname "$root")" && pwd -P) || return 1
    root="$parent/$(basename "$root")"
    common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir) || return 1
    common=$(cd "$common" && pwd -P) || return 1
    case "$root/" in "$project/"*|"${common%/*}/"*|"$home/"*) fm_git_worktree_error 'root is inside project/primary/home'; return 1 ;; esac
    if [ ! -e "$root" ]; then (umask 077; mkdir "$root") || return 1; fi
    fm_git_worktree_private_dir "$root" || return 1
    [ "$(cd "$root" && pwd -P)" = "$root" ] || return 1
    git -C "$project" cat-file -e "$base^{commit}" || return 1
    # mkdir refuses any previous/foreign path, including dangling symlinks.
    (umask 077; mkdir "$root/$id") || { fm_git_worktree_error 'task path already exists without this reservation'; return 1; }
    FM_GIT_WORKTREE_PATH="$root/$id/worktree"
    tmp=$(mktemp "$state/.$id.git-worktree.XXXXXXXX") || return 1
    {
      printf 'schema=fm-git-worktree.v1\ntask=%s\nhome=%s\nproject=%s\ncommon=%s\nroot=%s\npath=%s\nbase=%s\nsource_ref=%s\n' \
        "$id" "$home" "$project" "$common" "$root" "$FM_GIT_WORKTREE_PATH" "$base" "$source_ref"
    } > "$tmp"
    mv "$tmp" "$record" || return 1
  fi
  if [ ! -e "$FM_GIT_WORKTREE_PATH" ]; then
    git -C "$project" worktree add --detach "$FM_GIT_WORKTREE_PATH" "$base" || return 1
  fi
  fm_git_worktree_identity "$state" "$id" "$home" "$project" || return 1
  if [ "$(git -C "$FM_GIT_WORKTREE_PATH" rev-parse HEAD)" != "$base" ] ||
    ! fm_git_worktree_clean "$FM_GIT_WORKTREE_PATH"; then
    fm_git_worktree_error 'interrupted copy changed; preserving it for recovery'; return 1
  fi
}

fm_git_worktree_safe() { # <state> <id> <home> <project> <expected-path>
  local ref
  fm_git_worktree_identity "$@" || return 1
  [ -d "$FM_GIT_WORKTREE_PATH" ] || return 0 # confirmed unregistered removal/reservation recovery
  fm_git_worktree_clean "$FM_GIT_WORKTREE_PATH" || return 1
  ref=$(fm_git_worktree_field "$1/$2.git-worktree" source_ref) || return 1
  case "$ref" in refs/heads/*|refs/remotes/origin/*) ;; *) return 1 ;; esac
  if ! git -C "$4" show-ref --verify --quiet "$ref" ||
    ! git -C "$FM_GIT_WORKTREE_PATH" merge-base --is-ancestor HEAD "$ref"; then
    fm_git_worktree_error "unlanded HEAD is not contained in $ref; preserving copy"; return 1
  fi
}

fm_git_worktree_remove() { # same arguments as safe; caller proved endpoint gone/no processes
  local container
  fm_git_worktree_safe "$@" || return 1
  container=${FM_GIT_WORKTREE_PATH%/worktree}
  if [ -d "$FM_GIT_WORKTREE_PATH" ]; then
    git -C "$4" worktree remove -- "$FM_GIT_WORKTREE_PATH" || return 1
  fi
  if [ -d "$container" ]; then rmdir -- "$container" || return 1; fi
  rm -- "$1/$2.git-worktree"
}
