#!/bin/bash
set -euo pipefail

# The same packaging path is used locally and by GitHub Actions.
version="${1:-1.0.0}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Expected a version such as 1.0.0" >&2
  exit 1
fi
build_number="${GITHUB_RUN_NUMBER:-1}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${HAMASTER_BUILD_DIR:-$repo_root/DerivedData/Release}"
output_dir="$repo_root/dist"

xcodebuild -project "$repo_root/Hamaster.xcodeproj" -scheme Hamaster \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$build_dir" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=NO build

app="$build_dir/Build/Products/Release/Hamaster.app"
lipo "$app/Contents/MacOS/Hamaster" -verify_arch arm64 x86_64
# Free ad-hoc signing supports Apple Silicon, but is not Developer ID/notarization.
codesign --force --sign - "$app"
codesign --verify --strict "$app"
mkdir -p "$output_dir"
archive="Hamaster-$version-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output_dir/$archive"
(cd "$output_dir" && shasum -a 256 "$archive" > "$archive.sha256")
echo "Packaged $output_dir/$archive"
