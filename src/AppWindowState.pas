unit AppWindowState;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

uses
    Windows;

{ Remembers the window state across runs, stored next to the exe when that folder is
  writable, otherwise in the user's temp directory under a name derived from the full
  exe path (so different installs keep separate state).

  Two independent pieces (an app uses one, per its mode):
    win=<left top right bottom showCmd>  - normal windowed geometry + maximized state
    kioskfull=<0|1>                      - fullscreen(1) / restored(0) for kiosk mode

  Windowed: attachWindowState restores the geometry and tracks changes (subclassing
  the window so state is captured even on X-button close / hard kill); flushWindowState
  writes on shutdown. Kiosk: saveKioskFull / loadKioskFull persist the AppBar toggle. }
procedure attachWindowState(aWnd: HWND);
procedure flushWindowState();
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
    gOrigProc: LONG_PTR = 0;   // subclassed window's original WndProc
    gLastGeom: string = '';    // latest "left top right bottom showCmd"

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
    if showCmd = SW_SHOWMAXIMIZED then
        wp.showCmd := SW_SHOWMAXIMIZED
    else
        wp.showCmd := SW_SHOWNORMAL;
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
* stateWndProc — subclass proc: records the geometry on every move/size (while not
* minimized) and persists it as soon as a move/resize settles or the window is
* maximized/restored, then chains to the original proc.
*******************************************************************************}
function stateWndProc(aWnd: HWND; aMsg: UINT; aWParam: WPARAM; aLParam: LPARAM): LRESULT; stdcall;
var
    s: string;
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
    Result := CallWindowProcW(TFNWndProc(Pointer(gOrigProc)), aWnd, aMsg, aWParam, aLParam);
end;

{*******************************************************************************
* attachWindowState
*******************************************************************************}
procedure attachWindowState(aWnd: HWND);
begin
    if aWnd = 0 then
        Exit;
    restoreWindowState(aWnd);
    gLastGeom := placementString(aWnd);
    gOrigProc := SetWindowLongPtrW(aWnd, GWL_WNDPROC, LONG_PTR(PtrInt(@stateWndProc)));
end;

{*******************************************************************************
* flushWindowState
*******************************************************************************}
procedure flushWindowState();
begin
    writeGeom;
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
