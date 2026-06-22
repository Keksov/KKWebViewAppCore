unit AppBar;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

uses
    Windows, Math;

{ Creates an RDP-style floating control bar pinned to the top-center of the main
  window with minimize / restore-fullscreen / close buttons. The bar stays
  visible but faint and fades to fully opaque while the cursor is over it, so it
  can always be located. Must be called on the GUI thread before the webview
  message loop starts; that loop pumps the bar's messages. aFullScreen tells the
  bar the window's initial state. }
procedure createControlBar(aMainWindow: HWND; aFullScreen: Boolean);

implementation

const
    BAR_CLASS: PWideChar = 'AppCoreControlBar';
    BAR_WIDTH = 132;
    BAR_HEIGHT = 30;
    BTN_WIDTH = 44;
    TIMER_ID = 1;
    TIMER_MS = 30;
    ID_MIN = 1001;
    ID_MAX = 1002;
    ID_CLOSE = 1003;
    ALPHA_IDLE = 60;    // faint but still findable when the cursor is away
    ALPHA_ACTIVE = 255; // fully opaque while hovered
    ALPHA_STEP = 22;    // per-tick fade speed

var
    gFull: Boolean = True;
    gAlpha: Integer = ALPHA_IDLE;
    gScreenW: Integer = 0;
    gScreenH: Integer = 0;
    gBarWnd: HWND = 0;
    gMainWnd: HWND = 0;
    gBtnMin: HWND = 0;
    gBtnMax: HWND = 0;
    gBtnClose: HWND = 0;

{*******************************************************************************
* applyMainGeometry
* Switches the (borderless) main window between full screen and a centered
* restored size.
*******************************************************************************}
procedure applyMainGeometry(aFull: Boolean);
var
    rw, rh: Integer;
begin
    SetWindowLongW(gMainWnd, GWL_STYLE, Integer(WS_POPUP or WS_VISIBLE));
    if aFull then
        SetWindowPos(gMainWnd, HWND_TOP, 0, 0, gScreenW, gScreenH, SWP_FRAMECHANGED)
    else
    begin
        rw := (gScreenW * 7) div 10;
        rh := (gScreenH * 7) div 10;
        SetWindowPos(gMainWnd, HWND_TOP, (gScreenW - rw) div 2, (gScreenH - rh) div 2,
            rw, rh, SWP_FRAMECHANGED);
    end;
    gFull := aFull;
    SetForegroundWindow(gMainWnd);
end;

{*******************************************************************************
* setBarAlpha
*******************************************************************************}
procedure setBarAlpha(aAlpha: Integer);
begin
    if aAlpha < 0 then aAlpha := 0;
    if aAlpha > 255 then aAlpha := 255;
    gAlpha := aAlpha;
    SetLayeredWindowAttributes(gBarWnd, 0, Byte(aAlpha), LWA_ALPHA);
end;

{*******************************************************************************
* cursorOverBar
* DPI-safe hover test: compares the window under the cursor against the bar and
* its buttons by handle, avoiding any cursor-vs-screen coordinate arithmetic.
*******************************************************************************}
function cursorOverBar: Boolean;
var
    pt: TPoint;
    h: HWND;
begin
    Result := False;
    if not GetCursorPos(pt) then
        Exit;
    h := WindowFromPoint(pt);
    Result := (h = gBarWnd) or (h = gBtnMin) or (h = gBtnMax) or (h = gBtnClose);
end;

{*******************************************************************************
* updateBar
* Keeps the bar pinned to the top-center of the main window and fades it between
* a faint idle level and fully opaque depending on whether the cursor is over
* it. The bar never fully disappears (except while the window is minimized).
*******************************************************************************}
procedure updateBar;
var
    wr: TRect;
    target: Integer;
    barX, barTop: Integer;
begin
    if IsIconic(gMainWnd) or (not GetWindowRect(gMainWnd, wr)) then
    begin
        if IsWindowVisible(gBarWnd) then
            ShowWindow(gBarWnd, SW_HIDE);
        Exit;
    end;

    barX := wr.Left + ((wr.Right - wr.Left) - BAR_WIDTH) div 2;
    barTop := wr.Top;
    SetWindowPos(gBarWnd, HWND_TOPMOST, barX, barTop, BAR_WIDTH, BAR_HEIGHT,
        SWP_NOACTIVATE or SWP_SHOWWINDOW);

    if cursorOverBar then target := ALPHA_ACTIVE else target := ALPHA_IDLE;

    if gAlpha < target then
        setBarAlpha(Min(gAlpha + ALPHA_STEP, target))
    else if gAlpha > target then
        setBarAlpha(Max(gAlpha - ALPHA_STEP, target));
end;

{*******************************************************************************
* barWndProc
*******************************************************************************}
function barWndProc(aWnd: HWND; aMsg: UINT; aWParam: WPARAM; aLParam: LPARAM): LRESULT; stdcall;
begin
    case aMsg of
        WM_TIMER:
            begin
                updateBar;
                Result := 0;
            end;
        WM_COMMAND:
            begin
                case LOWORD(aWParam) of
                    ID_MIN: ShowWindow(gMainWnd, SW_MINIMIZE);
                    ID_MAX: applyMainGeometry(not gFull);
                    ID_CLOSE: PostMessageW(gMainWnd, WM_CLOSE, 0, 0);
                end;
                Result := 0;
            end;
        WM_DESTROY:
            begin
                KillTimer(aWnd, TIMER_ID);
                Result := 0;
            end;
    else
        Result := DefWindowProcW(aWnd, aMsg, aWParam, aLParam);
    end;
end;

{*******************************************************************************
* addButton
*******************************************************************************}
function addButton(const aCaption: UnicodeString; aId: Integer; aX: Integer;
    aInst: HINST; aFont: HGDIOBJ): HWND;
begin
    Result := CreateWindowExW(0, 'BUTTON', PWideChar(aCaption),
        WS_CHILD or WS_VISIBLE or BS_PUSHBUTTON or BS_FLAT,
        aX, 0, BTN_WIDTH, BAR_HEIGHT, gBarWnd, HMENU(PtrUInt(aId)), aInst, nil);
    if (Result <> 0) and (aFont <> 0) then
        SendMessageW(Result, WM_SETFONT, WPARAM(aFont), 1);
end;

{*******************************************************************************
* createControlBar
*******************************************************************************}
procedure createControlBar(aMainWindow: HWND; aFullScreen: Boolean);
var
    wc: WNDCLASSEXW;
    inst: HINST;
    font: HGDIOBJ;
begin
    gMainWnd := aMainWindow;
    gFull := aFullScreen;
    gScreenW := GetSystemMetrics(SM_CXSCREEN);
    gScreenH := GetSystemMetrics(SM_CYSCREEN);
    inst := GetModuleHandleW(nil);

    FillChar(wc, SizeOf(wc), 0);
    wc.cbSize := SizeOf(wc);
    wc.lpfnWndProc := @barWndProc;
    wc.hInstance := inst;
    wc.hCursor := LoadCursorW(0, PWideChar(IDC_ARROW));
    wc.hbrBackground := HBRUSH(COLOR_BTNFACE + 1);
    wc.lpszClassName := BAR_CLASS;
    RegisterClassExW(@wc);

    gBarWnd := CreateWindowExW(
        WS_EX_TOPMOST or WS_EX_TOOLWINDOW or WS_EX_NOACTIVATE or WS_EX_LAYERED,
        BAR_CLASS, '', WS_POPUP, 0, 0, BAR_WIDTH, BAR_HEIGHT, 0, 0, inst, nil);
    if gBarWnd = 0 then
        Exit;

    // Larger glyph font for readability (button size stays 44x30).
    font := CreateFontW(-20, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, 5 {CLEARTYPE_QUALITY},
        DEFAULT_PITCH or FF_DONTCARE, 'Segoe UI Symbol');
    if font = 0 then
        font := GetStockObject(DEFAULT_GUI_FONT);
    gBtnMin := addButton(UnicodeString(#$2013), ID_MIN, 0, inst, font);            // en dash
    gBtnMax := addButton(UnicodeString(#$25A1), ID_MAX, BTN_WIDTH, inst, font);    // square
    gBtnClose := addButton(UnicodeString(#$2715), ID_CLOSE, BTN_WIDTH * 2, inst, font); // cross

    // Start faint and visible so the bar can always be found.
    setBarAlpha(ALPHA_IDLE);
    ShowWindow(gBarWnd, SW_SHOWNOACTIVATE);
    SetTimer(gBarWnd, TIMER_ID, TIMER_MS, nil);
end;

end.
