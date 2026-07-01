program AppMain;

{$IFDEF FPC}
{$mode delphiunicode}
{$codepage utf8}
{$ENDIF}

uses
    Math, Windows, SysUtils, webview, AppConfig, AppLaunch, AppUpdate, AppBar;

const
    // Shown immediately while services start, so the window never looks frozen.
    // A spinner plus a live checklist that startServices fills in via acPhase().
    // acPhase is defined up front and queues calls until __render (after <body>)
    // is ready, so no early step is lost. All ASCII (the source is ANSI); step
    // labels come from Pascal.
    SPLASH_HTML =
        '<!doctype html><meta charset="utf-8">' +
        '<style>' +
        'html,body{margin:0;height:100%}' +
        'body{display:flex;align-items:center;justify-content:center;' +
        'background:#1e1e1e;color:#e0e0e0;font-family:Segoe UI,Arial,sans-serif}' +
        '.box{width:min(80vw,360px)}' +
        '.sp{width:46px;height:46px;margin:0 auto 20px;border:4px solid #333;' +
        'border-top-color:#22d3ee;border-radius:50%;animation:r 1s linear infinite}' +
        '@keyframes r{to{transform:rotate(360deg)}}' +
        '.t{font-size:22px;font-weight:600;text-align:center;margin-bottom:18px}' +
        '.steps div{color:#8a8a8a;font-size:14px;line-height:1.9}' +
        '.steps div.active{color:#22d3ee}.steps div.done{color:#4ade80}' +
        '.steps div::before{content:"\2022";display:inline-block;width:22px;text-align:center}' +
        '.steps div.active::before{content:"\2026"}' +
        '.steps div.done::before{content:"\2713"}' +
        '</style>' +
        '<script>window.__ph=[];window.__title=null;' +
        'window.acPhase=function(t){window.__ph.push(t);if(window.__render)window.__render()};' +
        'window.acTitle=function(t){window.__title=t;if(window.__render)window.__render()}</script>' +
        '<body><div class="box"><div class="sp"></div>' +
        '<div class="t">...</div><div class="steps" id="steps"></div></div>' +
        '<script>window.__c=null;window.__render=function(){' +
        'if(window.__title!==null){var h=document.querySelector(".t");if(h)h.textContent=window.__title}' +
        'var c=document.getElementById("steps");if(!c)return;' +
        'while(window.__ph.length){var t=window.__ph.shift();' +
        'if(window.__c)window.__c.className="done";' +
        'var e=document.createElement("div");e.className="active";e.textContent=t;' +
        'c.appendChild(e);window.__c=e}};window.__render()</script></body>';

var
    wnd: HWND;
    i: Integer;
    w: PWebView;
    tid: DWORD;
    cfg: TAppConfig;
    cfgErr: string;
    startUrl: string;
    configPath: string;
    defaultCfg: string;
    gWebView: PWebView;       // shared with the startup thread
    gConfig: TAppConfig;      // shared with the startup thread
    gStartUtf8: UTF8String;   // resolved target URL (UTF-8), opened once ready
    useServices: Boolean;
    useFullScreen: Boolean;
    fullScreenForced: Boolean;

function SetProcessDPIAware: BOOL; stdcall; external 'user32' name 'SetProcessDPIAware';

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
* doEval
* Runs on the GUI thread (via webview_dispatch): evaluates the queued JS, then
* frees the buffer allocated by pushEval.
*******************************************************************************}
procedure doEval(aWebView: PWebView; aArg: Pointer); cdecl;
begin
    if aArg = nil then
        Exit;
    webview_eval(aWebView, PAnsiChar(aArg));
    FreeMem(aArg);
end;

{*******************************************************************************
* pushEval
* Queues a JS snippet (UTF-8) to run on the GUI thread from any thread. The
* buffer is handed to doEval, which frees it.
*******************************************************************************}
procedure pushEval(const aJs: UTF8String);
var
    len: Integer;
    buf: PAnsiChar;
begin
    if gWebView = nil then
        Exit;
    len := Length(aJs);
    GetMem(buf, len + 1);
    if len > 0 then
        Move(aJs[1], buf^, len);
    buf[len] := #0;
    webview_dispatch(gWebView, @doEval, buf);
end;

{*******************************************************************************
* splashPhase
* Adds/advances a step on the splash checklist (aText must be plain ASCII with
* no double quotes).
*******************************************************************************}
procedure splashPhase(const aText: string);
begin
    pushEval(UTF8String('window.acPhase&&acPhase("' + aText + '")'));
end;

{*******************************************************************************
* splashTitle
* Sets the splash heading (aText plain, no double quotes).
*******************************************************************************}
procedure splashTitle(const aText: string);
begin
    pushEval(UTF8String('window.acTitle&&acTitle("' + aText + '")'));
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
begin
    splashTitle(tr('Запуск…', 'Starting'));
    if aCfg.Mode = amDev then
    begin
        envPrefix := Format('set PORT=%d&& ', [aCfg.ServerPort]);
        if aCfg.ServerDir <> '' then
        begin
            splashPhase(tr('Запуск сервера', 'Starting backend'));
            launchInConsole(aCfg.ServerDir,
                '"' + aCfg.BunExe + '" run dev', 'KK Server (dev)', envPrefix, True);
        end;
        // PORT lets the quasar proxy target the (possibly relocated) backend;
        // --port moves the quasar dev server itself to the chosen free UI port.
        if aCfg.UiDir <> '' then
        begin
            splashPhase(tr('Запуск интерфейса', 'Starting interface'));
            launchInConsole(aCfg.UiDir,
                Format('"%s" run dev -- --port %d', [aCfg.BunExe, aCfg.ReadyPort]),
                'KK UI (quasar dev)', envPrefix, True);
        end;
    end
    else
    begin
        if aCfg.BuildUi and (aCfg.UiDir <> '') then
        begin
            splashPhase(tr('Сборка интерфейса', 'Building interface'));
            if not runAndWait(aCfg.UiDir, '"' + aCfg.BunExe + '" run build',
                'KK UI build', exitCode) then
                fail('Failed to start UI build (bun run build).');
            if exitCode <> 0 then
                fail(Format('UI build failed (exit code %d).', [exitCode]));
        end;

        if aCfg.ServerDir <> '' then
        begin
            splashPhase(tr('Запуск сервера', 'Starting server'));
            envPrefix := Format('set PORT=%d&& ', [aCfg.ServerPort]);
            launchInConsole(aCfg.ServerDir,
                '"' + aCfg.BunExe + '" run start', 'KK Server', envPrefix, False);
        end;
    end;

    splashPhase(tr('Ожидание готовности', 'Waiting for services'));
    waitForPort(aCfg.ReadyPort, aCfg.ReadyTimeoutSec);
    splashPhase(tr('Готово', 'Ready'));
end;

{*******************************************************************************
* navigateWhenReady
* Runs on the GUI thread (via webview_dispatch) once services are up: switches
* the window from the splash page to the real application URL.
*******************************************************************************}
procedure navigateWhenReady(aWebView: PWebView; aArg: Pointer); cdecl;
begin
    webview_navigate(aWebView, PAnsiChar(gStartUtf8));
end;

{*******************************************************************************
* startupThread
* Worker thread: starts the services and waits for readiness off the GUI thread,
* then asks the GUI thread to navigate to the application URL.
*******************************************************************************}
function startupThread(aParam: Pointer): DWORD; stdcall;
begin
    startServices(gConfig);
    webview_dispatch(gWebView, @navigateWhenReady, nil);
    Result := 0;
end;

begin
    // Become DPI-aware before any window is created so cursor, window and
    // metric coordinates share one space (needed for the control bar to track
    // the window) and the web content renders crisply on high-DPI displays.
    SetProcessDPIAware;

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

    useServices := configPath <> '';
    if useServices then
    begin
        if not loadAppConfig(configPath, cfg, cfgErr) then
            fail(cfgErr);
        // Self-update from ExeAutoUpdatePath: if a newer binary is staged, swap it
        // in and relaunch before doing anything else.
        if cfg.ExeAutoUpdate and applyExeAutoUpdate(cfg.ExeAutoUpdatePath) then
            Halt(0);
        // Relocate to free ports so several AppCore apps can run at once.
        resolveFreePorts(cfg);
        startUrl := cfg.StartUrl;
        gConfig := cfg;
        if not fullScreenForced then
            useFullScreen := cfg.FullScreen;
    end;

    gStartUtf8 := toUtf8(startUrl);

    w := webview_create(WebView_NoDevTools, nil);
    if w = nil then
        fail('Failed to create WebView2 instance.'#13#10 +
            'Make sure Microsoft Edge WebView2 Runtime is installed.');
    gWebView := w;

    webview_set_title(w, PAnsiChar(toUtf8('AppCore')));

    if useFullScreen then
    begin
        wnd := HWND(webview_get_window(w));
        SetWindowLongW(wnd, GWL_STYLE, Integer(WS_POPUP or WS_VISIBLE));
        SetWindowPos(wnd, HWND_TOP, 0, 0,
            GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN),
            SWP_FRAMECHANGED);
        // Borderless window has no system buttons; add an RDP-style floating bar.
        createControlBar(wnd, True);
    end
    else
        webview_set_size(w, 1024, 768, WebView_Hint_None);

    webview_bind(w, PAnsiChar(toUtf8('__appcoreExit')), @handleExit, w);
    webview_init(w, PAnsiChar(toUtf8(
        'document.addEventListener("keydown",function(e){' +
        'if(e.key==="Escape")window.__appcoreExit();' +
        '});')));

    // With services, show the splash immediately and let a worker thread start
    // the servers and navigate when ready, so the window is never invisible
    // during the (possibly long) startup. Without services, open the URL now.
    if useServices then
    begin
        webview_set_html(w, PAnsiChar(toUtf8(SPLASH_HTML)));
        CreateThread(nil, 0, @startupThread, nil, 0, tid);
    end
    else
        webview_navigate(w, PAnsiChar(gStartUtf8));

    webview_run(w);

    // Window closed: stop the dev servers / build process and their console
    // windows before tearing down the webview.
    terminateProcessGroup;
    webview_destroy(w);
end.
