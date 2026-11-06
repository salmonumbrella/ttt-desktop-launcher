// Synthetic deadlines exercise the final-match boundary without launching apps.
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
for (const scenario of ['expired', 'failed', 'timed-out', 'success', 'activation-failed', 'activation-expired', 'no-match']) {
    let now = 0;
    const dispatched = [], fallback = [];
    const $ = x => x;
    $.NSRunningApplication = {
        runningApplicationWithProcessIdentifier(pid) {
            return {isTerminated:false, activationPolicy:0,
                activateWithOptions() {fallback.push(pid); return true;}};
        }
    };
    const context = vm.createContext({$, ObjC:{import(){}}, Date:{now:() => now}});
    vm.runInContext(source, context);
    context.execute = (exe, args, deadline) => {
        assert.equal(deadline, exe === 'app' && args[0] === 'ls' ? 1000 : 3000, 'one shared focus budget');
        if (now >= deadline) return null;
        dispatched.push([exe, ...args]);
        if (exe === '/bin/ps') return {status:0, text:'1'};
        if (exe === 'app' && args[0] === 'ls') return {status:0, text:JSON.stringify({spaces:[
            {id:'s1', machine:null, tabs:[{terminals:[{terminal:'t22'}]}]}
        ]})};
        if (exe === 'core') {
            assert.deepEqual(Array.from(args), ['get', 't22', '--json']);
            if (scenario === 'expired' || scenario === 'no-match') now = 3000;
            return {status:0, text:JSON.stringify({pid:scenario === 'no-match' ? 99 : 42})};
        }
        if (exe === 'app') {
            assert.deepEqual(Array.from(args), ['do', 'agent.focus', '{"terminal":"t22"}']);
            if (scenario === 'timed-out') {now = 3000; return null;}
            if (scenario === 'activation-expired') now = 3000;
            return {status:scenario === 'failed' ? 1 : 0, text:'{}'};
        }
        assert.equal(exe, '/usr/bin/open');
        assert.deepEqual(Array.from(args), ['-a', 'Herdr']);
        return {status:scenario === 'activation-failed' ? 1 : 0, text:''};
    };
    assert.equal(context.run(['focus', '42', 'Ghostty', 'app', 'core']), 'yes');
    const needsFallback = ['expired', 'failed', 'timed-out', 'no-match'].includes(scenario);
    assert.deepEqual(fallback, needsFallback ? [42] : [], scenario + ': ordinary focus fallback');
    assert.equal(dispatched.filter(c => c[1] === 'do').length,
        ['expired', 'no-match'].includes(scenario) ? 0 : 1, scenario + ': focus dispatch count');
    assert.equal(dispatched.filter(c => c[0] === '/usr/bin/open').length,
        ['success', 'activation-failed'].includes(scenario) ? 1 : 0, scenario + ': activation count');
    assert(!dispatched.some(c => ['tab.new', 'space.new'].includes(c[2])), 'focus never launches an editor');
}
console.log('Herdr focus deadline and dispatch fallback: ok');
