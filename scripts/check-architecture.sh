#!/usr/bin/env bash
# Enforces the module boundaries from ARCHITECTURE.md §2: each module of JutsuKit and HiggsfieldKit may import
# only the frameworks listed here. SwiftPM already enforces module-to-module dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."

# A function instead of an associative array: macOS ships Bash 3.2, which has no `declare -A`.
allowed() {
    case $1 in
        JutsuCore) echo "Foundation" ;;
        HiggsfieldProviders) echo "Foundation JutsuCore HiggsfieldCore HiggsfieldAPI HiggsfieldMCP os" ;;
        Secrets) echo "Foundation Security JutsuCore os" ;;
        # HiggsfieldKit knows nothing of the app.
        HiggsfieldCore) echo "Foundation FoundationNetworking" ;;
        HiggsfieldAPI) echo "Foundation FoundationNetworking HiggsfieldCore os" ;;
        HiggsfieldMCP) echo "Foundation FoundationNetworking HiggsfieldCore CryptoKit Network os" ;;
        MediaKit) echo "Foundation JutsuCore AVFoundation CoreMedia CoreVideo CoreImage CoreGraphics ImageIO UniformTypeIdentifiers CryptoKit os" ;;
        Persistence) echo "Foundation JutsuCore SwiftData os" ;;
        JobEngine) echo "Foundation FoundationNetworking JutsuCore HiggsfieldCore os" ;;
        Presentation) echo "Foundation JutsuCore Observation os" ;;
        # The helper links these two: nothing of the app, and no AppKit (it starts the app through its own target).
        JutsuAgent) echo "Foundation Darwin Dispatch CryptoKit" ;;
        JutsuMCP) echo "Foundation JutsuAgent HiggsfieldMCP" ;;
    esac
}

status=0
for module in JutsuCore HiggsfieldProviders Secrets MediaKit Persistence JobEngine Presentation JutsuAgent JutsuMCP \
    HiggsfieldCore HiggsfieldAPI HiggsfieldMCP; do
    dir="Packages/JutsuKit/Sources/$module"
    [[ -d $dir ]] || dir="Packages/HiggsfieldKit/Sources/$module"
    [[ -d $dir ]] || continue
    list=$(allowed "$module")
    while IFS=: read -r file line text; do
        name=$(sed -E 's/^.*import[[:space:]]+(struct |class |enum |protocol |func |typealias )?([A-Za-z0-9_]+).*$/\2/' <<<"$text")
        if [[ " $list " != *" $name "* ]]; then
            echo "$file:$line: $module must not import $name (allowed: $list)"
            status=1
        fi
    done < <(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]' "$dir" --include='*.swift' || true)
done

# UI frameworks belong to the app target only.
if grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(SwiftUI|AppKit)\b' Packages/JutsuKit/Sources Packages/HiggsfieldKit/Sources \
    --include='*.swift'; then
    echo "SwiftUI/AppKit are app-target only"
    status=1
fi

exit $status
