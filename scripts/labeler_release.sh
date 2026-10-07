#!/bin/zsh
# Build the Labeler iPhone app and publish it behind a fixed install link.
#
#   LABELER_EMAIL=… LABELER_PASSWORD=… scripts/labeler_release.sh
#
# Archives the Labeler scheme (development-signed for the team's registered
# devices, provisioned with the App Store Connect API key), exports the IPA,
# and uploads it with its install manifest to the private labeler-builds
# bucket at latest/ — replacing the previous build. The install link it
# prints points at latest/manifest.plist, so the same link installs every
# new build until it expires (30 days; re-run to get a fresh one). Open the
# link in Safari on the iPhone. The account must be a labeler.
set -euo pipefail

ROOT=${0:A:h:h}
KEY_ID=64N92V67FL
ISSUER=a42b4a1a-499c-4fd6-9a42-a2971d9669b9
KEY=$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8
SECRETS=$ROOT/BumpSetCut/Core/Networking/Secrets.swift
EXPIRES=2592000   # 30 days

[[ -n ${LABELER_EMAIL:-} && -n ${LABELER_PASSWORD:-} ]] || { print "❌ Set LABELER_EMAIL and LABELER_PASSWORD (a labeler account)."; exit 1 }
[[ -f $KEY ]] || { print "❌ No App Store Connect key at $KEY"; exit 1 }
URL=$(sed -n 's/.*supabaseURL *= *"\(.*\)".*/\1/p' $SECRETS)
ANON=$(sed -n 's/.*supabaseAnonKey *= *"\(.*\)".*/\1/p' $SECRETS)

WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
AUTH=(-allowProvisioningUpdates -authenticationKeyPath $KEY -authenticationKeyID $KEY_ID -authenticationKeyIssuerID $ISSUER)
BUILD=$(date +%Y%m%d%H%M)

print "▸ Archiving Labeler (build $BUILD)…"
xcodebuild -project $ROOT/BumpSetCut.xcodeproj -scheme Labeler -configuration Release -destination generic/platform=iOS \
    -archivePath $WORK/Labeler.xcarchive archive CURRENT_PROJECT_VERSION=$BUILD "${AUTH[@]}" -quiet
cat > $WORK/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>debugging</string>
<key>teamID</key><string>8UHLPBQL7Y</string>
<key>signingStyle</key><string>automatic</string>
<key>thinning</key><string>&lt;none&gt;</string>
</dict></plist>
EOF
print "▸ Exporting the IPA…"
xcodebuild -exportArchive -archivePath $WORK/Labeler.xcarchive -exportPath $WORK/export -exportOptionsPlist $WORK/export.plist "${AUTH[@]}" -quiet

TOKEN=$(curl -sf "$URL/auth/v1/token?grant_type=password" -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d "$(python3 -c 'import json,os;print(json.dumps({"email":os.environ["LABELER_EMAIL"],"password":os.environ["LABELER_PASSWORD"]}))')" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')
upload() {   # file, path, content type
    curl -sf -o /dev/null -X POST "$URL/storage/v1/object/labeler-builds/$2" -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: $3" -H "x-upsert: true" --data-binary @"$1" || { print "❌ Upload of $2 failed (is the account a labeler?)"; exit 1 }
}
signed() {   # path
    curl -sf -X POST "$URL/storage/v1/object/sign/labeler-builds/$1" -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" -d "{\"expiresIn\":$EXPIRES}" \
        | python3 -c "import json,sys;print('$URL/storage/v1'+json.load(sys.stdin)['signedURL'])"
}

print "▸ Uploading…"
upload $WORK/export/Labeler.ipa latest/Labeler.ipa application/octet-stream
IPA=$(signed latest/Labeler.ipa | sed 's/&/\&amp;/g')
cat > $WORK/manifest.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>$IPA</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>app.BumpSetCut.Labeler</string><key>bundle-version</key><string>$BUILD</string><key>kind</key><string>software</string><key>title</key><string>Labeler</string></dict>
</dict></array></dict></plist>
EOF
upload $WORK/manifest.plist latest/manifest.plist application/xml
MANIFEST=$(signed latest/manifest.plist)
LINK="itms-services://?action=download-manifest&url=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$MANIFEST")"
print "✅ Labeler build $BUILD published. Install link (Safari on the iPhone; valid 30 days):"
print -r -- "$LINK"
