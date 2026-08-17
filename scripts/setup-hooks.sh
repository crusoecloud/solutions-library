#!/usr/bin/env bash
# One-time setup: point this clone's git hooks at the checked-in .githooks/
# directory, so `git commit` runs the solutions-structure check locally.
set -euo pipefail

repo_root=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)
git -C "$repo_root" config core.hooksPath .githooks
echo "Git hooks installed: core.hooksPath -> .githooks"
echo "The solutions-structure check now runs on every 'git commit' in this clone."
