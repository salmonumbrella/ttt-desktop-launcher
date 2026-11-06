// Shared LaunchServices bridge. All CFString arguments must be Objective-C strings.
ObjC.import('CoreServices');
ObjC.import('Foundation');
ObjC.import('AppKit');
function read(path) {
    var value = $.NSString.stringWithContentsOfFileEncodingError($(path), $.NSUTF8StringEncoding, null);
    return value ? value.js : '';
}
function absolute(path) {
    if (path[0] !== '/') path = $.NSFileManager.defaultManager.currentDirectoryPath.js + '/' + path;
    var parts = [];
    path.split('/').forEach(function(p) {
        if (p === '..') parts.pop(); else if (p && p !== '.') parts.push(p);
    });
    return '/' + parts.join('/');
}
function configPaths(override, exe) {
    return override ? [override] : [
        $(exe).stringByResolvingSymlinksInPath.stringByDeletingLastPathComponent.js + '/config',
        $.NSHomeDirectory().js + '/.config/ttt'];
}
function preferences(override, exe) {
    var paths = configPaths(override, exe), dir = paths[paths.length - 1];
    if (paths.length > 1 && $.NSFileManager.defaultManager.fileExistsAtPath($(paths[0] + '/settings.json'))) dir = paths[0];
    var file = dir + '/desktop-launcher.json', value = {terminal:'auto', fallback:'auto'};
    if ($.NSFileManager.defaultManager.fileExistsAtPath($(file))) {
        value = JSON.parse(read(file));
        if (!value || Array.isArray(value) || typeof value !== 'object') throw Error('invalid desktop-launcher.json');
    }
    var ordinary = ['auto', 'ghostty', 'kitty', 'wezterm', 'alacritty', 'iterm', 'terminal'];
    var terminal = value.terminal === undefined ? 'auto' : value.terminal;
    var fallback = value.fallback === undefined ? 'auto' : value.fallback;
    if (ordinary.concat(['herdr', 'herdr-app']).indexOf(terminal) < 0 || ordinary.indexOf(fallback) < 0)
        throw Error('invalid terminal or fallback in desktop-launcher.json');
    return JSON.stringify({terminal:terminal, fallback:fallback});
}
// Use files rather than pipes so a large snapshot cannot block a child on stdout.
function execute(exe, args, deadline) {
    if (!exe || Date.now() >= deadline) return null;
    var file = $.NSTemporaryDirectory().js + 'ttt-herdr-' + $.NSProcessInfo.processInfo.globallyUniqueString.js;
    var task = $.NSTask.alloc.init, handle;
    try {
        $.NSFileManager.defaultManager.createFileAtPathContentsAttributes($(file), $.NSData.data, $({NSFilePosixPermissions:384}));
        handle = $.NSFileHandle.fileHandleForWritingAtPath($(file));
        task.launchPath = $(exe); task.arguments = $(args);
        task.standardOutput = handle; task.standardError = $.NSFileHandle.fileHandleWithNullDevice;
        task.launch;
        while (task.isRunning && Date.now() < deadline) $.NSThread.sleepForTimeInterval(0.02);
        if (task.isRunning) {
            // The CLI may ignore TERM; kill and reap only the child we started.
            var killer = $.NSTask.alloc.init;
            killer.launchPath = $('/bin/kill'); killer.arguments = $(['-KILL', String(task.processIdentifier)]);
            killer.standardOutput = $.NSFileHandle.fileHandleWithNullDevice;
            killer.standardError = $.NSFileHandle.fileHandleWithNullDevice;
            killer.launch; killer.waitUntilExit; task.waitUntilExit;
            return null;
        }
        task.waitUntilExit;
        return {status:task.terminationStatus, text:read(file)};
    } catch (_) { return null; }
    finally {
        if (handle) handle.closeFile;
        $.NSFileManager.defaultManager.removeItemAtPathError($(file), null);
    }
}
function snapshot(exe, deadline) {
    var result = execute(exe, ['ls'], Math.min(deadline, Date.now() + 1000));
    if (!result || result.status !== 0) return null;
    try {
        var value = JSON.parse(result.text);
        return Array.isArray(value.spaces) ? value.spaces : null;
    } catch (_) { return null; }
}
function localSpaces(spaces) {
    return spaces.filter(function(s) {return s.machine === null && typeof s.id === 'string' && s.id && s.id.indexOf('/') < 0;});
}
function herdrLaunch(exe, command, folder) {
    var deadline = Date.now() + 10000, spaces = snapshot(exe, deadline);
    if (!spaces) {
        execute('/usr/bin/open', ['-a', 'Herdr'], Math.min(deadline, Date.now() + 1000));
        while (!spaces && Date.now() < deadline) {
            $.NSThread.sleepForTimeInterval(0.1);
            spaces = snapshot(exe, deadline);
        }
    }
    if (!spaces) return '2'; // No creation dispatched; fallback is safe.
    var local = localSpaces(spaces), space = local.filter(function(s) {return s.active;})[0] || local[0];
    var payload = {name:'TTT', folder:folder, argv:['/bin/sh', '-c', command]};
    if (space) payload.space = space.id;
    else { payload.machine = ''; payload.tab = 'TTT'; }
    // Never retry a creation: a lost or failed reply can still mean it launched.
    var result = execute(exe, ['do', space ? 'tab.new' : 'space.new', JSON.stringify(payload)], Date.now() + 10000);
    if (!result || result.status !== 0) return '1';
    try { if (JSON.parse(result.text).error) return '1'; }
    catch (_) { return '1'; }
    execute('/usr/bin/open', ['-a', 'Herdr'], Date.now() + 1000);
    return '0'; // Activation failure cannot request another editor.
}
function ancestry(pid, deadline) {
    var pids = [];
    while (pid > 1 && pids.length < 64 && pids.indexOf(pid) < 0 && Date.now() < deadline) {
        pids.push(pid);
        var result = execute('/bin/ps', ['-o', 'ppid=', '-p', String(pid)], deadline);
        if (!result || result.status !== 0) break;
        pid = Number(result.text.trim());
    }
    return pids;
}
function herdrFocus(exe, core, pids, deadline) {
    var spaces = snapshot(exe, deadline);
    if (!spaces) return false;
    for (var space of localSpaces(spaces)) {
        for (var tab of space.tabs || []) {
            for (var terminal of tab.terminals || []) {
                var address = terminal.terminal;
                if (typeof address !== 'string' || !address || address.indexOf('/') >= 0) continue;
                var result = execute(core, ['get', address, '--json'], deadline);
                if (!result || result.status !== 0) continue;
                try {
                    var state = JSON.parse(result.text);
                    if (pids.indexOf(Number(state.pid)) < 0 && pids.indexOf(Number((state.foreground || {}).pid)) < 0) continue;
                } catch (_) { continue; }
                result = execute(exe, ['do', 'agent.focus', JSON.stringify({terminal:address})], deadline);
                if (!result || result.status !== 0) return false;
                execute('/usr/bin/open', ['-a', 'Herdr'], deadline);
                return true;
            }
        }
    }
    return false;
}
function privateType(ext) {
    return 'io.github.simonocampo1.tttlauncher.code.' + ext.replace(/[^a-z0-9.]/g, function(c) {
        return '-' + c.charCodeAt(0).toString(16) + '-';
    });
}
function conforms(type, parent) { return Boolean($.UTTypeConformsTo($(type), $(parent))); }
function textType(type) {
    return ['public.text', 'public.source-code', 'public.data', 'public.content', 'public.item',
        'public.mpeg-2-transport-stream', 'com.microsoft.word.dot', 'cx.c3.pp-archive'].indexOf(type) < 0 &&
        (conforms(type, 'public.text') || conforms(type, 'public.source-code')) &&
        !['public.html', 'public.xhtml', 'public.audiovisual-content', 'public.archive'].some(function(p) {
            return conforms(type, p);
        });
}
function typesFor(ext) {
    // Include text associations even when a binary type is preferred (e.g. ts).
    var refs = $.UTTypeCreateAllIdentifiersForTag($.kUTTagClassFilenameExtension, $(ext), null);
    var types = refs ? ObjC.deepUnwrap(ObjC.castRefToObject(refs)) : [];
    return types.filter(function(t, i, all) { return t && !/^dyn\./.test(t) && all.indexOf(t) === i; });
}
function run(argv) {
    var mode = argv[0];
    if (mode === 'herdr-launch') return herdrLaunch(argv[1], argv[2], argv[3]);
    if (mode === 'preferences') return preferences(argv[1], argv[2]);
    if (mode === 'preference') return JSON.parse(argv[1])[argv[2]];
    if (mode === 'herdr-pane') {
        var pane = JSON.parse(argv[1]).result.root_pane.pane_id;
        if (typeof pane !== 'string' || !pane) throw Error('invalid Herdr pane');
        return pane;
    }
    if (mode === 'reuse') {
        var paths = configPaths(argv[1], argv[2]);
        for (var path of paths) {
            var value = $.NSString.stringWithContentsOfFileEncodingError($(path + '/settings.json'), $.NSUTF8StringEncoding, null);
            if (value) {
                try {
                    var settings = JSON.parse(value.js), reuse = false;
                    Object.keys(settings).forEach(function(key) {
                        if (key.replace(/\u017f/g, 's').toLowerCase() === 'reusewindow' && settings[key] !== null) {
                            if (typeof settings[key] !== 'boolean') throw Error('invalid reuseWindow');
                            reuse = settings[key];
                        }
                    });
                    return reuse ? 'yes' : 'no';
                }
                catch (_) { return 'no'; }
            }
        }
        return 'no';
    }
    if (mode === 'absolute') return absolute(argv[1]);
    if (mode === 'focus') {
        var deadline = Date.now() + 3000, pids = ancestry(Number(argv[1]), deadline);
        if (argv[3] && argv[4] && herdrFocus(argv[3], argv[4], pids, deadline)) return 'yes';
        for (var pid of pids) {
            var running = $.NSRunningApplication.runningApplicationWithProcessIdentifier(pid);
            if (running && !running.isTerminated && running.activationPolicy === 0 &&
                running.activateWithOptions($.NSApplicationActivateIgnoringOtherApps)) return 'yes';
        }
        var ids = {Ghostty:'com.mitchellh.ghostty', kitty:'net.kovidgoyal.kitty', WezTerm:'com.github.wez.wezterm',
            Alacritty:'org.alacritty', iTerm:'com.googlecode.iterm2', Terminal:'com.apple.Terminal'};
        if (!ids[argv[2]]) return 'no';
        var terminals = $.NSRunningApplication.runningApplicationsWithBundleIdentifier($(ids[argv[2]]));
        if (terminals.count > 0) terminals.objectAtIndex(0).activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
        return 'yes';
    }
    if (mode === 'get') {
        var h = $.LSCopyDefaultRoleHandlerForContentType($(argv[1]), $.kLSRolesAll);
        return h ? ObjC.castRefToObject(h).js : '';
    }
    if (mode === 'set') return $.LSSetDefaultRoleHandlerForContentType($(argv[1]), $.kLSRolesAll, $(argv[2]));
    var extensions = read(argv[1]).trim().split(/\s+/);
    var types = extensions.map(typesFor);
    if (mode === 'defaults' || mode === 'excluded') {
        var selected = argv.slice(2), result = [];
        types.forEach(function(resolved, i) {
            if (selected.length && selected.indexOf(extensions[i]) < 0) return;
            var safe = ['htm', 'html', 'xhtml', 'shtml'].indexOf(extensions[i]) < 0 ? resolved.filter(textType) : [];
            result = result.concat(mode === 'defaults' ? safe : (safe.length ? [] : [extensions[i]]));
        });
        return result.filter(function(t, i, all) { return all.indexOf(t) === i; }).join(mode === 'defaults' ? '\n' : ', ');
    }
    // Only genuinely undeclared extensions need a private declaration. Recheck
    // actual associations after registration before choosing defaults.
    var declarations = [];
    types = types.reduce(function(all, resolved, i) {
        var type = privateType(extensions[i]);
        if (!resolved.length || resolved.every(function(t) { return t === type; })) {
            declarations.push({ UTTypeIdentifier: type, UTTypeConformsTo: ['public.source-code'],
                UTTypeTagSpecification: { 'public.filename-extension': extensions[i] } });
            resolved = [type];
        }
        return all.concat(resolved);
    }, []);
    if (mode === 'documents') return JSON.stringify([{
        CFBundleTypeName: 'Code and text', CFBundleTypeRole: 'Editor', LSHandlerRank: 'Alternate',
        CFBundleTypeExtensions: extensions, LSItemContentTypes: types.filter(function(t, i, all) { return all.indexOf(t) === i; }).concat(['public.folder'])
    }]);
    if (mode === 'declarations') return JSON.stringify(declarations);
    throw Error('unknown services operation: ' + mode);
}
