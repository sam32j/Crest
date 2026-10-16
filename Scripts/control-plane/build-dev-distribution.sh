#!/bin/bash
# Build an ad-hoc signed personal review app using a prebuilt engine.
set -euo pipefail

build_root="$RUNNER_TEMP/crest-dev"
mkdir -p "$build_root/publish"
# Reuse the published engine; this script never compiles Chromium.
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
profile="pr409-combined-$short_sha"
review_app="$build_root/CrestEngine.app"
python3 Scripts/control-plane/package-chromium-host.py --browser "$engine_root/Chromium.app" \
    --ui "$ui" --core "$core" --personal --display-name "$app_name" \
    --signing-identity=- --output "$review_app"
app="$build_root/$app_name.app"
python3 Scripts/control-plane/package-dev-app.py --app "$review_app" --output "$app" \
    --profile "$profile" --personal --signing-identity=-
codesign --verify --deep --strict "$app"
# Launch the final wrapper once to catch framework/engine loading failures.
"$app/Contents/MacOS/CrestDev" > "$build_root/dev-launch.log" 2>&1 &
smoke_pid=$!
sleep 10
if ! kill -0 "$smoke_pid" 2>/dev/null; then
    cat "$build_root/dev-launch.log"
    echo 'The packaged dev app exited during its startup check.' >&2
    exit 1
fi
kill -TERM "$smoke_pid"
wait "$smoke_pid" || true
cp "$build_root/dev-launch.log" "$build_root/publish/startup-check.log"
python3 - "$build_root/publish/build-info.json" "$engine_tag" <<'PY'
import json, os, pathlib, subprocess, sys
source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "source_commit": source,
    "reduced_pr_commit": os.environ["REDUCED_PR_SHA"],
    "engine_release": sys.argv[2],
    "engine_rebuilt": False,
    "personal_build": True,
}, indent=2) + "\n")
PY
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
Includes reduced PR 409 (history search/deletion, search providers, richer listings and native window tools), background startup, sidebar utility shortcuts and the current sidebar/page-cache fixes.
Reduced PR source: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/commit/$REDUCED_PR_SHA
Reuses $engine_tag from upstream; Chromium is not rebuilt and the separate engine patch is excluded.
In the dev app, enable Settings > Agents and allow a Space, then copy the agent setup from that app.
Source: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/commit/$(git rev-parse HEAD)
EOF
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$build_root/publish/README.txt" >> "$GITHUB_STEP_SUMMARY"
    echo 'Download the Crest-Dev artifact from this run; it contains the personal test DMG.' >> "$GITHUB_STEP_SUMMARY"
fi
