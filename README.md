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

Two steps — the first only needs to be repeated when the webview C++ sources change:

```bat
build\win_x64\build_webview.bat   :: builds webview\build\win_x64\core\libwebview.dll
build\win_x64\build_app.bat       :: compiles bin\AppMain.exe and copies the DLL
```

Outputs land in `build\win_x64\bin\` (`AppMain.exe` + `libwebview.dll`).
Intermediate FPC units go to `build\win_x64\dcu\`.

## Usage

```bat
build\win_x64\bin\AppMain.exe                          :: windowed 1024x768
build\win_x64\bin\AppMain.exe -FullScreen              :: fullscreen kiosk mode
build\win_x64\bin\AppMain.exe -url http://example.com  :: custom start URL
```

Press **ESC** or **Alt+F4** to exit.

## Project layout

```
src/
  AppMain.pas    entry point: window setup, fullscreen, ESC handling
  webview.pas    FPC bindings to the webview C API (libwebview.dll)
build/win_x64/
  build_webview.bat  builds libwebview.dll via CMake + MinGW
  build_app.bat      compiles the FPC application
  fpc-x64.cfg        FPC compiler configuration (relative paths)
```

## License

[MIT](LICENSE). The bundled `webview` library and `fpwebview` bindings are also MIT;
`WebView2Loader` code is covered by Microsoft's license.
