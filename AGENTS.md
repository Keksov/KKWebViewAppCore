# AppCore

Fullscreen WebView2 kiosk application built with Free Pascal.

## Pascal conventions (READ FIRST)

Before creating or editing any `.pas` / `.pp` / `.inc` file in this project,
read [.github/instructions/pascal.instructions.md](.github/instructions/pascal.instructions.md)
and follow it: 4-space indentation, lowercase camelCase routine/local names,
local declarations sorted by line length (shortest first), `a`-prefixed
`const` parameters, `{*...*}` header banners before each routine, `FreeAndNil`
for cleanup, and `{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}` for Delphi
compatibility.

## Build

Two-step build process:

1. Build webview shared library (one-time, unless webview sources change):
   ```
   build\win_x64\build_webview.bat
   ```
   Produces `webview\build\win_x64\core\libwebview.dll` with embedded WebView2 loader.
   No separate WebView2Loader.dll needed.

2. Build the FPC application:
   ```
   build\win_x64\build_app.bat
   ```
   Produces `build\win_x64\bin\AppMain.exe` and copies `libwebview.dll` alongside.
   It also deploys both artifacts to `..\..\KKLeftRight\server` when that folder
   exists (skipped with a warning otherwise).

## FPC Toolchain

Resolved from: `..\..\..\..\KKMindWave\VendorsCore\fpc\fpc-main`
Override: set `FPC_EXE_x64` environment variable.

## C++ Toolchain

MSYS2 MinGW-w64: `c:\bin\msys64\mingw64`
Override: set `MSYS2_ROOT_OVERRIDE` environment variable.

## Startup splash (native Pixie/Direct2D)

On launch, `AppSplash.pas` shows a native frameless banner **before**
`webview_create`, so the user gets instant feedback while WebView2's (slow)
environment init and the services start behind it. It is drawn with Pixie
(Direct2D/DirectWrite) on its own `BeginThread` with an animation timer: a
spinner, a bold title and a step checklist that `startServices` fills in via
`splashSetPhase`. The WebView2 window stays hidden behind the topmost splash
until the app URL is ready, then is revealed and the splash is closed (no
blank-white swap). The old in-WebView HTML splash was removed.

Splash language follows the `SplashLang` cfg key (`ru` default / `en`).

### Dev-mode console tabs (Windows 11)

In `Mode=dev` two dev servers are started (backend + quasar). On **Windows 11**
(build ≥ 22000, detected via `RtlGetVersion` — the registry ProductName still
says "Windows 10") with **Windows Terminal** (`wt.exe`) present, they open as two
**tabs of one** terminal window (`wt -w new nt … ; nt …`, each tab a tiny
generated `%TEMP%\kkdev-<pid>-N.cmd`); otherwise they fall back to a separate
console window each. Because Windows Terminal hosts the tab shells outside our
kill-on-close job, the servers' ports are registered and, on exit,
`terminateProcessGroup` finds each listener (`GetExtendedTcpTable`), walks up to
its `cmd.exe` tab shell (toolhelp) and kills that tree — closing the tab and
stopping the server. See `AppLaunch.terminalTabsAvailable` / `launchConsoleTabs`.

Dev mode also creates the WebView2 with DevTools enabled (so **F12** works) and
adds a `</>` button to the full-screen control bar that opens the browser
dev-tools in a **separate window**. `AppMain.openDevTools` reaches the WebView2
via `webview_get_native_handle(Browser_Controller)` and calls, by COM vtable
slot, `ICoreWebView2Controller.get_CoreWebView2` (25) then
`ICoreWebView2.OpenDevToolsWindow` (51) — slots taken from the bundled
`WebView2.h`; no change to the C++ webview library.

### Startup profiling

`AppProfile.pas` is a zero-overhead-when-disabled high-res profiler. Run with
`--profile-splash` to log the time-to-splash and exit (before WebView2 /
services), or `--profile` to log the full startup on entry to the run loop. The
log is appended to `%TEMP%\appcore-startup-profile.log` (per-step + cumulative
ms, incl. a pre-main DLL-load/RTL figure and the splash-thread D2D init).

Port resolution runs **behind** the splash and uses a non-blocking, 150 ms-bounded
connect probe (`AppLaunch.portInUse`): a blocking probe stalled ~2 s per free
loopback port on machines where a security filter delays the RST, which used to
push the splash out by ~4 s.

## Branding (per-deployment title + taskbar icon)

So several AppCore apps are distinguishable as taskbar buttons, `AppBranding.pas`
reads, at startup, files next to the exe:

- `AppCore.ico` — if present, the window icon (small + big via `WM_SETICON`).
- `AppCore.ini` — UTF-8 `KEY=VALUE`: `AppTitle=<window title>` and, only when
  `AppCore.ico` is absent, `AppIcon=<base64 of an .ico>`.

It also sets a per-app `AppUserModelID` (from the title) so the taskbar button
does not group with / borrow the icon of another AppCore instance. Titles may be
Cyrillic (the ini is UTF-8). Currently deployed placeholders: KKLeftRight = blue
left/right arrows "Лево-Право", SoundTrainer = teal equalizer "Логопед",
MindWaveCore = violet sine wave "MindWave" — swap the `.ico` / edit `AppTitle`
per deployment.

### EXE file icon (IconStamp)

`AppBranding` only sets the **window/taskbar** icon at runtime (`WM_SETICON`); the
**.exe file** icon (Explorer, pinned shortcuts, the moment before the window shows)
must be embedded into the PE. Since one generic `AppMain.exe` is built and copied to
several deployments, the per-deployment icon is stamped **after** copying:

- `src/IconStamp.pas` → `build_iconstamp.bat` builds `bin/IconStamp.exe` (one-time,
  like `build_webview.bat`). It writes the `.ico` as `RT_ICON` + one `RT_GROUP_ICON`
  via `BeginUpdateResource`/`UpdateResource`.
- **Overlay-safe:** FPC appends a ~1 MB symbol overlay after the PE sections, which
  `UpdateResource` would strip — so IconStamp captures the overlay first and
  re-appends it (byte-identical, EOF-relative) after stamping.
- `build_app.bat` deploys `AppMain.exe` + `libwebview.dll` to **all** known deployments
  (`KKLeftRight`, `SoundTrainer`, `MindWaveCore` — add new ones to the deploy list at the
  bottom of the script) and stamps each with its own `AppCore.ico`. `deploy_to
  <target-server-dir>` does the same for one target ad hoc.
- The stamping core is shared (`src/IconStamper.pas`), so the **self-update**
  (`AppUpdate`) and `sync-appcore-launcher.ps1` also re-stamp after copying the generic
  bin exe — otherwise auto-update would drop the icon on every rebuild.
- After stamping, `IconStamper` calls `SHChangeNotify(SHCNE_ASSOCCHANGED)` so the shell
  re-reads the icon (a path that was previously unstamped keeps a stale cached icon
  otherwise; a one-off `explorer.exe` restart also clears it).
- Manual form: `bin\IconStamp.exe <target.exe> <icon.ico>`. The exe must not be
  running. `.ico`s are per-deployment binaries and are **not committed**.

### Taskbar button identity (name + icon)

Non-obvious Windows behaviour learned the hard way: the **taskbar button** keys off the
process's **application identity (AppUserModelID)**, *not* the window's caption or
`WM_SETICON` icon (those only drive the window title bar and the hover thumbnail). An
unregistered exe with no AUMID shows the **exe filename** ("AppMain.exe") and a generic
icon on the button, even though the caption/thumbnail are correct — `SetWindowText` on the
window does **not** change the button.

Fix (`AppBranding.setWindowTaskbarIdentity`, called from `AppMain` after the window is
created): stamp the window's property store via `SHGetPropertyStoreForWindow` with
- `PKEY_AppUserModel_ID` — a per-deployment AUMID (`appUserModelId`: ASCII of the title,
  or an FNV-1a hash of the exe path when the title is non-ASCII, e.g. Cyrillic),
- `PKEY_AppUserModel_RelaunchDisplayNameResource` — the deployment title (button label),
- `PKEY_AppUserModel_RelaunchIconResource` — `"<exe>,0"` (its stamped icon; unquoted).

Notes: build the `PROPVARIANT` by hand (`CoTaskMemAlloc` + `VT_LPWSTR`) — do **not** import
`InitPropVariantFromString`, it is not a stable `propsys.dll` export. To *measure* the
button objectively, use UIA (`Shell_TrayWnd` → descendant Buttons; each button's `Name` is
its label) plus a screenshot — see the scratchpad `measure_taskbar.ps1` from that session.

## Config

FPC config: `build\win_x64\fpc-x64.cfg`
Target: x64, Windows GUI (`-WG`)

The splash pulls in **Pixie**, referenced (not vendored) from the EchoScript
copy: `..\..\..\..\EchoScript\EchoRecorder\vendors\pixie\source\{common,paintbox}`,
plus the FPC packages `fcl-image`, `paszlib`, `hash`, `pasjpeg`. These `-Fu`
paths are already in `fpc-x64.cfg`; no third-party sources are committed here.

## Linking

webview C++ library is built as a DLL with `-static-libgcc -static-libstdc++`
(C++ runtime statically linked into DLL). Only `libwebview.dll` ships alongside the exe.
WebView2 Runtime (Edge) must be installed on the target system.

## Usage

```
build\win_x64\bin\AppMain.exe                          # windowed 1024x768
build\win_x64\bin\AppMain.exe -FullScreen              # fullscreen kiosk mode
build\win_x64\bin\AppMain.exe -url http://example.com  # custom URL
```

Alt+F4 (or the window's Close button / system menu) closes the application.
