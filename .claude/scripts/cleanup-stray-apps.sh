#!/bin/bash
#
# Removes throwaway apps and simulators that sessions leave behind, and nothing else.
#
# Three kinds of cruft accumulate while working on this project, and none of them announce
# themselves:
#
#   1. Probe apps. A session scaffolds a tiny Xcode project to test one behaviour in isolation,
#      installs it on a simulator, learns the answer, and abandons it. `com.probe.navbar` sat on
#      a simulator for months that way. They are invisible until something goes looking.
#   2. Agent simulators. A worktree agent creates its own device so it is not fighting the main
#      one for a boot, then the worktree goes away and the device does not.
#   3. The real app, spread across every simulator it was ever tested on. Six copies of an app
#      whose server binds a fixed port is how you end up debugging the wrong instance.
#
# SAFETY, because this deletes things:
#   - Simulators only. `simctl` cannot touch a physical device, and nothing here calls
#     `devicectl`, so the phone in your pocket is never in scope.
#   - Never removes an app whose bundle id belongs to this project (derived from the same
#     xcconfig the build uses) except under the explicit "spread across simulators" rule below,
#     which always keeps the booted device and the most recent ones.
#   - Never removes a bundle id listed in .claude/cleanup-keep.txt. That file exists because
#     "not declared in this repo" is not the same as "junk" — other real projects on this Mac
#     install apps too, and deleting one of those would destroy work.
#   - Never deletes a booted simulator.
#   - Prints every action. Run with --dry-run to see them without doing them.
#
# Usage: cleanup-stray-apps.sh [--dry-run] [--quiet] [--keep-recent N] [--hook]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEEP_FILE="$REPO_ROOT/.claude/cleanup-keep.txt"
STAMP="${TMPDIR:-/tmp}/vvdemus-cleanup-stray-apps.stamp"

DRY_RUN=0
QUIET=0
HOOK_MODE=0
# How many simulators keep the real app. Enough to switch between an iPhone and an iPad without
# a reinstall; not so many that a fixed-port server has several instances to be confused by.
KEEP_RECENT=2

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --quiet) QUIET=1 ;;
        --hook) HOOK_MODE=1; QUIET=1 ;;
        --keep-recent) shift; KEEP_RECENT="${1:-2}" ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
# Actions are printed even when quiet: a hook that silently deletes things is how you lose
# something you needed and never find out what took it.
act() { printf '%s\n' "$*"; }

# --- Hook mode: only after a command that could have installed something -----------------------
#
# PostToolUse fires on every Bash call. Sweeping the whole simulator set each time would be a
# real cost on an unrelated `git status`, so the payload decides.
if [ "$HOOK_MODE" -eq 1 ]; then
    PAYLOAD="$(cat)"
    COMMAND="$(printf '%s' "$PAYLOAD" | /usr/bin/python3 -c \
        'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: print("")' 2>/dev/null)"
    case "$COMMAND" in
        *xcodebuild*|*simctl*|*xcrun*) ;;
        *) exit 0 ;;
    esac
    # Throttled. A test run is a dozen xcodebuild invocations; sweeping after each is pointless
    # and makes the session feel slow for no extra safety.
    if [ -f "$STAMP" ]; then
        LAST=$(stat -f %m "$STAMP" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        [ $((NOW - LAST)) -lt 120 ] && exit 0
    fi
    touch "$STAMP"
fi

command -v xcrun >/dev/null 2>&1 || exit 0

# --- Which bundle ids belong to this project ---------------------------------------------------
#
# Read from the xcconfig rather than hardcoded, because `VVDEMUS_BUNDLE_ID` is per-machine by
# design (see ios/SETUP.md) — hardcoding it here would make this script delete the real app on
# the other developer's Mac.
read_xcconfig_id() {
    [ -f "$1" ] || return 0
    /usr/bin/sed -n 's/^[[:space:]]*VVDEMUS_BUNDLE_ID[[:space:]]*=[[:space:]]*\([^[:space:]/]*\).*/\1/p' "$1" | head -1
}

PROJECT_IDS=""
for cfg in "$REPO_ROOT/ios/Config/Signing.local.xcconfig" "$REPO_ROOT/ios/Config/Signing.xcconfig"; do
    base="$(read_xcconfig_id "$cfg")"
    [ -n "$base" ] || continue
    # The suffixes project.yml appends per target.
    PROJECT_IDS="$PROJECT_IDS $base $base.mac $base.tests"
done

if [ -z "${PROJECT_IDS// /}" ]; then
    say "cleanup-stray-apps: could not read VVDEMUS_BUNDLE_ID — refusing to guess which apps are ours."
    exit 0
fi

KEEP_IDS=""
if [ -f "$KEEP_FILE" ]; then
    KEEP_IDS="$(/usr/bin/sed -e 's/#.*//' -e 's/[[:space:]]//g' "$KEEP_FILE" | /usr/bin/grep -v '^$' | tr '\n' ' ')"
fi

is_project_id() { case " $PROJECT_IDS " in *" $1 "*) return 0 ;; esac; return 1; }
is_kept_id()    { case " $KEEP_IDS "    in *" $1 "*) return 0 ;; esac; return 1; }

# Removes an app from a simulator, and actually checks that it went.
#
# `simctl uninstall` only works on a *booted* device. On a shutdown one it fails with
# "Unable to lookup in current state: Shutdown" — and exits 0 while doing it, so `|| fallback`
# never fires and the sweep cheerfully reported removing things it had left exactly where they
# were. Most of the devices this runs against are shutdown, so that was nearly all of them.
#
# So the bundle container is the source of truth: try the supported path, then look.
# uninstall_app <udid> <state> <bundle-id> <bundle-container-dir>
uninstall_app() {
    local udid="$1" state="$2" bid="$3" container="$4"
    if [ "$state" = "Booted" ]; then
        xcrun simctl uninstall "$udid" "$bid" >/dev/null 2>&1
    fi
    [ -d "$container" ] || return 0

    /bin/rm -rf "$container"
    # And the app's data container, or its defaults, downloads and caches outlive the "uninstall"
    # and are silently inherited by the next install of the same bundle id.
    local data_root="$SIM_ROOT/$udid/data/Containers/Data/Application"
    [ -d "$data_root" ] || return 0
    local meta
    for candidate in "$data_root"/*; do
        [ -d "$candidate" ] || continue
        meta="$candidate/.com.apple.mobile_container_manager.metadata.plist"
        [ -f "$meta" ] || continue
        if [ "$(/usr/libexec/PlistBuddy -c 'Print :MCMMetadataIdentifier' "$meta" 2>/dev/null)" = "$bid" ]; then
            /bin/rm -rf "$candidate"
        fi
    done
}

REMOVED_APPS=0
REMOVED_DEVICES=0

# --- Walk every simulator ----------------------------------------------------------------------
#
# Bundle containers are read straight off disk rather than via `simctl listapps`, which is slow
# per device and needs the device booted to answer for user apps.
DEVICE_LIST="$(xcrun simctl list devices -j 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for runtime, devices in data.get("devices", {}).items():
    for d in devices:
        if d.get("isAvailable") is False:
            continue
        print("\t".join([d.get("udid",""), d.get("state",""), d.get("name","")]))
' 2>/dev/null)"

[ -n "$DEVICE_LIST" ] || exit 0

SIM_ROOT="$HOME/Library/Developer/CoreSimulator/Devices"
# Device+timestamp for every simulator carrying the real app, so the "spread across simulators"
# rule can keep the ones actually in use.
PROJECT_APP_HITS=""

while IFS=$'\t' read -r UDID STATE NAME; do
    [ -n "$UDID" ] || continue
    APPS_DIR="$SIM_ROOT/$UDID/data/Containers/Bundle/Application"
    [ -d "$APPS_DIR" ] || continue

    for CONTAINER in "$APPS_DIR"/*; do
        [ -d "$CONTAINER" ] || continue
        APP="$(/usr/bin/find "$CONTAINER" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null)"
        [ -n "$APP" ] || continue
        BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null)"
        [ -n "$BID" ] || continue

        if is_project_id "$BID"; then
            MTIME=$(stat -f %m "$APP" 2>/dev/null || echo 0)
            PROJECT_APP_HITS="$PROJECT_APP_HITS$MTIME\t$UDID\t$STATE\t$NAME\t$BID\t$CONTAINER\n"
            continue
        fi

        if is_kept_id "$BID"; then
            say "  keep    $BID on $NAME (protected by cleanup-keep.txt)"
            continue
        fi

        act "  remove  $BID  ($(basename "$APP")) from $NAME"
        if [ "$DRY_RUN" -eq 0 ]; then
            uninstall_app "$UDID" "$STATE" "$BID" "$CONTAINER"
        fi
        REMOVED_APPS=$((REMOVED_APPS + 1))
    done
done <<< "$DEVICE_LIST"

# --- The real app, spread across simulators ----------------------------------------------------
#
# Keeps every booted device (you are plainly using it) plus the most recently installed ones.
# Uninstalling elsewhere destroys that device's app data — play history, downloads, radios — but
# a simulator's data is test junk by construction, and stale copies of a fixed-port server are
# actively misleading.
if [ -n "$PROJECT_APP_HITS" ]; then
    KEPT=0
    while IFS=$'\t' read -r MTIME UDID STATE NAME BID CONTAINER; do
        [ -n "$UDID" ] || continue
        if [ "$STATE" = "Booted" ]; then
            say "  keep    $BID on $NAME (booted)"
            continue
        fi
        if [ "$KEPT" -lt "$KEEP_RECENT" ]; then
            KEPT=$((KEPT + 1))
            say "  keep    $BID on $NAME (recent)"
            continue
        fi
        act "  remove  $BID from $NAME (the real app, but this simulator is not in use)"
        if [ "$DRY_RUN" -eq 0 ]; then
            uninstall_app "$UDID" "$STATE" "$BID" "$CONTAINER"
        fi
        REMOVED_APPS=$((REMOVED_APPS + 1))
    done <<< "$(printf '%b' "$PROJECT_APP_HITS" | /usr/bin/grep -v '^$' | /usr/bin/sort -rn)"
fi

# --- Simulators an agent made and left -------------------------------------------------------
while IFS=$'\t' read -r UDID STATE NAME; do
    [ -n "$UDID" ] || continue
    # Devices this project made for itself, rather than the stock ones. Stock simulators are
    # named after the hardware ("iPhone 17", "iPad Air 11-inch (M4)"), so anything carrying the
    # project's name or an agent's was created by a run that has since ended — a worktree agent
    # wanting its own device, or an end-to-end pairing test wanting a device with no history.
    case "$NAME" in
        *-agent-*|*agent-*|VVDemus-*) ;;
        *) continue ;;
    esac
    if [ "$STATE" = "Booted" ]; then
        say "  keep    simulator $NAME (booted)"
        continue
    fi
    act "  remove  simulator $NAME ($UDID) — created by an agent run that has ended"
    if [ "$DRY_RUN" -eq 0 ]; then
        xcrun simctl delete "$UDID" >/dev/null 2>&1
    fi
    REMOVED_DEVICES=$((REMOVED_DEVICES + 1))
done <<< "$DEVICE_LIST"

# --- iOS build products masquerading as Mac apps ----------------------------------------------
#
# Every iOS build leaves a `VVDemus.app` in DerivedData, and macOS registers it with
# LaunchServices because it is an app bundle sitting in the user's home. It then shows up in
# Spotlight and Launchpad as an application and does nothing at all when opened — an iOS bundle
# has no Mac executable. Two of them were sitting there.
#
# Unregistering does not delete the build; it only removes the claim that this is something you
# can launch. The next iOS build re-registers it, which is why this runs on every sweep rather
# than once.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
UNREGISTERED=0
if [ -x "$LSREGISTER" ]; then
    GHOSTS="$("$LSREGISTER" -dump 2>/dev/null | /usr/bin/awk '
        /^[[:space:]]*path:/ { p=$2; for (i=3; i<=NF; i++) p=p" "$i }
        /^[[:space:]]*identifier:/ { print $2 "\t" p }
    ' | /usr/bin/grep '/DerivedData/' || true)"

    while IFS=$'\t' read -r BID APP_PATH; do
        [ -n "$APP_PATH" ] || continue
        # Only ours, and only bundles built for a platform this Mac cannot run. The Mac build
        # lands in plain `Debug/` or `Release/` and is a real, launchable app — leave it alone.
        is_project_id "$BID" || continue
        case "$APP_PATH" in
            *-iphoneos/*|*-iphonesimulator/*|*-watchos/*|*-watchsimulator/*|\
            *-appletvos/*|*-appletvsimulator/*|*-xros/*|*-xrsimulator/*) ;;
            *) continue ;;
        esac
        # Strip the trailing " (0x1234)" LaunchServices prints after the path.
        CLEAN_PATH="$(printf '%s' "$APP_PATH" | /usr/bin/sed 's/ (0x[0-9a-f]*)$//')"
        [ -d "$CLEAN_PATH" ] || continue
        act "  unregister  $BID  (iOS build product registered as a Mac app) $CLEAN_PATH"
        if [ "$DRY_RUN" -eq 0 ]; then
            "$LSREGISTER" -u "$CLEAN_PATH" >/dev/null 2>&1
        fi
        UNREGISTERED=$((UNREGISTERED + 1))
    done <<< "$GHOSTS"
fi

if [ "$UNREGISTERED" -gt 0 ]; then
    act "cleanup-stray-apps: unregistered $UNREGISTERED non-Mac build product(s) from LaunchServices"
fi

if [ "$REMOVED_APPS" -gt 0 ] || [ "$REMOVED_DEVICES" -gt 0 ]; then
    SUFFIX=""
    [ "$DRY_RUN" -eq 1 ] && SUFFIX=" (dry run — nothing was removed)"
    act "cleanup-stray-apps: $REMOVED_APPS app(s), $REMOVED_DEVICES simulator(s)$SUFFIX"
else
    say "cleanup-stray-apps: nothing to remove."
fi

exit 0
