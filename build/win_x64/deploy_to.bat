@echo off
setlocal
rem Copies the built AppMain.exe + libwebview.dll into a deployment's server dir and, if
rem that dir has an AppCore.ico, stamps it into the copied exe (so Explorer / taskbar /
rem pinned shortcuts show the right icon). Usage:
rem     deploy_to <target-server-dir>

if "%~1"=="" (
    echo Usage: deploy_to ^<target-server-dir^>
    exit /b 2
)

set "TARGET=%~1"
set "BIN=%~dp0bin"

if not exist "%BIN%\AppMain.exe" (
    echo ERROR: bin\AppMain.exe missing - run build_app.bat first.
    exit /b 1
)
if not exist "%TARGET%\" (
    echo ERROR: target dir not found: %TARGET%
    exit /b 1
)

echo Copying AppMain.exe + libwebview.dll to %TARGET% ...
copy /Y "%BIN%\AppMain.exe" "%TARGET%\" >nul
copy /Y "%BIN%\libwebview.dll" "%TARGET%\" >nul

if exist "%TARGET%\AppCore.ico" (
    if exist "%BIN%\IconStamp.exe" (
        echo Stamping icon from %TARGET%\AppCore.ico ...
        "%BIN%\IconStamp.exe" "%TARGET%\AppMain.exe" "%TARGET%\AppCore.ico"
        if errorlevel 1 exit /b 1
    ) else (
        echo NOTE: IconStamp.exe missing - run build_iconstamp.bat to enable icon stamping.
    )
) else (
    echo NOTE: no AppCore.ico in %TARGET% - exe keeps the default icon.
)

echo Done.
