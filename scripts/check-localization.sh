#!/usr/bin/env bash
# Fails when a string the code looks up isn't in its target's string catalog. Xcode adds the app target's keys
# only when the project is built in the IDE, and nothing adds the packages' keys, so a new string can ship without
# an entry for translators.
#
# Keys come from `xcstringstool extract`, a parse without the compiler: it sees String(localized:),
# LocalizedStringResource(…) and SwiftUI's own views, not literals passed to the app's components that take a
# LocalizedStringResource. It writes interpolations as "%arg", so specifiers are compared as one placeholder.
# Needs Xcode's xcstringstool, so it is skipped elsewhere (the Linux lint job).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcrun --find xcstringstool >/dev/null 2>&1; then
    echo "xcstringstool not found, skipping the string catalog check"
    exit 0
fi

# Each source folder and the catalog its strings belong to.
TARGETS=(
    "JutsuStudio:JutsuStudio/Resources/Localizable.xcstrings"
    "Packages/JutsuKit/Sources/Presentation:Packages/JutsuKit/Sources/Presentation/Resources/Localizable.xcstrings"
    "Packages/JutsuKit/Sources/HiggsfieldProviders:Packages/JutsuKit/Sources/HiggsfieldProviders/Resources/Localizable.xcstrings"
    "Packages/JutsuKit/Sources/JobEngine:Packages/JutsuKit/Sources/JobEngine/Resources/Localizable.xcstrings"
    "Packages/JutsuKit/Sources/MediaKit:Packages/JutsuKit/Sources/MediaKit/Resources/Localizable.xcstrings"
)

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

status=0
for target in "${TARGETS[@]}"; do
    sources=${target%%:*}
    catalog=${target#*:}
    out="$scratch/${sources//\//_}"
    mkdir -p "$out"
    # Quiet: it notes every String(localized: resource), whose key is a variable.
    find "$sources" -name '*.swift' -print0 |
        xargs -0 xcrun xcstringstool extract --modern-localizable-strings --SwiftUI -o "$out" >/dev/null 2>&1
    python3 - "$catalog" "$out" <<'EOF' || status=1
import glob, json, os, re, sys

specifier = re.compile(r"%(\d+\$)?(lld|ld|d|@|arg)")
catalog_path, extracted = sys.argv[1], sys.argv[2]
with open(catalog_path) as f:
    catalog = {specifier.sub("%arg", key) for key in json.load(f)["strings"]}
missing = 0
for path in sorted(glob.glob(extracted + "/*.stringsdata")):
    with open(path) as f:
        data = json.load(f)
    for items in data.get("tables", {}).values():
        for item in items:
            if specifier.sub("%arg", item["key"]) not in catalog:
                source = os.path.relpath(data["source"])
                print(f'{source}:{item["location"]["startingLine"]}: "{item["key"]}" is missing from {catalog_path}')
                missing += 1
sys.exit(1 if missing else 0)
EOF
done

if ((status)); then
    echo "Add the keys: build the app in Xcode for its catalog, or for a package run" \
        "xcrun xcstringstool sync <catalog> --stringsdata <its target's .stringsdata from swift build>"
fi
exit $status
