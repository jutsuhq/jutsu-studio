#!/usr/bin/env bash
# Builds, signs, notarizes and staples build/Jutsu-Studio-<version>.dmg and zips its dSYMs. macOS only.
# Run with --help for usage and prerequisites; CONTRIBUTING.md#releasing has the one-time setup.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/release.sh [VERSION] [--skip-notarize] [--skip-smoke]

Builds a universal (arm64 + x86_64) Release build of Jutsu Studio with the
hardened runtime, signs it with your Developer ID, notarizes and staples the
app, packs it into build/Jutsu-Studio-<VERSION>.dmg, notarizes and staples the
DMG and prints its SHA-256. The dSYMs go to build/Jutsu-Studio-<VERSION>-dSYMs.zip.
scripts/appcast.sh then signs the DMG for Software Update.
Fails unless CURRENT_PROJECT_VERSION in project.yml is higher than in the
previous release tag.

  VERSION           Marketing version, e.g. 0.1.0. Defaults to MARKETING_VERSION
                    in project.yml. Bump project.yml rather than overriding here.
  --skip-notarize   Local test build: ad-hoc signature, no Developer ID, no
                    notarization. The DMG will not pass Gatekeeper on other Macs.
  --skip-smoke      Don't launch the finished app (scripts/smoke-launch.sh). Only for a Mac
                    without a logged-in GUI session; a release should always be launched once.
  -h, --help        Show this help.

Environment (not needed with --skip-notarize):
  DEVELOPMENT_TEAM  Apple Developer Team ID (10 characters).
  NOTARY_PROFILE    Keychain profile created with `xcrun notarytool store-credentials`.
  NOTARY_KEY        Instead of NOTARY_PROFILE: path to an App Store Connect API key
                    (AuthKey_XXXXXXXXXX.p8), with NOTARY_KEY_ID and NOTARY_ISSUER.
                    This is what the GitHub release workflow uses.
  SIGNING_IDENTITY  Optional. Defaults to "Developer ID Application: … (DEVELOPMENT_TEAM)"
                    found in your keychain.

Requires macOS with Xcode 26+, git, XcodeGen (brew install xcodegen; CI pins it with
scripts/install-xcodegen.sh) and python3 (for dmgbuild, installed into build/.dmgbuild on first run).
EOF
}

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "› $*"; }

VERSION=""
NOTARIZE=1
SMOKE=1
while [[ $# -gt 0 ]]; do
    case $1 in
        -h | --help) usage; exit 0 ;;
        --skip-notarize) NOTARIZE=0 ;;
        --skip-smoke) SMOKE=0 ;;
        -*) usage >&2; die "unknown option: $1" ;;
        *) [[ -z $VERSION ]] || die "version given twice: $VERSION and $1"; VERSION=$1 ;;
    esac
    shift
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ $(uname -s) == Darwin ]] || die "release builds need macOS (xcodebuild, codesign, hdiutil, notarytool)."
for tool in git xcodegen xcodebuild xcrun codesign hdiutil ditto lipo shasum plutil security python3 cmp; do
    command -v "$tool" >/dev/null || die "'$tool' not found.$([[ $tool == xcodegen ]] && echo " Install it with: brew install xcodegen")"
done

PROJECT_VERSION=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' project.yml | head -n 1)
[[ -n $PROJECT_VERSION ]] || die "MARKETING_VERSION not found in project.yml."
VERSION=${VERSION:-$PROJECT_VERSION}
VERSION=${VERSION#v}
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3, got '$VERSION'."
[[ $VERSION == "$PROJECT_VERSION" ]] ||
    echo "warning: building $VERSION but project.yml says $PROJECT_VERSION; bump project.yml before tagging." >&2

build_number() { sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' | head -n 1; }
PROJECT_BUILD=$(build_number <project.yml)
[[ $PROJECT_BUILD =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION in project.yml must be a whole number, got '$PROJECT_BUILD'."
# The previous release is the newest version tag reachable from HEAD, other than the one being built.
PREVIOUS_TAG=$(git describe --tags --abbrev=0 --match 'v*.*.*' --exclude "v$VERSION" HEAD 2>/dev/null || true)
if [[ -n $PREVIOUS_TAG ]]; then
    PREVIOUS_BUILD=$(git show "$PREVIOUS_TAG:project.yml" | build_number)
    if [[ $PREVIOUS_BUILD =~ ^[0-9]+$ ]] && ((10#$PROJECT_BUILD <= 10#$PREVIOUS_BUILD)); then
        message="build number $PROJECT_BUILD is not higher than $PREVIOUS_BUILD in $PREVIOUS_TAG; increment CURRENT_PROJECT_VERSION in project.yml."
        ((NOTARIZE)) && die "$message"
        echo "warning: $message" >&2
    fi
fi

if ((NOTARIZE)); then
    [[ -n ${DEVELOPMENT_TEAM:-} ]] || die "set DEVELOPMENT_TEAM to your Apple Team ID, or pass --skip-notarize for a local build."
    if [[ -n ${NOTARY_KEY:-} ]]; then
        [[ -f $NOTARY_KEY ]] || die "NOTARY_KEY '$NOTARY_KEY' is not a file."
        [[ -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER:-} ]] || die "NOTARY_KEY needs NOTARY_KEY_ID and NOTARY_ISSUER."
        NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    elif [[ -n ${NOTARY_PROFILE:-} ]]; then
        NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    else
        die "set NOTARY_PROFILE (or NOTARY_KEY with NOTARY_KEY_ID and NOTARY_ISSUER), or pass --skip-notarize."
    fi
    if [[ -z ${SIGNING_IDENTITY:-} ]]; then
        SIGNING_IDENTITY=$(security find-identity -v -p codesigning |
            sed -nE "s/.*\"(Developer ID Application: .*\\($DEVELOPMENT_TEAM\\))\".*/\\1/p" | head -n 1)
        [[ -n $SIGNING_IDENTITY ]] ||
            die "no 'Developer ID Application' certificate for team $DEVELOPMENT_TEAM in your keychain. See CONTRIBUTING.md#releasing."
    fi
    xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 ||
        die "notarization credentials not usable. See CONTRIBUTING.md#releasing."
fi

BUILD=build
ARCHIVE=$BUILD/JutsuStudio.xcarchive
EXPORT=$BUILD/export
APP_NAME="Jutsu Studio.app"
APP=$EXPORT/$APP_NAME
DMG=$BUILD/Jutsu-Studio-$VERSION.dmg
DSYMS=$BUILD/Jutsu-Studio-$VERSION-dSYMs.zip

rm -rf "$ARCHIVE" "$EXPORT" "$DMG" "$DSYMS"
mkdir -p "$BUILD"

step "xcodegen generate"
xcodegen generate --quiet

COMMON_SETTINGS=(
    MARKETING_VERSION="$VERSION"
    ARCHS="arm64 x86_64"
    ONLY_ACTIVE_ARCH=NO
    ENABLE_HARDENED_RUNTIME=YES
)
if ((NOTARIZE)); then
    SIGN_SETTINGS=(
        CODE_SIGN_STYLE=Manual
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
        OTHER_CODE_SIGN_FLAGS=--timestamp
    )
else
    SIGN_SETTINGS=(CODE_SIGN_IDENTITY=-)
fi

step "xcodebuild archive ($VERSION, Release, arm64 + x86_64)"
xcodebuild archive \
    -project JutsuStudio.xcodeproj \
    -scheme JutsuStudio \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -clonedSourcePackagesDirPath "$BUILD/SourcePackages" \
    -quiet \
    "${COMMON_SETTINGS[@]}" "${SIGN_SETTINGS[@]}"

if ((NOTARIZE)); then
    step "export (Developer ID)"
    cat >"$BUILD/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$DEVELOPMENT_TEAM</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$SIGNING_IDENTITY</string>
</dict>
</plist>
EOF
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportPath "$EXPORT" \
        -exportOptionsPlist "$BUILD/ExportOptions.plist" \
        -quiet
else
    step "copy app from archive (ad-hoc, no export)"
    mkdir -p "$EXPORT"
    ditto "$ARCHIVE/Products/Applications/$APP_NAME" "$APP"
fi
[[ -d $APP ]] || die "export produced no '$APP'."

step "verify app"
codesign --verify --deep --strict --verbose=2 "$APP"
ARCHS_BUILT=$(lipo -archs "$APP/Contents/MacOS/Jutsu Studio")
[[ $ARCHS_BUILT == *arm64* && $ARCHS_BUILT == *x86_64* ]] || die "app is not universal (archs: $ARCHS_BUILT)."
# Captured first: `grep -q` stops reading at the first match, and pipefail would turn codesign's SIGPIPE into a failure.
SIGNATURE=$(codesign --display --verbose=2 "$APP" 2>&1)
[[ $SIGNATURE == *flags=*runtime* ]] || die "app is not signed with the hardened runtime."
BUNDLE_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
[[ $BUNDLE_VERSION == "$VERSION" ]] || die "app reports version $BUNDLE_VERSION, expected $VERSION."
BUNDLE_BUILD=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")
[[ $BUNDLE_BUILD == "$PROJECT_BUILD" ]] || die "app reports build $BUNDLE_BUILD, expected $PROJECT_BUILD."
echo "universal ($ARCHS_BUILT), hardened runtime, version $BUNDLE_VERSION ($BUNDLE_BUILD)"

step "zip dSYMs into $DSYMS"
APP_DSYM="$ARCHIVE/dSYMs/$APP_NAME.dSYM"
[[ -d $APP_DSYM ]] || die "the archive has no '$APP_DSYM'; crash reports could not be symbolicated."
# Crash reports match a dSYM by UUID, one per architecture.
uuids() { xcrun dwarfdump --uuid "$1" | awk '{ print $2 }' | sort; }
[[ $(uuids "$APP/Contents/MacOS/Jutsu Studio") == "$(uuids "$APP_DSYM")" ]] ||
    die "the dSYM in the archive does not match the exported app."
ditto -c -k --keepParent "$ARCHIVE/dSYMs" "$DSYMS"

# Usage: notarize FILE. Waits for the result and prints Apple's log if it is not accepted.
notarize() {
    local result status submission
    result=$(xcrun notarytool submit "$1" --wait --output-format json "${NOTARY_AUTH[@]}")
    status=$(plutil -extract status raw -o - - <<<"$result")
    submission=$(plutil -extract id raw -o - - <<<"$result")
    if [[ $status != Accepted ]]; then
        xcrun notarytool log "$submission" "${NOTARY_AUTH[@]}" >&2 || true
        die "notarization of ${1##*/} finished with status '$status' (submission $submission); the log is above."
    fi
    echo "accepted (submission $submission)"
}

if ((NOTARIZE)); then
    # Stapled before it goes into the DMG, so the copy in /Applications passes Gatekeeper offline too.
    step "notarize and staple the app (this usually takes a few minutes)"
    APP_ZIP=$BUILD/notarize-app.zip
    ditto -c -k --keepParent "$APP" "$APP_ZIP"
    notarize "$APP_ZIP"
    rm -f "$APP_ZIP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

step "create $DMG"
# dmgbuild lays out the installer window (background, icon positions) without scripting Finder, so it also works
# on a CI runner. Pinned with hashes in scripts/dmg/requirements.txt and kept in its own venv.
DMGBUILD_ENV=$BUILD/.dmgbuild
if ! cmp -s scripts/dmg/requirements.txt "$DMGBUILD_ENV/requirements.txt"; then
    rm -rf "$DMGBUILD_ENV"
    python3 -m venv "$DMGBUILD_ENV"
    "$DMGBUILD_ENV/bin/pip" install --quiet --disable-pip-version-check --require-hashes --only-binary :all: \
        -r scripts/dmg/requirements.txt
    cp scripts/dmg/requirements.txt "$DMGBUILD_ENV/requirements.txt"
fi
"$DMGBUILD_ENV/bin/dmgbuild" -s scripts/dmg/settings.py -D app="$APP" -D background="$PWD/scripts/dmg/background.png" \
    "Jutsu Studio" "$DMG" >/dev/null

if ((NOTARIZE)); then
    step "sign DMG"
    codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"

    step "notarize the DMG (this usually takes a few minutes)"
    notarize "$DMG"

    step "staple and check Gatekeeper"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -vv -t open --context context:primary-signature "$DMG"
    spctl -a -vv "$APP"
else
    step "skipped signing with Developer ID, notarization and Gatekeeper check (--skip-notarize)"
fi

if ((SMOKE)); then
    step "launch the app from the DMG (smoke test)"
    scripts/smoke-launch.sh "$DMG"
else
    step "skipped launching the app (--skip-smoke)"
fi

step "done"
(cd "$BUILD" && shasum -a 256 "${DMG##*/}" | tee "${DMG##*/}.sha256")
echo "dSYMs: $DSYMS"
