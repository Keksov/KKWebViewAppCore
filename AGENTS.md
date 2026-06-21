# AppCore

Fullscreen WebView2 kiosk application built with Free Pascal.

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

## FPC Toolchain

Resolved from: `..\..\..\..\KKMindWave\VendorsCore\fpc\fpc-main`
Override: set `FPC_EXE_x64` environment variable.

## C++ Toolchain

MSYS2 MinGW-w64: `c:\bin\msys64\mingw64`
Override: set `MSYS2_ROOT_OVERRIDE` environment variable.

## Config

FPC config: `build\win_x64\fpc-x64.cfg`
Target: x64, Windows GUI (`-WG`)

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

ESC or Alt+F4 closes the application.
