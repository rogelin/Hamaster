#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
preview_dir="${1:-/tmp/hamaster-menu-previews}"
preview_work="$(mktemp -d)"
trap 'rm -rf "$preview_work"' EXIT
preview_binary="$preview_work/hamaster-preview"
xcrun swiftc -parse-as-library \
  Hamaster/Models/MouseSettings.swift Hamaster/Models/MousePanelStatus.swift \
  Hamaster/Views/PanelChrome.swift Hamaster/Views/MouseSettingsView.swift \
  Hamaster/Views/PermissionCard.swift scripts/preview-menu.swift \
  -module-cache-path "$preview_work/ModuleCache" -o "$preview_binary"
"$preview_binary" "$preview_dir"
