"""Fixture CLI boundary tests; never call the installed Herdr app or core."""
import json
import os
import pathlib
import random
import subprocess
import sys
import time

root, tmp = map(pathlib.Path, sys.argv[1:])
bin_dir = tmp / 'bin'
app = bin_dir / 'herdr-app'
core = bin_dir / 'hc'
log = tmp / 'herdr-events'
state = tmp / 'herdr-state'
app.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, time
args=sys.argv[1:]; case=os.environ.get('HERDR_CASE','remote')
log=pathlib.Path(os.environ['HERDR_LOG']); state=pathlib.Path(os.environ['HERDR_STATE'])
with open(os.environ['HERDR_PIDS'],'a') as f: f.write(str(os.getpid())+'\\n')
with log.open('a') as f: f.write(json.dumps(args)+'\\n')
if args==['ls']:
    count=int(state.read_text()) if state.exists() else 0
    state.write_text(str(count+1))
    if case=='timeout': sys.exit(1)
    if case=='hung-inspect': time.sleep(60)
    if case=='cold' and count<2: sys.exit(1)
    spaces=[{'id':'remote/s1','machine':'remote','active':True,'tabs':[{'terminals':[{'terminal':'remote/t1','pane':'p1'}]}]}]
    if case!='no-local':
        spaces += [{'id':'s1','machine':None,'active':False,'tabs':[{'terminals':[{'terminal':'t11','pane':'p11'},{'terminal':'t22','pane':'p22'}]}]},
                   {'id':'s2','machine':None,'active':case=='active','tabs':[]}]
    print(json.dumps({'spaces':spaces})); sys.exit()
if args[:2]==['do','agent.focus']:
    if case=='focus-fail': sys.exit(1)
    print('{}'); sys.exit()
assert args[:1]==['do']
assert args[1] in ['tab.new','space.new'], args
payload=json.loads(args[2])
assert payload.get('space','s1') in ['s1','s2'], 'remote launch'
assert payload.get('machine','')=='', 'remote machine'
if case=='create-fail': print('{"error":"rejected"}'); sys.exit(1)
if case=='create-hang': time.sleep(60)
if case=='create-invalid': print('broken reply'); sys.exit()
print('{"terminal":"t99","pane":"p99"}')
''')
core.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['HERDR_PIDS'],'a') as f: f.write(str(os.getpid())+'\\n')
with open(os.environ['HERDR_LOG'],'a') as f: f.write(json.dumps(['hc']+sys.argv[1:])+'\\n')
assert sys.argv[1:] in [['get','t11','--json'],['get','t22','--json']]
print(json.dumps({'pid':999,'foreground':{'pid':int(os.environ.get('FOCUS_OWNER','101')) if sys.argv[2]=='t22' else 998}}))
''')
(bin_dir / 'open').write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['HERDR_PIDS'],'a') as f: f.write(str(os.getpid())+'\\n')
with open(os.environ['HERDR_LOG'],'a') as f: f.write(json.dumps(['open']+sys.argv[1:])+'\\n')
sys.exit(1 if os.environ.get('HERDR_CASE')=='focus-fail' else 0)
''')
for file in [app, core, bin_dir / 'open']:
    file.chmod(0o755)
native = bool(os.environ.get('TEST_NATIVE_JXA'))
owner = os.getpid() if native else 101
pids_file = tmp / 'herdr-pids'
pids_file.write_text('')
env = dict(os.environ, HERDR_PIDS=str(pids_file), FOCUS_OWNER=str(owner), HERDR_LOG=str(log), HERDR_STATE=str(state), TEST_ANCESTRY='42:101,101:1')
for key in ['CODEX_HOME','CLAUDE_CONFIG_DIR','PI_CODING_AGENT_DIR','HERDR_APP_HOME','HC_SESSION','HC_TERMINAL_ID']:
    env.pop(key, None)
helper = root / 'desktop-launcher-macos/herdr.sh'
services = root / 'desktop-launcher-macos/services.js'

def calls():
    return [json.loads(line) for line in log.read_text().splitlines()]

def reset(case):
    log.write_text('')
    state.unlink(missing_ok=True)
    return dict(env, HERDR_CASE=case)

def launch(case, command='ttt --welcome', first='', app_path=None):
    result = subprocess.run(['sh', str(helper), 'herdr-app', str(app if app_path is None else app_path),
                             str(core), command, first], env=reset(case), capture_output=True, text=True, timeout=18)
    return result

# Wrong local selection, inherited remote target, missing argv, or a second create fails these.
for case, expected in [('remote','s1'),('active','s2'),('cold','s1'),('no-local',None)]:
    result = launch(case)
    assert result.returncode == 0, (case, result.returncode, result.stderr)
    events = calls()
    creates = [c for c in events if c[:1] == ['do'] and c[1] != 'agent.focus']
    assert len(creates) == 1, events
    payload = json.loads(creates[0][2])
    assert payload['argv'] == ['/bin/sh','-c','ttt --welcome']
    assert payload['folder'] == env['HOME']
    assert payload['name'] == 'TTT'
    if expected:
        assert creates[0][1] == 'tab.new' and payload['space'] == expected
    else:
        assert creates[0][1] == 'space.new' and payload['machine'] == '' and payload['tab'] == 'TTT'
    if case == 'cold':
        assert events.count(['open','-a','Herdr']) == 2, events
        assert sum(c == ['ls'] for c in events) >= 3

for case, status in [('timeout',2),('hung-inspect',2),('create-fail',1),('create-hang',1),('create-invalid',1),('focus-fail',0)]:
    started = time.monotonic()
    result = launch(case)
    assert result.returncode == status, (case,result.returncode,result.stderr)
    elapsed = time.monotonic()-started
    assert elapsed < (17 if native else 13), (case,elapsed)
    print('%s bounded in %.2fs' % (case,elapsed), flush=True)
    creates = [c for c in calls() if c[:1] == ['do'] and c[1] != 'agent.focus']
    assert len(creates) == (0 if status == 2 else 1), (case, calls())
assert launch('remote',app_path=tmp/'missing-cli').returncode == 2
assert calls() == []

# Random commands and filenames preserve bytes through JSON and shell boundaries.
rng=random.Random(61105)
alphabet="abc XYZ'\"\\;$`()[]*?\n\t日本語"
for i in range(12):
    command=''.join(rng.choices(alphabet,k=rng.randrange(1,140)))
    directory=tmp/('trailing-newline\n' if i==0 else ''.join(rng.choices(alphabet,k=24)))
    directory.mkdir(exist_ok=True)
    first=directory if i%2 else directory/'a;$(touch nope).md'
    result=launch('remote',command,str(first))
    assert result.returncode==0, result.stderr
    create=next(c for c in calls() if c[:2]==['do','tab.new'])
    payload=json.loads(create[2])
    assert payload['argv']==['/bin/sh','-c',command]
    assert payload['folder']==str(directory)

for case in ['remote','focus-fail']:
    result=subprocess.run(['osascript','-l','JavaScript',str(services),'focus',str(owner) if native else '42','Ghostty',str(app),str(core)],
                          env=reset(case),capture_output=True,text=True,timeout=5)
    assert result.returncode==0, result.stderr
    events=calls()
    assert ['hc','get','t11','--json'] in events and ['hc','get','t22','--json'] in events
    assert ['do','agent.focus','{"terminal":"t22"}'] in events, events
    assert all('remote/t1' not in c for c in events)
    assert not any(c[:2] in [['do','tab.new'],['do','space.new']] for c in events)
for pid in pids_file.read_text().splitlines():
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        continue
    raise AssertionError('fixture CLI survived: '+pid)
print('Herdr.app fixture launch, deadlines, local focus and quoting: ok')
