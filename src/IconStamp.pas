program IconStamp;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

{ Stamps an .ico into an existing .exe as its application icon (overlay-safe), so
  Explorer / the taskbar / pinned shortcuts show the right icon without running the
  program. Intended as a post-copy step:

      IconStamp <target.exe> <icon.ico>

  with that deployment's AppCore.ico. The core lives in IconStamper (shared with the
  self-update). The target exe must not be running. }

uses
    SysUtils, IconStamper;

begin
    if ParamCount < 2 then
    begin
        Writeln('Usage: IconStamp <target.exe> <icon.ico>');
        Halt(2);
    end;
    if not stampExeIcon(ParamStr(1), ParamStr(2)) then
    begin
        Writeln('ERROR: failed to stamp icon into: ', ParamStr(1));
        Halt(1);
    end;
    Writeln('OK: icon written to ', ParamStr(1));
end.
