#!/bin/bash
# Ask's results for the search review queries (search spec §9.3), in light and dark, from the hero seed library
# without PhotoKit, at the spec's fixed now. Run through `make screens`, which builds and installs the app first.
#
#   Tools/screens.sh <simulator UDID> <output folder> <bundle id>
#
# ONLY="01 33" limits the queries, THEMES="dark" the appearances, WAIT the seconds each launch gets (index, place
# names and the search).
set -euo pipefail
udid="$1" out="$2" app="$3"
queries=(
    "01|Al-Nakheel Park"
    "03|soccer at Al-Nakheel Park"
    "07|Greece"
    "11|Dubai last December"
    "17|trips"
    "22|Paris"
    "29|sunset"
    "33|Salam Park"
)
mkdir -p "$out"
for theme in ${THEMES:-light dark}; do
    for entry in "${queries[@]}"; do
        number="${entry%%|*}" query="${entry#*|}"
        if [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $number "* ]]; then continue; fi
        slug=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-$//')
        xcrun simctl launch --terminate-running-process "$udid" "$app" -LZSkipOnboarding 1 -LZSeed hero \
            -LZNow 2026-10-28T12:00:00+03:00 -LZTheme "$theme" -LZQuery "$query" > /dev/null
        sleep "${WAIT:-15}"
        xcrun simctl io "$udid" screenshot --type=png "$out/$number-$slug-$theme.png" > /dev/null 2>&1
        echo "$out/$number-$slug-$theme.png"
    done
done
