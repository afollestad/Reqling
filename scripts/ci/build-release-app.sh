#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

: "${EXPORT_PATH:?}"

# The imported keychain holds a single Developer ID Application identity, so the name prefix is unambiguous.
CODESIGN_IDENTITY="Developer ID Application" "$repo_root/scripts/build.sh" --release

# Later steps read the bundle and its dSYMs from EXPORT_PATH, outside the checkout, so `.build/` layout stays private
# to `scripts/build.sh` and `scripts/lib/common.sh`.
mkdir -p "$EXPORT_PATH"
ditto "$(app_path release)" "$EXPORT_PATH/$app_name.app"
ditto "$(dsyms_path release)" "$EXPORT_PATH/dSYMs"
