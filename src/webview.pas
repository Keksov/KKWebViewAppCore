unit webview;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

type
  PWebView = type Pointer;
  TWebViewDispatchProc = procedure(w: PWebView; arg: Pointer); cdecl;
  TWebViewBindProc = procedure(const seq: PAnsiChar; const req: PAnsiChar; arg: Pointer); cdecl;

const
  webview_lib = 'libwebview.dll';

  WebView_NoDevTools = 0;
  WebView_DevTools = 1;
  WebView_Hint_None = 0;
  WebView_Hint_Min = 1;
  WebView_Hint_Max = 2;
  WebView_Hint_Fixed = 3;
  WebView_Return_Ok = 0;
  WebView_Return_Error = 1;

type
  WebViewNativeHandleKind = (UI_Window, UI_Widget, Browser_Controller);

function webview_create(debug: Integer; window: Pointer): PWebView;
  cdecl; external webview_lib;
procedure webview_destroy(w: PWebView);
  cdecl; external webview_lib;
procedure webview_run(w: PWebView);
  cdecl; external webview_lib;
procedure webview_terminate(w: PWebView);
  cdecl; external webview_lib;
procedure webview_dispatch(w: PWebView; fn: TWebViewDispatchProc; arg: Pointer);
  cdecl; external webview_lib;
function webview_get_window(w: PWebView): Pointer;
  cdecl; external webview_lib;
function webview_get_native_handle(w: PWebView; kind: WebViewNativeHandleKind): Pointer;
  cdecl; external webview_lib;
procedure webview_set_title(w: PWebView; const title: PAnsiChar);
  cdecl; external webview_lib;
procedure webview_set_size(w: PWebView; width, height, hints: Integer);
  cdecl; external webview_lib;
procedure webview_navigate(w: PWebView; const url: PAnsiChar);
  cdecl; external webview_lib;
procedure webview_set_html(w: PWebView; const html: PAnsiChar);
  cdecl; external webview_lib;
procedure webview_init(w: PWebView; const js: PAnsiChar);
  cdecl; external webview_lib;
procedure webview_eval(w: PWebView; const js: PAnsiChar);
  cdecl; external webview_lib;
procedure webview_bind(w: PWebView; const name: PAnsiChar; fn: TWebViewBindProc; arg: Pointer);
  cdecl; external webview_lib;
procedure webview_unbind(w: PWebView; const name: PAnsiChar);
  cdecl; external webview_lib;
procedure webview_return(w: PWebView; const seq: PAnsiChar; status: Integer; const result: PAnsiChar);
  cdecl; external webview_lib;

implementation

end.
