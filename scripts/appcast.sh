#!/usr/bin/env bash
# Signs the release DMG for Sparkle and writes build/appcast.xml, the feed Software Update reads. macOS only.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/appcast.sh VERSION [NOTES_FILE]

Run after scripts/release.sh VERSION. Signs build/Jutsu-Studio-<VERSION>.dmg with the
Sparkle EdDSA key, checks the signature against SUPublicEDKey in the exported app, and
writes build/appcast.xml with that one release. The release workflow attaches it to the
GitHub release; the app reads it from releases/latest/download/appcast.xml, so it goes
live when the draft is published.

  NOTES_FILE   Markdown shown in the update window, e.g. from scripts/release-notes.sh.

The key comes from SPARKLE_ED_PRIVATE_KEY (the release workflow's secret) or, when that
is unset, from the login Keychain item created by
`generate_keys --account jutsu-studio`. CONTRIBUTING.md#releasing has the setup.
EOF
}

die() { echo "error: $*" >&2; exit 1; }

[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 1; }
VERSION=${1#v}
NOTES=${2:-}
[[ -z $NOTES || -f $NOTES ]] || die "notes file '$NOTES' not found."

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUILD=build
DMG=$BUILD/Jutsu-Studio-$VERSION.dmg
APP="$BUILD/export/Jutsu Studio.app"
APPCAST=$BUILD/appcast.xml
# release.sh resolves the packages here, so the tools match the Sparkle the app embeds.
SIGN_UPDATE=$BUILD/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update

[[ -f $DMG ]] || die "'$DMG' not found; run scripts/release.sh $VERSION first."
[[ -d $APP ]] || die "'$APP' not found; run scripts/release.sh $VERSION first."
[[ -x $SIGN_UPDATE ]] || die "'$SIGN_UPDATE' not found; run scripts/release.sh $VERSION first."

info() { plutil -extract "$1" raw -o - "$APP/Contents/Info.plist"; }
BUILD_NUMBER=$(info CFBundleVersion)
MINIMUM_SYSTEM=$(info LSMinimumSystemVersion)
PUBLIC_KEY=$(info SUPublicEDKey)
FEED=$(info SUFeedURL)
REPOSITORY=${FEED%/releases/latest/download/appcast.xml}
[[ $REPOSITORY != "$FEED" && $REPOSITORY == https://github.com/*/* ]] || die "unexpected SUFeedURL: '$FEED'."
[[ $(info CFBundleShortVersionString) == "$VERSION" ]] || die "the exported app is not version $VERSION."

if [[ -n ${SPARKLE_ED_PRIVATE_KEY:-} ]]; then
    SIGNATURE=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - -p "$DMG")
else
    SIGNATURE=$("$SIGN_UPDATE" --account jutsu-studio -p "$DMG")
fi
LENGTH=$(stat -f %z "$DMG")

# A key that doesn't match the app's would ship an update every copy of the app refuses.
xcrun swift - "$PUBLIC_KEY" "$SIGNATURE" "$DMG" <<'SWIFT' || die "the signature doesn't match SUPublicEDKey in project.yml."
import CryptoKit
import Foundation

let arguments = CommandLine.arguments.suffix(3).map { $0 }
guard let key = Data(base64Encoded: arguments[0]), let signature = Data(base64Encoded: arguments[1]),
    let file = FileManager.default.contents(atPath: arguments[2]),
    (try? Curve25519.Signing.PublicKey(rawRepresentation: key))?.isValidSignature(signature, for: file) == true
else { exit(1) }
SWIFT

# Sparkle renders the Markdown; CDATA keeps it verbatim unless it contains the closing sequence.
notes=""
if [[ -n $NOTES ]]; then
    notes=$(<"$NOTES")
    [[ $notes != *']]>'* ]] || die "the notes contain ']]>', which can't go in the feed."
fi

cat >"$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Jutsu Studio</title>
        <link>$REPOSITORY</link>
        <item>
            <title>Version $VERSION</title>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>$REPOSITORY/releases</sparkle:fullReleaseNotesLink>
            <description sparkle:format="markdown"><![CDATA[$notes]]></description>
            <enclosure url="$REPOSITORY/releases/download/v$VERSION/${DMG##*/}" length="$LENGTH"
                type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
        </item>
    </channel>
</rss>
EOF
xmllint --noout "$APPCAST"
echo "$APPCAST: version $VERSION ($BUILD_NUMBER), $LENGTH bytes, signature checked"
