#!/bin/sh
# Usage: launcher.sh install|repair|set-defaults|remove [ttt-executable] [config-directory] [extensions...]
#
# Finder hands files to a registered .app as an Apple Event, not argv, so the
# launcher is an AppleScript applet. install leaves an existing TTT.app alone;
# repair rebuilds it. Only an app carrying the marker is ever touched.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
action=${1:-}
exe=${2:-}
app=$HOME/Applications/TTT.app
res=$app/Contents/Resources
marker=$res/ttt-managed
previous=$res/previous-handlers
bundle_id=io.github.simonocampo1.tttlauncher
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
config=${3-${TTT_CONFIG_DIR:-}}
services() { osascript -l JavaScript "$here/services.js" "$@"; }

die() {
	echo "$*" >&2
	exit 1
}

applescript_string() {
	printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"
}

# Sets launch to AppleScript that starts `cmd` (a shell-quoted ttt command
# line) in the terminal ttt was running in when the plugin was installed.
detect_terminal() {
	open_app=''
	terminal=Terminal
	if [ -n "${GHOSTTY_RESOURCES_DIR:-}" ] || [ "${TERM_PROGRAM:-}" = ghostty ]; then
		open_app=Ghostty open_args='-e'
	elif [ -n "${KITTY_WINDOW_ID:-}" ]; then
		open_app=kitty open_args=''
	elif [ -n "${WEZTERM_PANE:-}" ]; then
		open_app=WezTerm open_args='start --'
	elif [ -n "${ALACRITTY_WINDOW_ID:-}" ]; then
		open_app=Alacritty open_args='-e'
	fi
	prefs=$(services preferences "$config" "$exe")
	choice=${TTT_LAUNCHER_TERMINAL:-$(services preference "$prefs" terminal)}
	fallback=$(services preference "$prefs" fallback)
	herdr_mode=''
	case $choice in
	herdr | herdr-app) herdr_mode=$choice ;;
	auto) [ "${HERDR_ENV:-}" != 1 ] || herdr_mode=herdr ;;
	esac
	ordinary=$choice
	[ -z "$herdr_mode" ] || ordinary=$fallback
	case $ordinary in
	auto) ;; # Keep the detected terminal as Herdr's fallback.
	ghostty) open_app=Ghostty open_args='-e' ;;
	kitty) open_app=kitty open_args='' ;;
	wezterm) open_app=WezTerm open_args='start --' ;;
	alacritty) open_app=Alacritty open_args='-e' ;;
	iterm | terminal) open_app='' ;;
	*) die "unknown TTT_LAUNCHER_TERMINAL: $TTT_LAUNCHER_TERMINAL" ;;
	esac
	if [ -n "$open_app" ]; then
		terminal=$open_app
		launch="do shell script \"open -na $open_app --args $open_args \" & cmd"
	elif [ "$ordinary" = iterm ] || { [ "$ordinary" != terminal ] && [ "${TERM_PROGRAM:-}" = iTerm.app ]; }; then
		terminal=iTerm
		launch='tell application "iTerm"
		activate
		create window with default profile command cmd
	end tell'
	else
		launch='tell application "Terminal"
		activate
		do script cmd
	end tell'
	fi
	host_terminal=$terminal
	if [ "$terminal" = Terminal ] && [ "$ordinary" = auto ] && [ "${TERM_PROGRAM:-}" != Apple_Terminal ]; then host_terminal=''; fi
	herdr_exe=''
	herdr_app_exe=''
	herdr_core_exe=''
	if [ "$herdr_mode" = herdr ]; then
		if herdr_exe=$(command -v herdr); then
			# command -v may return a relative PATH entry; launchd needs absolute.
			case $herdr_exe in /*) ;; *) herdr_exe="$PWD/$herdr_exe" ;; esac
			launch="try
		do shell script \"/bin/sh \" & quoted form of POSIX path of (path to resource \"herdr.sh\") & \" \" & quoted form of herdrExe & \" \" & quoted form of cmd & \" \" & quoted form of terminalHost & \" \" & quoted form of firstPath
	on error
		$launch
	end try"
		fi
	fi
	if [ "$herdr_mode" = herdr-app ]; then
		herdr_app_exe=$(command -v herdr-app || true)
		herdr_core_exe=$(command -v hc || true)
		case $herdr_app_exe in '' | /*) ;; *) herdr_app_exe="$PWD/$herdr_app_exe" ;; esac
		case $herdr_core_exe in '' | /*) ;; *) herdr_core_exe="$PWD/$herdr_core_exe" ;; esac
		launch="try
		do shell script \"/bin/sh \" & quoted form of POSIX path of (path to resource \"herdr.sh\") & \" herdr-app \" & quoted form of herdrAppExe & \" \" & quoted form of herdrCoreExe & \" \" & quoted form of cmd & \" \" & quoted form of firstPath
	on error messageText number errorNumber
		if errorNumber is 2 then
			$launch
		else
			display notification messageText with title \"ttt: could not open files\"
		end if
	end try"
	fi
}

applet() {
	cat <<SCRIPT
property tttExe : $(applescript_string "$exe")
property configDir : $(applescript_string "$config")
property terminalApp : $(applescript_string "$terminal")
property terminalHost : $(applescript_string "$host_terminal")
property herdrMode : $(applescript_string "$herdr_mode")
property herdrAppExe : $(applescript_string "$herdr_app_exe")
property herdrCoreExe : $(applescript_string "$herdr_core_exe")
property herdrExe : $(applescript_string "$herdr_exe")

on run
	launchTTT({})
end run

on open theItems
	launchTTT(theItems)
end open

on launchTTT(theItems)
	set resources to POSIX path of (path to resource "forward.sh")
	set forwardCmd to "/bin/sh " & quoted form of resources & " " & quoted form of tttExe & " " & quoted form of configDir & " " & quoted form of terminalApp & " --herdr-app " & quoted form of herdrAppExe & " " & quoted form of herdrCoreExe
	set cmd to "env TTT_CONFIG_DIR=" & quoted form of configDir & " " & quoted form of tttExe & " --welcome"
	set firstPath to ""
	repeat with f in theItems
		if firstPath is "" then set firstPath to POSIX path of f
		set cmd to cmd & " " & quoted form of POSIX path of f
		set forwardCmd to forwardCmd & " " & quoted form of POSIX path of f
	end repeat
	try
		do shell script forwardCmd
		return
	on error messageText number errorNumber
		if errorNumber is not 2 then
			display notification messageText with title "ttt: could not open files"
			return
		end if
	end try
	$launch
end launchTTT
SCRIPT
}

build() {
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	applet >"$tmp/ttt.applescript"
	osacompile -o "$tmp/TTT.app" "$tmp/ttt.applescript"
	plist=$tmp/TTT.app/Contents/Info.plist
	plutil -replace CFBundleIdentifier -string "$bundle_id" "$plist"
	plutil -replace CFBundleName -string TTT "$plist"
	plutil -replace CFBundleIconFile -string ttt "$plist"
	plutil -replace LSUIElement -bool true "$plist"
	plutil -remove CFBundleIconName "$plist" 2>/dev/null || true
	plutil -replace CFBundleDocumentTypes -json "$(services documents "$here/extensions.txt")" "$plist"
	plutil -replace UTExportedTypeDeclarations -json "$(services declarations "$here/extensions.txt")" "$plist"
	cp "$here/ttt.icns" "$tmp/TTT.app/Contents/Resources/ttt.icns"
	rm -f "$tmp/TTT.app/Contents/Resources/applet.icns" "$tmp/TTT.app/Contents/Resources/droplet.icns" "$tmp/TTT.app/Contents/Resources/Assets.car"
	cp "$here/forward.sh" "$here/herdr.sh" "$here/services.js" "$here/launcher.sh" "$here/extensions.txt" "$tmp/TTT.app/Contents/Resources/"
	[ ! -f "$previous" ] || cp "$previous" "$tmp/TTT.app/Contents/Resources/previous-handlers"
	: >"$tmp/TTT.app/Contents/Resources/ttt-managed"
	# Editing Info.plist invalidates osacompile's ad-hoc signature.
	codesign --force --sign - "$tmp/TTT.app" >/dev/null 2>&1
	mkdir -p "$(dirname "$app")"
	rm -rf "$app"
	mv "$tmp/TTT.app" "$app"
	"$lsregister" -f "$app" >/dev/null 2>&1 || true
}

handler() { services get "$1"; }

set_handler() {
	[ "$(services set "$1" "$2")" = 0 ] || die "could not change the default for $1"
}

install() {
	[ "$(uname)" = Darwin ] || die "this plugin is for macOS; use desktop-launcher-linux on Linux"
	if [ -e "$app" ]; then
		[ -e "$marker" ] || die "$app was not created by ttt; leaving it alone"
		[ "$action" = repair ] || return 0
	fi
	if [ -z "$exe" ]; then
		exe=$(command -v ttt) || die "cannot find the ttt executable"
	fi
	[ -z "$config" ] || config=$(services absolute "$config")
	detect_terminal
	build
}

set_defaults() {
	[ -e "$marker" ] || die "TTT.app is not installed; run Desktop Launcher: Repair"
	# Optional extension arguments let Mac verification touch md/json only.
	if [ "$#" -ge 3 ]; then shift 3; else set --; fi
	"$lsregister" -f "$app" >/dev/null 2>&1 || true
	utis=$(services defaults "$here/extensions.txt" "$@")
	applied=0
	for uti in $utis; do
		current=$(handler "$uti")
		if [ "$current" != "$bundle_id" ] && ! awk -v key="$uti" '$1 == key {found=1} END {exit !found}' "$previous" 2>/dev/null; then
			printf '%s %s\n' "$uti" "$current" >>"$previous"
		fi
		set_handler "$uti" "$bundle_id"
		applied=$((applied + 1))
	done
	skipped=$(services excluded "$here/extensions.txt" "$@")
	printf 'Finder defaults: %s text types applied. Excluded extensions: %s\n' "$applied" "${skipped:-none}"
}

remove() {
	[ -e "$app" ] && [ -e "$marker" ] || return 0
	if [ -f "$previous" ]; then
		while read -r uti prev; do
			[ -n "$prev" ] || continue
			current=$(handler "$uti") || die "could not read the default for $uti; keeping recovery data"
			if [ "$current" = "$bundle_id" ]; then set_handler "$uti" "$prev"; fi
		done <"$previous"
	fi
	"$lsregister" -u "$app" >/dev/null 2>&1 || true
	rm -rf "$app"
}

case $action in
install | repair) install ;;
set-defaults) set_defaults "$@" ;;
remove) remove ;;
*) die "usage: $0 install|repair|set-defaults|remove [ttt-executable] [config-directory] [extensions...]" ;;
esac
