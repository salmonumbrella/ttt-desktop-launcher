#!/bin/sh
# 2 means unavailable (safe to open a terminal); 1 means an attempted handoff failed.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
exe=$1 override=$2 terminal=$3
shift 3
app='' core=''
if [ "${1:-}" = --herdr-app ]; then
	app=$2 core=$3
	shift 3
fi
[ "$#" -gt 0 ] || exit 2
for file do
	[ -f "$file" ] || exit 2
done
[ "$(osascript -l JavaScript "$here/services.js" reuse "$override" "$exe")" = yes ] || exit 2
config=$(osascript -l JavaScript "$here/services.js" absolute "${override:-$HOME/.config/ttt}")
prefix=$(printf '%s' "$config" | shasum -a 256 | cut -c 1-8)
temp=${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}
dir=${temp%/}/ttt-$(id -u)
[ -d "$dir" ] && [ ! -L "$dir" ] || exit 2
[ "$(stat -f '%u:%Lp' "$dir")" = "$(id -u):700" ] || exit 2
# Read lines rather than splitting the temp directory or socket path on spaces.
selected=$(find "$dir" -type s -name "$prefix-*.sock" -print | LC_ALL=C sort -r | while IFS= read -r socket; do
	name=${socket##*/}; name=${name#"$prefix-"}; stamp=${name%-*}
	case $stamp in (????????*) ;; (*) continue ;; esac
	case $stamp in (*[!0-9a-z]*) continue ;; esac
	encoded=${name#*-}; encoded=${encoded%.sock}
	case $encoded in (''|*[!0-9a-z]*) continue ;; esac
	candidate=$(printf '%s\n' "$encoded" | awk '{n=0; for(i=1;i<=length;i++) n=n*36+index("0123456789abcdefghijklmnopqrstuvwxyz",substr($0,i,1))-1; printf "%.0f",n}')
	if [ "$candidate" -le 0 ] || [ "$candidate" -gt 2147483647 ] || ! kill -0 "$candidate" 2>/dev/null; then continue; fi
	/usr/bin/nc -U -w 1 "$socket" </dev/null >/dev/null 2>&1 || continue
	printf '%s' "$candidate"
	break
done)
[ -n "$selected" ] || exit 2
err=$(mktemp)
client='' watchdog=''
cleanup() {
	[ -z "$watchdog" ] || { kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true; }
	[ -z "$client" ] || { kill "$client" 2>/dev/null || true; wait "$client" 2>/dev/null || true; }
	rm -f "$err"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# An empty override preserves core's executable-adjacent settings search.
TTT_CONFIG_DIR=$override "$exe" --welcome "$@" </dev/null >/dev/null 2>"$err" &
client=$!
# Detach capture pipes and reap the timer even when the client finishes early.
(
	timer=
	trap '[ -z "$timer" ] || { kill "$timer" 2>/dev/null || true; wait "$timer" 2>/dev/null || true; }' EXIT
	trap 'exit 0' HUP INT TERM
	sleep 32 & timer=$!
	wait "$timer"
	echo 'ttt: handoff timed out' >>"$err"
	kill "$client" 2>/dev/null || true
) </dev/null >/dev/null 2>&1 &
watchdog=$!
status=0
wait "$client" || status=$?
client=
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true
watchdog=
if [ "$status" -ne 0 ]; then
	cat "$err" >&2
	exit 1
fi
osascript -l JavaScript "$here/services.js" focus "$selected" "$terminal" "$app" "$core" >/dev/null 2>&1 || true
