unit AppWindowState;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

uses
    Windows, AppWindowMode;

type
    { Called on the main window's drag/resize end while in kiosk mode, so the AppBar can
      refill the monitor (fullscreen) or remember the restored rect (WN-D5). }
    TKioskDragEndProc = procedure();

{ Remembers the window state across runs, stored next to the exe when that folder is
  writable, otherwise in the user's temp directory under a name derived from the full
  exe path (so different installs keep separate state).

  Pieces:
    dispmode=<kiosk|normal>              - the display mode, restored across runs (WN1.1)
    win=<left top right bottom showCmd>  - normal windowed geometry + maximized state
    kioskfull=<0|1>                      - fullscreen(1) / restored(0) for kiosk mode

  Windowed/Normal: attachWindowState restores the geometry and tracks changes (subclassing
  the window so state is captured even on X-button close / hard kill); flushWindowState
  writes on shutdown. Kiosk: saveKioskFull / loadKioskFull persist the AppBar toggle.
  saveDispMode / loadDispMode persist which mode the app is in (Kiosk vs Normal). }
{ Restores the saved windowed geometry WITHOUT showing the window (it is revealed
  later) and starts tracking changes. restoredShowCmd returns how it should be
  shown once ready: SW_SHOWMAXIMIZED if it was saved maximized, else SW_SHOWNORMAL. }
procedure attachWindowState(aWnd: HWND);
function restoredShowCmd(): Integer;
procedure flushWindowState();
procedure installMainTracker(aWnd: HWND);
procedure setTrackMode(aMode: TWindowMode);
procedure setKioskDragEndHandler(aProc: TKioskDragEndProc);
procedure applyNormalPlacement(aWnd: HWND);
procedure saveDispMode(const aMode: string);
function loadDispMode(out aMode: string): Boolean;
procedure saveKioskFull(aFull: Boolean);
function loadKioskFull(out aFull: Boolean): Boolean;
procedure saveKioskRect(aWnd: HWND);
function loadKioskRect(out aLeft, aTop, aRight, aBottom: Integer): Boolean;
procedure saveKioskMon(aLeft, aTop, aRight, aBottom: Integer);
function loadKioskMon(out aLeft, aTop, aRight, aBottom: Integer): Boolean;

implementation

uses
    SysUtils;

const
    STATE_NAME = 'AppCore.window';

var
    gOrigProc: LONG_PTR = 0;              // subclassed window's original WndProc
    gLastGeom: string = '';               // latest "left top right bottom showCmd"
    gShowCmd: Integer = SW_SHOWNORMAL;     // how to show once ready (normal/maximized)
    gTrackMode: TWindowMode = wmKiosk;     // which mode the tracker records geometry for
    gKioskDragEnd: TKioskDragEndProc = nil; // AppBar's kiosk drag/resize-end handler

{*******************************************************************************
* exePathKey — FNV-1a hash (hex) of the lowercased full exe path; the per-install
* key for the temp-dir fallback file.
*******************************************************************************}
function exePathKey(): string;
var
    p: UnicodeString;
    h: LongWord;
    i: Integer;
begin
    p := LowerCase(UnicodeString(ParamStr(0)));
    h := LongWord(2166136261);
    for i := 1 to Length(p) do
    begin
        h := h xor LongWord(Ord(p[i]));
        h := h * LongWord(16777619);
    end;
    Result := IntToHex(h, 8);
end;

function nearExePath(): string;
begin
    Result := ExtractFilePath(ParamStr(0)) + STATE_NAME;
end;

function tempPath(): string;
begin
    Result := IncludeTrailingPathDelimiter(GetTempDir) + 'AppCore-' + exePathKey + '.window';
end;

{*******************************************************************************
* writeStateFile — writes aData next to the exe, else to the temp fallback.
*******************************************************************************}
procedure writeStateFile(const aData: string);

    function tryWrite(const aPath: string): Boolean;
    var
        f: TextFile;
    begin
        Result := False;
        try
            AssignFile(f, aPath);
            Rewrite(f);
            try
                Write(f, aData);
            finally
                CloseFile(f);
            end;
            Result := True;
        except
            Result := False;
        end;
    end;

begin
    if not tryWrite(nearExePath) then
        tryWrite(tempPath);
end;

{*******************************************************************************
* readStateFile — reads the whole state file (near-exe preferred, then temp).
*******************************************************************************}
function readStateFile(out aData: string): Boolean;

    function tryRead(const aPath: string): Boolean;
    var
        f: TextFile;
        line: string;
    begin
        Result := False;
        if not FileExists(aPath) then
            Exit;
        try
            AssignFile(f, aPath);
            Reset(f);
            try
                while not Eof(f) do
                begin
                    ReadLn(f, line);
                    aData := aData + line + #10;
                end;
            finally
                CloseFile(f);
            end;
            Result := True;
        except
            Result := False;
        end;
    end;

begin
    aData := '';
    Result := tryRead(nearExePath) or tryRead(tempPath);
end;

{*******************************************************************************
* readValue — returns the value of "aKey=..." from the state file.
*******************************************************************************}
function readValue(const aKey: string; out aValue: string): Boolean;
var
    data: string;
    rest: string;
    line: string;
    nl: Integer;
    prefix: string;
begin
    Result := False;
    aValue := '';
    if not readStateFile(data) then
        Exit;
    prefix := aKey + '=';
    rest := data;
    while rest <> '' do
    begin
        nl := Pos(#10, rest);
        if nl > 0 then
        begin
            line := Copy(rest, 1, nl - 1);
            rest := Copy(rest, nl + 1, Length(rest));
        end
        else
        begin
            line := rest;
            rest := '';
        end;
        line := Trim(line);
        if Copy(line, 1, Length(prefix)) = prefix then
        begin
            aValue := Copy(line, Length(prefix) + 1, Length(line));
            Exit(True);
        end;
    end;
end;

{*******************************************************************************
* setStateValue — updates "aKey=aValue" in the state file, preserving other keys.
*******************************************************************************}
procedure setStateValue(const aKey, aValue: string);
var
    data: string;
    rest: string;
    line: string;
    prefix: string;
    outData: string;
    nl: Integer;
begin
    prefix := aKey + '=';
    outData := '';
    if readStateFile(data) then
    begin
        rest := data;
        while rest <> '' do
        begin
            nl := Pos(#10, rest);
            if nl > 0 then
            begin
                line := Trim(Copy(rest, 1, nl - 1));
                rest := Copy(rest, nl + 1, Length(rest));
            end
            else
            begin
                line := Trim(rest);
                rest := '';
            end;
            if (line <> '') and (Copy(line, 1, Length(prefix)) <> prefix) then
                outData := outData + line + #13#10;
        end;
    end;
    outData := outData + prefix + aValue + #13#10;
    writeStateFile(outData);
end;

{*******************************************************************************
* placementString — "left top right bottom showCmd" for aWnd, or '' on failure.
*******************************************************************************}
function placementString(aWnd: HWND): string;
var
    wp: TWindowPlacement;
begin
    Result := '';
    FillChar(wp, SizeOf(wp), 0);
    wp.length := SizeOf(wp);
    if GetWindowPlacement(aWnd, @wp) then
        Result := Format('%d %d %d %d %d',
            [wp.rcNormalPosition.Left, wp.rcNormalPosition.Top,
             wp.rcNormalPosition.Right, wp.rcNormalPosition.Bottom, Integer(wp.showCmd)]);
end;

{*******************************************************************************
* nextInt — pops the next space-separated integer token from aStr.
*******************************************************************************}
function nextInt(var aStr: string; out aVal: Integer): Boolean;
var
    sp: Integer;
    tok: string;
begin
    aStr := TrimLeft(aStr);
    sp := Pos(' ', aStr);
    if sp > 0 then
    begin
        tok := Copy(aStr, 1, sp - 1);
        aStr := Copy(aStr, sp + 1, Length(aStr));
    end
    else
    begin
        tok := aStr;
        aStr := '';
    end;
    Result := TryStrToInt(tok, aVal);
end;

{*******************************************************************************
* onScreen — True when aRect overlaps the virtual screen (all monitors).
*******************************************************************************}
function onScreen(const aRect: TRect): Boolean;
var
    screen: TRect;
    dummy: TRect;
begin
    screen.Left := GetSystemMetrics(SM_XVIRTUALSCREEN);
    screen.Top := GetSystemMetrics(SM_YVIRTUALSCREEN);
    screen.Right := screen.Left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
    screen.Bottom := screen.Top + GetSystemMetrics(SM_CYVIRTUALSCREEN);
    Result := IntersectRect(dummy, aRect, screen);
end;

{*******************************************************************************
* restoreWindowState — applies the saved windowed geometry to aWnd if valid.
*******************************************************************************}
procedure restoreWindowState(aWnd: HWND);
var
    rest: string;
    left, top, right, bottom, showCmd: Integer;
    wp: TWindowPlacement;
    r: TRect;
begin
    if not readValue('win', rest) then
        Exit;
    if not (nextInt(rest, left) and nextInt(rest, top) and nextInt(rest, right)
            and nextInt(rest, bottom) and nextInt(rest, showCmd)) then
        Exit;
    r.Left := left;
    r.Top := top;
    r.Right := right;
    r.Bottom := bottom;
    if (r.Right - r.Left <= 0) or (r.Bottom - r.Top <= 0) or (not onScreen(r)) then
        Exit;
    FillChar(wp, SizeOf(wp), 0);
    wp.length := SizeOf(wp);
    wp.rcNormalPosition := r;
    // Position the window but keep it HIDDEN — it is revealed later, in one step,
    // at the correct place/state (no empty-window flash during startup). The
    // intended show state is remembered for restoredShowCmd.
    if showCmd = SW_SHOWMAXIMIZED then
        gShowCmd := SW_SHOWMAXIMIZED
    else
        gShowCmd := SW_SHOWNORMAL;
    wp.showCmd := SW_HIDE;
    SetWindowPlacement(aWnd, @wp);
end;

{*******************************************************************************
* writeGeom — persists the tracked windowed geometry.
*******************************************************************************}
procedure writeGeom();
begin
    if gLastGeom <> '' then
        setStateValue('win', gLastGeom);
end;

{*******************************************************************************
* centeredDefault — a centred 1024x768 rectangle on the primary monitor.
*******************************************************************************}
procedure centeredDefault(out aRect: TRect);
var
    sw, sh: Integer;
begin
    sw := GetSystemMetrics(SM_CXSCREEN);
    sh := GetSystemMetrics(SM_CYSCREEN);
    aRect.Left := (sw - 1024) div 2;
    aRect.Top := (sh - 768) div 2;
    aRect.Right := aRect.Left + 1024;
    aRect.Bottom := aRect.Top + 768;
end;

{*******************************************************************************
* applyNormalPlacement — positions and SHOWS the window from the saved 'win=' geometry
* (normal or maximized, WN-D7), or a centred 1024x768 default when none is saved / it is
* off-screen. Used when switching to Normal mode at runtime (WN2.1).
*******************************************************************************}
procedure applyNormalPlacement(aWnd: HWND);
var
    rest: string;
    left, top, right, bottom, showCmd: Integer;
    wp: TWindowPlacement;
    r: TRect;
begin
    showCmd := SW_SHOWNORMAL;
    if readValue('win', rest)
        and nextInt(rest, left) and nextInt(rest, top) and nextInt(rest, right)
        and nextInt(rest, bottom) and nextInt(rest, showCmd) then
    begin
        r.Left := left;
        r.Top := top;
        r.Right := right;
        r.Bottom := bottom;
    end
    else
        centeredDefault(r);
    if (r.Right - r.Left <= 0) or (r.Bottom - r.Top <= 0) or (not onScreen(r)) then
    begin
        centeredDefault(r);
        showCmd := SW_SHOWNORMAL;
    end;
    FillChar(wp, SizeOf(wp), 0);
    wp.length := SizeOf(wp);
    wp.rcNormalPosition := r;
    if showCmd = SW_SHOWMAXIMIZED then
        wp.showCmd := SW_SHOWMAXIMIZED
    else
        wp.showCmd := SW_SHOWNORMAL;
    SetWindowPlacement(aWnd, @wp);
    gLastGeom := placementString(aWnd);
end;

{*******************************************************************************
* stateWndProc — the single main-window subclass (WN-D5). In Normal mode it records
* the windowed geometry (win=) on move/size and persists it when a move/resize settles
* or the window is maximized/restored. In Kiosk mode it defers a drag/resize-end to the
* AppBar's handler (refill monitor / remember restored rect), or saves the kiosk rect if
* no handler is registered. Then chains to the original proc.
*******************************************************************************}
function stateWndProc(aWnd: HWND; aMsg: UINT; aWParam: WPARAM; aLParam: LPARAM): LRESULT; stdcall;
var
    s: string;
begin
    if gTrackMode = wmNormal then
    begin
        if ((aMsg = WM_WINDOWPOSCHANGED) or (aMsg = WM_SIZE)) and (not IsIconic(aWnd)) then
        begin
            s := placementString(aWnd);
            if s <> '' then
                gLastGeom := s;
            if (aMsg = WM_SIZE) and ((aWParam = SIZE_MAXIMIZED) or (aWParam = SIZE_RESTORED)) then
                writeGeom;
        end
        else if aMsg = WM_EXITSIZEMOVE then
            writeGeom;
    end
    else if aMsg = WM_EXITSIZEMOVE then
    begin
        if Assigned(gKioskDragEnd) then
            gKioskDragEnd()
        else
            saveKioskRect(aWnd);
    end;
    Result := CallWindowProcW(TFNWndProc(Pointer(gOrigProc)), aWnd, aMsg, aWParam, aLParam);
end;

{*******************************************************************************
* attachWindowState — Normal/windowed start: restore the saved geometry, then install
* the tracker in Normal mode.
*******************************************************************************}
procedure attachWindowState(aWnd: HWND);
begin
    if aWnd = 0 then
        Exit;
    restoreWindowState(aWnd);
    gLastGeom := placementString(aWnd);
    setTrackMode(wmNormal);
    installMainTracker(aWnd);
end;

{*******************************************************************************
* installMainTracker — installs the single main-window subclass once (idempotent).
* Used by attachWindowState (Normal start) and by the AppBar (kiosk start), so exactly
* one subclass is ever present regardless of the starting mode (WN-D5).
*******************************************************************************}
procedure installMainTracker(aWnd: HWND);
begin
    if (aWnd = 0) or (gOrigProc <> 0) then
        Exit;
    gOrigProc := SetWindowLongPtrW(aWnd, GWL_WNDPROC, LONG_PTR(PtrInt(@stateWndProc)));
end;

{*******************************************************************************
* setTrackMode — tells the tracker which mode's geometry to record (Normal -> win=,
* Kiosk -> kioskrect via the drag-end handler).
*******************************************************************************}
procedure setTrackMode(aMode: TWindowMode);
begin
    gTrackMode := aMode;
end;

{*******************************************************************************
* setKioskDragEndHandler — registers the AppBar's kiosk drag/resize-end handler.
*******************************************************************************}
procedure setKioskDragEndHandler(aProc: TKioskDragEndProc);
begin
    gKioskDragEnd := aProc;
end;

{*******************************************************************************
* restoredShowCmd — how the window should be shown once ready (SW_SHOWNORMAL, or
* SW_SHOWMAXIMIZED when it was saved maximized).
*******************************************************************************}
function restoredShowCmd(): Integer;
begin
    Result := gShowCmd;
end;

{*******************************************************************************
* flushWindowState
*******************************************************************************}
procedure flushWindowState();
begin
    writeGeom;
end;

{*******************************************************************************
* saveDispMode / loadDispMode — persist the display mode ('kiosk' or 'normal') so
* a runtime Kiosk<->Normal switch is restored on the next launch (WN1.1).
*******************************************************************************}
procedure saveDispMode(const aMode: string);
begin
    setStateValue('dispmode', aMode);
end;

function loadDispMode(out aMode: string): Boolean;
var
    v: string;
begin
    Result := readValue('dispmode', v);
    if Result then
        aMode := LowerCase(Trim(v));
end;

{*******************************************************************************
* saveKioskFull / loadKioskFull — persist the kiosk fullscreen/restored toggle.
*******************************************************************************}
procedure saveKioskFull(aFull: Boolean);
begin
    if aFull then
        setStateValue('kioskfull', '1')
    else
        setStateValue('kioskfull', '0');
end;

function loadKioskFull(out aFull: Boolean): Boolean;
var
    v: string;
begin
    Result := readValue('kioskfull', v);
    if Result then
        aFull := (Trim(v) = '1');
end;

{*******************************************************************************
* saveKioskRect / loadKioskRect — the restored (non-fullscreen) kiosk geometry.
*******************************************************************************}
procedure saveKioskRect(aWnd: HWND);
var
    r: TRect;
begin
    if (aWnd <> 0) and GetWindowRect(aWnd, r) then
        setStateValue('kioskrect', Format('%d %d %d %d', [r.Left, r.Top, r.Right, r.Bottom]));
end;

function loadKioskRect(out aLeft, aTop, aRight, aBottom: Integer): Boolean;
var
    rest: string;
begin
    Result := False;
    if not readValue('kioskrect', rest) then
        Exit;
    rest := Trim(rest);
    if not (nextInt(rest, aLeft) and nextInt(rest, aTop)
            and nextInt(rest, aRight) and nextInt(rest, aBottom)) then
        Exit;
    if (aRight - aLeft <= 0) or (aBottom - aTop <= 0) then
        Exit;
    Result := True;
end;

{*******************************************************************************
* saveKioskMon / loadKioskMon — rectangle of the monitor a fullscreen kiosk window
* was on (used to restore it to the same monitor, or the nearest one if gone).
*******************************************************************************}
procedure saveKioskMon(aLeft, aTop, aRight, aBottom: Integer);
begin
    setStateValue('kioskmon', Format('%d %d %d %d', [aLeft, aTop, aRight, aBottom]));
end;

function loadKioskMon(out aLeft, aTop, aRight, aBottom: Integer): Boolean;
var
    rest: string;
begin
    Result := False;
    if not readValue('kioskmon', rest) then
        Exit;
    rest := Trim(rest);
    if not (nextInt(rest, aLeft) and nextInt(rest, aTop)
            and nextInt(rest, aRight) and nextInt(rest, aBottom)) then
        Exit;
    Result := (aRight > aLeft) and (aBottom > aTop);
end;

end.
