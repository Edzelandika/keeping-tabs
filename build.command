#!/bin/zsh
set -eu
cd "${0:A:h}"
signing_identity="${SAFARI_TABS_SIGNING_IDENTITY:-Safari Recent Tabs Local}"
if ! security find-identity -v -p codesigning | grep -Fq -- "$signing_identity"; then
  print -u2 "Missing persistent signing identity: $signing_identity. Run setup-signing.command first."
  exit 1
fi
module_cache="${TMPDIR:-/tmp}/safari-recent-tabs-module-cache"
mkdir -p "$module_cache"
build_temp=$(mktemp -d /tmp/safari-recent-tabs-build.XXXXXX)
trap 'rm -rf "$build_temp"' EXIT
bundle="$build_temp/Keeping Tabs.app"
mkdir -p "$bundle/Contents/MacOS"
cp Source/Info.plist "$bundle/Contents/Info.plist"
xcrun swiftc -swift-version 5 -module-cache-path "$module_cache" -O -framework AppKit -framework ApplicationServices \
  Source/Recency.swift Source/Bridge.swift Source/Picker.swift Source/PickerKey.swift Source/RefreshScheduler.swift Source/main.swift \
  -o "$bundle/Contents/MacOS/SafariRecentTabs"
codesign --force --sign "$signing_identity" --timestamp=none "$bundle"
codesign --verify --deep --strict "$bundle"
ditto --norsrc --noextattr "$bundle" 'Keeping Tabs.app'
print "Built Keeping Tabs.app"
