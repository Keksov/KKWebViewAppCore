unit AppSplash;

{$IFDEF FPC}
{$mode delphiunicode}
{$codepage utf8}
{$ENDIF}

{*******************************************************************************
* AppSplash
* A native, frameless banner splash rendered with Pixie (Direct2D/DirectWrite).
* It runs on its own thread with its own message pump and animation timer, so it
* appears within one frame and keeps animating while the main thread is blocked
* in webview_create / service startup. Status is pushed in from the startup
* worker thread; drawing happens only on the splash thread.
*
* Public API (all thread-safe):
*   startSplash(aTitle)     - create + show the banner (returns once it is up).
*   splashSetTitle(aText)   - set the heading.
*   splashSetPhase(aText)   - mark the current step done, add aText as active.
*   stopSplash()            - close the window and join the thread.
*******************************************************************************}

interface

procedure startSplash(const aTitle: string);
procedure splashSetTitle(const aText: string);
procedure splashSetPhase(const aText: string);
procedure stopSplash();

implementation

uses
    Windows, ActiveX, SysUtils,
    Pixie.WebColor, Pixie.Canvas, Pixie.Canvas.D2D, Pixie.DrawingCanvas;

const
    SPLASH_CLASS: PWideChar = 'AppCoreSplashWnd';
    LOGICAL_W  = 470;   // logical (96-dpi) banner width
    LOGICAL_H  = 214;   // logical banner height
    MAX_PHASES = 8;     // checklist capacity
    TIMER_ID   = 1;
    TIMER_MS   = 33;    // ~30 fps spinner

    // Multi-monitor / DPI WinAPI bits absent from this FPC's Windows unit.
    MONITOR_DEFAULTTONEAREST = 2;

type
    TSplashPhase = record
        text: string;
        done: Boolean;
    end;

    TMonInfo = record
        cbSize:    DWORD;
        rcMonitor: TRect;
        rcWork:    TRect;
        dwFlags:   DWORD;
    end;

    TGetDpiForWindow = function(aWnd: HWND): UINT; stdcall;

function MonitorFromPoint(aPt: TPoint; aFlags: DWORD): HMONITOR; stdcall;
    external 'user32' name 'MonitorFromPoint';
function GetMonitorInfoW(aMon: HMONITOR; var aInfo: TMonInfo): BOOL; stdcall;
    external 'user32' name 'GetMonitorInfoW';

var
    gThread:   TThreadID = 0;
    gWnd:      HWND = 0;
    gReady:    THandle = 0;    // signalled once the window is shown
    gDone:     THandle = 0;    // signalled after the thread has fully cleaned up
    gCanvas:   TPixieD2DCanvas = nil;
    gDraw:     TPixieDrawingCanvas = nil;
    gLock:     TRTLCriticalSection;
    gLockInit: Boolean = False;
    gPhases:   array[0..MAX_PHASES - 1] of TSplashPhase;
    gPhaseCnt: Integer = 0;
    gTitle:    string = '';
    gTick:     Integer = 0;
    gScale:    Single = 1.0;
    gPhysW:    Integer = LOGICAL_W;
    gPhysH:    Integer = LOGICAL_H;

{*******************************************************************************
* col
*******************************************************************************}
function col(aR, aG, aB: Byte; aA: Byte = 255): TPixieWebColor;
begin
    Result.Red := aR;
    Result.Green := aG;
    Result.Blue := aB;
    Result.Alpha := aA;
    Result.IsCurrentColor := False;
end;

{*******************************************************************************
* dpiScaleForWindow
* Per-Monitor DPI scale (PMv2) for the splash's monitor. GetDpiForWindow is
* Win10 1607+; on older systems fall back to 1.0.
*******************************************************************************}
function dpiScaleForWindow(aWnd: HWND): Single;
var
    getDpi: TGetDpiForWindow;
    hUser:  HMODULE;
    dpi:    UINT;
begin
    Result := 1.0;
    hUser := GetModuleHandleW('user32');
    if hUser = 0 then
        Exit;
    getDpi := TGetDpiForWindow(GetProcAddress(hUser, 'GetDpiForWindow'));
    if not Assigned(getDpi) then
        Exit;
    dpi := getDpi(aWnd);
    if dpi >= 48 then
        Result := dpi / 96.0;
end;

{*******************************************************************************
* targetMonitorRect
* Full bounds of the monitor under the cursor (where the user launched), so the
* banner appears where they are looking. Falls back to the primary monitor.
*******************************************************************************}
procedure targetMonitorRect(out aRect: TRect);
var
    pt:  TPoint;
    mon: HMONITOR;
    mi:  TMonInfo;
begin
    aRect.Left := 0;
    aRect.Top := 0;
    aRect.Right := GetSystemMetrics(SM_CXSCREEN);
    aRect.Bottom := GetSystemMetrics(SM_CYSCREEN);
    if not GetCursorPos(pt) then
        Exit;
    mon := MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    if mon = 0 then
        Exit;
    FillChar(mi, SizeOf(mi), 0);
    mi.cbSize := SizeOf(mi);
    if GetMonitorInfoW(mon, mi) then
        aRect := mi.rcMonitor;
end;

{*******************************************************************************
* drawMarker
* Draws the per-step glyph at (aCx,aCy) in logical units: a green check when the
* step is done, a filled cyan dot while it is active. (Drawn, not text, so the
* markers do not depend on the system codepage.)
*******************************************************************************}
procedure drawMarker(aCx, aCy: Single; aDone: Boolean);
begin
    if aDone then
    begin
        gDraw.Brush.Style := bsClear;
        gDraw.Pen.Style := psSolid;
        gDraw.Pen.Width := 2;
        gDraw.Pen.Color := col(74, 222, 128);
        gDraw.Line(aCx - 4, aCy, aCx - 1, aCy + 3);
        gDraw.Line(aCx - 1, aCy + 3, aCx + 5, aCy - 4);
    end
    else
    begin
        gDraw.Pen.Style := psClear;
        gDraw.Brush.Style := bsSolid;
        gDraw.Brush.Color := col(34, 211, 238);
        gDraw.Circle(aCx, aCy, 4);
    end;
end;

{*******************************************************************************
* paintSplash
* Renders the banner: background, spinner, title, and the loading checklist.
* Coordinates are logical; the D2D scale transform (SetScale) maps them to the
* monitor's physical pixels.
*******************************************************************************}
procedure paintSplash(aWnd: HWND);
var
    ps:      TPaintStruct;
    dc:      HDC;
    i:       Integer;
    cnt:     Integer;
    y:       Single;
    ang:     Single;
    spX, spY, spD: Single;
    title:   string;
    phases:  array[0..MAX_PHASES - 1] of TSplashPhase;
begin
    dc := Windows.BeginPaint(aWnd, ps);
    try
        if (gCanvas = nil) or (gDraw = nil) then
            Exit;

        // Snapshot shared state briefly, then draw without holding the lock.
        if gLockInit then
            EnterCriticalSection(gLock);
        title := gTitle;
        cnt := gPhaseCnt;
        for i := 0 to cnt - 1 do
            phases[i] := gPhases[i];
        if gLockInit then
            LeaveCriticalSection(gLock);

        gCanvas.SetViewSize(gPhysW, gPhysH);
        gCanvas.SetScale(gScale);
        gCanvas.BeginPaint(PtrUInt(dc));
        gDraw.Bind(gCanvas);

        // Background + hairline border.
        gDraw.Pen.Style := psClear;
        gDraw.Brush.Style := bsSolid;
        gDraw.Brush.Color := col(30, 30, 30);
        gDraw.FillRect(0, 0, LOGICAL_W, LOGICAL_H);
        gDraw.Brush.Style := bsClear;
        gDraw.Pen.Style := psSolid;
        gDraw.Pen.Width := 1;
        gDraw.Pen.Color := col(64, 64, 64);
        gDraw.Rectangle(0, 0, LOGICAL_W, LOGICAL_H);

        // Spinner: static grey ring + a rotating cyan arc.
        spD := 34;
        spX := 26;
        spY := 24;
        gDraw.Pen.Width := 4;
        gDraw.Pen.Color := col(51, 51, 51);
        gDraw.Arc(spX, spY, spD, spD, 0, 360);
        gDraw.Pen.Color := col(34, 211, 238);
        ang := (gTick * 11) mod 360;
        gDraw.Arc(spX, spY, spD, spD, ang, 100);

        // Title.
        gDraw.Font.Family := 'Segoe UI';
        gDraw.Font.Style := [fsBold];
        gDraw.Font.Size := 19;
        gDraw.Font.Color := col(230, 230, 230);
        gDraw.TextOut(spX + spD + 18, 26, title);

        // Checklist.
        gDraw.Font.Style := [];
        gDraw.Font.Size := 13;
        y := 84;
        for i := 0 to cnt - 1 do
        begin
            drawMarker(30, y + 8, phases[i].done);
            if phases[i].done then
                gDraw.Font.Color := col(150, 150, 150)
            else
                gDraw.Font.Color := col(34, 211, 238);
            gDraw.TextOut(48, y, phases[i].text);
            y := y + 26;
        end;

        gDraw.Unbind;
        gCanvas.EndPaint;
    finally
        Windows.EndPaint(aWnd, ps);
    end;
end;

{*******************************************************************************
* splashWndProc
*******************************************************************************}
function splashWndProc(aWnd: HWND; aMsg: UINT; aWp: WPARAM; aLp: LPARAM): LRESULT; stdcall;
begin
    case aMsg of
        WM_PAINT:
            begin
                paintSplash(aWnd);
                Result := 0;
            end;
        WM_TIMER:
            begin
                Inc(gTick);
                InvalidateRect(aWnd, nil, False);
                Result := 0;
            end;
        WM_ERASEBKGND:
            Result := 1;   // painted fully in WM_PAINT; skip flicker
        WM_DESTROY:
            begin
                PostQuitMessage(0);
                Result := 0;
            end;
    else
        Result := DefWindowProcW(aWnd, aMsg, aWp, aLp);
    end;
end;

{*******************************************************************************
* splashThreadProc
* Owns the Pixie canvas, the window, and the message loop. Created and destroyed
* on this thread only (D2D objects are thread-affine).
*******************************************************************************}
function splashThreadProc(aParam: Pointer): PtrInt;
var
    wc:   WNDCLASSEXW;
    inst: HINST;
    msg:  TMsg;
    rc:   TRect;
    x, y: Integer;
begin
    CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
    inst := GetModuleHandleW(nil);

    FillChar(wc, SizeOf(wc), 0);
    wc.cbSize := SizeOf(wc);
    wc.lpfnWndProc := @splashWndProc;
    wc.hInstance := inst;
    wc.hCursor := LoadCursorW(0, PWideChar(IDC_ARROW));
    wc.hbrBackground := CreateSolidBrush(RGB(30, 30, 30)); // dark even if D2D fails
    wc.lpszClassName := SPLASH_CLASS;
    RegisterClassExW(@wc);

    gCanvas := TPixieD2DCanvas.Create;
    gDraw := TPixieDrawingCanvas.Create;

    targetMonitorRect(rc);
    x := rc.Left + ((rc.Right - rc.Left) - LOGICAL_W) div 2;
    y := rc.Top + ((rc.Bottom - rc.Top) - LOGICAL_H) div 2;

    // Tool window => no taskbar button; topmost => stays above the (hidden then
    // shown) WebView2 window; no-activate => does not steal focus.
    gWnd := CreateWindowExW(WS_EX_TOPMOST or WS_EX_TOOLWINDOW or WS_EX_NOACTIVATE,
        SPLASH_CLASS, '', WS_POPUP, x, y, LOGICAL_W, LOGICAL_H, 0, 0, inst, nil);

    if gWnd <> 0 then
    begin
        gScale := dpiScaleForWindow(gWnd);
        if gScale <= 0 then
            gScale := 1.0;
        gPhysW := Round(LOGICAL_W * gScale);
        gPhysH := Round(LOGICAL_H * gScale);
        x := rc.Left + ((rc.Right - rc.Left) - gPhysW) div 2;
        y := rc.Top + ((rc.Bottom - rc.Top) - gPhysH) div 2;
        SetWindowPos(gWnd, HWND_TOPMOST, x, y, gPhysW, gPhysH, SWP_NOACTIVATE);

        SetTimer(gWnd, TIMER_ID, TIMER_MS, nil);
        ShowWindow(gWnd, SW_SHOWNOACTIVATE);
        UpdateWindow(gWnd);
    end;

    if gReady <> 0 then
        SetEvent(gReady);

    if gWnd <> 0 then
        while GetMessageW(msg, 0, 0, 0) do
        begin
            TranslateMessage(msg);
            DispatchMessageW(msg);
        end;

    if gWnd <> 0 then
        KillTimer(gWnd, TIMER_ID);
    FreeAndNil(gDraw);
    FreeAndNil(gCanvas);
    UnregisterClassW(SPLASH_CLASS, inst);
    CoUninitialize;
    // Signal only after COM is fully torn down, so stopSplash never returns
    // while the D2D objects are still being released on this thread.
    if gDone <> 0 then
        SetEvent(gDone);
    Result := 0;
end;

{*******************************************************************************
* startSplash
*******************************************************************************}
procedure startSplash(const aTitle: string);
begin
    if gThread <> 0 then
        Exit;
    InitializeCriticalSection(gLock);
    gLockInit := True;
    gTitle := aTitle;
    gPhaseCnt := 0;
    gTick := 0;
    gReady := CreateEventW(nil, True, False, nil);
    gDone := CreateEventW(nil, True, False, nil);
    // BeginThread (not raw CreateThread) so the FPC RTL sets up thread-local
    // state / exception frames for the Pixie + string work on the splash thread.
    IsMultiThread := True;
    gThread := BeginThread(@splashThreadProc, nil);
    if (gThread <> 0) and (gReady <> 0) then
        WaitForSingleObject(gReady, 3000); // bounded: proceed even if slow
end;

{*******************************************************************************
* splashSetTitle
*******************************************************************************}
procedure splashSetTitle(const aText: string);
begin
    if not gLockInit then
        Exit;
    EnterCriticalSection(gLock);
    try
        gTitle := aText;
    finally
        LeaveCriticalSection(gLock);
    end;
end;

{*******************************************************************************
* splashSetPhase
* Marks the current active step done and appends aText as the new active step.
*******************************************************************************}
procedure splashSetPhase(const aText: string);
begin
    if not gLockInit then
        Exit;
    EnterCriticalSection(gLock);
    try
        if gPhaseCnt > 0 then
            gPhases[gPhaseCnt - 1].done := True;
        if gPhaseCnt < MAX_PHASES then
        begin
            gPhases[gPhaseCnt].text := aText;
            gPhases[gPhaseCnt].done := False;
            Inc(gPhaseCnt);
        end;
    finally
        LeaveCriticalSection(gLock);
    end;
end;

{*******************************************************************************
* stopSplash
*******************************************************************************}
procedure stopSplash();
begin
    if gThread = 0 then
        Exit;
    if gWnd <> 0 then
        PostMessageW(gWnd, WM_CLOSE, 0, 0);
    // Wait for the thread to finish its own COM teardown (deterministic,
    // independent of TThreadID handle semantics), then release the handle.
    if gDone <> 0 then
        WaitForSingleObject(gDone, 5000)
    else
        WaitForSingleObject(THandle(gThread), 5000);
    CloseHandle(THandle(gThread));
    gThread := 0;
    gWnd := 0;
    if gReady <> 0 then
    begin
        CloseHandle(gReady);
        gReady := 0;
    end;
    if gDone <> 0 then
    begin
        CloseHandle(gDone);
        gDone := 0;
    end;
    if gLockInit then
    begin
        DeleteCriticalSection(gLock);
        gLockInit := False;
    end;
end;

end.
