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

    { Called on WM_SYSCOMMAND with the masked command; returns True if it handled a custom
      system-menu item (so the tracker swallows it) — used for the Normal-mode menu (WN2.2). }
    TSysCommandProc = function(aCmd: WPARAM): Boolean;

{ Remembers the window state across runs, stored next to the exe when that folder is
  writable, otherwise in the user's temp directory under a name derived from the full
  exe path (so different installs keep separate state).

  Pieces:
    dispmode=<kiosk|normal>              - the display mode, restored across runs (WN1.1)
    mon.<key>.win=<l t r b showCmd>      - Normal geometry + maximized state remembered PER
    mon.<key>.work=<l t r b>               monitor (key = stable EDID id, AppMonitors); its
                                           work area detects a resolution change of that
                                           same monitor
    lastmon=<key>                        - which monitor to open on at startup
    win=/winmon=                         - legacy single-slot geometry (pre-per-monitor);
                                           still read as a fallback for old state files
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
procedure setSysCommandHandler(aProc: TSysCommandProc);
procedure applyNormalPlacement(aWnd: HWND);

{ Remaps a saved Normal window rect onto the target monitor's work area when the display
  config changed (e.g. the monitor is gone / a different resolution). Pure geometry, so it
  is unit-testable. aSavedMon is the work area of the monitor the window was on (an empty
  rect means unknown). Policy: target >= source -> preserve the edge margins (window grows,
  so a near-maximized window stays near-maximized on a bigger screen); target < source ->
  keep the size if it still fits, else fill the target work area. Maximized/fullscreen state
  is applied by the caller on top of the returned rect. }
function remapNormalRect(const aSavedWin, aSavedMon, aTargetWork: TRect): TRect;
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
    SysUtils, Math, AppMonitors;

const
    STATE_NAME = 'AppCore.window';
    MIN_W = 320;                           // never restore a window smaller than this
    MIN_H = 240;

var
    gOrigProc: LONG_PTR = 0;              // subclassed window's original WndProc
    gTrackedWnd: HWND = 0;                 // the subclassed main window (used by flush)
    gDragStartKey: string = '';            // monitor key captured at drag start (WM_ENTERSIZEMOVE)
    gShowCmd: Integer = SW_SHOWNORMAL;     // how to show once ready (normal/maximized)
    gTrackMode: TWindowMode = wmKiosk;     // which mode the tracker records geometry for
    gKioskDragEnd: TKioskDragEndProc = nil; // AppBar's kiosk drag/resize-end handler
    gSysCmd: TSysCommandProc = nil;         // custom system-menu command handler (Normal mode)

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
* mkRect — a TRect from its four edges.
*******************************************************************************}
function mkRect(aL, aT, aR, aB: Integer): TRect;
begin
    Result.Left := aL;
    Result.Top := aT;
    Result.Right := aR;
    Result.Bottom := aB;
end;

{*******************************************************************************
* parseRect — parses "l t r b" into aRect. False when malformed.
*******************************************************************************}
function parseRect(const aStr: string; out aRect: TRect): Boolean;
var
    s: string;
    l, t, r, b: Integer;
begin
    s := Trim(aStr);
    Result := nextInt(s, l) and nextInt(s, t) and nextInt(s, r) and nextInt(s, b);
    if Result then
    begin
        aRect.Left := l;
        aRect.Top := t;
        aRect.Right := r;
        aRect.Bottom := b;
    end;
end;

{*******************************************************************************
* fullyWithin — True when aInner lies entirely inside aOuter.
*******************************************************************************}
function fullyWithin(const aInner, aOuter: TRect): Boolean;
begin
    Result := (aInner.Left >= aOuter.Left) and (aInner.Top >= aOuter.Top)
        and (aInner.Right <= aOuter.Right) and (aInner.Bottom <= aOuter.Bottom);
end;

{*******************************************************************************
* clampRect — fits aRect inside aWork: cap the size to the work area (min MIN_W/H) and
* shift it fully on-screen.
*******************************************************************************}
procedure clampRect(var aRect: TRect; const aWork: TRect);
var
    w, h, workW, workH: Integer;
begin
    workW := aWork.Right - aWork.Left;
    workH := aWork.Bottom - aWork.Top;
    w := Min(Max(aRect.Right - aRect.Left, Min(MIN_W, workW)), workW);
    h := Min(Max(aRect.Bottom - aRect.Top, Min(MIN_H, workH)), workH);
    if aRect.Left + w > aWork.Right then
        aRect.Left := aWork.Right - w;
    if aRect.Top + h > aWork.Bottom then
        aRect.Top := aWork.Bottom - h;
    if aRect.Left < aWork.Left then
        aRect.Left := aWork.Left;
    if aRect.Top < aWork.Top then
        aRect.Top := aWork.Top;
    aRect.Right := aRect.Left + w;
    aRect.Bottom := aRect.Top + h;
end;

{*******************************************************************************
* remapNormalRect — see the interface comment. Pure geometry.
*******************************************************************************}
function remapNormalRect(const aSavedWin, aSavedMon, aTargetWork: TRect): TRect;
var
    winW, winH, tW, tH, sW, sH: Integer;
    hasSrc: Boolean;
    r: TRect;
begin
    winW := aSavedWin.Right - aSavedWin.Left;
    winH := aSavedWin.Bottom - aSavedWin.Top;
    tW := aTargetWork.Right - aTargetWork.Left;
    tH := aTargetWork.Bottom - aTargetWork.Top;
    sW := aSavedMon.Right - aSavedMon.Left;
    sH := aSavedMon.Bottom - aSavedMon.Top;
    hasSrc := (sW > 0) and (sH > 0);

    if hasSrc and (tW >= sW) and (tH >= sH) then
    begin
        // Target monitor >= source: preserve the distance to each edge (the window grows,
        // so a near-maximized window stays near-maximized on a bigger screen).
        r.Left := aTargetWork.Left + Max(0, aSavedWin.Left - aSavedMon.Left);
        r.Top := aTargetWork.Top + Max(0, aSavedWin.Top - aSavedMon.Top);
        r.Right := aTargetWork.Right - Max(0, aSavedMon.Right - aSavedWin.Right);
        r.Bottom := aTargetWork.Bottom - Max(0, aSavedMon.Bottom - aSavedWin.Bottom);
    end
    else if (winW <= tW) and (winH <= tH) then
    begin
        // Smaller (or unknown) target, window still fits: keep the size. Preserve the
        // relative top-left offset when the source is known, else centre it.
        if hasSrc then
        begin
            r.Left := aTargetWork.Left + Round((aSavedWin.Left - aSavedMon.Left) / sW * tW);
            r.Top := aTargetWork.Top + Round((aSavedWin.Top - aSavedMon.Top) / sH * tH);
        end
        else
        begin
            r.Left := aTargetWork.Left + (tW - winW) div 2;
            r.Top := aTargetWork.Top + (tH - winH) div 2;
        end;
        r.Right := r.Left + winW;
        r.Bottom := r.Top + winH;
    end
    else
        // Window does not fit the smaller target: fill its work area (stay Normal).
        r := aTargetWork;

    clampRect(r, aTargetWork);
    Result := r;
end;

{*******************************************************************************
* readSavedNormal — reads win= (rect + showCmd) and winmon= (monitor work area, empty
* rect when absent). False when there is no valid saved geometry.
*******************************************************************************}
function readSavedNormal(out aWin, aMon: TRect; out aShowCmd: Integer): Boolean;
var
    rest, monRest: string;
    l, t, r, b: Integer;
begin
    Result := False;
    aShowCmd := SW_SHOWNORMAL;
    aMon := mkRect(0, 0, 0, 0);
    if not readValue('win', rest) then
        Exit;
    if not (nextInt(rest, l) and nextInt(rest, t) and nextInt(rest, r) and nextInt(rest, b)
            and nextInt(rest, aShowCmd)) then
        Exit;
    aWin.Left := l;
    aWin.Top := t;
    aWin.Right := r;
    aWin.Bottom := b;
    if (aWin.Right - aWin.Left <= 0) or (aWin.Bottom - aWin.Top <= 0) then
        Exit;
    if readValue('winmon', monRest) then
        parseRect(monRest, aMon);
    Result := True;
end;

{*******************************************************************************
* monitorWorkString — "l t r b" of the work area of aWnd's monitor.
*******************************************************************************}
function monitorWorkString(aWnd: HWND): string;
var
    r: TRect;
begin
    r := monitorWorkAreaForWindow(aWnd);
    Result := Format('%d %d %d %d', [r.Left, r.Top, r.Right, r.Bottom]);
end;

{*******************************************************************************
* normalTarget — resolves where a saved Normal window should go now: the exact saved rect
* if its monitor is unchanged, else the remap onto the nearest current monitor.
*******************************************************************************}
function normalTarget(const aSavedWin, aSavedMon: TRect): TRect;
var
    work: TRect;
    noMon: Boolean;
begin
    work := monitorWorkAreaForRect(aSavedWin);
    noMon := aSavedMon.Right <= aSavedMon.Left;   // no winmon saved (pre-upgrade state)
    if rectsEqual(aSavedMon, work) then
        Result := aSavedWin                        // same monitor, unchanged
    else if noMon and fullyWithin(aSavedWin, work) then
        Result := aSavedWin                        // unknown monitor but still fully on-screen
    else
        Result := remapNormalRect(aSavedWin, aSavedMon, work);
end;

{*******************************************************************************
* readMonState — reads mon.<key>.win (rect + showCmd) and mon.<key>.work (work area).
* False when there is no valid saved state for that monitor.
*******************************************************************************}
function readMonState(const aKey: string; out aWin, aWork: TRect; out aShowCmd: Integer): Boolean;
var
    rest: string;
    l, t, r, b: Integer;
begin
    Result := False;
    aShowCmd := SW_SHOWNORMAL;
    aWork := mkRect(0, 0, 0, 0);
    if not readValue('mon.' + aKey + '.win', rest) then
        Exit;
    if not (nextInt(rest, l) and nextInt(rest, t) and nextInt(rest, r) and nextInt(rest, b)
            and nextInt(rest, aShowCmd)) then
        Exit;
    aWin := mkRect(l, t, r, b);
    if (aWin.Right - aWin.Left <= 0) or (aWin.Bottom - aWin.Top <= 0) then
        Exit;
    if readValue('mon.' + aKey + '.work', rest) then
        parseRect(rest, aWork);
    Result := True;
end;

{*******************************************************************************
* hasMonState — True when a saved state exists for the monitor key.
*******************************************************************************}
function hasMonState(const aKey: string): Boolean;
var
    dummy: string;
begin
    Result := (aKey <> '') and readValue('mon.' + aKey + '.win', dummy);
end;

{*******************************************************************************
* writeMonState — saves aWnd's geometry + state under its monitor's key and marks it the
* last-used monitor. Skips a minimized window.
*******************************************************************************}
procedure writeMonState(aWnd: HWND);
var
    key, geom: string;
begin
    if (aWnd = 0) or IsIconic(aWnd) then
        Exit;
    key := monitorKeyForWindow(aWnd);
    geom := placementString(aWnd);
    if (key = '') or (geom = '') then
        Exit;
    setStateValue('mon.' + key + '.win', geom);
    setStateValue('mon.' + key + '.work', monitorWorkString(aWnd));
    setStateValue('lastmon', key);
end;

{*******************************************************************************
* applyMonState — restores the layout remembered for aKey onto aWnd (assumed already on
* that monitor), remapping if the monitor's work area changed.
*******************************************************************************}
function applyMonState(aWnd: HWND; const aKey: string): Boolean;
var
    win, work, curWork, target: TRect;
    showCmd: Integer;
    wp: TWindowPlacement;
begin
    Result := False;
    if not readMonState(aKey, win, work, showCmd) then
        Exit;
    curWork := monitorWorkAreaForWindow(aWnd);
    if rectsEqual(work, curWork) then
        target := win
    else
        target := remapNormalRect(win, work, curWork);
    FillChar(wp, SizeOf(wp), 0);
    wp.length := SizeOf(wp);
    wp.rcNormalPosition := target;
    if showCmd = SW_SHOWMAXIMIZED then
        wp.showCmd := SW_SHOWMAXIMIZED
    else
        wp.showCmd := SW_SHOWNORMAL;
    SetWindowPlacement(aWnd, @wp);
    Result := True;
end;

{*******************************************************************************
* resolveStartupPlacement — where to open, from per-monitor state:
*  (a) the last-used monitor is still connected -> its remembered layout (remapped if its
*      resolution changed);
*  (b) else the monitor nearest the old position has its OWN remembered layout -> use it;
*  (c) else remap the last geometry onto that nearest monitor.
* False when there is no per-monitor state at all (caller falls back to legacy/default).
*******************************************************************************}
function resolveStartupPlacement(out aTarget: TRect; out aShowCmd: Integer): Boolean;
var
    lastKey, fbKey: string;
    sWin, sWork, curWork, fbWin, fbWork, fbCur: TRect;
    sShow, fbShow: Integer;
begin
    Result := False;
    if not readValue('lastmon', lastKey) then
        Exit;
    lastKey := Trim(lastKey);
    if not readMonState(lastKey, sWin, sWork, sShow) then
        Exit;
    if findMonitorWorkByKey(lastKey, curWork) then       // (a) last monitor still here
    begin
        aShowCmd := sShow;
        if rectsEqual(sWork, curWork) then
            aTarget := sWin
        else
            aTarget := remapNormalRect(sWin, sWork, curWork);
        Exit(True);
    end;
    fbKey := monitorKeyForRect(sWin);                    // (b) fallback monitor's own layout
    if (fbKey <> '') and readMonState(fbKey, fbWin, fbWork, fbShow)
        and findMonitorWorkByKey(fbKey, fbCur) then
    begin
        aShowCmd := fbShow;
        if rectsEqual(fbWork, fbCur) then
            aTarget := fbWin
        else
            aTarget := remapNormalRect(fbWin, fbWork, fbCur);
        Exit(True);
    end;
    aShowCmd := sShow;                                   // (c) remap last geometry onto nearest
    aTarget := remapNormalRect(sWin, sWork, monitorWorkAreaForRect(sWin));
    Result := True;
end;

{*******************************************************************************
* handleDisplayChange — on a runtime monitor change, if the Normal window got stranded
* (off its monitor / no longer fits), re-place it from the saved per-monitor state.
*******************************************************************************}
procedure handleDisplayChange(aWnd: HWND);
var
    cur, work, target: TRect;
    wp: TWindowPlacement;
    showCmd: Integer;
    maximized: Boolean;
begin
    if (aWnd = 0) or IsIconic(aWnd) then
        Exit;
    FillChar(wp, SizeOf(wp), 0);
    wp.length := SizeOf(wp);
    if not GetWindowPlacement(aWnd, @wp) then
        Exit;
    maximized := wp.showCmd = SW_SHOWMAXIMIZED;
    cur := wp.rcNormalPosition;
    work := monitorWorkAreaForRect(cur);
    if fullyWithin(cur, work) and (not maximized) then
        Exit;   // still fully visible; leave it
    if resolveStartupPlacement(target, showCmd) then
    begin
        FillChar(wp, SizeOf(wp), 0);
        wp.length := SizeOf(wp);
        wp.rcNormalPosition := target;
        if showCmd = SW_SHOWMAXIMIZED then
            wp.showCmd := SW_SHOWMAXIMIZED
        else
            wp.showCmd := SW_SHOWNORMAL;
        SetWindowPlacement(aWnd, @wp);
    end
    else
    begin
        target := remapNormalRect(cur, mkRect(0, 0, 0, 0), work);
        FillChar(wp, SizeOf(wp), 0);
        wp.length := SizeOf(wp);
        wp.rcNormalPosition := target;
        if maximized then
            wp.showCmd := SW_SHOWMAXIMIZED
        else
            wp.showCmd := SW_SHOWNORMAL;
        SetWindowPlacement(aWnd, @wp);
    end;
end;

{*******************************************************************************
* restoreWindowState — places the (still-hidden) window from the saved per-monitor state,
* falling back to the legacy single win=/winmon= slot for pre-upgrade state files.
*******************************************************************************}
procedure restoreWindowState(aWnd: HWND);
var
    target, savedWin, savedMon: TRect;
    showCmd, lShow: Integer;
    wp: TWindowPlacement;
begin
    if resolveStartupPlacement(target, showCmd) then
        { placed from per-monitor state }
    else if readSavedNormal(savedWin, savedMon, lShow) then
    begin
        target := normalTarget(savedWin, savedMon);   // legacy win=/winmon=
        showCmd := lShow;
    end
    else
        Exit;   // nothing saved -> leave the webview default
    if showCmd = SW_SHOWMAXIMIZED then
        gShowCmd := SW_SHOWMAXIMIZED
    else
        gShowCmd := SW_SHOWNORMAL;
    FillChar(wp, SizeOf(wp), 0);
    wp.length := SizeOf(wp);
    // Keep it HIDDEN — revealed later at the right place/state; a maximized window
    // maximizes on the monitor holding rcNormalPosition.
    wp.rcNormalPosition := target;
    wp.showCmd := SW_HIDE;
    SetWindowPlacement(aWnd, @wp);
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
    savedWin, savedMon, target: TRect;
    showCmd, lShow: Integer;
    wp: TWindowPlacement;
begin
    if resolveStartupPlacement(target, showCmd) then
        { placed from per-monitor state }
    else if readSavedNormal(savedWin, savedMon, lShow) then
    begin
        target := normalTarget(savedWin, savedMon);
        showCmd := lShow;
    end
    else
    begin
        centeredDefault(target);
        showCmd := SW_SHOWNORMAL;
    end;
    FillChar(wp, SizeOf(wp), 0);
    wp.length := SizeOf(wp);
    wp.rcNormalPosition := target;
    if showCmd = SW_SHOWMAXIMIZED then
        wp.showCmd := SW_SHOWMAXIMIZED
    else
        wp.showCmd := SW_SHOWNORMAL;
    SetWindowPlacement(aWnd, @wp);
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
    curKey: string;
begin
    // Custom system-menu items (Normal mode) arrive as WM_SYSCOMMAND; let the app handle
    // them and swallow the message. The low 4 bits are system-reserved (mask with $FFF0).
    if (aMsg = WM_SYSCOMMAND) and Assigned(gSysCmd) then
        if gSysCmd(aWParam and WPARAM($FFF0)) then
            Exit(0);
    if gTrackMode = wmNormal then
        case aMsg of
            WM_SIZE:
                // Maximize / restore / Aero-snap settles here (no WM_EXITSIZEMOVE): save it.
                if (not IsIconic(aWnd)) and ((aWParam = SIZE_MAXIMIZED) or (aWParam = SIZE_RESTORED)) then
                    writeMonState(aWnd);
            WM_ENTERSIZEMOVE:
                gDragStartKey := monitorKeyForWindow(aWnd);
            WM_EXITSIZEMOVE:
                begin
                    // If a drag moved the window onto a DIFFERENT monitor that has a remembered
                    // layout, snap to it; otherwise just save the new geometry for this monitor.
                    curKey := monitorKeyForWindow(aWnd);
                    if (curKey <> '') and (curKey <> gDragStartKey) and hasMonState(curKey) then
                        applyMonState(aWnd, curKey)
                    else
                        writeMonState(aWnd);
                end;
            WM_DISPLAYCHANGE:
                handleDisplayChange(aWnd);
        end
    else
        case aMsg of
            WM_EXITSIZEMOVE:
                if Assigned(gKioskDragEnd) then
                    gKioskDragEnd()
                else
                    saveKioskRect(aWnd);
            WM_DISPLAYCHANGE:
                if Assigned(gKioskDragEnd) then
                    gKioskDragEnd();   // kiosk: re-fill the (nearest) monitor
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
    gTrackedWnd := aWnd;   // remembered so flushWindowState can save on shutdown
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
* setSysCommandHandler — registers the custom WM_SYSCOMMAND handler (Normal-mode menu).
*******************************************************************************}
procedure setSysCommandHandler(aProc: TSysCommandProc);
begin
    gSysCmd := aProc;
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
* flushWindowState — on shutdown, save the tracked Normal window's state for its monitor.
*******************************************************************************}
procedure flushWindowState();
begin
    if gTrackMode = wmNormal then
        writeMonState(gTrackedWnd);
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
