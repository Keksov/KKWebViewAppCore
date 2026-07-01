unit AppProfile;

{$IFDEF FPC}
{$mode delphiunicode}
{$codepage utf8}
{$ENDIF}

{*******************************************************************************
* AppProfile
* Tiny high-resolution startup profiler. profMark records a (thread, label, QPC)
* sample; profFlush appends the run — per-step and cumulative deltas — to a log
* file. Disabled by default: every call is a cheap no-op until profEnable, so it
* costs nothing in normal runs. Enabled via the --profile / --profile-splash
* command-line flags.
*******************************************************************************}

interface

procedure profEnable();
function  profEnabled(): Boolean;
procedure profMark(const aLabel: string);
procedure profFlush(const aPath: string);

implementation

uses
    Windows, SysUtils;

const
    MAX_MARKS = 64;

type
    TProfMark = record
        tid:  DWORD;
        qpc:  Int64;
        text: string;
    end;

var
    gEnabled: Boolean = False;
    gLockOn:  Boolean = False;
    gCount:   Integer = 0;
    gFreq:    Int64 = 0;
    gPreMain: Double = -1;   // ms from process creation to profEnable (DLL load + RTL init)
    gLock:    TRTLCriticalSection;
    gMarks:   array[0..MAX_MARKS - 1] of TProfMark;

{*******************************************************************************
* profEnable
* Turns profiling on and captures the pre-main cost (process creation -> now).
*******************************************************************************}
procedure profEnable();
var
    ftCreate, ftExit, ftKernel, ftUser, ftNow: TFileTime;
    tCreate, tNow: Int64;
begin
    if gLockOn then
        Exit;
    InitializeCriticalSection(gLock);
    gLockOn := True;
    QueryPerformanceFrequency(gFreq);
    if gFreq = 0 then
        gFreq := 1;
    gEnabled := True;
    if GetProcessTimes(GetCurrentProcess, ftCreate, ftExit, ftKernel, ftUser) then
    begin
        GetSystemTimeAsFileTime(ftNow);
        tCreate := (Int64(ftCreate.dwHighDateTime) shl 32) or Cardinal(ftCreate.dwLowDateTime);
        tNow := (Int64(ftNow.dwHighDateTime) shl 32) or Cardinal(ftNow.dwLowDateTime);
        gPreMain := (tNow - tCreate) / 10000.0;   // 100ns units -> ms
    end;
end;

{*******************************************************************************
* profEnabled
*******************************************************************************}
function profEnabled(): Boolean;
begin
    Result := gEnabled;
end;

{*******************************************************************************
* profMark
*******************************************************************************}
procedure profMark(const aLabel: string);
var
    q: Int64;
begin
    if not gEnabled then
        Exit;
    QueryPerformanceCounter(q);
    EnterCriticalSection(gLock);
    try
        if gCount < MAX_MARKS then
        begin
            gMarks[gCount].tid := GetCurrentThreadId;
            gMarks[gCount].qpc := q;
            gMarks[gCount].text := aLabel;
            Inc(gCount);
        end;
    finally
        LeaveCriticalSection(gLock);
    end;
end;

{*******************************************************************************
* profFlush
* Appends the collected marks to aPath (per-step + cumulative ms).
*******************************************************************************}
procedure profFlush(const aPath: string);
var
    f:    TextFile;
    i:    Integer;
    base: Int64;
    prev: Int64;

    function ms(aFrom, aTo: Int64): Double;
    begin
        Result := (aTo - aFrom) * 1000.0 / gFreq;
    end;

begin
    if (not gEnabled) or (gCount = 0) then
        Exit;
    AssignFile(f, aPath);
    try
        if FileExists(aPath) then
            Append(f)
        else
            Rewrite(f);
    except
        Exit;
    end;
    try
        WriteLn(f, '');
        WriteLn(f, Format('=== AppCore startup profile @ %s ===',
            [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now)]));
        if gPreMain >= 0 then
            WriteLn(f, Format('  pre-main (process created -> profiling start): %8.1f ms   [DLL load + RTL init]',
                [gPreMain]));
        base := gMarks[0].qpc;
        prev := base;
        for i := 0 to gCount - 1 do
        begin
            WriteLn(f, Format('  %-22s step %8.1f ms   total %8.1f ms   [tid %d]',
                [gMarks[i].text, ms(prev, gMarks[i].qpc), ms(base, gMarks[i].qpc), gMarks[i].tid]));
            prev := gMarks[i].qpc;
        end;
    finally
        CloseFile(f);
    end;
end;

end.
