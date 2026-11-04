#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

chmod +x "$repo_root"/.githooks/*
git -C "$repo_root" config core.hooksPath .githooks

echo "Configured repo-local Git hooks at .githooks"
echo "Pre-commit hook: $repo_root/.githooks/pre-commit"
