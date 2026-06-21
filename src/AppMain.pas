program AppMain;

{$mode objfpc}{$H+}

uses
  Math, Windows, SysUtils, webview;

var
  w: PWebView;
  wnd: HWND;
  useFullScreen: Boolean;
  startUrl: AnsiString;
  i: Integer;

{ Bound JS callback: terminates the run loop. WebView2's window.close() only
  raises WindowCloseRequested, which the webview library does not handle, so a
  native terminate is required to make ESC actually close the application. }
procedure handleExit(const seq: PAnsiChar; const req: PAnsiChar; arg: Pointer); cdecl;
begin
  webview_terminate(PWebView(arg));
end;

begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                     exOverflow, exUnderflow, exPrecision]);

  useFullScreen := False;
  startUrl := 'http://localhost:8080';

  for i := 1 to ParamCount do
  begin
    if SameText(ParamStr(i), '-FullScreen') or SameText(ParamStr(i), '--FullScreen') then
      useFullScreen := True
    else if (SameText(ParamStr(i), '-url') or SameText(ParamStr(i), '--url')) and (i < ParamCount) then
      startUrl := ParamStr(i + 1);
  end;

  w := webview_create(WebView_NoDevTools, nil);
  if w = nil then
  begin
    MessageBoxW(0, 'Failed to create WebView2 instance.'#13#10 +
      'Make sure Microsoft Edge WebView2 Runtime is installed.',
      'AppCore Error', MB_OK or MB_ICONERROR);
    Halt(1);
  end;

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
