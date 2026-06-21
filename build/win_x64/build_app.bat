@echo off
setlocal

set "ROOT_FPC_HOME=%~dp0..\..\..\..\KKMindWave\VendorsCore\fpc\fpc-main"
set "ROOT_FPC_BIN=%ROOT_FPC_HOME%\bin\x86_64-win64"
set "CFG_FILE=%~dp0fpc-x64.cfg"
set "WEBVIEW_DLL_DIR=%~dp0..\..\webview\build\win_x64\core"
set "SRC_DIR=%~dp0..\..\src"
set "DEPLOY_DIR=%~dp0..\..\..\KKLeftRight\server"

set "FPC=%ROOT_FPC_BIN%\fpc.exe"
if defined FPC_EXE_x64 (
    set "FPC=%FPC_EXE_x64%"
)
if not exist "%FPC%" (
    echo ERROR: FPC compiler not found.
    echo   Expected: %FPC%
    exit /b 1
)

if not exist "%CFG_FILE%" (
    echo ERROR: FPC config not found.
    echo   Expected: %CFG_FILE%
    exit /b 1
)

if not exist "%WEBVIEW_DLL_DIR%\libwebview.dll" (
    echo ERROR: webview DLL not found.
    echo   Expected: %WEBVIEW_DLL_DIR%\libwebview.dll
    echo   Run build_webview.bat first.
    exit /b 1
)

if not exist "%ROOT_FPC_BIN%\ppcx64.exe" (
    echo ERROR: FPC backend not found: %ROOT_FPC_BIN%\ppcx64.exe
    exit /b 1
)

set "PATH=%ROOT_FPC_BIN%;%PATH%"

pushd "%~dp0"
if errorlevel 1 exit /b 1

if not exist dcu mkdir dcu
if not exist bin mkdir bin

echo Compiling AppCore...
"%FPC%" -n @"%CFG_FILE%" ^
  -Fl"%WEBVIEW_DLL_DIR%" ^
  "%SRC_DIR%\AppMain.pas"
if %ERRORLEVEL% neq 0 (
    echo BUILD FAILED
    popd
    exit /b %ERRORLEVEL%
)

echo Copying libwebview.dll to bin...
copy /Y "%WEBVIEW_DLL_DIR%\libwebview.dll" bin\ >nul

if exist "%DEPLOY_DIR%\" (
    echo Deploying artifacts to KKLeftRight\server...
    copy /Y bin\AppMain.exe "%DEPLOY_DIR%\" >nul
    copy /Y bin\libwebview.dll "%DEPLOY_DIR%\" >nul
) else (
    echo WARNING: deploy target not found, skipping: %DEPLOY_DIR%
)

popd
echo.
echo Build successful: build\win_x64\bin\AppMain.exe
