#!/bin/zsh
# Development tool, not part of the app: one anonymized snapshot of the live
# tenant, for analysis outside Xcode. Run from anywhere: ./Scripts/snapshot.sh
#
# It runs one live step, LiveSnapshot/takeSnapshot(), through the release
# check (a partial run, never a release check): the allow-list's read-only
# production role on its guarded network (GET and the sign-in only, through
# JTKit's readers), and only when that role reaches the tenant of SUD's saved
# connection (whose tracked Blueprints it reads). Credentials are the role's,
# from the login Keychain the allow-list names; none is
# printed or written. The snapshot is anonymized before it is written, in
# the app's container, and moved here, outside every repo:
#   ~/Developer/_release-gate/sud-snapshots/SUD snapshot <date and time>.json
# Made-up IDs come from a key kept beside the snapshots (.snapshot-key,
# created once), so the same device gets the same ID in every snapshot.
cd "$(dirname "$0")/.." || exit 1

OUT="$HOME/Developer/_release-gate/sud-snapshots"
KEYFILE="$OUT/.snapshot-key"
PICKUP="$HOME/Library/Containers/be.jordythery.softwareupdatedashboard/Data/tmp/SUDSnapshots"

mkdir -p "$OUT" && chmod 700 "$OUT" || { print -u2 "Can’t make $OUT"; exit 1 }
if [[ ! -s "$KEYFILE" ]]; then
    ( umask 077; openssl rand -hex 32 > "$KEYFILE" ) || { print -u2 "Can’t make the snapshot key"; exit 1 }
fi

export SUD_SNAPSHOT=1 TEST_RUNNER_SUD_SNAPSHOT=1 SUD_SNAPSHOT_SCRIPT="${0:A}"
export TEST_RUNNER_SUD_SNAPSHOT_KEY="$(<"$KEYFILE")"
./Scripts/release-check.sh --include-production --only "takeSnapshot()"
check=$?
unset TEST_RUNNER_SUD_SNAPSHOT_KEY TEST_RUNNER_SUD_SNAPSHOT SUD_SNAPSHOT SUD_SNAPSHOT_SCRIPT

moved=0
for file in "$PICKUP"/*.json(N); do
    mv "$file" "$OUT/" && chmod 600 "$OUT/${file:t}" && print -r -- "Snapshot: $OUT/${file:t}" && (( moved++ ))
done
(( moved )) || print -u2 "No snapshot was written (see the report above)."
(( check == 0 && moved > 0 ))
