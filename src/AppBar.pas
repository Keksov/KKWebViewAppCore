unit AppBar;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

uses
    Windows, Math;

type
    { Invoked (on the GUI thread) when the dev-tools bar button is clicked. }
    TDevToolsProc = procedure();

{ Creates an RDP-style floating control bar pinned to the top-center of the main
  window with minimize / restore-fullscreen / close buttons. The bar stays
  visible but faint and fades to fully opaque while the cursor is over it, so it
  can always be located. Must be called on the GUI thread before the webview
  message loop starts; that loop pumps the bar's messages. aFullScreen tells the
  bar the window's initial state. When aDevTools is True an extra button is shown
  (dev mode) that calls aDevProc to open the browser dev-tools window. }
procedure createControlBar(aMainWindow: HWND; aFullScreen: Boolean;
    aDevTools: Boolean = False; aDevProc: TDevToolsProc = nil);

{ Shows/hides the floating bar at runtime. In Normal mode the OS caption replaces it, so
  it is deactivated (hidden and kept from re-showing) — WN-D2. }
procedure setBarActive(aActive: Boolean);

{ Re-activates kiosk mode from a running Normal window: shows the bar and re-asserts the
  saved kiosk fullscreen/restored geometry. Use when the bar was already created. }
procedure activateKioskBar();

implementation

uses
    AppWindowState, AppWindowMode;

const
    BAR_CLASS: PWideChar = 'AppCoreControlBar';
    BAR_WIDTH = 176;
    BAR_HEIGHT = 30;
    BTN_WIDTH = 44;
    TIMER_ID = 1;
    TIMER_MS = 30;
    ID_MOVE = 1000;
    ID_MIN = 1001;
    ID_MAX = 1002;
    ID_CLOSE = 1003;
    ID_DEV = 1004;
    ALPHA_IDLE = 60;    // faint but still findable when the cursor is away
    ALPHA_ACTIVE = 255; // fully opaque while hovered
    ALPHA_STEP = 22;    // per-tick fade speed

var
    gFull: Boolean = True;
    gAssertTicks: Integer = 0;         // re-assert startup geometry for this many ticks
    gUsePreferredMon: Boolean = False; // during restore, target gPreferredPt's monitor
    gPreferredPt: TPoint;              // a point on the last-used monitor
    gAlpha: Integer = ALPHA_IDLE;
    gBarActive: Boolean = True;        // False in Normal mode: bar hidden, geometry unmanaged
    gScreenW: Integer = 0;
    gScreenH: Integer = 0;
    gBarWnd: HWND = 0;
    gMainWnd: HWND = 0;
    gBtnMove: HWND = 0;
    gBtnMin: HWND = 0;
    gBtnMax: HWND = 0;
    gBtnClose: HWND = 0;
    gBtnDev: HWND = 0;                 // dev-tools button (dev mode only)
    gDevProc: TDevToolsProc = nil;     // opens the browser dev-tools window
    gMoveOrigProc: LONG_PTR = 0;       // subclassed Move button's original WndProc
    gFont: HGDIOBJ = 0;                // current (DPI-scaled) button font
    gDpi: Integer = 96;                // DPI the bar is currently scaled for
    gBarW: Integer = BAR_WIDTH;        // scaled bar width
    gBarH: Integer = BAR_HEIGHT;       // scaled bar height

// Multi-monitor API (missing from this FPC's Windows unit).
type
    TMonitorInfo = record
        cbSize: DWORD;
        rcMonitor: TRect;
        rcWork: TRect;
        dwFlags: DWORD;
    end;

const
    MONITOR_DEFAULTTONULL = 0;
    MONITOR_DEFAULTTONEAREST = 2;

function MonitorFromWindow(aWnd: HWND; aFlags: DWORD): HMONITOR;
    stdcall; external 'user32' name 'MonitorFromWindow';
function MonitorFromPoint(aPt: TPoint; aFlags: DWORD): HMONITOR;
    stdcall; external 'user32' name 'MonitorFromPoint';
function MonitorFromRect(aRect: Pointer; aFlags: DWORD): HMONITOR;
    stdcall; external 'user32' name 'MonitorFromRect';
function GetMonitorInfoW(aMonitor: HMONITOR; aInfo: Pointer): BOOL;
    stdcall; external 'user32' name 'GetMonitorInfoW';

{*******************************************************************************
* rectOnSomeMonitor — True when the rectangle intersects a connected monitor.
*******************************************************************************}
function rectOnSomeMonitor(aLeft, aTop, aRight, aBottom: Integer): Boolean;
var
    rc: TRect;
begin
    rc.Left := aLeft;
    rc.Top := aTop;
    rc.Right := aRight;
    rc.Bottom := aBottom;
    Result := MonitorFromRect(@rc, MONITOR_DEFAULTTONULL) <> 0;
end;

{*******************************************************************************
* windowMonitorRect — rcMonitor of the monitor aWnd is on (primary as fallback).
*******************************************************************************}
procedure windowMonitorRect(aWnd: HWND; out aL, aT, aR, aB: Integer);
var
    mon: HMONITOR;
    mi: TMonitorInfo;
begin
    mon := MonitorFromWindow(aWnd, MONITOR_DEFAULTTONEAREST);
    FillChar(mi, SizeOf(mi), 0);
    mi.cbSize := SizeOf(mi);
    if GetMonitorInfoW(mon, @mi) then
    begin
        aL := mi.rcMonitor.Left;
        aT := mi.rcMonitor.Top;
        aR := mi.rcMonitor.Right;
        aB := mi.rcMonitor.Bottom;
    end
    else
    begin
        aL := 0;
        aT := 0;
        aR := gScreenW;
        aB := gScreenH;
    end;
end;

{*******************************************************************************
* applyMainGeometry
* Switches the borderless main window between full screen and a restored size. The
* target monitor is the one the window sits on (so fullscreen fills the monitor whose
* bar the user clicked) — except during startup restore, when it is the last-used
* monitor (gPreferredPt), or the nearest connected one if that monitor is gone.
* Restored windows get a sizing border (WS_THICKFRAME) and reuse the last geometry.
*******************************************************************************}
procedure applyMainGeometry(aFull: Boolean);
var
    rw, rh: Integer;
    l, t, r, b: Integer;
    mL, mT, mW, mH: Integer;
    mon: HMONITOR;
    mi: TMonitorInfo;
begin
    if gUsePreferredMon then
        mon := MonitorFromPoint(gPreferredPt, MONITOR_DEFAULTTONEAREST)
    else
        mon := MonitorFromWindow(gMainWnd, MONITOR_DEFAULTTONEAREST);
    FillChar(mi, SizeOf(mi), 0);
    mi.cbSize := SizeOf(mi);
    if GetMonitorInfoW(mon, @mi) then
    begin
        mL := mi.rcMonitor.Left;
        mT := mi.rcMonitor.Top;
        mW := mi.rcMonitor.Right - mi.rcMonitor.Left;
        mH := mi.rcMonitor.Bottom - mi.rcMonitor.Top;
    end
    else
    begin
        mL := 0;
        mT := 0;
        mW := gScreenW;
        mH := gScreenH;
    end;

    if aFull then
    begin
        SetWindowLongW(gMainWnd, GWL_STYLE, Integer(WS_POPUP or WS_VISIBLE));
        SetWindowPos(gMainWnd, HWND_TOP, mL, mT, mW, mH, SWP_FRAMECHANGED);
    end
    else
    begin
        SetWindowLongW(gMainWnd, GWL_STYLE, Integer(WS_POPUP or WS_THICKFRAME or WS_VISIBLE));
        if loadKioskRect(l, t, r, b) and rectOnSomeMonitor(l, t, r, b) then
            SetWindowPos(gMainWnd, HWND_TOP, l, t, r - l, b - t, SWP_FRAMECHANGED)
        else
        begin
            rw := (mW * 7) div 10;
            rh := (mH * 7) div 10;
            SetWindowPos(gMainWnd, HWND_TOP, mL + (mW - rw) div 2, mT + (mH - rh) div 2,
                rw, rh, SWP_FRAMECHANGED);
        end;
    end;
    gFull := aFull;
end;

{*******************************************************************************
* rememberFullscreenMonitor — records which monitor the fullscreen window is on.
*******************************************************************************}
procedure rememberFullscreenMonitor();
var
    l, t, r, b: Integer;
begin
    windowMonitorRect(gMainWnd, l, t, r, b);
    saveKioskMon(l, t, r, b);
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
    Result := (h = gBarWnd) or (h = gBtnMove) or (h = gBtnMin)
        or (h = gBtnMax) or (h = gBtnClose);
end;

{*******************************************************************************
* mainWindowIsActive
* True when our application is the foreground app. The bar is WS_EX_NOACTIVATE so
* it never steals the foreground; interacting with the bar leaves the main window
* as the foreground window. When another application's window is brought to the
* front, the foreground window's root owner is no longer the main window, so the
* (top-most) bar must be hidden to avoid floating over other apps.
*******************************************************************************}
function mainWindowIsActive: Boolean;
var
    fg: HWND;
begin
    fg := GetForegroundWindow;
    Result := (fg <> 0) and
        ((fg = gMainWnd) or (fg = gBarWnd) or
         (GetAncestor(fg, GA_ROOTOWNER) = gMainWnd));
end;

{*******************************************************************************
* dpiForWindow — DPI of aWnd's monitor (GetDpiForWindow; 96 on older Windows).
*******************************************************************************}
function dpiForWindow(aWnd: HWND): Integer;
type
    TGetDpi = function(aWnd: HWND): UINT; stdcall;
var
    hUser: HMODULE;
    fn: TGetDpi;
begin
    Result := 96;
    hUser := GetModuleHandleW('user32');
    if hUser <> 0 then
    begin
        fn := TGetDpi(GetProcAddress(hUser, 'GetDpiForWindow'));
        if Assigned(fn) then
            Result := Integer(fn(aWnd));
    end;
    if Result <= 0 then
        Result := 96;
end;

{*******************************************************************************
* rescaleBar — resizes the bar, its buttons and font for aDpi so it looks right on
* whichever monitor the window currently sits on.
*******************************************************************************}
procedure rescaleBar(aDpi: Integer);
var
    btnW, cnt, idx: Integer;
    newFont: HGDIOBJ;
begin
    gDpi := aDpi;
    cnt := 4;
    if gBtnDev <> 0 then
        Inc(cnt);
    gBarW := MulDiv(BTN_WIDTH * cnt, aDpi, 96);
    gBarH := MulDiv(BAR_HEIGHT, aDpi, 96);
    btnW := MulDiv(BTN_WIDTH, aDpi, 96);

    newFont := CreateFontW(-MulDiv(20, aDpi, 96), 0, 0, 0, FW_NORMAL, 0, 0, 0,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, 5,
        DEFAULT_PITCH or FF_DONTCARE, 'Segoe UI Symbol');

    SetWindowPos(gBarWnd, 0, 0, 0, gBarW, gBarH,
        SWP_NOMOVE or SWP_NOZORDER or SWP_NOACTIVATE);
    // Order: Move, Min, Max, [Dev], Close.
    idx := 0;
    MoveWindow(gBtnMove, btnW * idx, 0, btnW, gBarH, True); Inc(idx);
    MoveWindow(gBtnMin, btnW * idx, 0, btnW, gBarH, True); Inc(idx);
    MoveWindow(gBtnMax, btnW * idx, 0, btnW, gBarH, True); Inc(idx);
    if gBtnDev <> 0 then
    begin
        MoveWindow(gBtnDev, btnW * idx, 0, btnW, gBarH, True); Inc(idx);
    end;
    MoveWindow(gBtnClose, btnW * idx, 0, btnW, gBarH, True);

    if newFont <> 0 then
    begin
        SendMessageW(gBtnMove, WM_SETFONT, WPARAM(newFont), 1);
        SendMessageW(gBtnMin, WM_SETFONT, WPARAM(newFont), 1);
        SendMessageW(gBtnMax, WM_SETFONT, WPARAM(newFont), 1);
        SendMessageW(gBtnClose, WM_SETFONT, WPARAM(newFont), 1);
        if gBtnDev <> 0 then
            SendMessageW(gBtnDev, WM_SETFONT, WPARAM(newFont), 1);
        if gFont <> 0 then
            DeleteObject(gFont);
        gFont := newFont;
    end;
end;

{*******************************************************************************
* updateBar
* Keeps the bar pinned to the top-center of the main window and fades it between
* a faint idle level and fully opaque depending on whether the cursor is over
* it. The bar is hidden while the window is minimized or while another
* application is in the foreground, so it never floats over other apps.
*******************************************************************************}
procedure updateBar;
var
    wr: TRect;
    dpi: Integer;
    target: Integer;
    barX, barTop: Integer;
begin
    if (not gBarActive) or IsIconic(gMainWnd) or (not mainWindowIsActive)
        or (not GetWindowRect(gMainWnd, wr)) then
    begin
        if IsWindowVisible(gBarWnd) then
            ShowWindow(gBarWnd, SW_HIDE);
        Exit;
    end;

    // Match the bar to the DPI of the monitor the window is currently on.
    dpi := dpiForWindow(gMainWnd);
    if dpi <> gDpi then
        rescaleBar(dpi);

    barX := wr.Left + ((wr.Right - wr.Left) - gBarW) div 2;
    barTop := wr.Top;
    SetWindowPos(gBarWnd, HWND_TOPMOST, barX, barTop, gBarW, gBarH,
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
                // Geometry set before the loop runs is overridden by the webview as
                // it initializes, so re-assert the saved state for the first ~1s (kiosk
                // only; skipped in Normal mode where the OS manages the frame).
                if gBarActive and (gAssertTicks > 0) then
                begin
                    applyMainGeometry(gFull);
                    Dec(gAssertTicks);
                    if gAssertTicks = 0 then
                        gUsePreferredMon := False;  // restore done; later toggles use current monitor
                end;
                updateBar;
                Result := 0;
            end;
        WM_COMMAND:
            begin
                case LOWORD(aWParam) of
                    ID_MIN: ShowWindow(gMainWnd, SW_MINIMIZE);
                    ID_MAX:
                        begin
                            applyMainGeometry(not gFull);
                            saveKioskFull(gFull);   // remember fullscreen/restored
                            if gFull then
                                rememberFullscreenMonitor;
                            SetForegroundWindow(gMainWnd);
                        end;
                    ID_CLOSE: PostMessageW(gMainWnd, WM_CLOSE, 0, 0);
                    ID_DEV:
                        if Assigned(gDevProc) then
                            gDevProc();
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
* kioskDragEnd
* Registered with AppWindowState's tracker and invoked when a drag/resize of the main
* window settles while in kiosk mode: a fullscreen window dragged to another monitor
* refills that monitor; a restored window remembers its new geometry (WN-D5).
*******************************************************************************}
procedure kioskDragEnd();
begin
    if gFull then
    begin
        applyMainGeometry(True);      // dragged to another monitor -> fill it
        rememberFullscreenMonitor;    // and remember that monitor
    end
    else
        saveKioskRect(gMainWnd);      // remember the moved/resized restored geometry
end;

{*******************************************************************************
* moveBtnProc
* Subclass of the Move button: pressing it starts a title-bar-style drag of the
* main window (via WM_NCLBUTTONDOWN/HTCAPTION), so the window can be dragged around
* the screen — and across monitors — even in fullscreen mode.
*******************************************************************************}
function moveBtnProc(aWnd: HWND; aMsg: UINT; aWParam: WPARAM; aLParam: LPARAM): LRESULT; stdcall;
begin
    if aMsg = WM_LBUTTONDOWN then
    begin
        ReleaseCapture;
        SendMessageW(gMainWnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
        Exit(0);
    end;
    Result := CallWindowProcW(TFNWndProc(Pointer(gMoveOrigProc)), aWnd, aMsg, aWParam, aLParam);
end;

{*******************************************************************************
* createControlBar
*******************************************************************************}
procedure createControlBar(aMainWindow: HWND; aFullScreen: Boolean;
    aDevTools: Boolean = False; aDevProc: TDevToolsProc = nil);
var
    wc: WNDCLASSEXW;
    inst: HINST;
    font: HGDIOBJ;
    savedFull: Boolean;
    ml, mt, mr, mb: Integer;
    nx, cnt: Integer;
begin
    gMainWnd := aMainWindow;
    gFull := aFullScreen;
    gDevProc := aDevProc;
    cnt := 4;
    if aDevTools then
        Inc(cnt);
    // Set the bar width from the button count now, so it is correct even on a
    // 96-DPI monitor where rescaleBar (which also sizes from the count) never
    // runs — otherwise updateBar would shrink the bar and clip the last button.
    gBarW := BTN_WIDTH * cnt;
    gBarH := BAR_HEIGHT;
    // Install the single mode-aware window tracker (AppWindowState) in kiosk mode; the
    // AppBar handles the kiosk drag/resize-end via a callback, so there is exactly one
    // main-window subclass regardless of the starting mode (WN-D5).
    installMainTracker(gMainWnd);
    setTrackMode(wmKiosk);
    setKioskDragEndHandler(@kioskDragEnd);
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
        BAR_CLASS, '', WS_POPUP, 0, 0, BTN_WIDTH * cnt, BAR_HEIGHT, 0, 0, inst, nil);
    if gBarWnd = 0 then
        Exit;

    // Larger glyph font for readability (button size stays 44x30).
    font := CreateFontW(-20, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, 5 {CLEARTYPE_QUALITY},
        DEFAULT_PITCH or FF_DONTCARE, 'Segoe UI Symbol');
    if font = 0 then
        font := GetStockObject(DEFAULT_GUI_FONT);
    gFont := font;   // tracked so a DPI rescale can free it
    // Order: Move, Min, Max, [Dev], Close.
    gBtnMove := addButton(UnicodeString(#$2725), ID_MOVE, 0, inst, font);              // move handle
    gBtnMin := addButton(UnicodeString(#$2013), ID_MIN, BTN_WIDTH, inst, font);        // en dash
    gBtnMax := addButton(UnicodeString(#$25A1), ID_MAX, BTN_WIDTH * 2, inst, font);    // square
    nx := BTN_WIDTH * 3;
    if aDevTools then
    begin
        gBtnDev := addButton(UnicodeString('</>'), ID_DEV, nx, inst, font);            // dev tools
        Inc(nx, BTN_WIDTH);
    end;
    gBtnClose := addButton(UnicodeString(#$2715), ID_CLOSE, nx, inst, font);           // cross
    // Subclass Move so a mouse-press starts a title-bar-style window drag.
    if gBtnMove <> 0 then
        gMoveOrigProc := SetWindowLongPtrW(gBtnMove, GWL_WNDPROC, LONG_PTR(PtrInt(@moveBtnProc)));

    // Start faint; leave it HIDDEN — the first updateBar (timer) shows it already
    // positioned over the main window, so it never flashes at (0,0) before the
    // main window is placed on its monitor.
    setBarAlpha(ALPHA_IDLE);
    SetTimer(gBarWnd, TIMER_ID, TIMER_MS, nil);

    // Apply the saved (or default) fullscreen/restored state once the message loop
    // is running, re-asserting for ~1s (34 * 30ms) to win over the webview's own
    // startup resize of the host window.
    if loadKioskFull(savedFull) then
        gFull := savedFull;

    // Restore onto the last-used monitor. gPreferredPt is a point on it; if that
    // monitor is now disconnected, MonitorFromPoint/NEAREST resolves to the nearest
    // connected one (i.e. the first available), keeping the saved mode.
    if gFull and loadKioskMon(ml, mt, mr, mb) then
    begin
        gPreferredPt.X := (ml + mr) div 2;
        gPreferredPt.Y := (mt + mb) div 2;
    end
    else if (not gFull) and loadKioskRect(ml, mt, mr, mb) then
    begin
        gPreferredPt.X := (ml + mr) div 2;
        gPreferredPt.Y := (mt + mb) div 2;
    end
    else
    begin
        gPreferredPt.X := gScreenW div 2;
        gPreferredPt.Y := gScreenH div 2;
    end;
    gUsePreferredMon := True;
    gAssertTicks := 34;
    // Apply the resolved geometry synchronously so a caller can position the (still
    // hidden) window on the correct monitor BEFORE showing it — no flash on the
    // primary monitor. The timer above re-asserts it for ~1s as a safety net.
    applyMainGeometry(gFull);
end;

{*******************************************************************************
* setBarActive — enable/disable the floating bar. When disabled (Normal mode) the bar
* is hidden and updateBar keeps it hidden and stops managing the window geometry.
*******************************************************************************}
procedure setBarActive(aActive: Boolean);
begin
    gBarActive := aActive;
    if (not aActive) and (gBarWnd <> 0) and IsWindowVisible(gBarWnd) then
        ShowWindow(gBarWnd, SW_HIDE);
end;

{*******************************************************************************
* activateKioskBar — re-enter kiosk from Normal: mark the tracker kiosk, re-assert the
* saved fullscreen/restored geometry, and let updateBar show the bar again.
*******************************************************************************}
procedure activateKioskBar();
begin
    gBarActive := True;
    setTrackMode(wmKiosk);
    applyMainGeometry(gFull);
end;

end.
