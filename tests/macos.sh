#!/bin/sh
# Portable runtime/LaunchServices regression tests (Node and Python 3 required).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/ttt-launcher-test.XXXXXX)
fixture=''
cp -R "$root/desktop-launcher-macos" "$tmp/plugin"
script=$tmp/plugin/launcher.sh
trap '[ -z "$fixture" ] || { kill "$fixture" 2>/dev/null || true; wait "$fixture" 2>/dev/null || true; }; rm -rf "$tmp"' EXIT
# Optional native JXA gate; replace UI activation in a temporary source copy.
if [ "${TEST_NATIVE_JXA:-}" = 1 ]; then
    if [ "$(uname)" != Darwin ]; then echo 'native JXA: skipped (requires macOS)'; exit; fi
    mkdir -p "$tmp/native-root" "$tmp/bin" "$tmp/home"
    cp -R "$root/desktop-launcher-macos" "$tmp/native-root/desktop-launcher-macos"
    python3 - "$tmp" <<'PY_NATIVE'
from pathlib import Path
import sys
root = Path(sys.argv[1])
p = root / 'native-root/desktop-launcher-macos/services.js'
source = p.read_text().replace('/usr/bin/open', str(root / 'bin/open'))
source = source.replace('$.NSRunningApplication.runningApplicationWithProcessIdentifier(pid)', 'null')
source = source.replace('$.NSRunningApplication.runningApplicationsWithBundleIdentifier($(ids[argv[2]]))', '({count:0})')
p.write_text(source)
PY_NATIVE
    env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR -u HERDR_APP_HOME -u HC_SESSION -u HC_TERMINAL_ID HOME="$tmp/home" PATH="$tmp/bin:$PATH" python3 "$root/tests/macos-herdr.py" "$tmp/native-root" "$tmp"
    exit
fi
export TEST_BRIDGE="$tmp/bridge.js" TEST_STATE="$tmp/state.json" TEST_LOG="$tmp/events"
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/config" "$tmp/temp with spaces"
ln -s "$(command -v node)" "$tmp/bin/node"
cat >"$TEST_BRIDGE" <<'STUB'
const child = require('child_process');
const fs = require('fs'), vm = require('vm'), assert = require('assert'), path = require('path');
const [script, ...args] = process.argv.slice(4);
const state = fs.existsSync(process.env.TEST_STATE) ? JSON.parse(fs.readFileSync(process.env.TEST_STATE)) : {};
const log = s => fs.appendFileSync(process.env.TEST_LOG, s + '\n');
const wrap = js => ({js, get stringByStandardizingPath() {return wrap(path.normalize(js).replace(/^\/private\//, '/'));},
    get stringByResolvingSymlinksInPath() {return wrap(fs.existsSync(js) ? fs.realpathSync(js) : path.resolve(js));},
    get stringByDeletingLastPathComponent() {return wrap(path.dirname(js));}});
const $ = x => wrap(x);
$.NSFileManager = {defaultManager:{currentDirectoryPath:wrap(process.cwd()), fileExistsAtPath:p=>fs.existsSync(p.js),
    createFileAtPathContentsAttributes(p) {fs.writeFileSync(p.js,''); return true;},
    removeItemAtPathError(p) {fs.rmSync(p.js,{force:true}); return true;}}};
$.NSData = {data:{}};
$.NSTemporaryDirectory = () => wrap(process.env.TMPDIR);
$.NSProcessInfo = {processInfo:{get globallyUniqueString(){return wrap(require('crypto').randomUUID());}}};
$.NSFileHandle = {fileHandleForWritingAtPath:p=>({path:p.js, closeFile(){}}), fileHandleWithNullDevice:{}};
$.NSThread = {sleepForTimeInterval:s=>child.spawnSync('/bin/sleep',[String(s)])};
$.NSTask = {alloc:{get init() {return {
    isRunning:false, terminationStatus:0,
    get launch() {
        let exe=this.launchPath.js, args=this.arguments.js;
        if (exe==='/usr/bin/open') exe=process.env.HOME+'/../bin/open';
        let result;
        if (exe==='/bin/ps' && process.env.TEST_ANCESTRY) {
            const ancestry=Object.fromEntries(process.env.TEST_ANCESTRY.split(',').map(p=>p.split(':')));
            result={status:0,stdout:ancestry[args[args.length-1]] || '1'};
        } else result=child.spawnSync(exe,args,{encoding:'utf8',timeout:500,killSignal:'SIGKILL'});
        this.terminationStatus=result.status === null ? 124 : result.status;
        if (this.standardOutput.path) fs.writeFileSync(this.standardOutput.path,result.stdout || '');
    }, get waitUntilExit(){}, get terminate(){}
};}}};
$.NSHomeDirectory = () => wrap(process.env.HOME);
$.NSUTF8StringEncoding = 4; $.kLSRolesAll = -1;
$.NSString = {stringWithContentsOfFileEncodingError(p) {try {return wrap(fs.readFileSync(p.js, 'utf8'));} catch (_) {return null;}}};
$.LSCopyDefaultRoleHandlerForContentType = t => {
    assert.equal(typeof t.js, 'string', 'CoreServices needs a bridged string');
    if (process.env.FAIL_GET === t.js) throw Error('handler read failed');
    return wrap(state[t.js] || 'original.' + t.js);
};
$.LSSetDefaultRoleHandlerForContentType = (t, _, h) => {
    assert.equal(typeof t.js, 'string'); assert.equal(typeof h.js, 'string');
    log('set ' + t.js + ' ' + h.js);
    if (process.env.FAIL_SET === t.js) return -1;
    state[t.js] = h.js; fs.writeFileSync(process.env.TEST_STATE, JSON.stringify(state)); return 0;
};
const declarations = process.env.HOME + '/Applications/TTT.app/Contents/declared.json';
const declared = fs.existsSync(declarations) && !process.env.UNDECLARED ? JSON.parse(fs.readFileSync(declarations)) : [];
const native = {md:['net.daringfireball.markdown'], markdown:['net.daringfireball.markdown'], json:['public.json'],
    htm:['public.html'], html:['public.html'], xhtml:['public.xhtml'], shtml:['public.html'], phtml:['public.html'],
    ts:['public.mpeg-2-transport-stream', 'com.microsoft.typescript'], svg:['public.svg-image'],
    dot:['com.microsoft.word.dot'], pp:['cx.c3.pp-archive'], txt:['public.plain-text']};
const parents = t => {
    const d = declared.find(d => d.UTTypeIdentifier === t);
    if (d) return d.UTTypeConformsTo;
    if (t === 'public.svg-image') return ['public.text','public.xml','public.image'];
    if (t === 'com.microsoft.typescript') return ['public.text','public.source-code'];
    return /^(net.daringfireball|public.json|public.plain-text|public.html|public.xhtml)/.test(t) ? ['public.text'] : [];
};
$.UTTypeConformsTo = (t, p) => t.js === p.js || parents(t.js).includes(p.js);
const resolved = ext => native[ext] || declared.filter(d => d.UTTypeTagSpecification['public.filename-extension'] === ext).map(d => d.UTTypeIdentifier);
$.UTTypeCreateAllIdentifiersForTag = (_, ext, parent) => wrap((resolved(ext.js) || []).filter(t => !parent || $.UTTypeConformsTo(wrap(t), parent)));
$.NSRunningApplication = {runningApplicationWithProcessIdentifier(pid) {
    log('focus ' + pid); return {activationPolicy:process.env.FOCUS_FALLBACK ? 1 : 0,
        isTerminated:false, activateWithOptions(){log('activate pid ' + pid); return true;}};
}, runningApplicationsWithBundleIdentifier(id) {
    return {count:1, objectAtIndex(){return {activateWithOptions(){log('activate ' + id.js); return true;}};}};
}};
const context = { $, ObjC:{import(){}, castRefToObject:x=>x, deepUnwrap:x=>x.js},
    Application:{currentApplication(){return {doShellScript(){return '1';}};}} };
try {
    vm.createContext(context); vm.runInContext(fs.readFileSync(script, 'utf8'), context);
    const value = context.run(args); if (value !== undefined) console.log(value);
} catch (err) { console.error(err); process.exit(1); }
STUB
cat >"$tmp/bin/osascript" <<'STUB'
#!/bin/sh
exec node "$TEST_BRIDGE" "$@"
STUB
cat >"$tmp/bin/osacompile" <<'STUB'
#!/bin/sh
mkdir -p "$2/Contents/Resources"
cp "$3" "$2/Contents/Resources/script.applescript"
touch "$2/Contents/Resources/droplet.icns" "$2/Contents/Resources/applet.icns" "$2/Contents/Resources/Assets.car"
STUB
cat >"$tmp/bin/plutil" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$HOME/plutil.log"
if [ "$2" = UTExportedTypeDeclarations ]; then
    printf '%s\n' "$4" >"$(dirname "$5")/declared.json"
fi
STUB
cat >"$tmp/bin/stat" <<'STUB'
#!/bin/sh
if [ "$1" = -f ]; then
    python3 -c 'import os,sys,stat; s=os.stat(sys.argv[1]); print(str(s.st_uid)+":"+format(stat.S_IMODE(s.st_mode),"o"))' "$3"
else
    /usr/bin/stat "$@"
fi
STUB
cat >"$tmp/bin/ttt" <<'STUB'
#!/bin/sh
printf 'config=%s\n' "$TTT_CONFIG_DIR" >>"$TEST_LOG"
printf 'arg=%s\n' "$@" >>"$TEST_LOG"
[ "${CLIENT_HANG:-0}" = 0 ] || exec python3 -c 'import time; time.sleep(60)'
[ "${CLIENT_FAIL:-0}" = 0 ] || { echo 'ttt: cannot open file' >&2; exit 1; }
STUB
cat >"$tmp/bin/nc" <<'STUB'
#!/usr/bin/env python3
import socket,sys
assert sys.argv[1:4] == ['-U','-w','1']
s=socket.socket(socket.AF_UNIX); s.settimeout(1)
try: s.connect(sys.argv[4])
except OSError: sys.exit(1)
STUB
cat >"$tmp/bin/sleep" <<'STUB'
#!/bin/sh
echo "$$" >>"$HOME/timers"
exec /bin/sleep "${TIMER_SECONDS:-$1}"
STUB
printf '#!/bin/sh\necho Darwin\n' >"$tmp/bin/uname"
cat >"$tmp/bin/codesign" <<'STUB'
#!/bin/sh
exit "${FAIL_SIGN:-0}"
STUB
chmod +x "$tmp/bin/"*
app=$tmp/home/Applications/TTT.app
res=$app/Contents/Resources
applet=$res/script.applescript
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u PI_CODING_AGENT_DIR -u HERDR_APP_HOME -u HC_SESSION -u HC_TERMINAL_ID -u HERDR_ENV -u TTT_LAUNCHER_TERMINAL -u TTT_CONFIG_DIR -u KITTY_WINDOW_ID -u WEZTERM_PANE -u ALACRITTY_WINDOW_ID -u GHOSTTY_RESOURCES_DIR -u TERM_PROGRAM HOME="$tmp/home" PATH="$tmp/bin:$PATH" TMPDIR="$tmp/temp with spaces/" "$@"; }
service() { run osascript -l JavaScript "$root/desktop-launcher-macos/services.js" "$@"; }
if [ "${TEST_ONLY_HERDR:-}" = 1 ]; then
    run python3 "$root/tests/macos-herdr.py" "$root" "$tmp"
    exit
fi

run sh "$script" install '/opt/my "apps"/ttt' "$tmp/config"
grep -qF 'property tttExe : "/opt/my \"apps\"/ttt"' "$applet" || fail 'exe quoting'
grep -qF 'tell application "Terminal"' "$applet" || fail 'terminal fallback'
for file in ttt-managed ttt.icns forward.sh services.js launcher.sh extensions.txt; do [ -e "$res/$file" ] || fail "missing $file"; done
for file in droplet.icns applet.icns Assets.car; do [ ! -e "$res/$file" ] || fail "competing icon $file"; done
grep -q 'LSUIElement -bool true' "$tmp/home/plutil.log" || fail 'Dock setting'
grep -q 'remove CFBundleIconName' "$tmp/home/plutil.log" || fail 'icon setting'
run env GHOSTTY_RESOURCES_DIR=/x sh "$script" install /usr/local/bin/ttt
grep -qF '/opt/my' "$applet" || fail 'install rebuilt existing app'
# Herdr takes precedence over the terminal hosting its client. The generated
# app must retain a normal terminal fallback and an absolute CLI path.
cat >"$tmp/bin/herdr" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_LOG'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\n')
if os.environ.get('HERDR_FAIL') == sys.argv[1]: sys.exit(1)
if sys.argv[1] == 'tab': print(os.environ.get('HERDR_REPLY', '{"result":{"root_pane":{"pane_id":"w9:p3"}}}'))
STUB
chmod +x "$tmp/bin/herdr"
run env HERDR_ENV=1 GHOSTTY_RESOURCES_DIR=/x sh "$script" repair "$tmp/bin/ttt"
grep -qF 'property terminalHost : "Ghostty"' "$applet" || fail 'Herdr host detection'
grep -qF 'property terminalApp : "Ghostty"' "$applet" || fail 'Herdr forwarding host'
grep -qF "property herdrExe : \"$tmp/bin/herdr\"" "$applet" || fail 'absolute Herdr path'
grep -qF 'path to resource "herdr.sh"' "$applet" || fail 'Herdr runtime missing'
grep -qF 'on error' "$applet" || fail 'Herdr error fallback missing'
grep -qF 'do shell script "open -na Ghostty --args -e " & cmd' "$applet" || fail 'Herdr lost Ghostty fallback'
mv "$tmp/bin/herdr" "$tmp/herdr"
run env HERDR_ENV=1 GHOSTTY_RESOURCES_DIR=/x PATH="$tmp/bin:/usr/bin:/bin" sh "$script" repair "$tmp/bin/ttt"
grep -qF 'property terminalApp : "Ghostty"' "$applet" || fail 'missing Herdr did not fall through'
grep -qF 'property herdrExe : ""' "$applet" || fail 'missing Herdr still selected'
mv "$tmp/herdr" "$tmp/bin/herdr"
for pair in ghostty:Ghostty kitty:kitty wezterm:WezTerm alacritty:Alacritty iterm:iTerm terminal:Terminal; do
    override=${pair%:*}; expected=${pair#*:}
    run env HERDR_ENV=1 GHOSTTY_RESOURCES_DIR=/x TTT_LAUNCHER_TERMINAL="$override" sh "$script" repair "$tmp/bin/ttt"
    grep -qF "property terminalApp : \"$expected\"" "$applet" || fail "override $override ignored"
    grep -qF 'property herdrExe : ""' "$applet" || fail "override $override still selected Herdr"
done
run env TTT_LAUNCHER_TERMINAL=herdr sh "$script" repair "$tmp/bin/ttt"
grep -qF "property herdrExe : \"$tmp/bin/herdr\"" "$applet" || fail 'explicit Herdr ignored'
grep -qF 'property terminalHost : ""' "$applet" || fail 'unknown Herdr host guessed'
grep -qF 'tell application "Terminal"' "$applet" || fail 'Herdr lost Terminal fallback'
cp "$applet" "$tmp/before-invalid"
if run env TTT_LAUNCHER_TERMINAL=invalid sh "$script" repair "$tmp/bin/ttt" 2>/dev/null; then fail 'invalid override accepted'; fi
cmp "$tmp/before-invalid" "$applet" || fail 'invalid override replaced app'
# Saved configuration wins over the host on Repair, and invalid input preserves the app.
printf '{"terminal":"herdr-app","fallback":"ghostty"}' >"$tmp/config/desktop-launcher.json"
run sh "$script" repair "$tmp/bin/ttt" "$tmp/config"
grep -qF 'property herdrMode : "herdr-app"' "$applet" || fail 'saved Herdr.app choice ignored'
grep -qF 'property terminalApp : "Ghostty"' "$applet" || fail 'saved fallback ignored'
run env KITTY_WINDOW_ID=5 sh "$script" repair "$tmp/bin/ttt" "$tmp/config"
grep -qF 'property herdrMode : "herdr-app"' "$applet" || fail 'Repair changed saved terminal'
grep -qF 'property terminalApp : "Ghostty"' "$applet" || fail 'Repair changed saved fallback'
run env TTT_LAUNCHER_TERMINAL=terminal sh "$script" repair "$tmp/bin/ttt" "$tmp/config"
grep -qF 'property terminalApp : "Terminal"' "$applet" || fail 'environment override lost'
for choice in auto herdr-app herdr ghostty kitty wezterm alacritty iterm terminal; do
    printf '{"terminal":"%s"}' "$choice" >"$tmp/config/desktop-launcher.json"
    [ "$(service preferences "$tmp/config" "$tmp/bin/ttt")" = "{\"terminal\":\"$choice\",\"fallback\":\"auto\"}" ] || fail "preference $choice"
done
for fallback in auto ghostty kitty wezterm alacritty iterm terminal; do
    printf '{"fallback":"%s"}' "$fallback" >"$tmp/config/desktop-launcher.json"
    service preferences "$tmp/config" "$tmp/bin/ttt" >/dev/null || fail "fallback $fallback"
done
cp "$applet" "$tmp/before-invalid"
for json in invalid '[]' null '{"terminal":42}' '{"terminal":"bogus"}' '{"fallback":"herdr"}' '{"fallback":"herdr-app"}'; do
    printf '%s' "$json" >"$tmp/config/desktop-launcher.json"
    if run sh "$script" repair "$tmp/bin/ttt" "$tmp/config" 2>/dev/null; then fail "accepted preferences $json"; fi
    cmp "$tmp/before-invalid" "$applet" || fail 'invalid preferences replaced app'
done
rm "$tmp/config/desktop-launcher.json"
mkdir -p "$tmp/bin/config" "$tmp/home/.config/ttt"
printf '{"terminal":"ghostty"}' >"$tmp/home/.config/ttt/desktop-launcher.json"
[ "$(service preferences '' "$tmp/bin/ttt")" = '{"terminal":"ghostty","fallback":"auto"}' ] || fail 'home preference missed'
printf '{}' >"$tmp/bin/config/settings.json"
printf '{"terminal":"kitty"}' >"$tmp/bin/config/desktop-launcher.json"
ln -s "$tmp/bin/ttt" "$tmp/preference-link"
[ "$(service preferences '' "$tmp/preference-link")" = '{"terminal":"kitty","fallback":"auto"}' ] || fail 'sidecar preference missed'
[ "$(service preferences "$tmp/config" "$tmp/bin/ttt")" = '{"terminal":"auto","fallback":"auto"}' ] || fail 'override searched other preferences'
rm "$tmp/bin/config/settings.json" "$tmp/bin/config/desktop-launcher.json" "$tmp/home/.config/ttt/desktop-launcher.json"
# Runtime boundary: exact cwd and command survive shell metacharacters, spaces
# and newlines. No jq or shell evaluation of the Herdr reply is involved.
mkdir -p "$tmp/a 'quoted' directory"
command="env TTT_CONFIG_DIR='' '/opt/my ttt' --welcome 'a; \$(touch nope)'"
: >"$TEST_LOG"
run sh "$res/herdr.sh" "$tmp/bin/herdr" "$command" Ghostty "$tmp/a 'quoted' directory/file.md"
python3 - "$TEST_LOG" "$tmp" "$command" <<'PY'
import json, pathlib, sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
assert json.loads(lines[0])==['tab','create','--focus','--cwd',sys.argv[2]+"/a 'quoted' directory",'--label','ttt']
assert json.loads(lines[1])==['pane','run','w9:p3',sys.argv[3]]
assert lines[2]=='activate com.mitchellh.ghostty'
PY
: >"$TEST_LOG"
run sh "$res/herdr.sh" "$tmp/bin/herdr" "$command" ''
python3 - "$TEST_LOG" "$tmp/home" <<'PY'
import json, pathlib, sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
assert json.loads(lines[0])[4]==sys.argv[2]
assert len(lines)==2, 'unknown host must skip activation'
PY
for failure in tab pane; do
    if run env HERDR_FAIL="$failure" sh "$res/herdr.sh" "$tmp/bin/herdr" "$command" Ghostty 2>/dev/null; then fail "Herdr $failure failure hidden"; fi
done
for reply in invalid '{}' '{"result":{"root_pane":{"pane_id":""}}}'; do
    if run env HERDR_REPLY="$reply" sh "$res/herdr.sh" "$tmp/bin/herdr" "$command" Ghostty 2>/dev/null; then fail 'invalid Herdr reply accepted'; fi
done
# Property: passing any shell command as one argument never evaluates or
# changes it before pane run; directory names remain one cwd argument.
run python3 - "$res/herdr.sh" "$tmp" <<'PY'
import json, os, pathlib, random, subprocess, sys
helper, tmp = sys.argv[1], pathlib.Path(sys.argv[2])
rng=random.Random(61030)
alphabet="abc XYZ'\"\\;$`()[]*?\n\t日本語"
for i in range(12):
    command=''.join(rng.choices(alphabet, k=rng.randrange(1, 200)))
    # Named regression: a parent directory ending in a newline must survive.
    directory=tmp/('trailing-newline\n' if i == 0 else ''.join(rng.choices(alphabet, k=rng.randrange(1, 40))))
    directory.mkdir(exist_ok=True)
    pathlib.Path(os.environ['TEST_LOG']).write_text('')
    subprocess.run(['sh', helper, str(tmp/'bin/herdr'), command, '', str(directory/'file.md')], check=True)
    calls=pathlib.Path(os.environ['TEST_LOG']).read_text().splitlines()
    assert json.loads(calls[0])[4]==str(directory), repr(directory)
    assert json.loads(calls[1])==['pane','run','w9:p3',command]
PY
: >"$TEST_LOG"
service focus 42 Ghostty >/dev/null
grep -qx 'activate pid 42' "$TEST_LOG" || fail 'actual editor ancestry ignored'
: >"$TEST_LOG"
run env FOCUS_FALLBACK=1 osascript -l JavaScript "$res/services.js" focus 42 Ghostty >/dev/null
grep -qx 'activate com.mitchellh.ghostty' "$TEST_LOG" || fail 'Herdr host fallback not activated'
run python3 "$root/tests/macos-herdr.py" "$root" "$tmp"
service documents "$root/desktop-launcher-macos/extensions.txt" >"$tmp/docs.json"
service defaults "$root/desktop-launcher-macos/extensions.txt" >"$tmp/defaults"
service excluded "$root/desktop-launcher-macos/extensions.txt" >"$tmp/excluded"
python3 - "$root" "$tmp" <<'PY'
import json,sys,pathlib
root,tmp=map(pathlib.Path,sys.argv[1:])
ext=(root/'desktop-launcher-macos/extensions.txt').read_text().splitlines()
docs=json.loads((tmp/'docs.json').read_text())[0]
assert len(ext)==155 and docs['CFBundleTypeExtensions']==ext
utis=(tmp/'defaults').read_text().splitlines()
assert len(utis)==len(set(utis))
assert {'public.plain-text','public.svg-image','com.microsoft.typescript'} <= set(utis)
assert any(t.startswith('io.github.simonocampo1.') for t in utis), 'unknown extensions need registered declarations'
assert not set(utis)&{'public.html','public.xhtml','public.text','public.source-code','public.data',
    'public.mpeg-2-transport-stream','com.microsoft.word.dot','cx.c3.pp-archive'}
assert {'public.html','public.svg-image','public.mpeg-2-transport-stream','com.microsoft.typescript'} <= set(docs['LSItemContentTypes'])
assert set((tmp/'excluded').read_text().strip().split(', ')) == {'htm','html','xhtml','shtml','phtml','dot','pp'}
PY
[ "$(service absolute /private/tmp/a/../b)" = /private/tmp/b ] || fail 'config alias changed'
printf 'bash_login\nc++\ncplus\n' >"$tmp/types"
run env UNDECLARED=1 osascript -l JavaScript "$res/services.js" declarations "$tmp/types" >"$tmp/private.json"
[ -z "$(run env UNDECLARED=1 osascript -l JavaScript "$res/services.js" defaults "$tmp/types")" ] || fail 'unresolved types defaulted'
python3 - "$tmp/private.json" <<'PYT'
import json,sys,re
ids=[t['UTTypeIdentifier'] for t in json.load(open(sys.argv[1]))]
assert len(ids)==3 and len(set(ids))==3 and all(re.fullmatch('[a-z0-9.-]+',s) for s in ids)
PYT
mkdir -p "$tmp/bin/config" "$tmp/home/.config/ttt"
printf '{"reuseWindow":true}' >"$tmp/home/.config/ttt/settings.json"
[ "$(service reuse '' "$tmp/bin/ttt")" = yes ] || fail 'home settings missed'
for settings in 'invalid' ''; do
    printf '%s' "$settings" >"$tmp/bin/config/settings.json"
    [ "$(service reuse '' "$tmp/bin/ttt")" = no ] || fail 'invalid/empty sidecar fell through'
done
for key in reuseWindow ReuseWindow REUSEWINDOW; do
    printf '{"%s":true}' "$key" >"$tmp/bin/config/settings.json"
    [ "$(service reuse '' "$tmp/bin/ttt")" = yes ] || fail "settings field $key missed"
done
printf '{"reuseWindow":true}' >"$tmp/bin/config/settings.json"
[ "$(service reuse "$tmp/config" "$tmp/bin/ttt")" = no ] || fail 'override searched sidecar'
ln -s "$tmp/bin/ttt" "$tmp/linked-ttt"
[ "$(service reuse '' "$tmp/linked-ttt")" = yes ] || fail 'executable symlink settings missed'
run env TTT_CONFIG_DIR= sh "$script" repair "$tmp/bin/ttt"
grep -qF 'property configDir : ""' "$applet" || fail 'normal search forced an override'
service defaults "$root/desktop-launcher-macos/extensions.txt" >"$tmp/repaired-defaults"
cmp "$tmp/defaults" "$tmp/repaired-defaults" || fail 'repair lost registered text types'
# Capture before changes, preserve first originals, preserve through repair, retry restore.
if run env FAIL_SET=public.json sh "$script" set-defaults '' '' md json 2>/dev/null; then fail 'partial failure hidden'; fi
grep -qx 'public.json original.public.json' "$res/previous-handlers" || fail 'failed set not journaled'
run sh "$script" set-defaults '' '' md json
cp "$res/previous-handlers" "$tmp/saved"
run sh "$script" set-defaults '' '' md json
cmp "$tmp/saved" "$res/previous-handlers"
run env GHOSTTY_RESOURCES_DIR=/x TTT_CONFIG_DIR="$tmp/config" sh "$script" repair "$tmp/bin/ttt"
cmp "$tmp/saved" "$res/previous-handlers"
if run env FAIL_SIGN=1 sh "$script" repair "$tmp/bin/ttt" "$tmp/config"; then fail 'sign failure hidden'; fi
cmp "$tmp/saved" "$res/previous-handlers"
grep -qF 'do shell script "open -na Ghostty --args -e " & cmd' "$applet" || fail 'Ghostty launch'
if run env FAIL_GET=public.json sh "$script" remove 2>/dev/null; then fail 'handler read failure hidden'; fi
cmp "$tmp/saved" "$res/previous-handlers"
[ "$(service get public.json)" = io.github.simonocampo1.tttlauncher ] || fail 'handler read failure changed default'
if run env FAIL_SET=public.json sh "$script" remove 2>/dev/null; then fail 'restore failure hidden'; fi
[ -f "$res/previous-handlers" ] || fail 'recovery data lost'
service set net.daringfireball.markdown later.choice >/dev/null
rm -rf "$tmp/plugin"
run sh "$res/launcher.sh" remove
[ "$(service get net.daringfireball.markdown)" = later.choice ] || fail 'later choice overwritten'
[ ! -e "$app" ] || fail 'app not removed'
grep -q 'set public.json original.public.json' "$TEST_LOG" || fail 'original not restored'
cp -R "$root/desktop-launcher-macos" "$tmp/plugin"
# Runtime: real Unix socket in a spaced temp directory, no RPC implementation in helper.
run sh "$script" install "$tmp/bin/ttt" "$tmp/config"
file="$tmp/a 'quoted' file.md"; touch "$file"
forward() { run sh "$res/forward.sh" "$tmp/bin/ttt" "$tmp/config" Ghostty "$@"; }
unavailable() { rc=0; forward "$@" || rc=$?; [ "$rc" = 2 ] || fail "fallback status $rc"; }
unavailable "$file"
printf '{"reuseWindow":true}\n' >"$tmp/config/settings.json"
unavailable "$file" # Old ttt/no listener.
# Linux has no macOS nc: use a real connect-only shim in the bundled helper.
if [ "$(uname)" != Darwin ]; then sed "s|/usr/bin/nc|$tmp/bin/nc|" "$res/forward.sh" >"$tmp/forward"; cp "$tmp/forward" "$res/forward.sh"; fi
python3 - "$tmp" "$$" <<'PYT' &
import sys,pathlib,socket,hashlib,os,selectors
root=pathlib.Path(sys.argv[1]); d=root/'temp with spaces'/('ttt-'+str(os.getuid())); d.mkdir(mode=0o700)
prefix=hashlib.sha256(str(root/'config').encode()).hexdigest()[:8]
def base36(n):
    s=''
    while n: n,r=divmod(n,36); s='0123456789abcdefghijklmnopqrstuvwxyz'[r]+s
    return s
sel=selectors.DefaultSelector()
for config,stamp,pid,live in [(prefix,'00000001',os.getpid(),True),(prefix,'100000000',int(sys.argv[2]),True),
    (prefix,'200000000',int(sys.argv[2]),False),(prefix,'zzzzzzzz!',os.getpid(),True),(prefix,'bad',os.getpid(),True),('othercfg','zzzzzzzz',os.getpid(),True)]:
    s=socket.socket(socket.AF_UNIX); s.bind(str(d/(config+'-'+stamp+'-'+base36(pid)+'.sock')))
    if live: s.listen(); sel.register(s,selectors.EVENT_READ)
    else: s.close()
(root/'ready').touch()
while True:
    for key,_ in sel.select():
        conn,_=key.fileobj.accept(); conn.close()
PYT
fixture=$!
while [ ! -e "$tmp/ready" ]; do /bin/sleep .05; done
: >"$TEST_LOG"
run python3 - "$res/forward.sh" "$tmp/bin/ttt" "$tmp/config" "$file" <<'PYT'
import subprocess,sys,time,os,pathlib,signal
start=time.monotonic()
p=subprocess.Popen(['sh',*sys.argv[1:4],'Ghostty',sys.argv[4]],stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
try: out,err=p.communicate(timeout=3)
finally:
    try: os.killpg(p.pid,signal.SIGKILL)
    except ProcessLookupError: pass
assert p.returncode==0,err
timers=pathlib.Path(os.environ['HOME'])/'timers'
for pid in timers.read_text().splitlines() if timers.exists() else []:
    try: os.kill(int(pid),0)
    except ProcessLookupError: continue
    raise AssertionError('timer survived: '+pid)
print('captured handoff completed in %.3fs; timer processes reaped'%(time.monotonic()-start))
PYT
grep -qx "focus $$" "$TEST_LOG" || fail 'newest live editor not focused'
grep -qxF "arg=$file" "$TEST_LOG" || fail 'filename changed'
[ "$(grep -c '^arg=' "$TEST_LOG")" = 2 ] || fail 'unexpected CLI file argument'
grep -qxF "config=$tmp/config" "$TEST_LOG" || fail 'config not passed'
run env FOCUS_FALLBACK=1 osascript -l JavaScript "$res/services.js" focus "$$" Ghostty >/dev/null
grep -qx 'activate com.mitchellh.ghostty' "$TEST_LOG" || fail 'terminal fallback not activated'
# Successful delivery stays successful when focusing its Herdr terminal fails.
: >"$TEST_LOG"
: >"$tmp/warm-herdr-events"
run env HERDR_LOG="$tmp/warm-herdr-events" HERDR_STATE="$tmp/warm-herdr-state" HERDR_PIDS="$tmp/herdr-pids" FOCUS_OWNER="$$" HERDR_CASE=focus-fail sh "$res/forward.sh" "$tmp/bin/ttt" "$tmp/config" Ghostty --herdr-app "$tmp/bin/herdr-app" "$tmp/bin/hc" "$file"
[ "$(grep -c '^config=' "$TEST_LOG")" = 1 ] || fail 'warm Herdr handoff launched twice'
python3 - "$tmp/warm-herdr-events" <<'PY_WARM'
import json, pathlib, sys
calls = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert ['do', 'agent.focus', '{"terminal":"t22"}'] in calls, calls
assert not any(c[:2] in [['do','tab.new'],['do','space.new']] for c in calls), calls
PY_WARM
: >"$TEST_LOG"
rc=0
run env CLIENT_FAIL=1 sh "$res/forward.sh" "$tmp/bin/ttt" "$tmp/config" Ghostty "$file" 2>"$tmp/error" || rc=$?
[ "$rc" = 1 ] || fail 'handoff error allowed terminal fallback'
grep -q 'cannot open file' "$tmp/error" || fail 'stderr lost'
[ "$(grep -c '^config=' "$TEST_LOG")" = 1 ] || fail 'handoff retried'
if grep -q '^focus' "$TEST_LOG"; then fail 'failed handoff focused'; fi
rc=0
run env CLIENT_HANG=1 TIMER_SECONDS=.2 sh "$res/forward.sh" "$tmp/bin/ttt" "$tmp/config" Ghostty "$file" 2>"$tmp/error" || rc=$?
[ "$rc" = 1 ] || fail 'watchdog exit status'
grep -q 'handoff timed out' "$tmp/error" || fail 'watchdog failed to bound client'
unavailable "$tmp" # Folders launch a terminal.
printf '{"reuseWindow":false}\n' >"$tmp/config/settings.json"
unavailable "$file"
printf '{"reuseWindow":true}\n' >"$tmp/config/settings.json"
chmod 755 "$tmp/temp with spaces/ttt-$(id -u)"
unavailable "$file"
chmod 700 "$tmp/temp with spaces/ttt-$(id -u)"
kill "$fixture"; wait "$fixture" 2>/dev/null || true; fixture=
unavailable "$file" # Stale sockets with live shell PID are unavailable.
run sh "$script" remove
mkdir -p "$app"
if run sh "$script" install /usr/local/bin/ttt 2>/dev/null; then fail 'overwrote unmanaged app'; fi
run sh "$script" remove
[ -d "$app" ] || fail 'deleted unmanaged app'
echo 'macos (stubbed runtime and LaunchServices): ok'
