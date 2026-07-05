unit AppWindowMode;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

uses
    Windows;

type
    { The window's display mode. Kiosk = borderless WS_POPUP with the floating AppBar
      (today's behavior). Normal = a standard OS-decorated window (title bar, system
      menu, minimize/maximize/close). Persisted as the 'dispmode' state key (WN-D1). }
    TWindowMode = (wmKiosk, wmNormal);

{ Bridges to/from the persisted 'dispmode' string ('kiosk' | 'normal'). }
function windowModeToString(aMode: TWindowMode): string;
function windowModeFromString(const aText: string; aDefault: TWindowMode): TWindowMode;

{ Applies the Normal (OS-decorated) window style to aWnd: WS_OVERLAPPEDWINDOW with a
  frame change. Position + show (normal/maximized, WN-D7) are done by the caller via
  AppWindowState.applyNormalPlacement. }
procedure applyNormalStyle(aWnd: HWND);

{ Applies the borderless kiosk style (WS_POPUP) to aWnd. The rich fullscreen/monitor
  geometry is (re)asserted by the AppBar; this just swaps the frame off. }
procedure applyKioskStyle(aWnd: HWND);

implementation

uses
    SysUtils;

const
    MODE_KIOSK  = 'kiosk';
    MODE_NORMAL = 'normal';

{*******************************************************************************
* windowModeToString
*******************************************************************************}
function windowModeToString(aMode: TWindowMode): string;
begin
    if aMode = wmNormal then
        Result := MODE_NORMAL
    else
        Result := MODE_KIOSK;
end;

{*******************************************************************************
* windowModeFromString
*******************************************************************************}
function windowModeFromString(const aText: string; aDefault: TWindowMode): TWindowMode;
var
    s: string;
begin
    s := LowerCase(Trim(aText));
    if s = MODE_NORMAL then
        Result := wmNormal
    else if s = MODE_KIOSK then
        Result := wmKiosk
    else
        Result := aDefault;
end;

{*******************************************************************************
* applyNormalStyle
* Swaps aWnd to a standard OS-decorated window frame. The caller then positions and
* shows it via AppWindowState.applyNormalPlacement (which honours the saved normal/
* maximized state).
*******************************************************************************}
procedure applyNormalStyle(aWnd: HWND);
begin
    SetWindowLongW(aWnd, GWL_STYLE, Integer(WS_OVERLAPPEDWINDOW or WS_VISIBLE));
    SetWindowPos(aWnd, 0, 0, 0, 0, 0,
        SWP_FRAMECHANGED or SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
end;

{*******************************************************************************
* applyKioskStyle
* Swaps aWnd back to the borderless kiosk frame. The AppBar re-asserts the actual
* fullscreen/restored monitor geometry once it is shown.
*******************************************************************************}
procedure applyKioskStyle(aWnd: HWND);
begin
    SetWindowLongW(aWnd, GWL_STYLE, Integer(WS_POPUP or WS_VISIBLE));
    SetWindowPos(aWnd, 0, 0, 0, 0, 0,
        SWP_FRAMECHANGED or SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
end;

end.
