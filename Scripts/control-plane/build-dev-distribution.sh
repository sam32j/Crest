#!/bin/bash
# Build an ad-hoc signed personal review app using a prebuilt engine.
set -euo pipefail

build_root="$RUNNER_TEMP/crest-dev"
mkdir -p "$build_root/publish"
# This API test build defers the two Quick Window extension fixes. Restoring
# their exact baseline makes every compiled engine input match a published engine.
git restore --source=36b7a5830e7bd5d949ebf55724087a119eaeffa6 -- \
    CrestEngines/Chromium/Overlay/chrome/browser/ui/crest/crest_chrome_host.mm \
    CrestEngines/Chromium/Overlay/chrome/browser/ui/crest/crest_engine_page.cc
engine_root="$build_root/engine"
mkdir -p "$engine_root"
engine_tag="$(python3 Scripts/control-plane/chromium_engine.py tag)"
test "$engine_tag" = chromium-engine-b6b8ccd6e4969bd3
engine_asset="$(python3 Scripts/control-plane/chromium_engine.py asset)"
gh release download "$engine_tag" --repo pauljoda/Crest \
    --pattern "$engine_asset" --pattern "${engine_asset}.sha256" --dir "$engine_root"
(cd "$engine_root" && shasum -a 256 -c "${engine_asset}.sha256")
ditto -x -k "$engine_root/$engine_asset" "$engine_root"

xcodebuild build -project Crest.xcodeproj -scheme CrestChromiumUI -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$build_root/DerivedData" CODE_SIGNING_ALLOWED=NO
products="$build_root/DerivedData/Build/Products/Release"
ui="$products/CrestChromiumUI.framework"
core="$products/CrestCore/CrestCore.Native.dylib"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ui/Resources/Info.plist")"
short_sha="$(git rev-parse --short=7 HEAD)"
app_name="Crest Dev $version ($short_sha)"
profile="native-automation-$short_sha"
review_app="$build_root/CrestEngine.app"
python3 Scripts/control-plane/package-chromium-host.py --browser "$engine_root/Chromium.app" \
    --ui "$ui" --core "$core" --personal --display-name "$app_name" \
    --signing-identity=- --output "$review_app"
app="$build_root/$app_name.app"
python3 Scripts/control-plane/package-dev-app.py --app "$review_app" --output "$app" \
    --profile "$profile" --personal --signing-identity=-
codesign --verify --deep --strict "$app"
mkdir -p "$build_root/dmg"
ditto "$app" "$build_root/dmg/$app_name.app"
ln -s /Applications "$build_root/dmg/Applications"
image="$build_root/publish/$app_name.dmg"
hdiutil create -volname "$app_name" -srcfolder "$build_root/dmg" -format UDZO "$image"
(cd "$build_root/publish" && shasum -a 256 *.dmg > SHA256SUMS)
cat > "$build_root/publish/README.txt" <<EOF
Requires Apple silicon and macOS $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist") or newer.
Open the DMG and drag $app_name.app into Applications. Open that app to test.
This is an ad-hoc signed personal build, without Apple notarization.
If macOS blocks it, try System Settings > Privacy & Security > Open Anyway.
If it is reported as damaged, remove quarantine from ONLY this dev app:
  xattr -dr com.apple.quarantine "/Applications/$app_name.app"
Then open the dev app again. Do not change quarantine on stable Crest.
This build has its own identity and profile. It does not update stable Crest or use its browsing data.
This API test build reuses the upstream engine and excludes the two Quick Window extension fixes.
In the dev app, enable Settings > Agents and allow a Space, then copy the agent setup from that app.
Source: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/commit/$(git rev-parse HEAD)
EOF
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$build_root/publish/README.txt" >> "$GITHUB_STEP_SUMMARY"
    echo 'Download the Crest-Dev artifact from this run; it contains the personal test DMG.' >> "$GITHUB_STEP_SUMMARY"
fi
