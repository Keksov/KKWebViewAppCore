program AppMain;

{$mode objfpc}{$H+}

uses
  Math, Windows, SysUtils, webview, AppConfig, AppLaunch;

var
  w: PWebView;
  wnd: HWND;
  useFullScreen: Boolean;
  fullScreenForced: Boolean;
  startUrl: AnsiString;
  configPath: AnsiString;
  defaultCfg: AnsiString;
  cfg: TAppConfig;
  cfgErr: AnsiString;
  i: Integer;

{ Bound JS callback: terminates the run loop. WebView2's window.close() only
  raises WindowCloseRequested, which the webview library does not handle, so a
  native terminate is required to make ESC actually close the application. }
procedure handleExit(const seq: PAnsiChar; const req: PAnsiChar; arg: Pointer); cdecl;
begin
  webview_terminate(PWebView(arg));
end;

procedure Fail(const aMsg: AnsiString);
begin
  MessageBoxW(0, PWideChar(UnicodeString(aMsg)), 'AppCore Error',
    MB_OK or MB_ICONERROR);
  Halt(1);
end;

{ Starts backend/frontend processes described by the config, then waits for the
  target port to become reachable. In dev mode the bun/quasar dev servers run in
  their own console windows that stay open (cmd /k); in prod the UI is built and
  the server started. }
procedure StartServices(const aCfg: TAppConfig);
var
  exitCode: DWORD;
  envPrefix: AnsiString;
begin
  if aCfg.Mode = amDev then
  begin
    if aCfg.ServerDir <> '' then
      LaunchInConsole(aCfg.ServerDir,
        '"' + aCfg.BunExe + '" run dev', 'KK Server (dev)', '', True);
    if aCfg.UiDir <> '' then
      LaunchInConsole(aCfg.UiDir,
        '"' + aCfg.BunExe + '" run dev', 'KK UI (quasar dev)', '', True);
  end
  else
  begin
    if aCfg.BuildUi and (aCfg.UiDir <> '') then
    begin
      if not RunAndWait(aCfg.UiDir, '"' + aCfg.BunExe + '" run build',
        'KK UI build', exitCode) then
        Fail('Failed to start UI build (bun run build).');
      if exitCode <> 0 then
        Fail(Format('UI build failed (exit code %d).', [exitCode]));
    end;

    if aCfg.ServerDir <> '' then
    begin
      envPrefix := Format('set PORT=%d&& ', [aCfg.ServerPort]);
      LaunchInConsole(aCfg.ServerDir,
        '"' + aCfg.BunExe + '" run start', 'KK Server', envPrefix, False);
    end;
  end;

  WaitForPort(aCfg.ReadyPort, aCfg.ReadyTimeoutSec);
end;

begin
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

  { No explicit config given: fall back to app.cfg next to the executable. }
  if configPath = '' then
  begin
    defaultCfg := ExtractFilePath(ParamStr(0)) + 'app.cfg';
    if FileExists(defaultCfg) then
      configPath := defaultCfg;
  end;

  if configPath <> '' then
  begin
    if not LoadAppConfig(configPath, cfg, cfgErr) then
      Fail(cfgErr);
    startUrl := cfg.StartUrl;
    if not fullScreenForced then
      useFullScreen := cfg.FullScreen;
    StartServices(cfg);
  end;

  w := webview_create(WebView_NoDevTools, nil);
  if w = nil then
    Fail('Failed to create WebView2 instance.'#13#10 +
      'Make sure Microsoft Edge WebView2 Runtime is installed.');

  webview_set_title(w, PAnsiChar('AppCore'));

  if useFullScreen then
  begin
    wnd := HWND(webview_get_window(w));
    SetWindowLongW(wnd, GWL_STYLE, Integer(WS_POPUP or WS_VISIBLE));
    SetWindowPos(wnd, HWND_TOP, 0, 0,
      GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN),
      SWP_FRAMECHANGED);
  end
  else
    webview_set_size(w, 1024, 768, WebView_Hint_None);

  webview_bind(w, PAnsiChar('__appcoreExit'), @handleExit, w);
  webview_init(w, PAnsiChar(
    'document.addEventListener("keydown",function(e){' +
    'if(e.key==="Escape")window.__appcoreExit();' +
    '});'));

  webview_navigate(w, PAnsiChar(startUrl));
  webview_run(w);
  webview_destroy(w);
end.
