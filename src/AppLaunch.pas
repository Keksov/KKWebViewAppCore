unit AppLaunch;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

uses
  Windows, SysUtils;

{ Launches aCommand in a brand new console window with aWorkDir as the working
  directory. When aKeepOpen is True the console stays open after the command
  exits (cmd.exe /k) so dev-server logs/errors remain visible; otherwise it
  closes on exit (cmd.exe /c). aEnvPrefix, when set, is prepended inside the
  console (e.g. 'set PORT=4300&& '). Does not wait for the process. }
function LaunchInConsole(const aWorkDir, aCommand, aTitle, aEnvPrefix: string;
  aKeepOpen: Boolean): Boolean;

{ Runs aCommand in a new console, waits for it to finish, returns its exit code. }
function RunAndWait(const aWorkDir, aCommand, aTitle: string; out aExitCode: DWORD): Boolean;

{ Polls 127.0.0.1:aPort once per second until it accepts a connection or
  aTimeoutSec elapses. Returns True once the port is reachable. }
function WaitForPort(aPort, aTimeoutSec: Integer): Boolean;

implementation

uses
  WinSock2;

function BuildCmdLine(const aCommand, aTitle, aEnvPrefix: string; aKeepOpen: Boolean): UnicodeString;
var
  switch, title: string;
begin
  if aKeepOpen then switch := '/k' else switch := '/c';
  title := aTitle;
  if title = '' then title := 'AppCore';
  // start "title" is a cmd builtin; using `title` command keeps it simple.
  Result := UnicodeString(Format('cmd.exe %s "title %s & %s%s"',
    [switch, title, aEnvPrefix, aCommand]));
end;

function SpawnConsole(const aWorkDir: string; const aCmdLine: UnicodeString;
  aWait: Boolean; out aExitCode: DWORD): Boolean;
var
  si: STARTUPINFOW;
  pi: PROCESS_INFORMATION;
  cmdBuf: array of WideChar;
  workDirW: UnicodeString;
  pWorkDir: PWideChar;
begin
  Result := False;
  aExitCode := 0;

  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  FillChar(pi, SizeOf(pi), 0);

  SetLength(cmdBuf, Length(aCmdLine) + 1);
  if Length(aCmdLine) > 0 then
    Move(PWideChar(aCmdLine)^, cmdBuf[0], Length(aCmdLine) * SizeOf(WideChar));
  cmdBuf[Length(aCmdLine)] := #0;

  if aWorkDir <> '' then
  begin
    workDirW := UnicodeString(aWorkDir);
    pWorkDir := PWideChar(workDirW);
  end
  else
    pWorkDir := nil;

  if CreateProcessW(nil, @cmdBuf[0], nil, nil, False, CREATE_NEW_CONSOLE,
    nil, pWorkDir, @si, @pi) then
  begin
    if aWait then
    begin
      WaitForSingleObject(pi.hProcess, INFINITE);
      GetExitCodeProcess(pi.hProcess, aExitCode);
    end;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    Result := True;
  end;
end;

function LaunchInConsole(const aWorkDir, aCommand, aTitle, aEnvPrefix: string;
  aKeepOpen: Boolean): Boolean;
var
  dummy: DWORD;
begin
  Result := SpawnConsole(aWorkDir,
    BuildCmdLine(aCommand, aTitle, aEnvPrefix, aKeepOpen), False, dummy);
end;

function RunAndWait(const aWorkDir, aCommand, aTitle: string; out aExitCode: DWORD): Boolean;
begin
  Result := SpawnConsole(aWorkDir,
    BuildCmdLine(aCommand, aTitle, '', False), True, aExitCode);
end;

function WaitForPort(aPort, aTimeoutSec: Integer): Boolean;
var
  wsa: TWSAData;
  s: TSocket;
  addr: TSockAddrIn;
  attempt: Integer;
begin
  Result := False;
  if WSAStartup($0202, wsa) <> 0 then
    Exit;
  try
    for attempt := 0 to aTimeoutSec do
    begin
      s := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
      if s <> INVALID_SOCKET then
      begin
        FillChar(addr, SizeOf(addr), 0);
        addr.sin_family := AF_INET;
        addr.sin_port := htons(Word(aPort));
        addr.sin_addr.S_addr := htonl($7F000001); // 127.0.0.1
        if connect(s, PSockAddr(@addr), SizeOf(addr)) = 0 then
        begin
          closesocket(s);
          Exit(True);
        end;
        closesocket(s);
      end;
      Sleep(1000);
    end;
  finally
    WSACleanup;
  end;
end;

end.
