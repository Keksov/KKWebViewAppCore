unit AppMonitors;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

{ Small multi-monitor helpers (the FPC Windows unit lacks the monitor APIs). Used to
  remap the saved window geometry onto whatever monitor exists now — e.g. when the app
  was last on a 1280x1024 second monitor that is gone and it must reopen on the 4K
  laptop screen. Work areas (not full rects) are used so windows never cover the taskbar. }

interface

uses
    Windows;

{ Work area (excludes the taskbar) of the monitor most-overlapping aRect / holding aWnd,
  falling back to the primary monitor. }
function monitorWorkAreaForRect(const aRect: TRect): TRect;
function monitorWorkAreaForWindow(aWnd: HWND): TRect;

{ Full rectangle (rcMonitor) of the monitor holding aWnd (for fullscreen). }
function monitorFullRectForWindow(aWnd: HWND): TRect;

function rectsEqual(const aA, aB: TRect): Boolean;

implementation

const
    MONITOR_DEFAULTTOPRIMARY = 1;
    MONITOR_DEFAULTTONEAREST = 2;

type
    TMonInfo = record
        cbSize: DWORD;
        rcMonitor: TRect;
        rcWork: TRect;
        dwFlags: DWORD;
    end;

function MonitorFromWindow(aWnd: HWND; aFlags: DWORD): HMONITOR;
    stdcall; external 'user32' name 'MonitorFromWindow';
function MonitorFromRect(aRect: Pointer; aFlags: DWORD): HMONITOR;
    stdcall; external 'user32' name 'MonitorFromRect';
function GetMonitorInfoW(aMonitor: HMONITOR; aInfo: Pointer): BOOL;
    stdcall; external 'user32' name 'GetMonitorInfoW';

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

{*******************************************************************************
* infoOf — fills aInfo for aMonitor; False when the handle is invalid.
*******************************************************************************}
function infoOf(aMonitor: HMONITOR; out aInfo: TMonInfo): Boolean;
begin
    FillChar(aInfo, SizeOf(aInfo), 0);
    aInfo.cbSize := SizeOf(aInfo);
    Result := (aMonitor <> 0) and GetMonitorInfoW(aMonitor, @aInfo);
end;

{*******************************************************************************
* monitorWorkAreaForRect
*******************************************************************************}
function monitorWorkAreaForRect(const aRect: TRect): TRect;
var
    r: TRect;
    mi: TMonInfo;
begin
    r := aRect;
    if infoOf(MonitorFromRect(@r, MONITOR_DEFAULTTONEAREST), mi) then
        Result := mi.rcWork
    else
        Result := primaryWork;
end;

{*******************************************************************************
* monitorWorkAreaForWindow
*******************************************************************************}
function monitorWorkAreaForWindow(aWnd: HWND): TRect;
var
    mi: TMonInfo;
begin
    if infoOf(MonitorFromWindow(aWnd, MONITOR_DEFAULTTONEAREST), mi) then
        Result := mi.rcWork
    else
        Result := primaryWork;
end;

{*******************************************************************************
* monitorFullRectForWindow
*******************************************************************************}
function monitorFullRectForWindow(aWnd: HWND): TRect;
var
    mi: TMonInfo;
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

{*******************************************************************************
* rectsEqual
*******************************************************************************}
function rectsEqual(const aA, aB: TRect): Boolean;
begin
    Result := (aA.Left = aB.Left) and (aA.Top = aB.Top)
        and (aA.Right = aB.Right) and (aA.Bottom = aB.Bottom);
end;

end.
