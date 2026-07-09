program AppMain;

{$IFDEF FPC}
{$mode delphiunicode}
{$codepage utf8}
{$ENDIF}

uses
    Math, Windows, SysUtils, webview, AppConfig, AppLaunch, AppUpdate,
    AppWindowState, AppWindowMode, AppBar, AppSplash, AppProfile, AppBranding;

const
    // How long the native splash lingers (topmost) after the WebView2 window is
    // shown and navigated, so the app has time to paint underneath before the
    // splash is removed — avoids a blank-white flash on the swap.
    SPLASH_LINGER_MS = 700;

    // Custom WM_SYSCOMMAND ids for the Normal-mode system menu (WN2.2). Must be < $F000
    // and have a zero low nibble (the system uses the low 4 bits of WM_SYSCOMMAND wParam).
    IDM_TOGGLE_MODE = $A010;   // toggle Kiosk <-> Normal
    IDM_DEVTOOLS    = $A020;   // open DevTools (dev mode only, WN-D8)

var
    wnd: HWND;
    i: Integer;
    w: PWebView;
    cfg: TAppConfig;
    cfgErr: string;
    startUrl: string;
    savedMode: string;        // persisted display mode ('kiosk'|'normal'), if any
    configPath: string;
    defaultCfg: string;
    gWebView: PWebView;       // shared with the startup thread
    gConfig: TAppConfig;      // shared with the startup thread
    gStartUtf8: UTF8String;   // resolved target URL (UTF-8), opened once ready
    gMainWnd: HWND;           // WebView2 window, kept hidden until ready
    gUseFullScreen: Boolean;  // shared with the reveal callback
    gDevMode: Boolean;        // dev config: enables DevTools + the bar button
    gWindowMode: TWindowMode; // current display mode (kiosk/normal), runtime-switchable
    gBarBuilt: Boolean;       // the control bar has been created at least once
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
* Bound JS callback (window.__appcoreExit): terminates the run loop. WebView2's
* window.close() only raises WindowCloseRequested, which the webview library does not
* handle, so a native terminate is required for the web UI to close the app.
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
* addSystemMenuItems
* Rebuilds the Normal-mode window system menu: reverts to the default, then appends a
* "toggle mode" item and (in dev mode) a DevTools item (WN2.2 / WN-D8). Reverting first
* means re-entering Normal mode never duplicates the items.
*******************************************************************************}
procedure addSystemMenuItems(aWnd: HWND);
var
    sysMenu: HMENU;
begin
    GetSystemMenu(aWnd, True);            // revert to default (drops any prior custom items)
    sysMenu := GetSystemMenu(aWnd, False);
    if sysMenu = 0 then
        Exit;
    AppendMenuW(sysMenu, MF_SEPARATOR, 0, nil);
    AppendMenuW(sysMenu, MF_STRING, IDM_TOGGLE_MODE, PWideChar(UnicodeString('Режим киоска')));
    if gDevMode then
        AppendMenuW(sysMenu, MF_STRING, IDM_DEVTOOLS, PWideChar(UnicodeString('Инструменты разработчика')));
end;

{*******************************************************************************
* showMainWindow
* Reveals the (until-now hidden) WebView2 window in one step, at the right
* place/size/state — so it never flashes empty during startup. In Kiosk it also
* creates the control bar; in Normal mode it honours the restored normal/maximized
* state and builds the system menu (WN3.1).
*******************************************************************************}
procedure showMainWindow();
begin
    if gUseFullScreen then
    begin
        // createControlBar positions the (still hidden) window on the saved kiosk
        // monitor first; then show it there directly — no primary-monitor flash.
        createControlBar(gMainWnd, True, gDevMode, @openDevTools);
        gBarBuilt := True;
        ShowWindow(gMainWnd, SW_SHOW);
    end
    else
    begin
        // Apply the full OS-decorated style so a Normal-mode START (dispmode=normal) has the
        // same chrome as a runtime switch: WS_OVERLAPPEDWINDOW brings WS_SYSMENU, which the
        // title-bar icon and the system menu both require (without it neither appears).
        applyNormalStyle(gMainWnd);
        ShowWindow(gMainWnd, restoredShowCmd);
        addSystemMenuItems(gMainWnd);     // Normal at startup: add the toggle/DevTools items
    end;
    SetForegroundWindow(gMainWnd);
end;

{*******************************************************************************
* setWindowMode
* Switches the display mode at runtime (WN2.1). To Normal: hide the floating bar, swap
* to an OS-decorated frame, restore the saved windowed placement and build the system
* menu. To Kiosk: build the bar the first time (or re-activate it) and re-assert the
* borderless kiosk geometry. The chosen mode is persisted so it is restored next launch.
*******************************************************************************}
procedure setWindowMode(aMode: TWindowMode);
begin
    if (gMainWnd = 0) or (aMode = gWindowMode) then
        Exit;
    gWindowMode := aMode;
    if aMode = wmNormal then
    begin
        setBarActive(False);              // hide the floating control bar (WN-D2)
        setTrackMode(wmNormal);
        applyNormalStyle(gMainWnd);       // OS-decorated frame
        applyNormalPlacement(gMainWnd);   // position + show from saved win= (WN-D7)
        addSystemMenuItems(gMainWnd);     // "toggle mode" + DevTools items (WN2.2)
    end
    else
    begin
        setTrackMode(wmKiosk);
        if not gBarBuilt then
        begin
            createControlBar(gMainWnd, True, gDevMode, @openDevTools);
            gBarBuilt := True;
        end
        else
            activateKioskBar();
    end;
    saveDispMode(windowModeToString(aMode));
    SetForegroundWindow(gMainWnd);
end;

{*******************************************************************************
* otherMode — the display mode opposite to the current one (for toggle actions).
*******************************************************************************}
function otherMode(): TWindowMode;
begin
    if gWindowMode = wmNormal then
        Result := wmKiosk
    else
        Result := wmNormal;
end;

{*******************************************************************************
* handleSetWindowMode
* Bound JS callback (window.__appcoreSetWindowMode): switches the display mode. The arg
* is a JSON array; "normal" or "kiosk" in it selects that mode, anything else toggles.
*******************************************************************************}
procedure handleSetWindowMode(const aSeq: PAnsiChar; const aReq: PAnsiChar; aArg: Pointer); cdecl;
var
    req: string;
    raw: UTF8String;
    target: TWindowMode;
begin
    raw := aReq;                        // copy the null-terminated UTF-8 args
    req := LowerCase(string(raw));
    if Pos('normal', req) > 0 then
        target := wmNormal
    else if Pos('kiosk', req) > 0 then
        target := wmKiosk
    else
        target := otherMode();
    setWindowMode(target);
    webview_return(PWebView(aArg), aSeq, 0, PAnsiChar('null'));
end;

{*******************************************************************************
* onSysCommand
* Handles the custom Normal-mode system-menu items (WN2.2): toggle the display mode or
* open DevTools. Returns True when it handled the command.
*******************************************************************************}
function onSysCommand(aCmd: WPARAM): Boolean;
begin
    Result := True;
    if aCmd = IDM_TOGGLE_MODE then
        setWindowMode(otherMode())
    else if aCmd = IDM_DEVTOOLS then
        openDevTools()
    else
        Result := False;
end;

{*******************************************************************************
* enterNormalMode — switch to Normal mode (registered as the AppBar Ctrl-click handler).
*******************************************************************************}
procedure enterNormalMode();
begin
    setWindowMode(wmNormal);
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

{*******************************************************************************
* runRemapTest — self-test for AppWindowState.remapNormalRect (the multi-monitor geometry
* remap). Writes PASS/FAIL per case to %TEMP%\appcore-remap-test.log (the GUI subsystem has
* no console). Run: AppMain.exe --test-remap
*******************************************************************************}
function mkRect(aL, aT, aR, aB: Integer): TRect;
begin
    Result.Left := aL;
    Result.Top := aT;
    Result.Right := aR;
    Result.Bottom := aB;
end;

procedure runRemapTest();
var
    log: TextFile;
    passed, total: Integer;
    src, tgt, win: TRect;

    procedure check(const aName: string; const aGot, aExp: TRect);
    var
        ok: Boolean;
        verdict: string;
    begin
        Inc(total);
        ok := (aGot.Left = aExp.Left) and (aGot.Top = aExp.Top)
            and (aGot.Right = aExp.Right) and (aGot.Bottom = aExp.Bottom);
        if ok then
        begin
            Inc(passed);
            verdict := 'PASS';
        end
        else
            verdict := 'FAIL';
        Writeln(log, Format('%-24s got (%d,%d,%d,%d) exp (%d,%d,%d,%d)  %s',
            [aName, aGot.Left, aGot.Top, aGot.Right, aGot.Bottom,
             aExp.Left, aExp.Top, aExp.Right, aExp.Bottom, verdict]));
    end;

begin
    AssignFile(log, IncludeTrailingPathDelimiter(GetTempDir) + 'appcore-remap-test.log');
    Rewrite(log);
    passed := 0; total := 0;

    // 1) Near-full on 1280x1024 (10px margins) -> bigger 3840x2160: preserve edge margins.
    src := mkRect(0, 0, 1280, 1024); win := mkRect(10, 10, 1270, 1014); tgt := mkRect(0, 0, 3840, 2160);
    check('bigger-preserve-margins', remapNormalRect(win, src, tgt), mkRect(10, 10, 3830, 2150));

    // 2) 800x600 on 1920x1080 -> smaller 1280x1024 (fits): keep size, proportional offset.
    src := mkRect(0, 0, 1920, 1080); win := mkRect(200, 150, 1000, 750); tgt := mkRect(0, 0, 1280, 1024);
    check('smaller-fits-keepsize', remapNormalRect(win, src, tgt), mkRect(133, 142, 933, 742));

    // 3) 1600x1000 on 1920x1080 -> smaller 1280x1024 (does not fit): fill the work area.
    src := mkRect(0, 0, 1920, 1080); win := mkRect(50, 40, 1650, 1040); tgt := mkRect(0, 0, 1280, 1024);
    check('smaller-nofit-fill', remapNormalRect(win, src, tgt), mkRect(0, 0, 1280, 1024));

    // 4) Unknown source monitor (old saved state), window fits: centre it.
    src := mkRect(0, 0, 0, 0); win := mkRect(0, 0, 800, 600); tgt := mkRect(0, 0, 1280, 1024);
    check('nosrc-center', remapNormalRect(win, src, tgt), mkRect(240, 212, 1040, 812));

    Writeln(log, Format('TOTAL: %d/%d passed', [passed, total]));
    CloseFile(log);
end;

begin
    for i := 1 to ParamCount do
        if SameText(ParamStr(i), '--test-remap') then
        begin
            runRemapTest();
            Halt(0);
        end;

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
    // taskbar buttons are distinguishable. The AUMID must be set before any window exists.
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
        // Mode precedence (WN-D6): -FullScreen forces Kiosk; else a previously saved
        // display mode wins (a runtime Kiosk<->Normal switch persists); else the
        // deployment default cfg.FullScreen (true = Kiosk for kiosk deployments).
        if not fullScreenForced then
        begin
            if loadDispMode(savedMode) then
                useFullScreen := (windowModeFromString(savedMode, wmKiosk) = wmKiosk)
            else
                useFullScreen := cfg.FullScreen;
        end;
    end;

    gUseFullScreen := useFullScreen;
    if useFullScreen then
        gWindowMode := wmKiosk
    else
        gWindowMode := wmNormal;
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
    // Register the window's taskbar identity so the button shows the deployment name + icon
    // instead of the exe filename ("AppMain.exe"): AUMID + display name + icon resource.
    // Prefer AppCore.ico (a stable data file) over the exe: the exe path may have a stale
    // shell icon-cache entry from when it was unstamped; the .ico avoids that.
    setWindowTaskbarIdentity(wnd, appUserModelId(brandTitle), brandTitle, ParamStr(0) + ',0');

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

    // Programmatic exit hook for the web UI (window.__appcoreExit()). No global ESC
    // handler is injected — closing on ESC is non-standard; use Alt+F4, the window's
    // Close button, or the system menu.
    webview_bind(w, PAnsiChar(toUtf8('__appcoreExit')), @handleExit, w);
    // Runtime window-mode switch from the web UI + the Normal-mode system menu (WN2.2).
    webview_bind(w, PAnsiChar(toUtf8('__appcoreSetWindowMode')), @handleSetWindowMode, w);
    setSysCommandHandler(@onSysCommand);
    setNormalModeHandler(@enterNormalMode);   // Ctrl-click the bar's Max button -> Normal


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
