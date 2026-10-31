#!/bin/bash
# Ask's results for the search review queries (search spec §9.3), in light and dark, from the hero seed library
# without PhotoKit, at the spec's fixed now. Run through `make screens`, which builds and installs the app first.
#
#   Tools/screens.sh <simulator UDID> <output folder> <bundle id>
#
# The review queries run unlocked (-LZUnlocked 1: the whole seed library); the "free-" ones show a free search, which
# covers the last 12 months (-LZUnlocked 0). Each says its layout (-LZResultsLayout): moment cards, or the "grid-" ones
# as a grid. ONLY="01 33 free-07" limits the queries, THEMES="dark" the appearances, WAIT the seconds each launch gets
# (index, place names and the search). TEXT=AccessibilityXXXL launches at that text size (a UIContentSizeCategory
# name without its prefix) and adds it to the file names.
set -euo pipefail
udid="$1" out="$2" app="$3"
queries=(
    "01|Al-Nakheel Park|1"
    "03|soccer at Al-Nakheel Park|1"
    "07|Greece|1"
    "11|Dubai last December|1"
    "17|trips|1"
    "22|Paris|1"
    "29|sunset|1"
    "33|Salam Park|1"
    "34|the first time I went to Dubai|1"
    "35|last time at Al-Nakheel Park|1"
    "36|Al-Nakheel Park oldest first|1"
    "free-01|Al-Nakheel Park|0"
    "free-07|Greece|0"
    "free-11|Dubai last December|0"
    "free-37|the first time at Al-Nakheel Park|0"
    "grid-01|Al-Nakheel Park|1|grid"
    "grid-07|Greece|1|grid"
    "grid-free-01|Al-Nakheel Park|0|grid"
    "grid-36|Al-Nakheel Park oldest first|1|grid"
)
size=() suffix=""
if [ -n "${TEXT:-}" ]; then
    size=(-UIPreferredContentSizeCategoryName "UICTContentSizeCategory$TEXT")
    suffix="-$(printf '%s' "$TEXT" | tr '[:upper:]' '[:lower:]')"
fi
mkdir -p "$out"
for theme in ${THEMES:-light dark}; do
    for entry in "${queries[@]}"; do
        IFS='|' read -r number query unlocked layout <<< "$entry"
        if [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $number "* ]]; then continue; fi
        slug=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-$//')
        xcrun simctl launch --terminate-running-process "$udid" "$app" -LZSkipOnboarding 1 -LZSeed hero \
            -LZNow 2026-10-28T12:00:00+03:00 -LZUnlocked "$unlocked" -LZResultsLayout "${layout:-moments}" -LZTheme "$theme" \
            -LZQuery "$query" ${size[@]+"${size[@]}"} > /dev/null
        sleep "${WAIT:-15}"
        xcrun simctl io "$udid" screenshot --type=png "$out/$number-$slug-$theme$suffix.png" > /dev/null 2>&1
        echo "$out/$number-$slug-$theme$suffix.png"
    done
done
