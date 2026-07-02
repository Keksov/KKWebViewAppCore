program AppMain;

{$IFDEF FPC}
{$mode delphiunicode}
{$codepage utf8}
{$ENDIF}

uses
    Math, Windows, SysUtils, webview, AppConfig, AppLaunch, AppUpdate,
    AppWindowState, AppBar, AppSplash, AppProfile, AppBranding;

const
    // How long the native splash lingers (topmost) after the WebView2 window is
    // shown and navigated, so the app has time to paint underneath before the
    // splash is removed — avoids a blank-white flash on the swap.
    SPLASH_LINGER_MS = 700;

var
    wnd: HWND;
    i: Integer;
    w: PWebView;
    cfg: TAppConfig;
    cfgErr: string;
    startUrl: string;
    configPath: string;
    defaultCfg: string;
    gWebView: PWebView;       // shared with the startup thread
    gConfig: TAppConfig;      // shared with the startup thread
    gStartUtf8: UTF8String;   // resolved target URL (UTF-8), opened once ready
    gMainWnd: HWND;           // WebView2 window, kept hidden until ready
    gUseFullScreen: Boolean;  // shared with the reveal callback
    gDevMode: Boolean;        // dev config: enables DevTools + the bar button
    useServices: Boolean;
    useFullScreen: Boolean;
    fullScreenForced: Boolean;
    profileHalt: Boolean;     // --profile-splash: log the startup profile and exit
    profPath: string;
    brandTitle: string;       // window title from AppCore.ini (AppTitle), or ''
    brandIconBig: HICON;
    brandIconSmall: HICON;

function SetProcessDPIAware: BOOL; stdcall; external 'user32' name 'SetProcessDPIAware';

{*******************************************************************************
* enablePerMonitorDpi
* Opts into Per-Monitor-V2 DPI awareness so window/cursor coordinates stay in one
* physical space across monitors with different DPI (the control bar is a separate
* window positioned by the main window's rect — without this it lands off-window on
* mixed-DPI setups). Falls back to system DPI awareness on older Windows.
*******************************************************************************}
procedure enablePerMonitorDpi();
type
    TSetCtx = function(aValue: HANDLE): BOOL; stdcall;
var
    hUser: HMODULE;
    setCtx: TSetCtx;
begin
    setCtx := nil;
    hUser := GetModuleHandleW('user32');
    if hUser <> 0 then
        setCtx := TSetCtx(GetProcAddress(hUser, 'SetProcessDpiAwarenessContext'));
    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4
    if (not Assigned(setCtx)) or (not setCtx(HANDLE(PtrInt(-4)))) then
        SetProcessDPIAware;
end;

{*******************************************************************************
* toUtf8
* webview's C API expects UTF-8. Under UnicodeString (UTF-16) the bytes must be
* transcoded before being handed over as PAnsiChar. The returned UTF8String lives
* until the end of the calling statement, which covers the duration of the call.
*******************************************************************************}
function toUtf8(const aValue: string): UTF8String;
begin
    Result := UTF8String(aValue);
end;

{*******************************************************************************
* fail
*******************************************************************************}
procedure fail(const aMsg: string);
begin
    MessageBoxW(0, PWideChar(aMsg), 'AppCore Error', MB_OK or MB_ICONERROR);
    Halt(1);
end;

{*******************************************************************************
* handleExit
* Bound JS callback: terminates the run loop. WebView2's window.close() only
* raises WindowCloseRequested, which the webview library does not handle, so a
* native terminate is required to make ESC actually close the application.
*******************************************************************************}
procedure handleExit(const aSeq: PAnsiChar; const aReq: PAnsiChar; aArg: Pointer); cdecl;
begin
    webview_terminate(PWebView(aArg));
end;

{*******************************************************************************
* tr
* Picks the Russian (default) or English splash string per gConfig.SplashLang.
*******************************************************************************}
function tr(const aRu, aEn: string): string;
begin
    if gConfig.SplashLang = 'en' then
        Result := aEn
    else
        Result := aRu;
end;

{*******************************************************************************
* resolveFreePorts
* Relocates the app to free TCP ports so several AppCore apps can run side by side.
* The backend always moves to the first bindable port at/after ServerPort. In dev
* the quasar dev-server port (ReadyPort/DevUrl) is relocated too. StartUrl — the URL
* the window opens — is rewritten to match (backend in prod, UI dev server in dev).
*******************************************************************************}
procedure resolveFreePorts(var aCfg: TAppConfig);
var
    uiPort: Integer;
begin
    aCfg.ServerPort := findFreePort(aCfg.ServerPort, 50);
    if aCfg.Mode = amDev then
    begin
        uiPort := findFreePort(aCfg.ReadyPort, 50); // ReadyPort = quasar dev port in dev
        aCfg.DevUrl := Format('http://localhost:%d/', [uiPort]);
        aCfg.StartUrl := aCfg.DevUrl;
        aCfg.ReadyPort := uiPort;
    end
    else
    begin
        aCfg.ReadyPort := aCfg.ServerPort;
        aCfg.StartUrl := Format('http://localhost:%d/', [aCfg.ServerPort]);
    end;
end;

{*******************************************************************************
* startServices
* Starts backend/frontend processes described by the config, then waits for the
* target port to become reachable. In dev mode the bun/quasar dev servers run in
* their own console windows that stay open (cmd /k); in prod the UI is built and
* the server started.
*******************************************************************************}
procedure startServices(const aCfg: TAppConfig);
var
    exitCode: DWORD;
    envPrefix: string;
    specs: array of TConsoleSpec;
    k: Integer;

    procedure addSpec(const aDir, aCmd, aTitle: string);
    begin
        SetLength(specs, Length(specs) + 1);
        specs[High(specs)].WorkDir := aDir;
        specs[High(specs)].Command := aCmd;
        specs[High(specs)].Title := aTitle;
        specs[High(specs)].EnvPrefix := envPrefix;
    end;

begin
    splashSetTitle(tr('Запуск…', 'Starting'));
    if aCfg.Mode = amDev then
    begin
        // PORT lets the quasar proxy target the (possibly relocated) backend;
        // --port moves the quasar dev server itself to the chosen free UI port.
        envPrefix := Format('set PORT=%d&& ', [aCfg.ServerPort]);
        SetLength(specs, 0);
        if aCfg.ServerDir <> '' then
            addSpec(aCfg.ServerDir, '"' + aCfg.BunExe + '" run dev', 'KK Server (dev)');
        if aCfg.UiDir <> '' then
            addSpec(aCfg.UiDir,
                Format('"%s" run dev -- --port %d', [aCfg.BunExe, aCfg.ReadyPort]),
                'KK UI (quasar dev)');

        if aCfg.ServerDir <> '' then
            splashSetPhase(tr('Запуск сервера', 'Starting backend'));
        if aCfg.UiDir <> '' then
            splashSetPhase(tr('Запуск интерфейса', 'Starting interface'));

        // On Windows 11 with Windows Terminal, open the dev servers as tabs of one
        // window instead of separate console windows. Windows Terminal owns those
        // shells (outside our kill-on-close job), so register their ports for the
        // exit cleanup. Otherwise fall back to a console window per server.
        if (Length(specs) >= 2) and terminalTabsAvailable() then
        begin
            launchConsoleTabs(specs);
            registerCleanupPort(aCfg.ServerPort);
            registerCleanupPort(aCfg.ReadyPort);
        end
        else
            for k := Low(specs) to High(specs) do
                launchInConsole(specs[k].WorkDir, specs[k].Command,
                    specs[k].Title, specs[k].EnvPrefix, True);
    end
    else
    begin
        if aCfg.BuildUi and (aCfg.UiDir <> '') then
        begin
            splashSetPhase(tr('Сборка интерфейса', 'Building interface'));
            if not runAndWait(aCfg.UiDir, '"' + aCfg.BunExe + '" run build',
                'KK UI build', exitCode) then
                fail('Failed to start UI build (bun run build).');
            if exitCode <> 0 then
                fail(Format('UI build failed (exit code %d).', [exitCode]));
        end;

        if aCfg.ServerDir <> '' then
        begin
            splashSetPhase(tr('Запуск сервера', 'Starting server'));
            envPrefix := Format('set PORT=%d&& ', [aCfg.ServerPort]);
            launchInConsole(aCfg.ServerDir,
                '"' + aCfg.BunExe + '" run start', 'KK Server', envPrefix, False);
        end;
    end;

    splashSetPhase(tr('Ожидание готовности', 'Waiting for services'));
    waitForPort(aCfg.ReadyPort, aCfg.ReadyTimeoutSec);
    splashSetPhase(tr('Готово', 'Ready'));
end;

{*******************************************************************************
* openDevTools
* Opens the browser dev-tools in a separate window. Reaches the WebView2 through
* the native browser-controller handle and calls, by COM vtable slot,
* ICoreWebView2Controller.get_CoreWebView2 (slot 25) then
* ICoreWebView2.OpenDevToolsWindow (slot 51) — indices taken from WebView2.h; the
* returned CoreWebView2 reference is Released (IUnknown slot 2). Requires the
* webview to have been created with DevTools enabled (dev mode).
*******************************************************************************}
type
    TComVtbl = array[0..255] of Pointer;
    PComVtbl = ^TComVtbl;
    TComGetCore = function(aSelf: Pointer; out aCore: Pointer): HResult; stdcall;
    TComNoArg = function(aSelf: Pointer): HResult; stdcall;

function comSlot(aObj: Pointer; aIndex: Integer): Pointer;
begin
    Result := PComVtbl(PPointer(aObj)^)^[aIndex];
end;

procedure openDevTools();
const
    IDX_GET_COREWEBVIEW2 = 25;   // ICoreWebView2Controller vtable slot
    IDX_OPENDEVTOOLS     = 51;   // ICoreWebView2 vtable slot
var
    ctrl, core: Pointer;
    getCore: TComGetCore;
    callNoArg: TComNoArg;
begin
    if gWebView = nil then
        Exit;
    ctrl := webview_get_native_handle(gWebView, Browser_Controller);
    if ctrl = nil then
        Exit;
    getCore := TComGetCore(comSlot(ctrl, IDX_GET_COREWEBVIEW2));
    core := nil;
    if (getCore(ctrl, core) <> S_OK) or (core = nil) then
        Exit;
    try
        callNoArg := TComNoArg(comSlot(core, IDX_OPENDEVTOOLS));
        callNoArg(core);
    finally
        callNoArg := TComNoArg(comSlot(core, 2)); // IUnknown.Release
        callNoArg(core);
    end;
end;

{*******************************************************************************
* showMainWindow
* Reveals the (until-now hidden) WebView2 window in one step, at the right
* place/size/state — so it never flashes empty during startup. In full-screen it
* also creates the control bar; in windowed mode it honours the restored
* normal/maximized state.
*******************************************************************************}
procedure showMainWindow();
begin
    if gUseFullScreen then
    begin
        // createControlBar positions the (still hidden) window on the saved kiosk
        // monitor first; then show it there directly — no primary-monitor flash.
        createControlBar(gMainWnd, True, gDevMode, @openDevTools);
        ShowWindow(gMainWnd, SW_SHOW);
    end
    else
        ShowWindow(gMainWnd, restoredShowCmd);
    SetForegroundWindow(gMainWnd);
end;

{*******************************************************************************
* revealWhenReady
* Runs on the GUI thread (via webview_dispatch) once services are up: shows the
* WebView2 window behind the still-topmost splash and navigates to the real app
* URL. The worker then lingers briefly so the page paints before the splash is
* closed.
*******************************************************************************}
procedure revealWhenReady(aWebView: PWebView; aArg: Pointer); cdecl;
begin
    showMainWindow();
    webview_navigate(aWebView, PAnsiChar(gStartUtf8));
end;

{*******************************************************************************
* startupThread
* Worker thread: starts the services and waits for readiness off the GUI thread,
* then reveals the WebView2 window and retires the native splash.
*******************************************************************************}
function startupThread(aParam: Pointer): PtrInt;
begin
    startServices(gConfig);
    webview_dispatch(gWebView, @revealWhenReady, nil);
    Sleep(SPLASH_LINGER_MS);   // let WebView2 paint under the topmost splash
    stopSplash();
    Result := 0;
end;

begin
    // Optional startup profiling (enabled as early as possible so the first mark
    // is representative). --profile-splash logs the time-to-splash and exits.
    profileHalt := False;
    for i := 1 to ParamCount do
        if SameText(ParamStr(i), '--profile') or SameText(ParamStr(i), '--profile-splash') then
        begin
            profEnable;
            if SameText(ParamStr(i), '--profile-splash') then
                profileHalt := True;
        end;
    profMark('main-entry');

    // Become DPI-aware before any window is created so cursor, window and
    // metric coordinates share one space (needed for the control bar to track
    // the window) and the web content renders crisply on high-DPI displays.
    enablePerMonitorDpi;
    profMark('dpi-aware');

    // Per-deployment title/icon (AppCore.ico / AppCore.ini next to the exe) so the
    // taskbar buttons are distinguishable. The AppUserModelID must be set before
    // any window exists, so do this up front.
    loadBranding(brandTitle, brandIconBig, brandIconSmall);
    setAppUserModelId(brandTitle);

    SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                      exOverflow, exUnderflow, exPrecision]);

    useFullScreen := False;
    fullScreenForced := False;
    startUrl := 'http://localhost:8080';
    configPath := '';

    for i := 1 to ParamCount do
    begin
        if SameText(ParamStr(i), '-FullScreen') or SameText(ParamStr(i), '--FullScreen') then
        begin
            useFullScreen := True;
            fullScreenForced := True;
        end
        else if (SameText(ParamStr(i), '-url') or SameText(ParamStr(i), '--url')) and (i < ParamCount) then
            startUrl := ParamStr(i + 1)
        else if (SameText(ParamStr(i), '-config') or SameText(ParamStr(i), '--config')
                 or SameText(ParamStr(i), '-c')) and (i < ParamCount) then
            configPath := ParamStr(i + 1);
    end;

    // No explicit config given: fall back to app.cfg next to the executable.
    if configPath = '' then
    begin
        defaultCfg := ExtractFilePath(ParamStr(0)) + 'app.cfg';
        if FileExists(defaultCfg) then
            configPath := defaultCfg;
    end;

    profMark('args-parsed');
    useServices := configPath <> '';
    if useServices then
    begin
        if not loadAppConfig(configPath, cfg, cfgErr) then
            fail(cfgErr);
        profMark('config-loaded');
        // Self-update from ExeAutoUpdatePath: if a newer binary is staged, swap it
        // in and relaunch before doing anything else (a relaunch must happen
        // before any splash is shown, to avoid flashing two splashes).
        if cfg.ExeAutoUpdate and applyExeAutoUpdate(cfg.ExeAutoUpdatePath) then
            Halt(0);
        profMark('autoupdate-checked');
        gConfig := cfg;                    // SplashLang for the splash title / tr()
        gDevMode := cfg.Mode = amDev;      // enables DevTools + the bar button
        if not fullScreenForced then
            useFullScreen := cfg.FullScreen;
    end;

    gUseFullScreen := useFullScreen;
    profMark('pre-splash');

    // Show the native Pixie banner NOW — before the TCP port probing, which can
    // take a while on some machines (loopback RSTs get delayed by security
    // filters). The splash appears within a frame; the slow work runs behind it.
    if useServices then
        startSplash(tr('Загрузка…', 'Loading'));
    profMark('splash-visible');

    // --profile-splash: we only wanted the time-to-splash; dump it and exit
    // before the port probing / WebView2 / services.
    if profileHalt then
    begin
        stopSplash();
        profPath := IncludeTrailingPathDelimiter(GetTempDir) + 'appcore-startup-profile.log';
        profFlush(profPath);
        Halt(0);
    end;

    // Relocate to free ports (so several AppCore apps can coexist) behind the
    // visible splash; the results feed the services and the URL opened on ready.
    if useServices then
    begin
        resolveFreePorts(cfg);
        gConfig := cfg;
        startUrl := cfg.StartUrl;
    end;
    profMark('ports-resolved');

    gStartUtf8 := toUtf8(startUrl);

    // Enable DevTools (F12 + the bar button) in dev mode only.
    if gDevMode then
        w := webview_create(WebView_DevTools, nil)
    else
        w := webview_create(WebView_NoDevTools, nil);
    profMark('webview-created');
    if w = nil then
    begin
        stopSplash();
        fail('Failed to create WebView2 instance.'#13#10 +
            'Make sure Microsoft Edge WebView2 Runtime is installed.');
    end;
    gWebView := w;
    wnd := HWND(webview_get_window(w));
    gMainWnd := wnd;

    if brandTitle <> '' then
        webview_set_title(w, PAnsiChar(toUtf8(brandTitle)))
    else
        webview_set_title(w, PAnsiChar(toUtf8('AppCore')));
    applyWindowIcons(wnd, brandIconBig, brandIconSmall);

    // The webview library shows the window once, at a default size, via a queued
    // set_size (engine_base dispatch_size_default) that runs on the first
    // webview_run iteration unless a size was already set — and set_size keeps the
    // window's position (SWP_NOMOVE), so it would pop up empty at wherever we
    // placed it. Neutralise it: park the window FAR off-screen, let that default
    // size apply there, and set the size ourselves (claims the slot so the queued
    // default is skipped); then hide it again. From here the window is only ever
    // shown — on-screen, at the right place/size — by showMainWindow.
    SetWindowPos(wnd, 0, -32000, -32000, 800, 600, SWP_NOZORDER or SWP_NOACTIVATE);
    webview_set_size(w, 800, 600, WebView_Hint_None);
    ShowWindow(wnd, SW_HIDE);

    // Configure the window while it stays HIDDEN. It is shown once — at the right
    // place/size/state — by showMainWindow, so no empty window flashes on screen.
    if useFullScreen then
    begin
        // Borderless fullscreen; NO WS_VISIBLE here (that + SWP_FRAMECHANGED would
        // realise the window). Sized now, shown later.
        SetWindowLongW(wnd, GWL_STYLE, Integer(WS_POPUP));
        SetWindowPos(wnd, HWND_TOP, 0, 0,
            GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN),
            SWP_FRAMECHANGED or SWP_NOACTIVATE or SWP_NOZORDER);
    end
    else
    begin
        // Default 1024x768 centred (WM_SIZE lays out WebView2); attachWindowState
        // then overrides with the saved geometry. Both keep the window hidden and
        // record how to show it (normal/maximized) for showMainWindow.
        SetWindowPos(wnd, 0,
            (GetSystemMetrics(SM_CXSCREEN) - 1024) div 2,
            (GetSystemMetrics(SM_CYSCREEN) - 768) div 2,
            1024, 768, SWP_NOZORDER or SWP_NOACTIVATE);
        attachWindowState(wnd);
    end;

    webview_bind(w, PAnsiChar(toUtf8('__appcoreExit')), @handleExit, w);
    webview_init(w, PAnsiChar(toUtf8(
        'document.addEventListener("keydown",function(e){' +
        'if(e.key==="Escape")window.__appcoreExit();' +
        '});')));

    // With services, a worker thread starts the servers, pushes status to the
    // native splash, then reveals the WebView2 window and closes the splash.
    // Without services, open the URL and show the window right away.
    if useServices then
        BeginThread(@startupThread, nil)
    else
    begin
        showMainWindow();
        webview_navigate(w, PAnsiChar(gStartUtf8));
    end;

    profMark('run-loop-enter');
    if profEnabled then
        profFlush(IncludeTrailingPathDelimiter(GetTempDir) + 'appcore-startup-profile.log');

    webview_run(w);

    // Persist the last tracked window geometry (windowed mode only).
    if not useFullScreen then
        flushWindowState();

    // Window closed: stop the dev servers / build process and their console
    // windows before tearing down the webview.
    terminateProcessGroup;
    webview_destroy(w);
end.
