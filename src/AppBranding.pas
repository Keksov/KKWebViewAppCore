unit AppBranding;

{$IFDEF FPC}
{$mode delphiunicode}
{$codepage utf8}
{$ENDIF}

{*******************************************************************************
* AppBranding
* Per-deployment window title + taskbar icon, so several AppCore apps are
* distinguishable as taskbar buttons. Read at startup from files next to the exe:
*   AppCore.ico  - if present, used as the window icon.
*   AppCore.ini  - UTF-8 KEY=VALUE; AppTitle=<window title>, AppIcon=<base64 .ico>
*                  (AppIcon is only used when AppCore.ico is absent).
* setAppUserModelId gives the process its own taskbar identity so its button does
* not group with, or borrow the icon of, another AppCore instance.
*******************************************************************************}

interface

uses
    Windows;

procedure loadBranding(out aTitle: string; out aIconBig, aIconSmall: HICON);
procedure applyWindowIcons(aWnd: HWND; aIconBig, aIconSmall: HICON);
function appUserModelId(const aTitle: string): string;
procedure setAppUserModelId(const aTitle: string);

implementation

uses
    SysUtils, base64;

function SetCurrentProcessExplicitAppUserModelID(aAppId: PWideChar): HResult; stdcall;
    external 'shell32' name 'SetCurrentProcessExplicitAppUserModelID';

{*******************************************************************************
* readFileUtf8 — reads aPath as raw bytes, strips a UTF-8 BOM, returns UTF-16.
*******************************************************************************}
function readFileUtf8(const aPath: string): string;
var
    f: file;
    sz: Int64;
    raw: RawByteString;
begin
    Result := '';
    if not FileExists(aPath) then
        Exit;
    AssignFile(f, aPath);
    {$I-}
    Reset(f, 1);
    {$I+}
    if IOResult <> 0 then
        Exit;
    try
        sz := FileSize(f);
        if sz > 0 then
        begin
            SetLength(raw, sz);
            BlockRead(f, raw[1], sz);
        end;
    finally
        CloseFile(f);
    end;
    if (Length(raw) >= 3) and (raw[1] = #$EF) and (raw[2] = #$BB) and (raw[3] = #$BF) then
        Delete(raw, 1, 3);
    Result := UTF8Decode(raw);
end;

{*******************************************************************************
* iniValue — value of aKey (case-insensitive) in a simple KEY=VALUE ini text.
* Blank lines, [sections] and # / ; comments are ignored.
*******************************************************************************}
function iniValue(const aText, aKey: string): string;
var
    i, ls: Integer;
    line: string;
    eq: Integer;
begin
    Result := '';
    i := 1;
    while i <= Length(aText) do
    begin
        ls := i;
        while (i <= Length(aText)) and (aText[i] <> #10) and (aText[i] <> #13) do
            Inc(i);
        line := Trim(Copy(aText, ls, i - ls));
        while (i <= Length(aText)) and ((aText[i] = #10) or (aText[i] = #13)) do
            Inc(i);
        if (line = '') or (line[1] = '#') or (line[1] = ';') or (line[1] = '[') then
            Continue;
        eq := Pos('=', line);
        if eq = 0 then
            Continue;
        if SameText(Trim(Copy(line, 1, eq - 1)), aKey) then
        begin
            Result := Trim(Copy(line, eq + 1, Length(line)));
            Exit;
        end;
    end;
end;

{*******************************************************************************
* writeBase64Ico — decodes aB64 (a base64 .ico) to a temp file; '' on failure.
*******************************************************************************}
function writeBase64Ico(const aB64: string): string;
var
    raw: AnsiString;
    f: file;
begin
    Result := '';
    raw := DecodeStringBase64(AnsiString(aB64));
    if raw = '' then
        Exit;
    Result := IncludeTrailingPathDelimiter(GetTempDir)
        + Format('AppCore-%d.ico', [GetCurrentProcessId]);
    AssignFile(f, Result);
    {$I-}
    Rewrite(f, 1);
    {$I+}
    if IOResult <> 0 then
    begin
        Result := '';
        Exit;
    end;
    BlockWrite(f, raw[1], Length(raw));
    CloseFile(f);
end;

{*******************************************************************************
* loadBranding
*******************************************************************************}
procedure loadBranding(out aTitle: string; out aIconBig, aIconSmall: HICON);
var
    dir, icoPath, iniPath, iniText: string;
    usedTemp: Boolean;
begin
    aTitle := '';
    aIconBig := 0;
    aIconSmall := 0;
    usedTemp := False;
    dir := ExtractFilePath(ParamStr(0));

    icoPath := dir + 'AppCore.ico';
    if not FileExists(icoPath) then
        icoPath := '';

    iniPath := dir + 'AppCore.ini';
    if FileExists(iniPath) then
    begin
        iniText := readFileUtf8(iniPath);
        aTitle := iniValue(iniText, 'AppTitle');
        if icoPath = '' then
        begin
            icoPath := writeBase64Ico(iniValue(iniText, 'AppIcon'));
            usedTemp := icoPath <> '';
        end;
    end;

    if icoPath <> '' then
    begin
        aIconBig := LoadImageW(0, PWideChar(UnicodeString(icoPath)), IMAGE_ICON,
            GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_LOADFROMFILE);
        aIconSmall := LoadImageW(0, PWideChar(UnicodeString(icoPath)), IMAGE_ICON,
            GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE);
        // The HICONs are independent of the file, so the temp copy can go now.
        if usedTemp then
            DeleteFileW(PWideChar(UnicodeString(icoPath)));
    end;
end;

{*******************************************************************************
* applyWindowIcons — sets the window's small (title bar / taskbar) and big
* (Alt-Tab) icons.
*******************************************************************************}
procedure applyWindowIcons(aWnd: HWND; aIconBig, aIconSmall: HICON);
begin
    if aIconBig <> 0 then
        SendMessageW(aWnd, WM_SETICON, ICON_BIG, LPARAM(aIconBig));
    if aIconSmall <> 0 then
        SendMessageW(aWnd, WM_SETICON, ICON_SMALL, LPARAM(aIconSmall));
end;

{*******************************************************************************
* appUserModelId — the AppUserModelID derived from the title (ASCII alphanumerics),
* or '' when the title yields no usable id (e.g. a purely Cyrillic title).
*******************************************************************************}
function appUserModelId(const aTitle: string): string;
var
    c: Char;
    id: string;
    i: Integer;
begin
    Result := '';
    id := '';
    for i := 1 to Length(aTitle) do
    begin
        c := aTitle[i];
        if ((c >= 'A') and (c <= 'Z')) or ((c >= 'a') and (c <= 'z'))
            or ((c >= '0') and (c <= '9')) then
            id := id + c;
    end;
    if id <> '' then
        Result := 'KK.AppCore.' + id;
end;

{*******************************************************************************
* setAppUserModelId — gives the process its own taskbar identity. No-op when the
* title yields no usable id.
*******************************************************************************}
procedure setAppUserModelId(const aTitle: string);
var
    id: string;
begin
    id := appUserModelId(aTitle);
    if id <> '' then
        SetCurrentProcessExplicitAppUserModelID(PWideChar(UnicodeString(id)));
end;

end.
