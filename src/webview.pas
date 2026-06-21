unit webview;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

type
    PWebView = type Pointer;
    TWebViewDispatchProc = procedure(aWebView: PWebView; aArg: Pointer); cdecl;
    TWebViewBindProc = procedure(const aSeq: PAnsiChar; const aReq: PAnsiChar; aArg: Pointer); cdecl;

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

{ Bindings to the webview C API (libwebview.dll). The exported symbol names are
  fixed by linkage and kept verbatim; parameters follow the 'a' prefix rule.
  All char* arguments are UTF-8. }
function webview_create(aDebug: Integer; aWindow: Pointer): PWebView;
    cdecl; external webview_lib;
procedure webview_destroy(aWebView: PWebView);
    cdecl; external webview_lib;
procedure webview_run(aWebView: PWebView);
    cdecl; external webview_lib;
procedure webview_terminate(aWebView: PWebView);
    cdecl; external webview_lib;
procedure webview_dispatch(aWebView: PWebView; aFn: TWebViewDispatchProc; aArg: Pointer);
    cdecl; external webview_lib;
function webview_get_window(aWebView: PWebView): Pointer;
    cdecl; external webview_lib;
function webview_get_native_handle(aWebView: PWebView; aKind: WebViewNativeHandleKind): Pointer;
    cdecl; external webview_lib;
procedure webview_set_title(aWebView: PWebView; const aTitle: PAnsiChar);
    cdecl; external webview_lib;
procedure webview_set_size(aWebView: PWebView; aWidth, aHeight, aHints: Integer);
    cdecl; external webview_lib;
procedure webview_navigate(aWebView: PWebView; const aUrl: PAnsiChar);
    cdecl; external webview_lib;
procedure webview_set_html(aWebView: PWebView; const aHtml: PAnsiChar);
    cdecl; external webview_lib;
procedure webview_init(aWebView: PWebView; const aJs: PAnsiChar);
    cdecl; external webview_lib;
procedure webview_eval(aWebView: PWebView; const aJs: PAnsiChar);
    cdecl; external webview_lib;
procedure webview_bind(aWebView: PWebView; const aName: PAnsiChar; aFn: TWebViewBindProc; aArg: Pointer);
    cdecl; external webview_lib;
procedure webview_unbind(aWebView: PWebView; const aName: PAnsiChar);
    cdecl; external webview_lib;
procedure webview_return(aWebView: PWebView; const aSeq: PAnsiChar; aStatus: Integer; const aResult: PAnsiChar);
    cdecl; external webview_lib;

implementation

end.
