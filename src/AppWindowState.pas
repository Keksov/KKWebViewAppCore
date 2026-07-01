unit AppWindowState;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

uses
    Windows;

{ Remembers the window position, size and maximized state across runs. State is
  stored next to the exe when that folder is writable, otherwise in the user's temp
  directory under a name derived from the full exe path (so different installs keep
  separate state). Off-screen or degenerate rectangles are ignored on restore.

  attachWindowState restores the saved geometry and starts tracking changes (the
  window is subclassed so the geometry is captured even when the window is closed
  via the X button, before it is destroyed). flushWindowState writes the last
  tracked geometry and must be called once on shutdown. }
procedure attachWindowState(aWnd: HWND);
procedure flushWindowState();

implementation

uses
    SysUtils;

const
    STATE_NAME = 'AppCore.window';

var
    gOrigProc: LONG_PTR = 0;   // subclassed window's original WndProc
    gLastState: string = '';   // latest "left top right bottom showCmd"

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
* tryWriteText — writes aData to aPath; False if the folder is not writable.
*******************************************************************************}
function tryWriteText(const aPath, aData: string): Boolean;
var
    f: TextFile;
begin
    Result := False;
    try
        AssignFile(f, aPath);
        Rewrite(f);
        try
            WriteLn(f, aData);
        finally
            CloseFile(f);
        end;
        Result := True;
    except
        Result := False;
    end;
end;

{*******************************************************************************
* tryReadText — reads the first line of aPath into aData.
*******************************************************************************}
function tryReadText(const aPath: string; out aData: string): Boolean;
var
    f: TextFile;
begin
    Result := False;
    aData := '';
    if not FileExists(aPath) then
        Exit;
    try
        AssignFile(f, aPath);
        Reset(f);
        try
            if not Eof(f) then
                ReadLn(f, aData);
        finally
            CloseFile(f);
        end;
        Result := True;
    except
        Result := False;
    end;
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
* restoreWindowState — applies the saved placement to aWnd if it is valid.
*******************************************************************************}
procedure restoreWindowState(aWnd: HWND);
var
    path: string;
    data: string;
    rest: string;
    left, top, right, bottom, showCmd: Integer;
    wp: TWindowPlacement;
    r: TRect;
begin
    path := nearExePath;
    if not FileExists(path) then
        path := tempPath;
    if not tryReadText(path, data) then
        Exit;
    rest := Trim(data);
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
* stateWndProc — subclass proc: records the geometry on every move/size (while
* not minimized), then chains to the original proc.
*******************************************************************************}
function stateWndProc(aWnd: HWND; aMsg: UINT; aWParam: WPARAM; aLParam: LPARAM): LRESULT; stdcall;
var
    s: string;
begin
    if ((aMsg = WM_WINDOWPOSCHANGED) or (aMsg = WM_SIZE)) and (not IsIconic(aWnd)) then
    begin
        s := placementString(aWnd);
        if s <> '' then
            gLastState := s;
    end;
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
    gLastState := placementString(aWnd);
    gOrigProc := SetWindowLongPtrW(aWnd, GWL_WNDPROC, LONG_PTR(PtrInt(@stateWndProc)));
end;

{*******************************************************************************
* flushWindowState
*******************************************************************************}
procedure flushWindowState();
begin
    if gLastState = '' then
        Exit;
    if not tryWriteText(nearExePath, gLastState) then
        tryWriteText(tempPath, gLastState);
end;

end.
