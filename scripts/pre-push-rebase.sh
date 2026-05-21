#!/usr/bin/env bash
# Pre-push hook: rebase the current branch onto origin/main before pushing.
# On a clean rebase, the push proceeds against the rebased tip (so subsequent
# build/test hooks run against post-rebase state). On conflict, aborts the
# rebase and blocks the push so the user can resolve manually.
#
# No-ops when:
#   - current branch IS main (nothing to rebase onto self)
#   - branch is already on top of origin/main (nothing to do)
#   - a rebase is already in progress (user is mid-resolution)

set -e

branch=$(git rev-parse --abbrev-ref HEAD)

if [ "$branch" = "main" ]; then
    exit 0
fi

if [ -d "$(git rev-parse --git-path rebase-merge)" ] || \
   [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
    echo "pre-push: rebase already in progress; finish it first" >&2
    exit 1
fi

if ! git diff-index --quiet HEAD --; then
    echo "pre-push: working tree not clean; commit or stash before pushing" >&2
    exit 1
fi

echo "pre-push: fetching origin/main..."
git fetch origin main

# Already up to date with origin/main?
merge_base=$(git merge-base HEAD origin/main)
origin_main=$(git rev-parse origin/main)
if [ "$merge_base" = "$origin_main" ]; then
    echo "pre-push: branch already on top of origin/main"
    exit 0
fi

echo "pre-push: rebasing $branch onto origin/main..."
if ! git rebase origin/main; then
    echo "" >&2
    echo "pre-push: rebase hit a conflict; aborting and blocking push" >&2
    echo "  resolve manually:  git rebase origin/main" >&2
    git rebase --abort
    exit 1
fi

echo "pre-push: rebase clean"
