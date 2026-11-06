# ttt desktop launcher

Plugins that add [ttt](https://github.com/eugenioenko/ttt) to your desktop, one per OS. Installing the plugin installs the launcher; uninstalling it removes the launcher.

| Plugin | What it adds |
|---|---|
| `desktop-launcher-linux` | `ttt.desktop` and its icon under `$XDG_DATA_HOME` (`~/.local/share`), so ttt shows up in your app launcher and in "Open With". |
| `desktop-launcher-macos` | `~/Applications/TTT.app`, an AppleScript applet that opens ttt and the files you double-click in Finder. **Experimental.** |

The launcher opens ttt in the terminal ttt was running in when you installed the plugin: kitty, WezTerm, Alacritty, Ghostty, foot or Konsole on Linux; Ghostty, kitty, WezTerm, Alacritty, iTerm or Terminal.app on macOS. On Linux, with no known terminal, the desktop picks one (`Terminal=true`).

## Install

From the **Plugins** panel, search for "Desktop Launcher". Or copy the folder for your OS into `~/.config/ttt/plugins/` and restart ttt:

```sh
git clone https://github.com/SimonOcampo1/ttt-desktop-launcher /tmp/ttt-desktop-launcher
cp -r /tmp/ttt-desktop-launcher/desktop-launcher-linux ~/.config/ttt/plugins/
```

Both plugins ask for two permissions: registering commands, and running `sh`, which runs the plugin's own `launcher.sh`.

## Commands

- **Desktop Launcher: Repair**: rewrite the launcher, for instance after moving ttt or to switch it to the terminal you are in now.
- **Desktop Launcher: Open code files with ttt** (macOS): make TTT.app the Finder default for the actual text types resolved from `desktop-launcher-macos/extensions.txt`, including plain text. HTML (`.htm`, `.html`, `.xhtml`, `.shtml` and shared aliases such as `.phtml`) and binary/Office/archive types keep their handlers. The command reports applied types and excluded extensions. macOS may ask you to confirm changes. Previous default apps are remembered across repeated runs and Repair, and restored on uninstall only while TTT remains selected, preserving later choices. A failed restore keeps the app and recovery data so you can retry with `sh "$HOME/Applications/TTT.app/Contents/Resources/launcher.sh" remove`, even after the plugin is deleted. Older snapshots with empty handlers cannot recover the lost app identity.

On macOS, enable `"reuseWindow": true` in ttt's `settings.json` and use a ttt main build after v1.9.0 that includes file forwarding. Finder opens then reach the newest running editor for the same ttt config directory and activate its terminal app. The launcher stays out of the Dock and uses the ttt icon. With no eligible editor, folders, disabled reuse or an older ttt, it opens one terminal as usual. A failed attempted handoff shows a notification. All listed extensions, including HTML, remain available through **Open With**.

On macOS, installing or repairing inside legacy herdr (`HERDR_ENV=1`, with `herdr` on PATH) makes cold launches open a new tab in its running session and activate its detected host terminal, such as Ghostty, without opening a new terminal window. The tab starts in the first item's directory, or your home directory with no files. Herdr errors fall back to the detected terminal or Terminal.app; forwarding activates the host terminal without selecting a pane. To override detection, start `TTT_LAUNCHER_TERMINAL=herdr ttt`, then run **Desktop Launcher: Repair**. Other values are `ghostty`, `kitty`, `wezterm`, `alacritty`, `iterm`, `terminal`, and `auto`. The app saves the choice; herdr needs its CLI at repair time and a running server at launch time. For Herdr.app, save the following as `desktop-launcher.json` in the active ttt configuration directory, then run **Desktop Launcher: Repair**:

```json
{"terminal":"herdr-app","fallback":"ghostty"}
```

The launcher reads this file from an explicit `TTT_CONFIG_DIR`, otherwise executable-adjacent `config` when it contains `settings.json`, otherwise `~/.config/ttt`. Both fields default to `auto`. `terminal` accepts `auto`, `herdr-app`, legacy `herdr`, or the six ordinary macOS terminals listed above; `fallback` accepts `auto` or an ordinary terminal. `TTT_LAUNCHER_TERMINAL` overrides the saved primary choice. Invalid configuration leaves the installed app intact. Repair snapshots the choices and CLI paths into the app; the preference file stays outside the bundle, so repairing from another terminal preserves your saved choice. Changes take effect on the next Repair.

## Safety

The scripts only touch files they created: `ttt.desktop` carries `X-TTT-Managed=true`, and `TTT.app` carries a `ttt-managed` marker. If you already have your own `ttt.desktop` or `TTT.app`, install fails without changing it.

## Tests

```sh
sh tests/linux.sh
sh tests/macos.sh   # requires Node and Python 3; stubs macOS commands (osascript, osacompile, plutil, codesign, stat, uname), runs anywhere
```
