#!/usr/bin/env bash
# Parallax pre-push / post-commit guard (v0.39 §5.2 D2 + §5.6) — mechanizes the detached-HEAD and
# moving-main checks the owner was doing BY HAND on the monorepo (parallax-errors.md:166/168).
#
# The live hazard (RUN-A): the feature worktree went DETACHED, its branch ref silently lagged
# (branch at 5b42b36 while HEAD advanced to 56a223d), so "a push at that point would have shipped an
# INCOMPLETE PR" — caught by a manual `git rev-parse` assertion, not by the machinery. And
# `origin/main` moved twice mid-run, so a naive push could be a non-fast-forward. This guard makes
# both fail closed.
#
# Subcommands (each fails CLOSED with exit 2 on violation; exit 3 on bad input):
#   ref-current <repo> <branch> [<expected-oid>]
#       assert `git rev-parse <branch>` == HEAD (or == <expected-oid>) — the branch ref is CURRENT,
#       not lagging behind a detached HEAD. Run after every commit before treating a slice as done.
#   ancestor <repo> <base-ref> <tip> [--fetch <remote> <remote-ref>]
#       assert <base-ref> is an ANCESTOR of <tip> — the push is a fast-forward over the (optionally
#       re-fetched) base. A non-ancestor => the base moved => merge first, never a blind push.
#   committed <repo> <worktree> <base-oid> [<expected-branch>]
#       assert the track actually COMMITTED (worktree HEAD != base-oid) and, if given, that its
#       current branch == <expected-branch> (committed to the RIGHT branch — parallax-errors.md:108/114).
set -uo pipefail

die(){ echo "PUSH-GUARD FAIL: $1" >&2; exit "${2:-2}"; }
usage(){ echo "usage: push-guard.sh {ref-current|ancestor|committed} ..." >&2; exit 3; }

cmd="${1:-}"; shift || usage
case "$cmd" in
  ref-current)
    repo="${1:-}"; branch="${2:-}"; expected="${3:-}"
    [ -n "$repo" ] && [ -n "$branch" ] || die "ref-current needs <repo> <branch>" 3
    git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
      || die "branch '$branch' does not exist in $repo" 2
    br="$(git -C "$repo" rev-parse "refs/heads/$branch")"
    head="$(git -C "$repo" rev-parse HEAD)"
    want="${expected:-$head}"
    if [ "$br" != "$want" ]; then
      die "branch ref '$branch' ($br) != ${expected:+expected }${want} (HEAD=$head) — a LAGGING branch ref (detached HEAD?); a push would ship an INCOMPLETE tree (§5.2 D2 / errors:168)" 2
    fi
    echo "ok: $branch == $want"
    ;;
  ancestor)
    repo="${1:-}"; base="${2:-}"; tip="${3:-}"; shift 3 2>/dev/null || usage
    [ -n "$repo" ] && [ -n "$base" ] && [ -n "$tip" ] || die "ancestor needs <repo> <base-ref> <tip>" 3
    if [ "${1:-}" = "--fetch" ]; then
      remote="${2:-}"; rref="${3:-}"
      [ -n "$remote" ] && [ -n "$rref" ] || die "--fetch needs <remote> <remote-ref>" 3
      git -C "$repo" fetch "$remote" "$rref" || die "git fetch $remote $rref failed" 2
    fi
    git -C "$repo" rev-parse --verify --quiet "$base" >/dev/null || die "base ref '$base' not found" 3
    git -C "$repo" rev-parse --verify --quiet "$tip" >/dev/null || die "tip '$tip' not found" 3
    if git -C "$repo" merge-base --is-ancestor "$base" "$tip"; then
      echo "ok: $base is an ancestor of $tip (fast-forward-able)"
    else
      die "$base is NOT an ancestor of $tip — the base moved; MERGE first, never a blind non-ff push (§5.2 D2 / errors:166)" 2
    fi
    ;;
  committed)
    repo="${1:-}"; wt="${2:-}"; base="${3:-}"; want_branch="${4:-}"
    [ -n "$repo" ] && [ -n "$wt" ] && [ -n "$base" ] || die "committed needs <repo> <worktree> <base-oid>" 3
    head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "cannot rev-parse HEAD in worktree $wt" 3
    baseoid="$(git -C "$repo" rev-parse "$base" 2>/dev/null)" || die "cannot resolve base '$base'" 3
    if [ "$head" = "$baseoid" ]; then
      die "track did NOT commit (worktree HEAD == base $baseoid) — nothing was authored (§5.6 / errors:108)" 2
    fi
    if [ -n "$want_branch" ]; then
      cur="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      [ "$cur" = "$want_branch" ] || die "track committed to the WRONG branch (on '$cur', expected '$want_branch') — §5.6 / errors:114" 2
    fi
    echo "ok: committed ($head) ${want_branch:+on $want_branch}"
    ;;
  *) usage ;;
esac
