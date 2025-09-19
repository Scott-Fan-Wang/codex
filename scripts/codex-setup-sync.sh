#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   bash scripts/codex-setup-sync.sh [UPSTREAM_URL]
# Default upstream is the original OpenAI repo.

UPSTREAM_URL_DEFAULT="https://github.com/openai/codex.git"
UPSTREAM_URL="${1:-$UPSTREAM_URL_DEFAULT}"

# Ensure inside a git repo
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "Error: run this inside the cloned repo directory." >&2
  exit 1
}

# Require 'origin' (your fork) to exist
if ! git remote | grep -qx origin; then
  echo "Error: no 'origin' remote. Add your fork first, e.g.:" >&2
  echo "  git remote add origin git@github.com:Scott-Fan-Wang/codex.git" >&2
  exit 1
fi

# Add or update 'upstream' (the original repo)
if git remote | grep -qx upstream; then
  current="$(git remote get-url upstream)"
  if [ "$current" != "$UPSTREAM_URL" ]; then
    echo "Updating upstream URL: $current -> $UPSTREAM_URL"
    git remote set-url upstream "$UPSTREAM_URL"
  else
    echo "upstream already set to $UPSTREAM_URL"
  fi
else
  echo "Adding upstream: $UPSTREAM_URL"
  git remote add upstream "$UPSTREAM_URL"
fi

echo "Fetching remotes…"
git fetch --prune origin
git fetch --prune upstream || true

# Ensure local main exists and tracks origin/main
if git show-ref --verify --quiet refs/heads/main; then
  git checkout main
else
  if git show-ref --verify --quiet refs/remotes/origin/main; then
    git checkout -b main origin/main
  else
    echo "Error: origin/main not found. Push your fork's main first." >&2
    exit 1
  fi
fi
git branch --set-upstream-to origin/main main >/dev/null 2>&1 || true

# Stash any local changes to keep work safe during merges
STASHED=0
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Stashing local changes…"
  git stash push -u -m "auto-stash before upstream sync" >/dev/null
  STASHED=1
fi

set +e
echo "Merging origin/main into main…"
git merge --no-edit origin/main
m1=$?

if git show-ref --verify --quiet refs/remotes/upstream/main; then
  echo "Merging upstream/main into main…"
  git merge --no-edit upstream/main
  m2=$?
else
  echo "Note: upstream/main not found; skipping merge from upstream."
  m2=0
fi
set -e

if [ $m1 -ne 0 ] || [ $m2 -ne 0 ]; then
  echo
  echo "Merge conflicts detected."
  echo "Resolve conflicts, commit, then push:"
  echo "  git status"
  echo "  # fix conflicts, then"
  echo "  git add -A && git commit"
  echo "  git push origin main"
  exit 1
fi

if [ $STASHED -eq 1 ]; then
  echo "Re-applying stashed changes…"
  set +e
  git stash pop
  pop_status=$?
  set -e
  if [ $pop_status -ne 0 ]; then
    echo
    echo "Conflicts when re-applying stash."
    echo "Resolve conflicts, commit, then push:"
    echo "  git status"
    echo "  git add -A && git commit"
    echo "  git push origin main"
    exit 1
  fi
fi

echo "Pushing to your fork (origin/main)…"
git push origin main
echo "Done: main is synced with upstream and pushed to origin."

