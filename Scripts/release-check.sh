#!/bin/zsh
# Software Update Dashboard's release check: JTKit's template
# (Scripts/release-check-lib.sh) with this app's settings. See JTKit's
# ROADMAP, step 11. Run from anywhere: ./Scripts/release-check.sh [options]
#
# Tenants are roles on the local allow-list, never named here:
# - jamfpro-production: the read-only production Jamf Pro, over the Platform
#   API; reads only (READ_ONLY_ROLES keeps it so, whatever the allow-list
#   says): GET and HEAD plus the sign-in. The app never changes anything in
#   Jamf. A production role takes part only with --include-production (or
#   the allow-list's productionReads), so a full run is
#   ./Scripts/release-check.sh --include-production
# Public hosts: Apple's release data, read by the app (JTKit's AppleReleases)
# from sofafeed.macadmins.io and gdmf.apple.com. They're named in the
# allow-list's publicHosts (JTKit 1.5.0), which lets only a GET without
# credentials, cookies or an authorization header through to them.
cd "$(dirname "$0")/.." || exit 1

APP_NAME="Software Update Dashboard"
APP_CODE="SUD"
PROJECT="Software Update Dashboard.xcodeproj"
SCHEME="Software Update Dashboard Release Check"
UNIT_TESTS="Software Update Dashboard Tests"
UI_TESTS="Software Update Dashboard UITests"
SMOKE_CLASS="DemoSmokeUITests"
SMOKE_FILE="$PWD/Software Update Dashboard UITests/DemoSmokeUITests.swift"
SIGNIN_TEST="Software Update Dashboard Tests/LiveSignInTests"
# Apple's release data first (public hosts only), then the production reads.
LIVE_TESTS=("Software Update Dashboard Tests/LiveReadTests/appleReleaseData()"
            "Software Update Dashboard Tests/LiveReadTests/mobileGroupEndToEnd()")
CLEANUP_TEST="Software Update Dashboard Tests/LiveCleanupTests"
ROLES=(jamfpro-production)
READ_ONLY_ROLES=(jamfpro-production)
CREDENTIALS=("jamfpro-production:jamfPlatform:client-id" "jamfpro-production:jamfPlatform:client-secret")
LEGACY_PREFIXES=""
APP_FAULTS=()
DOMAIN="be.jordythery.softwareupdatedashboard"
CONTAINER="$HOME/Library/Containers/$DOMAIN/Data"
TEST_HOST_CONTAINER="$DOMAIN"
FINGERPRINT_DEFAULTS=()
for key in connections activeConnectionID demoMode trackedBlueprints trackedGroups; do
    FINGERPRINT_DEFAULTS+=("$CONTAINER/Library/Preferences/$DOMAIN $key")
done
FINGERPRINT_PATHS=("$CONTAINER/Library/Application Support/History"
                   "$CONTAINER/Library/Application Support/Unreadable Copies"
                   "$CONTAINER/Library/Logs/Software Update Dashboard")
KEYCHAIN_PREFIXES=("be.jordythery.softwareupdatedashboard.jamf")

rm -rf "$CONTAINER/tmp/SoftwareUpdateDashboard-under-test"

if [[ " $* " == *" --local-jtkit "* ]]; then
    LIB="${JTKIT_LOCAL:-$HOME/Developer/JTKit}/Scripts/release-check-lib.sh"
else
    PACKAGES="$HOME/Library/Developer/Xcode/DerivedData/JTKitReleaseCheck-$APP_CODE/SourcePackages"
    xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
        -clonedSourcePackagesDirPath "$PACKAGES" > /dev/null || exit 1
    LIB="$PACKAGES/checkouts/JTKit/Scripts/release-check-lib.sh"
fi
[[ -f "$LIB" ]] || { print -u2 "No release-check template at $LIB (JTKit 1.5.0 or later)"; exit 1 }
source "$LIB"
release_check_main "$@"
