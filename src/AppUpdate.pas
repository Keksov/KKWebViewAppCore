unit AppUpdate;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

interface

{ Self-update. When aSourceDir holds a newer AppMain.exe / libwebview.dll than the
  running copy, swaps them in (rename the running file aside to .old — allowed for a
  loaded image — then copy the new one) and relaunches with the identical command
  line. Returns True once a relaunch has been started; the caller must then exit
  immediately. Leftover .old files from a previous update are removed (best effort)
  on every call. }
function applyExeAutoUpdate(const aSourceDir: string): Boolean;

implementation

uses
    Windows, SysUtils, IconStamper;

const
    UPDATE_FILES: array[0..1] of string = ('AppMain.exe', 'libwebview.dll');

{*******************************************************************************
* lastWriteTime
* Reads the last-write time of aPath as a 64-bit FILETIME value.
*******************************************************************************}
function lastWriteTime(const aPath: string; out aTime: Int64): Boolean;
var
    data: TWin32FileAttributeData;
begin
    Result := GetFileAttributesExW(PWideChar(aPath), GetFileExInfoStandard, @data);
    if Result then
        aTime := (Int64(data.ftLastWriteTime.dwHighDateTime) shl 32)
                 or Int64(Cardinal(data.ftLastWriteTime.dwLowDateTime));
end;

{*******************************************************************************
* sourceIsNewer
* True when aSrc exists and is strictly newer than aDst (or aDst is missing).
*******************************************************************************}
function sourceIsNewer(const aSrc, aDst: string): Boolean;
var
    srcT: Int64;
    dstT: Int64;
begin
    Result := False;
    if not lastWriteTime(aSrc, srcT) then
        Exit;
    if not lastWriteTime(aDst, dstT) then
        Exit(True);
    Result := srcT > dstT;
end;

{*******************************************************************************
* removeStale
* Best-effort delete of aPath + '.old', retried briefly (the just-exited old
* process may still hold its former image for a moment).
*******************************************************************************}
procedure removeStale(const aPath: string);
var
    old: string;
    tries: Integer;
begin
    old := aPath + '.old';
    for tries := 0 to 9 do
    begin
        if not FileExists(old) then
            Exit;
        if DeleteFileW(PWideChar(old)) then
            Exit;
        Sleep(100);
    end;
end;

{*******************************************************************************
* swapFile
* Renames aDst aside to .old (allowed even while it is a running image) and copies
* aSrc into its place. Restores the original on copy failure. Returns success.
*******************************************************************************}
function swapFile(const aSrc, aDst: string): Boolean;
var
    old: string;
begin
    Result := False;
    old := aDst + '.old';
    if FileExists(old) then
        if not DeleteFileW(PWideChar(old)) then
            Exit;                       // previous .old still locked -> skip this run
    if FileExists(aDst) then
        if not MoveFileW(PWideChar(aDst), PWideChar(old)) then
            Exit;
    if CopyFileW(PWideChar(aSrc), PWideChar(aDst), False) then
        Result := True
    else if FileExists(old) then
        MoveFileW(PWideChar(old), PWideChar(aDst));   // recover the original
end;

{*******************************************************************************
* relaunchSelf
* Starts a fresh instance with the identical command line and working directory.
* The exe path is unchanged (only its bytes were swapped), so this runs the new
* binary.
*******************************************************************************}
procedure relaunchSelf();
var
    si: TStartupInfoW;
    pi: TProcessInformation;
    cmd: UnicodeString;
begin
    cmd := GetCommandLineW;             // owns a mutable copy CreateProcess may edit
    UniqueString(cmd);
    FillChar(si, SizeOf(si), 0);
    si.cb := SizeOf(si);
    FillChar(pi, SizeOf(pi), 0);
    if CreateProcessW(nil, PWideChar(cmd), nil, nil, False, 0, nil, nil, si, pi) then
    begin
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    end;
end;

{*******************************************************************************
* applyExeAutoUpdate
*******************************************************************************}
function applyExeAutoUpdate(const aSourceDir: string): Boolean;
var
    curDir: string;
    srcDir: string;
    src: string;
    dst: string;
    ico: string;
    i: Integer;
    updated: Boolean;
    mainSwapped: Boolean;
begin
    Result := False;
    curDir := ExtractFilePath(ParamStr(0));

    // Tidy up leftovers from a previous update regardless of whether we update now.
    for i := Low(UPDATE_FILES) to High(UPDATE_FILES) do
        removeStale(curDir + UPDATE_FILES[i]);

    if aSourceDir = '' then
        Exit;
    srcDir := IncludeTrailingPathDelimiter(aSourceDir);
    // Nothing to do if the source is our own folder.
    if SameText(ExcludeTrailingPathDelimiter(srcDir), ExcludeTrailingPathDelimiter(curDir)) then
        Exit;

    updated := False;
    mainSwapped := False;
    for i := Low(UPDATE_FILES) to High(UPDATE_FILES) do
    begin
        src := srcDir + UPDATE_FILES[i];
        dst := curDir + UPDATE_FILES[i];
        if sourceIsNewer(src, dst) then
            if swapFile(src, dst) then
            begin
                updated := True;
                if SameText(UPDATE_FILES[i], 'AppMain.exe') then
                    mainSwapped := True;
            end;
    end;

    // The staged exe is the generic (icon-less) build; re-stamp the copy with this
    // deployment's AppCore.ico so the auto-update does not drop the taskbar/Explorer
    // icon (overlay-safe). Then relaunch runs the stamped binary.
    if mainSwapped then
    begin
        ico := curDir + 'AppCore.ico';
        if FileExists(ico) then
            stampExeIcon(curDir + 'AppMain.exe', ico);
    end;

    if updated then
    begin
        relaunchSelf();
        Result := True;
    end;
end;

end.
