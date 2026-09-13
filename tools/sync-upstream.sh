#!/usr/bin/env bash
set -Eeuo pipefail

# Keep the official source available while maintaining our independent fork.
# Default mode only fetches and reports divergence. Use --backup to create a
# local backup branch before a manual merge.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream https://github.com/Wei-Shaw/sub2api.git
fi

git fetch upstream main

if [[ "${1:-}" == "--backup" ]]; then
  current_branch=$(git branch --show-current)
  [[ -n "$current_branch" ]] || { echo "detached HEAD is not supported" >&2; exit 2; }
  backup_branch="backup/before-upstream-$(date -u +%Y%m%d-%H%M%S)"
  git branch "$backup_branch" "$current_branch"
  echo "created $backup_branch"
fi

echo "official baseline: $(git rev-parse --short upstream/main)"
echo "current branch:    $(git branch --show-current || true)"
echo "custom commits:    $(git rev-list --count upstream/main..HEAD)"
echo "upstream commits:  $(git rev-list --count HEAD..upstream/main)"
echo
echo "Review the diff with: git diff --stat upstream/main...HEAD"
echo "Merge manually after tests: git merge --no-ff upstream/main"

