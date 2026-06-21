# KKWebViewAppCore

Fullscreen WebView2 kiosk application built with Free Pascal (FPC).

A single native window embedding a Microsoft Edge WebView2 browser. On startup it
opens `http://localhost:8080` and can run borderless on the whole screen, making it
suitable for kiosk-style front ends backed by a local web server.

## Features

- Single window with an embedded Chromium/Edge WebView2 browser
- `-FullScreen` switch for borderless, full-screen (kiosk) mode
- `-url <address>` to override the start URL
- **ESC** (via a bound native callback) and **Alt+F4** close the application
- No `WebView2Loader.dll` to ship — the loader is built into `libwebview.dll`,
  which itself statically links the C++ runtime (`-static-libgcc -static-libstdc++`)

## Requirements

- [Free Pascal](https://www.freepascal.org/) toolchain
  (resolved from `..\..\..\..\KKMindWave\VendorsCore\fpc\fpc-main`; override with `FPC_EXE_x64`)
- [MSYS2 MinGW-w64](https://www.msys2.org/) at `c:\bin\msys64`
  (override with `MSYS2_ROOT_OVERRIDE`) — used to build the webview C++ library
- Microsoft Edge **WebView2 Runtime** installed on the target machine

The C++ sources of the [webview](https://github.com/webview/webview) library and the
[fpwebview](https://github.com/PierceNg/fpwebview) bindings are expected as sibling
folders (`webview/`, `fpwebview/`) and are not tracked in this repository.

## Build

The build has two stages. Stage 1 produces the native `libwebview.dll`; stage 2
compiles the Pascal application and links against it. Stage 1 only needs to be
repeated when the webview C++ sources change — day-to-day you just re-run stage 2.

### Prerequisites checklist

1. Clone the dependency sources as sibling folders inside the project root:
   ```bat
   git clone https://github.com/webview/webview.git      webview
   git clone https://github.com/PierceNg/fpwebview.git    fpwebview
   ```
2. Ensure MSYS2 MinGW-w64 is at `c:\bin\msys64` (or set `MSYS2_ROOT_OVERRIDE`).
   The scripts use its `gcc`, `g++`, `cmake`, `ninja`, `ar` and `ranlib`.
3. Ensure the FPC toolchain is reachable at
   `..\..\..\..\KKMindWave\VendorsCore\fpc\fpc-main` (or set `FPC_EXE_x64` to a
   full path to `fpc.exe`).
4. Install the Microsoft Edge **WebView2 Runtime** on any machine that runs the
   app. It ships preinstalled on Windows 11 and recent Windows 10; install it
   explicitly only if missing.

   Using winget:
   ```bat
   winget install --id Microsoft.EdgeWebView2Runtime --exact --silent --accept-package-agreements --accept-source-agreements
   ```

   Or download and run the Evergreen Bootstrapper silently:
   ```bat
   curl -L -o "%TEMP%\MicrosoftEdgeWebview2Setup.exe" https://go.microsoft.com/fwlink/p/?LinkId=2124703
   "%TEMP%\MicrosoftEdgeWebview2Setup.exe" /silent /install
   ```

   Verify it is installed (prints a version when present):
   ```bat
   reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" /v pv
   ```

### Stage 1 — native webview library

```bat
build\win_x64\build_webview.bat
```

Runs CMake + Ninja with MinGW to build a shared library, linking the C++ runtime
statically (`-static-libgcc -static-libstdc++`) and using webview's built-in
WebView2 loader. Output: `webview\build\win_x64\core\libwebview.dll`.

### Stage 2 — Pascal application

```bat
build\win_x64\build_app.bat
```

Compiles `src\AppMain.pas` with FPC as a Windows GUI app (`-WG`), then copies
`libwebview.dll` next to the executable.

| Path | Contents |
|------|----------|
| `build\win_x64\bin\AppMain.exe`      | the application |
| `build\win_x64\bin\libwebview.dll`   | webview runtime (copied by stage 2) |
| `build\win_x64\dcu\`                 | intermediate FPC units (`.ppu`/`.o`) |

Both `bin\` and `dcu\` are git-ignored.

### Overrides

| Variable | Effect |
|----------|--------|
| `FPC_EXE_x64`        | full path to `fpc.exe`, bypassing the default toolchain location |
| `MSYS2_ROOT_OVERRIDE`| MSYS2 install root used instead of `c:\bin\msys64` |

## Usage

```bat
build\win_x64\bin\AppMain.exe                          :: windowed 1024x768, http://localhost:8080
build\win_x64\bin\AppMain.exe -FullScreen              :: borderless fullscreen (kiosk)
build\win_x64\bin\AppMain.exe -url http://example.com  :: custom start URL
build\win_x64\bin\AppMain.exe -FullScreen -url http://localhost:9000
```

### Command-line parameters

| Parameter | Argument | Default | Description |
|-----------|----------|---------|-------------|
| `-config` / `--config` / `-c` | path (next argument) | `app.cfg` next to the exe, if present | Load a launch config file (see below). Starts backend/frontend services, waits for the port, then opens the resolved URL. |
| `-FullScreen` / `--FullScreen` | none | off | Borderless window covering the whole screen (`WS_POPUP`). Without it the window is 1024×768 with normal decorations. Overrides `FullScreen` from the config. |
| `-url` / `--url` | URL (next argument) | `http://localhost:8080` | Address to open on startup. Ignored when `-config` resolves its own URL. |

Parameter names are case-insensitive. Unknown arguments are ignored; `-url`
given without a following value falls back to the default URL.

### Launching services via a config file

`-config` turns AppCore into a launcher: it reads a `KEY=VALUE` file (`#`/`;`
comments), starts the backend and frontend, waits for the target TCP port, and
then opens the WebView2 window. This replaces a separate launcher script.

```bat
build\win_x64\bin\AppMain.exe -config C:\path\to\appcore.cfg
build\win_x64\bin\AppMain.exe -c C:\path\to\appcore.cfg
```

If neither `-config`/`-c` is given, AppCore looks for an `app.cfg` file next to
the executable and, when present, loads it automatically. With no config at all
it just opens the default/`-url` address without launching any services.

Relative paths inside the file are resolved against the file's own directory.
A bare `BunExe` name (no path separator) is looked up via `PATH`.

| Key | Default | Description |
|-----|---------|-------------|
| `Mode` | `prod` | `prod` builds the UI and runs the production server; `dev` runs the server and UI dev servers, each in its own console window that **stays open** (`cmd /k`). |
| `BunExe` | `bun` | Path to `bun`, or a bare command resolved via `PATH`. |
| `ServerDir` | — | Backend project dir (has `dev` / `start` scripts). |
| `UiDir` | — | Frontend project dir (has `dev` / `build` scripts). |
| `ServerPort` | *(required)* | Backend port; the prod URL is `http://localhost:<ServerPort>/`. |
| `DevUrl` | `http://localhost:<ServerPort>/` | URL opened in dev mode (e.g. the HMR dev server). |
| `BuildUi` | `true` | prod only: run `bun run build` in `UiDir` before starting the server. |
| `FullScreen` | `false` | Open the window borderless fullscreen. |
| `ReadyTimeoutSec` | `30` | Max seconds to wait for the port before opening the window anyway. |

In `prod` mode AppCore waits for `ServerPort`; in `dev` mode it waits for the
port parsed from `DevUrl`. The launched dev/server console windows run
independently — closing the AppCore window does not stop them. A ready-to-use
example is in [`examples/appcore.cfg`](examples/appcore.cfg).

### Exit

- **ESC** — handled by injected JavaScript that invokes a bound native callback
  (`webview_terminate`), since WebView2's `window.close()` alone does not close
  the host window.
- **Alt+F4** — closes via the native `WM_CLOSE` path.

## Project layout

```
src/
  AppMain.pas    entry point: arg parsing, service orchestration, window + ESC
  AppConfig.pas  KEY=VALUE launch-config parser (paths, mode, ports)
  AppLaunch.pas  console process launching + TCP port readiness wait
  webview.pas    FPC bindings to the webview C API (libwebview.dll)
build/win_x64/
  build_webview.bat  builds libwebview.dll via CMake + MinGW
  build_app.bat      compiles the FPC application
  fpc-x64.cfg        FPC compiler configuration (relative paths)
examples/
  appcore.cfg    sample launch configuration
```

## License

[MIT](LICENSE). The bundled `webview` library and `fpwebview` bindings are also MIT;
`WebView2Loader` code is covered by Microsoft's license.
