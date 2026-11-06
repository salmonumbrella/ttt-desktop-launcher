#!/bin/sh
# Exit 2 permits fallback before dispatch; exit 1 means creation may have happened.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
if [ "$1" = herdr-app ]; then
	app=$2 command=$4 # $3 is the core CLI, used by post-handoff focus.
	cwd=${5:-$HOME}
	[ -x "$app" ] || exit 2
	if [ ! -d "$cwd" ]; then
		cwd=${cwd%/*}
		[ -n "$cwd" ] || cwd=/
	fi
	status=$(osascript -l JavaScript "$here/services.js" herdr-launch "$app" "$command" "$cwd") || exit 1
	case $status in
	0 | 2) exit "$status" ;;
	*) echo 'ttt: Herdr launch failed; check Herdr before opening again' >&2; exit 1 ;;
	esac
fi
herdr=$1 command=$2 host=$3
cwd=${4:-$HOME}
if [ ! -d "$cwd" ]; then
	# Finder paths are absolute; avoid command substitution stripping newlines.
	cwd=${cwd%/*}
	[ -n "$cwd" ] || cwd=/
fi
reply=$("$herdr" tab create --focus --cwd "$cwd" --label ttt)
pane=$(osascript -l JavaScript "$here/services.js" herdr-pane "$reply")
"$herdr" pane run "$pane" "$command"
# Activation failure must not launch a second editor after pane run succeeded.
if [ -n "$host" ]; then
	osascript -l JavaScript "$here/services.js" focus 1 "$host" >/dev/null 2>&1 || true
fi
