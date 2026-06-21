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
  console (e.g. 'set PORT=4300&& '). The process (and its child processes and
  console window) joins a kill-on-close job, so terminateProcessGroup brings
  the whole tree down. Does not wait for the process. }
function launchInConsole(const aWorkDir, aCommand, aTitle, aEnvPrefix: string;
    aKeepOpen: Boolean): Boolean;

{ Runs aCommand in a new console, waits for it to finish, returns its exit code. }
function runAndWait(const aWorkDir, aCommand, aTitle: string; out aExitCode: DWORD): Boolean;

{ Polls 127.0.0.1:aPort once per second until it accepts a connection or
  aTimeoutSec elapses. Returns True once the port is reachable. }
function waitForPort(aPort, aTimeoutSec: Integer): Boolean;

{ Kills every process launched through this unit (dev servers, their bun/node
  children and the console windows). Safe to call when nothing was launched. }
procedure terminateProcessGroup;

implementation

uses
    WinSock2;

const
    JobObjectExtendedLimitInformation = 9;
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = $00002000;

{$packrecords C}
type
    TJobBasicLimitInformation = record
        PerProcessUserTimeLimit: LARGE_INTEGER;
        PerJobUserTimeLimit: LARGE_INTEGER;
        LimitFlags: DWORD;
        MinimumWorkingSetSize: SIZE_T;
        MaximumWorkingSetSize: SIZE_T;
        ActiveProcessLimit: DWORD;
        Affinity: ULONG_PTR;
        PriorityClass: DWORD;
        SchedulingClass: DWORD;
    end;

    TIoCounters = record
        ReadOperationCount: QWord;
        WriteOperationCount: QWord;
        OtherOperationCount: QWord;
        ReadTransferCount: QWord;
        WriteTransferCount: QWord;
        OtherTransferCount: QWord;
    end;

    TJobExtendedLimitInformation = record
        BasicLimitInformation: TJobBasicLimitInformation;
        IoInfo: TIoCounters;
        ProcessMemoryLimit: SIZE_T;
        JobMemoryLimit: SIZE_T;
        PeakProcessMemoryUsed: SIZE_T;
        PeakJobMemoryUsed: SIZE_T;
    end;
{$packrecords DEFAULT}

function CreateJobObjectW(aAttributes: Pointer; aName: PWideChar): HANDLE;
    stdcall; external 'kernel32' name 'CreateJobObjectW';
function SetInformationJobObject(aJob: HANDLE; aInfoClass: DWORD; aInfo: Pointer; aInfoLen: DWORD): BOOL;
    stdcall; external 'kernel32' name 'SetInformationJobObject';
function AssignProcessToJobObject(aJob, aProcess: HANDLE): BOOL;
    stdcall; external 'kernel32' name 'AssignProcessToJobObject';
function TerminateJobObject(aJob: HANDLE; aExitCode: UINT): BOOL;
    stdcall; external 'kernel32' name 'TerminateJobObject';

var
    gJob: HANDLE = 0;

{*******************************************************************************
* ensureJob
* Lazily creates the kill-on-close job that owns all launched processes.
*******************************************************************************}
function ensureJob: HANDLE;
var
    info: TJobExtendedLimitInformation;
begin
    if gJob = 0 then
    begin
        gJob := CreateJobObjectW(nil, nil);
        if gJob <> 0 then
        begin
            FillChar(info, SizeOf(info), 0);
            info.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(gJob, JobObjectExtendedLimitInformation,
                @info, SizeOf(info));
        end;
    end;
    Result := gJob;
end;

{*******************************************************************************
* buildCmdLine
*******************************************************************************}
function buildCmdLine(const aCommand, aTitle, aEnvPrefix: string; aKeepOpen: Boolean): UnicodeString;
var
    title, switch: string;
begin
    if aKeepOpen then switch := '/k' else switch := '/c';
    title := aTitle;
    if title = '' then title := 'AppCore';
    Result := UnicodeString(Format('cmd.exe %s "title %s & %s%s"',
        [switch, title, aEnvPrefix, aCommand]));
end;

{*******************************************************************************
* spawnConsole
* Starts a child in a new console, assigned to the kill-on-close job. The
* process is created suspended so it is in the job before it spawns children.
*******************************************************************************}
function spawnConsole(const aWorkDir: string; const aCmdLine: UnicodeString;
    aWait: Boolean; out aExitCode: DWORD): Boolean;
var
    job: HANDLE;
    si: STARTUPINFOW;
    pWorkDir: PWideChar;
    pi: PROCESS_INFORMATION;
    workDirW: UnicodeString;
    cmdBuf: array of WideChar;
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

    if CreateProcessW(nil, @cmdBuf[0], nil, nil, False,
        CREATE_NEW_CONSOLE or CREATE_SUSPENDED, nil, pWorkDir, @si, @pi) then
    begin
        job := ensureJob;
        if job <> 0 then
            AssignProcessToJobObject(job, pi.hProcess);
        ResumeThread(pi.hThread);
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

{*******************************************************************************
* launchInConsole
*******************************************************************************}
function launchInConsole(const aWorkDir, aCommand, aTitle, aEnvPrefix: string;
    aKeepOpen: Boolean): Boolean;
var
    dummy: DWORD;
begin
    Result := spawnConsole(aWorkDir,
        buildCmdLine(aCommand, aTitle, aEnvPrefix, aKeepOpen), False, dummy);
end;

{*******************************************************************************
* runAndWait
*******************************************************************************}
function runAndWait(const aWorkDir, aCommand, aTitle: string; out aExitCode: DWORD): Boolean;
begin
    Result := spawnConsole(aWorkDir,
        buildCmdLine(aCommand, aTitle, '', False), True, aExitCode);
end;

{*******************************************************************************
* terminateProcessGroup
*******************************************************************************}
procedure terminateProcessGroup;
begin
    if gJob <> 0 then
    begin
        TerminateJobObject(gJob, 0);
        CloseHandle(gJob);
        gJob := 0;
    end;
end;

{*******************************************************************************
* waitForPort
*******************************************************************************}
function waitForPort(aPort, aTimeoutSec: Integer): Boolean;
var
    s: TSocket;
    wsa: TWSAData;
    attempt: Integer;
    addr: TSockAddrIn;
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
