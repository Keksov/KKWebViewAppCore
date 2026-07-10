unit AppMonitors;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

{ Multi-monitor helpers (the FPC Windows unit lacks the monitor APIs). Used to remap the
  saved window geometry across display changes and to identify monitors so per-monitor
  window state can be remembered. Work areas (not full rects) are used so windows never
  cover the taskbar. }

interface

uses
    Windows;

{ Work area (excludes the taskbar) of the monitor most-overlapping aRect / holding aWnd,
  falling back to the primary monitor. }
function monitorWorkAreaForRect(const aRect: TRect): TRect;
function monitorWorkAreaForWindow(aWnd: HWND): TRect;

{ Full rectangle (rcMonitor) of the monitor holding aWnd (for fullscreen). }
function monitorFullRectForWindow(aWnd: HWND): TRect;

function primaryWorkArea(): TRect;
function rectsEqual(const aA, aB: TRect): Boolean;

{ A stable key identifying the physical monitor holding aWnd / nearest aRect, derived from
  the EDID device-interface id (manufacturer + product + connector UID), hashed. Survives
  disconnect/reconnect and reboot; distinguishes even identical models by connector. Empty
  string only if the monitor cannot be resolved. }
function monitorKeyForWindow(aWnd: HWND): string;
function monitorKeyForRect(const aRect: TRect): string;

{ Work area of the currently-connected monitor whose key = aKey, if present. }
function findMonitorWorkByKey(const aKey: string; out aWork: TRect): Boolean;

implementation

uses
    SysUtils;

const
    MONITOR_DEFAULTTONEAREST = 2;
    EDD_GET_DEVICE_INTERFACE_NAME = $1;

type
    TMonInfoEx = record
        cbSize: DWORD;
        rcMonitor: TRect;
        rcWork: TRect;
        dwFlags: DWORD;
        szDevice: array[0..31] of WideChar;
    end;

    TDisplayDeviceW = record
        cb: DWORD;
        DeviceName: array[0..31] of WideChar;
        DeviceString: array[0..127] of WideChar;
        StateFlags: DWORD;
        DeviceID: array[0..127] of WideChar;
        DeviceKey: array[0..127] of WideChar;
    end;

    TMonitorEnumProc = function(aMon: HMONITOR; aDC: HDC; aRc: PRect; aData: LPARAM): BOOL; stdcall;

function MonitorFromWindow(aWnd: HWND; aFlags: DWORD): HMONITOR;
    stdcall; external 'user32' name 'MonitorFromWindow';
function MonitorFromRect(aRect: Pointer; aFlags: DWORD): HMONITOR;
    stdcall; external 'user32' name 'MonitorFromRect';
function GetMonitorInfoW(aMonitor: HMONITOR; aInfo: Pointer): BOOL;
    stdcall; external 'user32' name 'GetMonitorInfoW';
function EnumDisplayDevicesW(aDevice: PWideChar; aDevNum: DWORD;
    var aDisplayDevice: TDisplayDeviceW; aFlags: DWORD): BOOL;
    stdcall; external 'user32' name 'EnumDisplayDevicesW';
function EnumDisplayMonitors(aDC: HDC; aClip: PRect; aProc: TMonitorEnumProc; aData: LPARAM): BOOL;
    stdcall; external 'user32' name 'EnumDisplayMonitors';

var
    gWantKey: string;      // findMonitorWorkByKey scratch (startup is single-threaded)
    gGotWork: TRect;
    gGotOk: Boolean;

{*******************************************************************************
* primaryWork — work area of the primary monitor, from system metrics (fallback).
*******************************************************************************}
function primaryWork(): TRect;
begin
    if not SystemParametersInfoW(SPI_GETWORKAREA, 0, @Result, 0) then
    begin
        Result.Left := 0;
        Result.Top := 0;
        Result.Right := GetSystemMetrics(SM_CXSCREEN);
        Result.Bottom := GetSystemMetrics(SM_CYSCREEN);
    end;
end;

function primaryWorkArea(): TRect;
begin
    Result := primaryWork;
end;

{*******************************************************************************
* infoOf — fills aInfo for aMonitor; False when the handle is invalid.
*******************************************************************************}
function infoOf(aMonitor: HMONITOR; out aInfo: TMonInfoEx): Boolean;
begin
    FillChar(aInfo, SizeOf(aInfo), 0);
    aInfo.cbSize := SizeOf(aInfo);
    Result := (aMonitor <> 0) and GetMonitorInfoW(aMonitor, @aInfo);
end;

{*******************************************************************************
* monitorWorkAreaForRect / ForWindow / monitorFullRectForWindow
*******************************************************************************}
function monitorWorkAreaForRect(const aRect: TRect): TRect;
var
    r: TRect;
    mi: TMonInfoEx;
begin
    r := aRect;
    if infoOf(MonitorFromRect(@r, MONITOR_DEFAULTTONEAREST), mi) then
        Result := mi.rcWork
    else
        Result := primaryWork;
end;

function monitorWorkAreaForWindow(aWnd: HWND): TRect;
var
    mi: TMonInfoEx;
begin
    if infoOf(MonitorFromWindow(aWnd, MONITOR_DEFAULTTONEAREST), mi) then
        Result := mi.rcWork
    else
        Result := primaryWork;
end;

function monitorFullRectForWindow(aWnd: HWND): TRect;
var
    mi: TMonInfoEx;
begin
    if infoOf(MonitorFromWindow(aWnd, MONITOR_DEFAULTTONEAREST), mi) then
        Result := mi.rcMonitor
    else
    begin
        Result.Left := 0;
        Result.Top := 0;
        Result.Right := GetSystemMetrics(SM_CXSCREEN);
        Result.Bottom := GetSystemMetrics(SM_CYSCREEN);
    end;
end;

function rectsEqual(const aA, aB: TRect): Boolean;
begin
    Result := (aA.Left = aB.Left) and (aA.Top = aB.Top)
        and (aA.Right = aB.Right) and (aA.Bottom = aB.Bottom);
end;

{*******************************************************************************
* stableMonId — the stable part of a device-interface id (everything between DISPLAY# and
* the trailing GUID), e.g. LEN8AB1#5&...&UID256 = EDID model + connector. Returns the input
* unchanged when it is not an interface path.
*******************************************************************************}
function stableMonId(const aStr: string): string;
var
    a, b, i: Integer;
begin
    Result := aStr;
    a := Pos('DISPLAY#', aStr);
    if a = 0 then
        Exit;
    a := a + Length('DISPLAY#');
    b := 0;
    for i := a to Length(aStr) - 1 do
        if (aStr[i] = '#') and (aStr[i + 1] = '{') then
        begin
            b := i;
            Break;
        end;
    if b = 0 then
        b := Length(aStr) + 1;
    Result := Copy(aStr, a, b - a);
end;

{*******************************************************************************
* fnvHex — 8-hex-digit FNV-1a hash of the lowercased string (compact stable key).
*******************************************************************************}
function fnvHex(const aStr: string): string;
var
    u: UnicodeString;
    h: LongWord;
    i: Integer;
begin
    u := LowerCase(UnicodeString(aStr));
    h := LongWord(2166136261);
    for i := 1 to Length(u) do
    begin
        h := h xor LongWord(Ord(u[i]));
        h := h * LongWord(16777619);
    end;
    Result := IntToHex(h, 8);
end;

{*******************************************************************************
* monitorKeyForMonitor — "m<fnv>" from the monitor's EDID device-interface id, or the
* adapter name as a weak fallback.
*******************************************************************************}
function monitorKeyForMonitor(aMonitor: HMONITOR): string;
var
    mi: TMonInfoEx;
    dd: TDisplayDeviceW;
    id: string;
begin
    Result := '';
    if not infoOf(aMonitor, mi) then
        Exit;
    id := '';
    FillChar(dd, SizeOf(dd), 0);
    dd.cb := SizeOf(dd);
    if EnumDisplayDevicesW(@mi.szDevice[0], 0, dd, EDD_GET_DEVICE_INTERFACE_NAME) then
        id := stableMonId(string(PWideChar(@dd.DeviceID[0])));
    if id = '' then
        id := string(PWideChar(@mi.szDevice[0]));   // \\.\DISPLAYn (unstable, last resort)
    if id <> '' then
        Result := 'm' + fnvHex(id);
end;

function monitorKeyForWindow(aWnd: HWND): string;
begin
    Result := monitorKeyForMonitor(MonitorFromWindow(aWnd, MONITOR_DEFAULTTONEAREST));
end;

function monitorKeyForRect(const aRect: TRect): string;
var
    r: TRect;
begin
    r := aRect;
    Result := monitorKeyForMonitor(MonitorFromRect(@r, MONITOR_DEFAULTTONEAREST));
end;

{*******************************************************************************
* findByKeyProc / findMonitorWorkByKey — locate the current monitor with a given key.
*******************************************************************************}
function findByKeyProc(aMon: HMONITOR; aDC: HDC; aRc: PRect; aData: LPARAM): BOOL; stdcall;
var
    mi: TMonInfoEx;
begin
    Result := True;   // keep enumerating
    if gGotOk then
        Exit;
    if monitorKeyForMonitor(aMon) = gWantKey then
        if infoOf(aMon, mi) then
        begin
            gGotWork := mi.rcWork;
            gGotOk := True;
        end;
end;

function findMonitorWorkByKey(const aKey: string; out aWork: TRect): Boolean;
begin
    Result := False;
    if aKey = '' then
        Exit;
    gWantKey := aKey;
    gGotOk := False;
    EnumDisplayMonitors(0, nil, @findByKeyProc, 0);
    Result := gGotOk;
    if Result then
        aWork := gGotWork;
end;

end.
