unit AppBar;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

uses
    Windows;

{ Creates an RDP-style floating control bar pinned to the top-center of the
  screen with minimize / restore-fullscreen / close buttons. The bar is a
  separate top-most tool window that auto-hides and slides into view when the
  cursor reaches the top edge. Its buttons act on aMainWindow. Must be called on
  the GUI thread before the webview message loop starts; that loop pumps the
  bar's messages. aFullScreen tells the bar the window's initial state. }
procedure createControlBar(aMainWindow: HWND; aFullScreen: Boolean);

implementation

const
    BAR_CLASS: PWideChar = 'AppCoreControlBar';
    BAR_WIDTH = 132;
    BAR_HEIGHT = 30;
    BTN_WIDTH = 44;
    TIMER_ID = 1;
    TIMER_MS = 120;
    ID_MIN = 1001;
    ID_MAX = 1002;
    ID_CLOSE = 1003;

var
    gShown: Boolean = False;
    gFull: Boolean = True;
    gScreenW: Integer = 0;
    gScreenH: Integer = 0;
    gBarWnd: HWND = 0;
    gMainWnd: HWND = 0;

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
* showBar
* Positions the bar at the top-center of the main window (tracking it even when
* not full screen) and makes it visible.
*******************************************************************************}
procedure showBar(aX, aTop: Integer);
begin
    SetWindowPos(gBarWnd, HWND_TOPMOST, aX, aTop, BAR_WIDTH, BAR_HEIGHT,
        SWP_NOACTIVATE or SWP_SHOWWINDOW);
    gShown := True;
end;

{*******************************************************************************
* hideBar
*******************************************************************************}
procedure hideBar;
begin
    if gShown then
    begin
        ShowWindow(gBarWnd, SW_HIDE);
        gShown := False;
    end;
end;

{*******************************************************************************
* updateAutoHide
* Shows the bar while the cursor is near the top-center edge, hides it once the
* cursor leaves the bar area or the main window is minimized.
*******************************************************************************}
procedure updateAutoHide;
var
    pt: TPoint;
    wr: TRect;
    barX, barTop: Integer;
    overShow, overKeep: Boolean;
begin
    if IsIconic(gMainWnd) or (not GetWindowRect(gMainWnd, wr)) then
    begin
        hideBar;
        Exit;
    end;
    if not GetCursorPos(pt) then
        Exit;
    barX := wr.Left + ((wr.Right - wr.Left) - BAR_WIDTH) div 2;
    barTop := wr.Top;
    if gShown then
    begin
        overKeep := (pt.x >= barX - 10) and (pt.x <= barX + BAR_WIDTH + 10);
        if (not overKeep) or (pt.y < barTop - 2) or (pt.y > barTop + BAR_HEIGHT + 6) then
            hideBar
        else
            showBar(barX, barTop); // keep it tracked over the window top
    end
    else
    begin
        overShow := (pt.x >= barX - 30) and (pt.x <= barX + BAR_WIDTH + 30);
        if overShow and (pt.y >= barTop - 2) and (pt.y <= barTop + 4) then
            showBar(barX, barTop);
    end;
end;

{*******************************************************************************
* barWndProc
*******************************************************************************}
function barWndProc(aWnd: HWND; aMsg: UINT; aWParam: WPARAM; aLParam: LPARAM): LRESULT; stdcall;
begin
    case aMsg of
        WM_TIMER:
            begin
                updateAutoHide;
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

    gBarWnd := CreateWindowExW(WS_EX_TOPMOST or WS_EX_TOOLWINDOW or WS_EX_NOACTIVATE,
        BAR_CLASS, '', WS_POPUP, 0, 0, BAR_WIDTH, BAR_HEIGHT, 0, 0, inst, nil);
    if gBarWnd = 0 then
        Exit;

    font := GetStockObject(DEFAULT_GUI_FONT);
    addButton(UnicodeString(#$2013), ID_MIN, 0, inst, font);            // en dash
    addButton(UnicodeString(#$25A1), ID_MAX, BTN_WIDTH, inst, font);    // square
    addButton(UnicodeString(#$2715), ID_CLOSE, BTN_WIDTH * 2, inst, font); // cross

    SetTimer(gBarWnd, TIMER_ID, TIMER_MS, nil);
end;

end.
