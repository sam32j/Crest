#!/bin/bash
# Build a notarized review app; never publish a release or an update feed.
set -euo pipefail

build_root="$RUNNER_TEMP/crest-dev"
mkdir -p "$build_root/publish"
keychain_path="$build_root/signing.keychain-db"
p12_path="$build_root/signing.p12"
api_key_path="$build_root/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
original_keychain="$(security default-keychain -d user | tr -d '"')"
security list-keychains -d user > "$build_root/keychains-before.txt"
keychain_password="$(openssl rand -hex 24)"
cleanup_signing() {
    security default-keychain -d user -s "$original_keychain" >/dev/null 2>&1 || true
    xargs security list-keychains -d user -s < "$build_root/keychains-before.txt" || true
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
    rm -f "$p12_path" "$api_key_path" "$build_root/keychains-before.txt"
}
trap cleanup_signing EXIT
printf '%s' "$DEVELOPER_ID_APPLICATION_P12_BASE64" | base64 -D > "$p12_path"
printf '%s' "$APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64" | base64 -D > "$api_key_path"
chmod 600 "$p12_path" "$api_key_path"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$p12_path" -k "$keychain_path" -P "$DEVELOPER_ID_APPLICATION_P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path"
security list-keychains -d user -s "$keychain_path" "$original_keychain"
security default-keychain -d user -s "$keychain_path"
identity_hash="$(security find-identity -v -p codesigning "$keychain_path" \
    | awk '/Developer ID Application:/ { print $2; exit }')"
test -n "$identity_hash"

engine_root="$build_root/engine"
mkdir -p "$engine_root"
engine_tag="$(python3 Scripts/control-plane/chromium_engine.py tag)"
engine_asset="$(python3 Scripts/control-plane/chromium_engine.py asset)"
gh release download "$engine_tag" --repo "$GITHUB_REPOSITORY" \
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
    --ui "$ui" --core "$core" --distribution --display-name "$app_name" \
    --signing-identity "$identity_hash" --output "$review_app"
app="$build_root/$app_name.app"
python3 Scripts/control-plane/package-dev-app.py --app "$review_app" --output "$app" \
    --profile "$profile" --signing-identity "$identity_hash"
archive="$build_root/notarization.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --key "$api_key_path" --key-id "$APP_STORE_CONNECT_API_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_API_ISSUER_ID" --wait
# Both apps must carry their tickets for offline launches.
xcrun stapler staple "$app/Contents/Helpers/CrestEngine.app"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=4 "$app"
mkdir -p "$build_root/dmg"
ditto "$app" "$build_root/dmg/$app_name.app"
ln -s /Applications "$build_root/dmg/Applications"
image="$build_root/publish/$app_name.dmg"
hdiutil create -volname "$app_name" -srcfolder "$build_root/dmg" -format UDZO "$image"
codesign --sign "$identity_hash" --timestamp "$image"
xcrun notarytool submit "$image" --key "$api_key_path" --key-id "$APP_STORE_CONNECT_API_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_API_ISSUER_ID" --wait
xcrun stapler staple "$image"
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature --verbose=4 "$image"
(cd "$build_root/publish" && shasum -a 256 *.dmg > SHA256SUMS)
cat > "$build_root/publish/README.txt" <<EOF
Requires Apple silicon and macOS $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist") or newer.
Open the DMG and drag $app_name.app into Applications. Open that app to test.
This build has its own identity and profile. It does not update stable Crest or use its browsing data.
In the dev app, enable Settings > Agents and allow a Space, then copy the agent setup from that app.
Source: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/commit/$(git rev-parse HEAD)
EOF
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$build_root/publish/README.txt" >> "$GITHUB_STEP_SUMMARY"
    echo 'Download the Crest-Dev artifact from this run; it contains the notarized DMG.' >> "$GITHUB_STEP_SUMMARY"
fi
