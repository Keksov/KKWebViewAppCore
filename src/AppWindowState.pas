unit AppWindowState;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

uses
    Windows, AppWindowMode;

type
    { Called on the main window's drag/resize end while in kiosk mode, so the AppBar can
      refill the monitor (fullscreen) or remember the restored rect (WN-D5). Also the shape
      of the kiosk display-change handler. }
    TKioskDragEndProc = procedure();

    { Called on WM_SYSCOMMAND with the masked command; returns True if it handled a custom
      system-menu item (so the tracker swallows it) — used for the Normal-mode menu (WN2.2). }
    TSysCommandProc = function(aCmd: WPARAM): Boolean;

{ Remembers the window state across runs, stored next to the exe when that folder is
  writable, otherwise in the user's temp directory under a name derived from the full
  exe path (so different installs keep separate state).

  Pieces:
    dispmode=<kiosk|normal>              - the display mode, restored across runs (WN1.1)
    mon.<key>.win=<l t r b showCmd>      - the NORMAL rect (screen coordinates, never the
                                           maximized rect) + 1|3 (normal|maximized),
                                           remembered PER monitor (key = stable EDID id,
                                           AppMonitors)
    mon.<key>.work=<l t r b>             - that monitor's work area at save time, so a
                                           resolution change of the same monitor is detected
    lastmon=<key>                        - which monitor to open on at startup
    win=/winmon=                         - legacy single-slot geometry (pre-per-monitor);
                                           still read as a fallback for old state files
    kioskfull=<0|1>                      - fullscreen(1) / restored(0) for kiosk mode

  Save model: geometry is CAPTURED into an in-memory cache on settle events (drag/resize
  end, maximize/restore, monitor arrival) and PERSISTED in one batched file write; saves
  are suppressed while a modal size/move loop is active (transient rects) and while the app
  itself applies a placement (begin/endPlacementChange). The exit flush persists the cache,
  which survives a destroyed (X-close) or minimized window. }
procedure attachWindowState(aWnd: HWND);
function restoredShowCmd(): Integer;
procedure flushWindowState();
procedure installMainTracker(aWnd: HWND);
procedure setTrackMode(aMode: TWindowMode);
procedure setKioskDragEndHandler(aProc: TKioskDragEndProc);
procedure setKioskDisplayChangeHandler(aProc: TKioskDragEndProc);
procedure setSysCommandHandler(aProc: TSysCommandProc);
procedure applyNormalPlacement(aWnd: HWND);

{ Suppress tracker saves while the app itself changes the window placement (mode switch,
  programmatic re-place), so induced WM_SIZE/WM_WINDOWPOSCHANGED do not persist transient
  geometry. Nestable. }
procedure beginPlacementChange();
procedure endPlacementChange();

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
    gOrigProc: LONG_PTR = 0;               // subclassed window's original WndProc
    gCurMon: HMONITOR = 0;                 // monitor the window was last seen on (arrival detection)
    gTrackedWnd: HWND = 0;                 // the subclassed main window (used by flush)
    gSuppress: Integer = 0;                // >0: the app is applying a placement; don't save
    gDragStartW: Integer = 0;              // window size at WM_ENTERSIZEMOVE (move vs resize)
    gDragStartH: Integer = 0;
    gInSizeMove: Boolean = False;          // inside the modal size/move loop
    gDragStartKey: string = '';            // monitor key captured at drag start
    gShowCmd: Integer = SW_SHOWNORMAL;     // how to show once ready (normal/maximized)
    gTrackMode: TWindowMode = wmKiosk;     // which mode the tracker records geometry for
    gKioskDragEnd: TKioskDragEndProc = nil; // AppBar's kiosk drag/resize-end handler
    gKioskDisplay: TKioskDragEndProc = nil; // AppBar's kiosk display-change handler
    gSysCmd: TSysCommandProc = nil;         // custom system-menu command handler (Normal mode)

    // Last-known-good Normal state (screen coordinates). Persisted by the exit flush, so
    // it must survive a destroyed (X-close) or minimized window.
    gCacheMax: Boolean = False;            // window was maximized
    gCacheValid: Boolean = False;
    gCacheKey: string = '';                // monitor key the state belongs to
    gCacheRect: TRect;                     // the NORMAL rect (never the maximized rect)
    gCacheWork: TRect;                     // that monitor's work area at capture time

{*******************************************************************************
* exePathKey — FNV-1a hash (hex) of the lowercased full exe path; the per-install
* key for the temp-dir fallback file.
*******************************************************************************}
function exePathKey(): string;
var
    i: Integer;
    h: LongWord;
    p: UnicodeString;
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

{*******************************************************************************
* nearExePath / tempPath — the two candidate state-file locations.
*******************************************************************************}
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
    nl: Integer;
    data: string;
    rest: string;
    line: string;
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
* setStateValues — updates several "key=value" pairs in ONE read-modify-write pass,
* preserving all other keys (a settle event updates three keys; one file rewrite).
*******************************************************************************}
procedure setStateValues(const aKeys, aValues: array of string);
var
    data: string;
    rest: string;
    line: string;
    keep: Boolean;
    i, nl: Integer;
    outData: string;
begin
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
            if line = '' then
                Continue;
            keep := True;
            for i := Low(aKeys) to High(aKeys) do
                if Copy(line, 1, Length(aKeys[i]) + 1) = aKeys[i] + '=' then
                begin
                    keep := False;
                    Break;
                end;
            if keep then
                outData := outData + line + #13#10;
        end;
    end;
    for i := Low(aKeys) to High(aKeys) do
        outData := outData + aKeys[i] + '=' + aValues[i] + #13#10;
    writeStateFile(outData);
end;

{*******************************************************************************
* setStateValue — single-key form of setStateValues.
*******************************************************************************}
procedure setStateValue(const aKey, aValue: string);
begin
    setStateValues([aKey], [aValue]);
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
        aRect := mkRect(l, t, r, b);
end;

{*******************************************************************************
* rectStr — "l t r b" for aRect.
*******************************************************************************}
function rectStr(const aRect: TRect): string;
begin
    Result := Format('%d %d %d %d', [aRect.Left, aRect.Top, aRect.Right, aRect.Bottom]);
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
    r: TRect;
    hasSrc: Boolean;
    winW, winH, tW, tH, sW, sH: Integer;
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
* readSavedNormal — reads the LEGACY win= (rect + showCmd) and winmon= keys (pre-
* per-monitor state files). False when there is no valid saved geometry.
*******************************************************************************}
function readSavedNormal(out aWin, aMon: TRect; out aShowCmd: Integer): Boolean;
var
    l, t, r, b: Integer;
    rest, monRest: string;
begin
    Result := False;
    aShowCmd := SW_SHOWNORMAL;
    aMon := mkRect(0, 0, 0, 0);
    if not readValue('win', rest) then
        Exit;
    if not (nextInt(rest, l) and nextInt(rest, t) and nextInt(rest, r) and nextInt(rest, b)
            and nextInt(rest, aShowCmd)) then
        Exit;
    aWin := mkRect(l, t, r, b);
    if (aWin.Right - aWin.Left <= 0) or (aWin.Bottom - aWin.Top <= 0) then
        Exit;
    if readValue('winmon', monRest) then
        parseRect(monRest, aMon);
    Result := True;
end;

{*******************************************************************************
* normalTarget — resolves where a LEGACY saved Normal window should go now: the exact
* saved rect if its monitor is unchanged, else the remap onto the nearest monitor.
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
* readMonState — reads mon.<key>.win (NORMAL rect + maximized flag) and mon.<key>.work
* (work area at save time). False when there is no valid saved state for that monitor.
*******************************************************************************}
function readMonState(const aKey: string; out aWin, aWork: TRect; out aMax: Boolean): Boolean;
var
    rest: string;
    l, t, r, b, sc: Integer;
begin
    Result := False;
    aMax := False;
    aWork := mkRect(0, 0, 0, 0);
    if not readValue('mon.' + aKey + '.win', rest) then
        Exit;
    if not (nextInt(rest, l) and nextInt(rest, t) and nextInt(rest, r) and nextInt(rest, b)
            and nextInt(rest, sc)) then
        Exit;
    aWin := mkRect(l, t, r, b);
    if (aWin.Right - aWin.Left <= 0) or (aWin.Bottom - aWin.Top <= 0) then
        Exit;
    aMax := sc = SW_SHOWMAXIMIZED;
    if readValue('mon.' + aKey + '.work', rest) then
        parseRect(rest, aWork);
    Result := True;
end;

{*******************************************************************************
* readLastMonState — the state saved for the last-used monitor (lastmon), if any.
*******************************************************************************}
function readLastMonState(out aWin, aWork: TRect; out aMax: Boolean): Boolean;
var
    lastKey: string;
begin
    Result := readValue('lastmon', lastKey)
        and readMonState(Trim(lastKey), aWin, aWork, aMax);
end;

{*******************************************************************************
* beginPlacementChange / endPlacementChange — save-suppression counter (see interface).
*******************************************************************************}
procedure beginPlacementChange();
begin
    Inc(gSuppress);
end;

procedure endPlacementChange();
begin
    if gSuppress > 0 then
        Dec(gSuppress);
end;

{*******************************************************************************
* seedCache — sets the last-known-good cache to a placement the app itself just applied
* (aRect = the NORMAL rect in screen coordinates).
*******************************************************************************}
procedure seedCache(const aRect: TRect; aMax: Boolean);
begin
    gCacheRect := aRect;
    gCacheMax := aMax;
    gCacheKey := monitorKeyForRect(aRect);
    gCacheWork := monitorWorkAreaForRect(aRect);
    gCacheValid := gCacheKey <> '';
end;

{*******************************************************************************
* captureState — refreshes the cache from the LIVE window: the normal rect (screen
* coords; kept from the cache while maximized), the maximized flag, and the monitor
* identity. Silently keeps the previous cache when the window is gone or minimized —
* that stale-but-valid state is exactly what the exit flush needs.
*******************************************************************************}
procedure captureState(aWnd: HWND);
var
    r: TRect;
    key: string;
    zoomed: Boolean;
    wp: TWindowPlacement;
begin
    if (aWnd = 0) or (not IsWindow(aWnd)) or IsIconic(aWnd) then
        Exit;
    zoomed := IsZoomed(aWnd);
    if zoomed then
    begin
        // The visible rect is the whole work area; the cache keeps the last normal rect.
        // First-ever capture on an already-maximized window: fall back to the placement's
        // restore rect (exact for a bottom taskbar, sane otherwise).
        if not gCacheValid then
        begin
            FillChar(wp, SizeOf(wp), 0);
            wp.length := SizeOf(wp);
            if not GetWindowPlacement(aWnd, @wp) then
                Exit;
            gCacheRect := wp.rcNormalPosition;
        end;
    end
    else
    begin
        if not GetWindowRect(aWnd, r) then
            Exit;
        gCacheRect := r;
    end;
    key := monitorKeyForWindow(aWnd);
    if key = '' then
        Exit;
    gCacheMax := zoomed;
    gCacheKey := key;
    gCacheWork := monitorWorkAreaForWindow(aWnd);
    gCacheValid := True;
end;

{*******************************************************************************
* captureIfChanged — cheap-path capture for WM_WINDOWPOSCHANGED: skips the (relatively
* costly) monitor-key lookup when nothing relevant changed since the last capture.
*******************************************************************************}
procedure captureIfChanged(aWnd: HWND);
var
    r: TRect;
    zoomed: Boolean;
begin
    if (aWnd = 0) or (not IsWindow(aWnd)) or IsIconic(aWnd) then
        Exit;
    zoomed := IsZoomed(aWnd);
    if gCacheValid and (zoomed = gCacheMax) then
    begin
        if zoomed then
            Exit;   // maximized and already cached: the normal rect is not changing
        if GetWindowRect(aWnd, r) and rectsEqual(r, gCacheRect) then
            Exit;
    end;
    captureState(aWnd);
end;

{*******************************************************************************
* persistState — writes the cached state under its monitor's key and marks that monitor
* the last-used one, in a single batched file write.
*******************************************************************************}
procedure persistState();
var
    sc: Integer;
begin
    if (not gCacheValid) or (gCacheKey = '') then
        Exit;
    if gCacheMax then
        sc := SW_SHOWMAXIMIZED
    else
        sc := SW_SHOWNORMAL;
    setStateValues(
        ['mon.' + gCacheKey + '.win', 'mon.' + gCacheKey + '.work', 'lastmon'],
        [rectStr(gCacheRect) + ' ' + IntToStr(sc), rectStr(gCacheWork), gCacheKey]);
end;

{*******************************************************************************
* saveNow — capture + persist (the settle-event save).
*******************************************************************************}
procedure saveNow(aWnd: HWND);
begin
    captureState(aWnd);
    persistState();
end;

{*******************************************************************************
* applyTarget — applies a Normal placement (screen coords + maximized flag) to a live
* window with tracker saves suppressed, then re-seeds the cache with what was applied.
*******************************************************************************}
procedure applyTarget(aWnd: HWND; const aRect: TRect; aMax: Boolean);
begin
    if (aWnd = 0) or (not IsWindow(aWnd)) then
        Exit;
    beginPlacementChange;
    try
        if IsZoomed(aWnd) then
            ShowWindow(aWnd, SW_RESTORE);
        SetWindowPos(aWnd, 0, aRect.Left, aRect.Top,
            aRect.Right - aRect.Left, aRect.Bottom - aRect.Top,
            SWP_NOZORDER or SWP_NOACTIVATE);
        if aMax then
            ShowWindow(aWnd, SW_MAXIMIZE);
    finally
        endPlacementChange;
    end;
    seedCache(aRect, aMax);
end;

{*******************************************************************************
* applySavedFor — restores the layout remembered for aKey onto aWnd (assumed already on
* that monitor), remapping if that monitor's work area changed, clamping the result
* on-screen, and persisting so lastmon reflects the move. False when aKey has no state.
*******************************************************************************}
function applySavedFor(aWnd: HWND; const aKey: string): Boolean;
var
    max: Boolean;
    win, work, curWork, target: TRect;
begin
    Result := False;
    if not readMonState(aKey, win, work, max) then
        Exit;
    curWork := monitorWorkAreaForWindow(aWnd);
    if rectsEqual(work, curWork) then
        target := win
    else
        target := remapNormalRect(win, work, curWork);
    if not fullyWithin(target, curWork) then
        clampRect(target, curWork);
    applyTarget(aWnd, target, max);
    persistState();
    Result := True;
end;

{*******************************************************************************
* resolveStartupTarget — where to open, from per-monitor state:
*  (a) the last-used monitor is still connected -> its remembered layout (remapped if its
*      resolution changed);
*  (b) else the monitor nearest the old position has its OWN remembered layout -> use it;
*  (c) else remap the last geometry onto that nearest monitor.
* Every branch clamps the target on-screen. False when there is no per-monitor state at
* all (caller falls back to legacy/default).
*******************************************************************************}
function resolveStartupTarget(out aTarget: TRect; out aMax: Boolean): Boolean;
var
    sMax, fbMax: Boolean;
    lastKey, fbKey: string;
    sWin, sWork, curWork, fbWin, fbWork, fbCur: TRect;
begin
    Result := False;
    if not readValue('lastmon', lastKey) then
        Exit;
    lastKey := Trim(lastKey);
    if not readMonState(lastKey, sWin, sWork, sMax) then
        Exit;
    if findMonitorWorkByKey(lastKey, curWork) then       // (a) last monitor still here
    begin
        aMax := sMax;
        if rectsEqual(sWork, curWork) then
            aTarget := sWin
        else
            aTarget := remapNormalRect(sWin, sWork, curWork);
        if not fullyWithin(aTarget, curWork) then
            clampRect(aTarget, curWork);
        Exit(True);
    end;
    fbKey := monitorKeyForRect(sWin);                    // (b) fallback monitor's own layout
    if (fbKey <> '') and readMonState(fbKey, fbWin, fbWork, fbMax)
        and findMonitorWorkByKey(fbKey, fbCur) then
    begin
        aMax := fbMax;
        if rectsEqual(fbWork, fbCur) then
            aTarget := fbWin
        else
            aTarget := remapNormalRect(fbWin, fbWork, fbCur);
        if not fullyWithin(aTarget, fbCur) then
            clampRect(aTarget, fbCur);
        Exit(True);
    end;
    aMax := sMax;                                        // (c) remap last geometry onto nearest
    aTarget := remapNormalRect(sWin, sWork, monitorWorkAreaForRect(sWin));
    Result := True;
end;

{*******************************************************************************
* handleDisplayChange — a monitor was (dis)connected / changed resolution while running.
* Maximized windows are left alone (Windows re-homes them itself); a stranded Normal
* window is remapped onto its nearest monitor per the policy and the result persisted.
*******************************************************************************}
procedure handleDisplayChange(aWnd: HWND);
var
    src: TRect;
    cur, work, target: TRect;
begin
    if (aWnd = 0) or (gSuppress > 0) or (not IsWindow(aWnd)) then
        Exit;
    gCurMon := monitorHandleForWindow(aWnd);   // refresh the arrival baseline
    if IsIconic(aWnd) or IsZoomed(aWnd) then
        Exit;
    if not GetWindowRect(aWnd, cur) then
        Exit;
    work := monitorWorkAreaForRect(cur);
    if fullyWithin(cur, work) then
    begin
        captureState(aWnd);   // still fine; refresh the monitor identity in the cache
        Exit;
    end;
    if gCacheValid then
        src := gCacheWork
    else
        src := mkRect(0, 0, 0, 0);
    target := remapNormalRect(cur, src, work);
    applyTarget(aWnd, target, False);
    persistState();
end;

{*******************************************************************************
* restoreWindowState — positions the (still-hidden) window from the saved per-monitor
* state, falling back to the legacy win=/winmon= slot for pre-upgrade state files. The
* window is revealed later by showMainWindow at restoredShowCmd.
*******************************************************************************}
procedure restoreWindowState(aWnd: HWND);
var
    max: Boolean;
    lShow: Integer;
    target, savedWin, savedMon: TRect;
begin
    if resolveStartupTarget(target, max) then
        { placed from per-monitor state }
    else if readSavedNormal(savedWin, savedMon, lShow) then
    begin
        target := normalTarget(savedWin, savedMon);   // legacy win=/winmon=
        max := lShow = SW_SHOWMAXIMIZED;
    end
    else
        Exit;   // nothing saved -> leave the webview default
    if max then
        gShowCmd := SW_SHOWMAXIMIZED
    else
        gShowCmd := SW_SHOWNORMAL;
    beginPlacementChange;
    try
        // Position the HIDDEN window in screen coordinates; a later
        // ShowWindow(SW_SHOWMAXIMIZED) maximizes on the monitor holding this rect.
        SetWindowPos(aWnd, 0, target.Left, target.Top,
            target.Right - target.Left, target.Bottom - target.Top,
            SWP_NOZORDER or SWP_NOACTIVATE);
    finally
        endPlacementChange;
    end;
    // Seed the cache so even a zero-interaction session persists a valid state at exit.
    seedCache(target, max);
end;

{*******************************************************************************
* centeredIn — a centred 1024x768 (clamped) rectangle inside aWork.
*******************************************************************************}
function centeredIn(const aWork: TRect): TRect;
begin
    Result.Left := aWork.Left + Max(0, (aWork.Right - aWork.Left - 1024) div 2);
    Result.Top := aWork.Top + Max(0, (aWork.Bottom - aWork.Top - 768) div 2);
    Result.Right := Result.Left + 1024;
    Result.Bottom := Result.Top + 768;
    clampRect(Result, aWork);
end;

{*******************************************************************************
* applyNormalPlacement — used when switching Kiosk -> Normal at RUNTIME: restores the
* CURRENT monitor's remembered layout (a mode toggle must un-fullscreen in place, never
* teleport to another monitor); without one, remaps the last-used/legacy state onto the
* current monitor; without any state, centres a default there.
*******************************************************************************}
procedure applyNormalPlacement(aWnd: HWND);
var
    max: Boolean;
    lShow: Integer;
    curKey: string;
    curWork, target, sWin, sWork, savedWin, savedMon: TRect;
begin
    curKey := monitorKeyForWindow(aWnd);
    if (curKey <> '') and applySavedFor(aWnd, curKey) then
        Exit;   // this monitor's own remembered layout, in place
    curWork := monitorWorkAreaForWindow(aWnd);
    if readLastMonState(sWin, sWork, max) then
        target := remapNormalRect(sWin, sWork, curWork)
    else if readSavedNormal(savedWin, savedMon, lShow) then
    begin
        target := remapNormalRect(savedWin, savedMon, curWork);
        max := lShow = SW_SHOWMAXIMIZED;
    end
    else
    begin
        target := centeredIn(curWork);
        max := False;
    end;
    applyTarget(aWnd, target, max);
    persistState();
end;

{*******************************************************************************
* stateWndProc — the single main-window subclass (WN-D5). Normal mode: captures/persists
* geometry on SETTLE events only (drag/resize end, maximize/restore outside the modal
* loop, monitor arrival), suppressed while the app applies placements. Kiosk mode: defers
* drag-end and display changes to the AppBar handlers. Then chains to the original proc.
*******************************************************************************}
function stateWndProc(aWnd: HWND; aMsg: UINT; aWParam: WPARAM; aLParam: LPARAM): LRESULT; stdcall;
var
    r: TRect;
    m: HMONITOR;
    curKey: string;
    pureMove: Boolean;
begin
    // Custom system-menu items (Normal mode) arrive as WM_SYSCOMMAND; let the app handle
    // them and swallow the message. The low 4 bits are system-reserved (mask with $FFF0).
    if (aMsg = WM_SYSCOMMAND) and Assigned(gSysCmd) then
        if gSysCmd(aWParam and WPARAM($FFF0)) then
            Exit(0);
    if gTrackMode = wmNormal then
        case aMsg of
            WM_ENTERSIZEMOVE:
                begin
                    gInSizeMove := True;
                    gDragStartKey := monitorKeyForWindow(aWnd);
                    if GetWindowRect(aWnd, r) then
                    begin
                        gDragStartW := r.Right - r.Left;
                        gDragStartH := r.Bottom - r.Top;
                    end
                    else
                    begin
                        gDragStartW := 0;
                        gDragStartH := 0;
                    end;
                end;
            WM_EXITSIZEMOVE:
                begin
                    gInSizeMove := False;
                    // A PURE MOVE onto a different monitor that has a remembered layout
                    // snaps to it; a resize (even one crossing monitors) just saves — the
                    // user's freshly chosen size must never be discarded.
                    pureMove := GetWindowRect(aWnd, r)
                        and (r.Right - r.Left = gDragStartW)
                        and (r.Bottom - r.Top = gDragStartH);
                    curKey := monitorKeyForWindow(aWnd);
                    gCurMon := monitorHandleForWindow(aWnd);
                    if pureMove and (curKey <> '') and (curKey <> gDragStartKey)
                        and applySavedFor(aWnd, curKey) then
                        { snapped to the destination monitor's layout (and persisted) }
                    else
                        saveNow(aWnd);
                end;
            WM_SIZE:
                // Maximize / restore / keyboard-snap settle here OUTSIDE the modal loop;
                // mid-drag WM_SIZE (live resize, maximized-drag tear-off) must not save.
                if (gSuppress = 0) and (not gInSizeMove) and (not IsIconic(aWnd))
                    and ((aWParam = SIZE_MAXIMIZED) or (aWParam = SIZE_RESTORED)) then
                    saveNow(aWnd);
            WM_WINDOWPOSCHANGED:
                if (gSuppress = 0) and (not gInSizeMove) and (not IsIconic(aWnd)) then
                begin
                    m := monitorHandleForWindow(aWnd);
                    if (gCurMon <> 0) and (m <> gCurMon) then
                    begin
                        // Arrived on another monitor WITHOUT a drag (Win+Shift+Arrow or a
                        // programmatic move): same policy as a drag — restore that
                        // monitor's remembered layout, else record the new home.
                        gCurMon := m;
                        curKey := monitorKeyForWindow(aWnd);
                        if (curKey = '') or (not applySavedFor(aWnd, curKey)) then
                            saveNow(aWnd);
                    end
                    else
                    begin
                        gCurMon := m;
                        captureIfChanged(aWnd);   // keep the exit-flush cache fresh
                    end;
                end;
            WM_DISPLAYCHANGE:
                handleDisplayChange(aWnd);
        end
    else
        case aMsg of
            WM_ENTERSIZEMOVE:
                gInSizeMove := True;
            WM_EXITSIZEMOVE:
                begin
                    gInSizeMove := False;
                    if Assigned(gKioskDragEnd) then
                        gKioskDragEnd()
                    else
                        saveKioskRect(aWnd);
                end;
            WM_DISPLAYCHANGE:
                // Kiosk: re-fill the monitor when fullscreen; a restored kiosk window is
                // left where the OS put it (its saved rect must NOT be overwritten).
                if Assigned(gKioskDisplay) then
                    gKioskDisplay();
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
* setTrackMode — tells the tracker which mode's geometry to record (Normal -> per-monitor
* mon.<key>.* state, Kiosk -> kioskrect via the drag-end handler).
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
* setKioskDisplayChangeHandler — registers the AppBar's kiosk display-change handler.
*******************************************************************************}
procedure setKioskDisplayChangeHandler(aProc: TKioskDragEndProc);
begin
    gKioskDisplay := aProc;
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
* flushWindowState — on shutdown (or before leaving Normal mode), persist the tracked
* window's state: best-effort live refresh, then write the last-known-good cache — which
* survives an already-destroyed (X-close) or minimized window.
*******************************************************************************}
procedure flushWindowState();
begin
    if gTrackMode <> wmNormal then
        Exit;
    captureState(gTrackedWnd);
    persistState();
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
        setStateValue('kioskrect', rectStr(r));
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
