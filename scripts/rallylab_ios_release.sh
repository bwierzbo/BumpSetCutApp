#!/bin/zsh
# Build RallyLab for iPhone (the Labeler target) and upload it to TestFlight.
#
#   scripts/rallylab_ios_release.sh
#
# Archives with a timestamp build number, signs and uploads with the App
# Store Connect API key (Xcode creates the distribution certificate and
# profile itself). App Store Connect app "BumpSetCut RallyLab"
# (app.BumpSetCut.RallyLab, id 6820196175); its internal group "Me" gets
# every build, so it lands in TestFlight once Apple has processed it —
# no App Review for internal testers.
set -euo pipefail

ROOT=${0:A:h:h}
KEY_ID=64N92V67FL
ISSUER=a42b4a1a-499c-4fd6-9a42-a2971d9669b9
KEY=$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8
[[ -f $KEY ]] || { print "❌ No App Store Connect key at $KEY"; exit 1 }

WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
AUTH=(-allowProvisioningUpdates -authenticationKeyPath $KEY -authenticationKeyID $KEY_ID -authenticationKeyIssuerID $ISSUER)
BUILD=$(date +%Y%m%d%H%M)

print "▸ Archiving RallyLab for iPhone (build $BUILD)…"
xcodebuild -project $ROOT/BumpSetCut.xcodeproj -scheme Labeler -configuration Release -destination generic/platform=iOS \
    -archivePath $WORK/RallyLab.xcarchive archive CURRENT_PROJECT_VERSION=$BUILD "${AUTH[@]}" -quiet
cat > $WORK/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>teamID</key><string>8UHLPBQL7Y</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>uploadSymbols</key><true/>
</dict></plist>
EOF
print "▸ Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath $WORK/RallyLab.xcarchive -exportPath $WORK/export -exportOptionsPlist $WORK/export.plist "${AUTH[@]}" -quiet
print "✅ Build $BUILD uploaded — it appears in TestFlight once Apple has processed it (usually 5–20 minutes)."
