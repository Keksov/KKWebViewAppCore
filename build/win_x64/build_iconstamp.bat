@echo off
setlocal

set "ROOT_FPC_BIN=%~dp0..\..\..\..\KKMindWave\VendorsCore\fpc\fpc-main\bin\x86_64-win64"
set "CFG_FILE=%~dp0fpc-x64.cfg"
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
    echo ERROR: FPC config not found: %CFG_FILE%
    exit /b 1
)

set "PATH=%ROOT_FPC_BIN%;%PATH%"
set "SRC=%~dp0..\..\src\IconStamp.pas"

pushd "%~dp0"
if not exist dcu mkdir dcu
if not exist bin mkdir bin

echo Compiling IconStamp...
rem Reuse the app config for RTL/unit paths, but override the subsystem to console (-WC)
rem so the tool can report success/failure on stdout.
"%FPC%" -n @"%CFG_FILE%" -WC "%SRC%"
set "RC=%ERRORLEVEL%"
popd

if %RC% neq 0 (
    echo BUILD FAILED
    exit /b %RC%
)
echo Built: build\win_x64\bin\IconStamp.exe
