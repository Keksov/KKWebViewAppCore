@echo off
setlocal

set "MSYS2_ROOT=c:\bin\msys64"
set "SRC_DIR=%~dp0..\..\webview"
set "BUILD_DIR=%SRC_DIR%\build\win_x64"
set "CMAKE_EXE=%MSYS2_ROOT%\mingw64\bin\cmake.exe"
set "GCC_EXE=%MSYS2_ROOT%\mingw64\bin\gcc.exe"
set "GXX_EXE=%MSYS2_ROOT%\mingw64\bin\g++.exe"
set "AR_EXE=%MSYS2_ROOT%\mingw64\bin\ar.exe"
set "RANLIB_EXE=%MSYS2_ROOT%\mingw64\bin\ranlib.exe"
set "NINJA_EXE=%MSYS2_ROOT%\mingw64\bin\ninja.exe"

if defined MSYS2_ROOT_OVERRIDE (
    set "MSYS2_ROOT=%MSYS2_ROOT_OVERRIDE%"
)

if not exist "%CMAKE_EXE%" (
    echo ERROR: cmake not found.
    echo   Expected: %CMAKE_EXE%
    exit /b 1
)
if not exist "%GCC_EXE%" (
    echo ERROR: gcc not found.
    echo   Expected: %GCC_EXE%
    exit /b 1
)
if not exist "%NINJA_EXE%" (
    echo ERROR: ninja not found.
    echo   Expected: %NINJA_EXE%
    exit /b 1
)

set "PATH=%MSYS2_ROOT%\mingw64\bin;%PATH%"

echo Configuring webview shared library...
"%CMAKE_EXE%" -G "Ninja" -B "%BUILD_DIR%" -S "%SRC_DIR%" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER="%GCC_EXE%" ^
  -DCMAKE_CXX_COMPILER="%GXX_EXE%" ^
  -DCMAKE_AR="%AR_EXE%" ^
  -DCMAKE_RANLIB="%RANLIB_EXE%" ^
  -DCMAKE_MAKE_PROGRAM="%NINJA_EXE%" ^
  -DCMAKE_SHARED_LINKER_FLAGS="-static-libgcc -static-libstdc++" ^
  -DWEBVIEW_BUILD_SHARED_LIBRARY=ON ^
  -DWEBVIEW_BUILD_STATIC_LIBRARY=OFF ^
  -DWEBVIEW_BUILD_TESTS=OFF ^
  -DWEBVIEW_BUILD_EXAMPLES=OFF ^
  -DWEBVIEW_BUILD_DOCS=OFF ^
  -DWEBVIEW_BUILD_AMALGAMATION=OFF ^
  -DWEBVIEW_USE_BUILTIN_MSWEBVIEW2=ON ^
  -DWEBVIEW_USE_COMPAT_MINGW=ON ^
  -DWEBVIEW_ENABLE_CHECKS=OFF ^
  -DWEBVIEW_INSTALL_TARGETS=OFF ^
  -DWEBVIEW_ENABLE_PACKAGING=OFF
if %ERRORLEVEL% neq 0 (
    echo CONFIGURE FAILED
    exit /b %ERRORLEVEL%
)

echo Building webview shared library...
"%CMAKE_EXE%" --build "%BUILD_DIR%" --config Release
if %ERRORLEVEL% neq 0 (
    echo BUILD FAILED
    exit /b %ERRORLEVEL%
)

echo.
echo Build successful: %BUILD_DIR%\core\libwebview.dll
