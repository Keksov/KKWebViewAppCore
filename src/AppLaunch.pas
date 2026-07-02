unit AppLaunch;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

uses
    Windows, SysUtils;

type
    { One console to open (used by launchConsoleTabs). }
    TConsoleSpec = record
        WorkDir: string;
        Command: string;
        Title: string;
        EnvPrefix: string;
    end;

{ Launches aCommand in a brand new console window with aWorkDir as the working
  directory. When aKeepOpen is True the console stays open after the command
  exits (cmd.exe /k) so dev-server logs/errors remain visible; otherwise it
  closes on exit (cmd.exe /c). aEnvPrefix, when set, is prepended inside the
  console (e.g. 'set PORT=4300&& '). The process (and its child processes and
  console window) joins a kill-on-close job, so terminateProcessGroup brings
  the whole tree down. Does not wait for the process. }
function launchInConsole(const aWorkDir, aCommand, aTitle, aEnvPrefix: string;
    aKeepOpen: Boolean): Boolean;

{ True on Windows 11 (build >= 22000) with Windows Terminal (wt.exe) present, i.e.
  when launchConsoleTabs can open the consoles as tabs of a single window. }
function terminalTabsAvailable(): Boolean;

{ Opens each spec as a tab in ONE new Windows Terminal window (cmd /k, so the tab
  stays open for logs). Because Windows Terminal hosts the shells under its own
  process (out of our kill-on-close job), the caller must registerCleanupPort for
  the ports the tab servers listen on, so terminateProcessGroup can stop them. }
function launchConsoleTabs(const aSpecs: array of TConsoleSpec): Boolean;

{ Records a TCP port whose listener (and its owning terminal tab) should be killed
  by terminateProcessGroup. Used for tab-hosted dev servers the job cannot reach. }
procedure registerCleanupPort(aPort: Integer);

{ Runs aCommand in a new console, waits for it to finish, returns its exit code. }
function runAndWait(const aWorkDir, aCommand, aTitle: string; out aExitCode: DWORD): Boolean;

{ Polls 127.0.0.1:aPort once per second until it accepts a connection or
  aTimeoutSec elapses. Returns True once the port is reachable. }
function waitForPort(aPort, aTimeoutSec: Integer): Boolean;

{ Returns the first bindable 127.0.0.1 port at or after aStartPort (scanning up to
  aMaxTries ports). Lets several AppCore apps coexist instead of fighting over one
  fixed port. Falls back to aStartPort if none is found. }
function findFreePort(aStartPort, aMaxTries: Integer): Integer;

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

const
    TCP_TABLE_OWNER_PID_LISTENER = 3;

type
    { RtlGetVersion reports the true OS version regardless of the exe manifest
      (unlike GetVersionEx / the CurrentVersion ProductName string). }
    TRtlOsVersionInfoW = record
        dwOSVersionInfoSize: DWORD;
        dwMajorVersion: DWORD;
        dwMinorVersion: DWORD;
        dwBuildNumber: DWORD;
        dwPlatformId: DWORD;
        szCSDVersion: array[0..127] of WideChar;
    end;

    TMibTcpRowOwnerPid = record
        dwState: DWORD;
        dwLocalAddr: DWORD;
        dwLocalPort: DWORD;
        dwRemoteAddr: DWORD;
        dwRemotePort: DWORD;
        dwOwningPid: DWORD;
    end;
    PMibTcpRowOwnerPid = ^TMibTcpRowOwnerPid;

function RtlGetVersion(var aInfo: TRtlOsVersionInfoW): LongInt; stdcall;
    external 'ntdll' name 'RtlGetVersion';
function GetExtendedTcpTable(aTable: Pointer; var aSize: DWORD; aOrder: BOOL;
    aAf: ULONG; aClass: DWORD; aReserved: ULONG): DWORD; stdcall;
    external 'iphlpapi' name 'GetExtendedTcpTable';

var
    gJob: HANDLE = 0;
    gCleanupPorts: array of Integer;
    gTempBatches: array of string;   // per-tab .cmd files to delete on exit

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
* terminalTabsAvailable
* True on Windows 11 (build >= 22000) with Windows Terminal (wt.exe) present.
*******************************************************************************}
function wtPath(): string;
begin
    Result := '';
    Result := GetEnvironmentVariable('LOCALAPPDATA');
    if Result = '' then
        Exit;
    Result := IncludeTrailingPathDelimiter(Result) + 'Microsoft\WindowsApps\wt.exe';
    if not FileExists(Result) then
        Result := '';
end;

function terminalTabsAvailable(): Boolean;
var
    vi: TRtlOsVersionInfoW;
    win11: Boolean;
begin
    FillChar(vi, SizeOf(vi), 0);
    vi.dwOSVersionInfoSize := SizeOf(vi);
    win11 := (RtlGetVersion(vi) = 0)
        and ((vi.dwMajorVersion > 10)
             or ((vi.dwMajorVersion = 10) and (vi.dwBuildNumber >= 22000)));
    Result := win11 and (wtPath() <> '');
end;

{*******************************************************************************
* launchConsoleTabs
* Writes a small .cmd per console (title + cd + env + command, so there is no
* quote nesting to fight through wt/cmd) and opens them as tabs of ONE new
* Windows Terminal window in a single `wt -w new nt ... ; nt ...` invocation.
*******************************************************************************}
function launchConsoleTabs(const aSpecs: array of TConsoleSpec): Boolean;
var
    wt, cl, batch: string;
    i, pid: Integer;
    f: TextFile;
    si: STARTUPINFOW;
    pi: PROCESS_INFORMATION;
    clW: UnicodeString;
    cmdBuf: array of WideChar;
begin
    Result := False;
    wt := wtPath();
    if (wt = '') or (Length(aSpecs) = 0) then
        Exit;
    pid := GetCurrentProcessId;
    cl := '"' + wt + '" -w new';
    for i := Low(aSpecs) to High(aSpecs) do
    begin
        batch := IncludeTrailingPathDelimiter(GetTempDir)
            + Format('kkdev-%d-%d.cmd', [pid, i]);
        AssignFile(f, batch);
        try
            Rewrite(f);
            WriteLn(f, '@echo off');
            WriteLn(f, 'title ' + aSpecs[i].Title);
            if aSpecs[i].WorkDir <> '' then
                WriteLn(f, 'cd /d "' + aSpecs[i].WorkDir + '"');
            WriteLn(f, aSpecs[i].EnvPrefix + aSpecs[i].Command);
            CloseFile(f);
        except
            Exit;
        end;
        SetLength(gTempBatches, Length(gTempBatches) + 1);
        gTempBatches[High(gTempBatches)] := batch;
        if i > Low(aSpecs) then
            cl := cl + ' ;';
        cl := cl + ' nt --title "' + aSpecs[i].Title + '" cmd /k "' + batch + '"';
    end;

    clW := UnicodeString(cl);
    SetLength(cmdBuf, Length(clW) + 1);
    if Length(clW) > 0 then
        Move(PWideChar(clW)^, cmdBuf[0], Length(clW) * SizeOf(WideChar));
    cmdBuf[Length(clW)] := #0;

    FillChar(si, SizeOf(si), 0);
    si.cb := SizeOf(si);
    FillChar(pi, SizeOf(pi), 0);
    // wt.exe forwards to Windows Terminal and exits immediately; no console of its own.
    if CreateProcessW(nil, @cmdBuf[0], nil, nil, False, CREATE_NO_WINDOW,
        nil, nil, @si, @pi) then
    begin
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        Result := True;
    end;
end;

{*******************************************************************************
* registerCleanupPort
*******************************************************************************}
procedure registerCleanupPort(aPort: Integer);
begin
    SetLength(gCleanupPorts, Length(gCleanupPorts) + 1);
    gCleanupPorts[High(gCleanupPorts)] := aPort;
end;

{*******************************************************************************
* portOwnerPid — PID of the process LISTENING on 127.0.0.1/0.0.0.0:aPort, or 0.
*******************************************************************************}
function portOwnerPid(aPort: Integer): DWORD;
var
    size: DWORD;
    buf: PByte;
    p: PByte;
    n, i: DWORD;
    row: PMibTcpRowOwnerPid;
    localPort: Word;
begin
    Result := 0;
    size := 0;
    GetExtendedTcpTable(nil, size, False, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
    if size = 0 then
        Exit;
    GetMem(buf, size);
    try
        if GetExtendedTcpTable(buf, size, False, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0) <> 0 then
            Exit;
        n := PDWORD(buf)^;
        p := buf + SizeOf(DWORD);
        for i := 0 to n - 1 do
        begin
            row := PMibTcpRowOwnerPid(p);
            localPort := ((row^.dwLocalPort and $FF) shl 8) or ((row^.dwLocalPort shr 8) and $FF);
            if localPort = Word(aPort) then
            begin
                Result := row^.dwOwningPid;
                Exit;
            end;
            Inc(p, SizeOf(TMibTcpRowOwnerPid));
        end;
    finally
        FreeMem(buf);
    end;
end;

{*******************************************************************************
* procParent — parent PID of aPid; aName returns the parent's exe file name.
*******************************************************************************}
function procParent(aPid: DWORD; out aName: string): DWORD;
var
    snap: HANDLE;
    pe: PROCESSENTRY32;
begin
    Result := 0;
    aName := '';
    snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if snap = INVALID_HANDLE_VALUE then
        Exit;
    try
        pe.dwSize := SizeOf(pe);
        if Process32First(snap, pe) then
            repeat
                if pe.th32ProcessID = aPid then
                begin
                    Result := pe.th32ParentProcessID;
                    Break;
                end;
            until not Process32Next(snap, pe);
        if Result = 0 then
            Exit;
        pe.dwSize := SizeOf(pe);
        if Process32First(snap, pe) then
            repeat
                if pe.th32ProcessID = Result then
                begin
                    aName := StrPas(pe.szExeFile);
                    Break;
                end;
            until not Process32Next(snap, pe);
    finally
        CloseHandle(snap);
    end;
end;

{*******************************************************************************
* killTree — terminates aRoot and all its descendant processes.
*******************************************************************************}
procedure killTree(aRoot: DWORD);
var
    snap: HANDLE;
    pe: PROCESSENTRY32;
    pids, ppids: array of DWORD;
    cnt: Integer;

    procedure killRec(aPid: DWORD);
    var
        j: Integer;
        h: HANDLE;
    begin
        for j := 0 to cnt - 1 do
            if (ppids[j] = aPid) and (pids[j] <> aPid) then
                killRec(pids[j]);
        h := OpenProcess(PROCESS_TERMINATE, False, aPid);
        if h <> 0 then
        begin
            TerminateProcess(h, 0);
            CloseHandle(h);
        end;
    end;

begin
    if aRoot = 0 then
        Exit;
    snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if snap = INVALID_HANDLE_VALUE then
        Exit;
    cnt := 0;
    pe.dwSize := SizeOf(pe);
    if Process32First(snap, pe) then
        repeat
            SetLength(pids, cnt + 1);
            SetLength(ppids, cnt + 1);
            pids[cnt] := pe.th32ProcessID;
            ppids[cnt] := pe.th32ParentProcessID;
            Inc(cnt);
        until not Process32Next(snap, pe);
    CloseHandle(snap);
    killRec(aRoot);
end;

{*******************************************************************************
* shellAncestor — walks up from aPid to the nearest cmd.exe ancestor (the tab's
* shell), or 0 if none within a few levels. The port listener is typically a
* child of bun, which is a child of the tab's cmd.exe, so we must climb past bun.
*******************************************************************************}
function shellAncestor(aPid: DWORD): DWORD;
var
    cur, par: DWORD;
    nm: string;
    depth: Integer;
begin
    Result := 0;
    cur := aPid;
    for depth := 0 to 5 do
    begin
        par := procParent(cur, nm);
        if par = 0 then
            Break;
        if SameText(nm, 'cmd.exe') then
        begin
            Result := par;
            Exit;
        end;
        cur := par;
    end;
end;

{*******************************************************************************
* killRegisteredPorts — stops tab-hosted dev servers the job cannot reach: for
* each registered port, kill the tab's cmd.exe tree (which closes the terminal
* tab AND stops bun + its dev server); if no cmd ancestor is found, kill the
* listener's own tree.
*******************************************************************************}
procedure killRegisteredPorts();
var
    i: Integer;
    pid, shell: DWORD;
begin
    for i := 0 to High(gCleanupPorts) do
    begin
        pid := portOwnerPid(gCleanupPorts[i]);
        if pid = 0 then
            Continue;
        shell := shellAncestor(pid);
        if shell <> 0 then
            killTree(shell)
        else
            killTree(pid);
    end;
    SetLength(gCleanupPorts, 0);
end;

{*******************************************************************************
* terminateProcessGroup
*******************************************************************************}
procedure terminateProcessGroup;
var
    i: Integer;
begin
    // Tab-hosted dev servers (Windows Terminal owns them, outside our job).
    killRegisteredPorts();
    // Separate-window consoles and their children (the fallback path).
    if gJob <> 0 then
    begin
        TerminateJobObject(gJob, 0);
        CloseHandle(gJob);
        gJob := 0;
    end;
    // Remove the per-tab .cmd helpers we wrote to TEMP.
    for i := 0 to High(gTempBatches) do
        DeleteFileW(PWideChar(UnicodeString(gTempBatches[i])));
    SetLength(gTempBatches, 0);
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

{*******************************************************************************
* portInUse
* True when something is already listening on 127.0.0.1:aPort. Uses connect()
* rather than a bind() probe: dev servers (vite/quasar) bind 0.0.0.0 with
* SO_REUSEADDR, so an overlapping bind to 127.0.0.1 wrongly succeeds — but a
* connect reliably reports a live listener regardless.
*
* The connect is NON-BLOCKING with a short timeout: a live loopback listener
* accepts within a millisecond, so it is detected fast; a free port that is not
* refused instantly (some security/firewall filters delay the RST on loopback by
* ~2s) times out quickly and is correctly treated as free — instead of stalling
* seconds per probe on the startup path.
*******************************************************************************}
function portInUse(aPort: Integer): Boolean;
const
    PROBE_MS = 150;
var
    s: TSocket;
    addr: TSockAddrIn;
    nonBlock: u_long;
    wfds: TFDSet;
    tv: TTimeVal;
    sel: LongInt;
    soErr: LongInt;
    soLen: LongInt;
begin
    Result := False;
    s := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if s = INVALID_SOCKET then
        Exit;
    try
        nonBlock := 1;
        ioctlsocket(s, LongInt(FIONBIO), nonBlock);

        FillChar(addr, SizeOf(addr), 0);
        addr.sin_family := AF_INET;
        addr.sin_port := htons(Word(aPort));
        addr.sin_addr.S_addr := htonl($7F000001); // 127.0.0.1

        if connect(s, PSockAddr(@addr), SizeOf(addr)) = 0 then
            Exit(True);                               // connected immediately
        if WSAGetLastError <> WSAEWOULDBLOCK then
            Exit(False);                              // refused/error now => free

        FD_ZERO(wfds);
        FD_SET(s, wfds);
        tv.tv_sec := 0;
        tv.tv_usec := PROBE_MS * 1000;
        sel := select(0, nil, @wfds, nil, @tv);
        if sel <= 0 then
            Exit(False);                              // timeout => treat as free

        // Writable: distinguish a real connection (SO_ERROR = 0) from a refusal.
        soErr := 0;
        soLen := SizeOf(soErr);
        if getsockopt(s, SOL_SOCKET, SO_ERROR, PAnsiChar(@soErr), soLen) = 0 then
            Result := soErr = 0;
    finally
        closesocket(s);
    end;
end;

{*******************************************************************************
* findFreePort
*******************************************************************************}
function findFreePort(aStartPort, aMaxTries: Integer): Integer;
var
    port: Integer;
    tries: Integer;
    wsa: TWSAData;
begin
    Result := aStartPort;
    if WSAStartup($0202, wsa) <> 0 then
        Exit;
    try
        port := aStartPort;
        for tries := 0 to aMaxTries - 1 do
        begin
            if not portInUse(port) then
                Exit(port);
            Inc(port);
        end;
    finally
        WSACleanup;
    end;
end;

end.
