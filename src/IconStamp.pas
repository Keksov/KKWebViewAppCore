program IconStamp;

{$IFDEF FPC}
{$mode delphiunicode}
{$ENDIF}

{ Stamps an .ico into an existing .exe as its application icon (RT_ICON images +
  a single RT_GROUP_ICON, id 1), so Explorer / the taskbar / pinned shortcuts show
  the right icon without running the program. Intended as a post-copy step: after the
  generic AppMain.exe is copied into a deployment, run

      IconStamp <target.exe> <icon.ico>

  with that deployment's AppCore.ico. Uses only the Win32 resource-update API — no
  third-party tools. The target exe must not be running (the file is opened for update). }

uses
    Windows, SysUtils, Classes;

const
    RT_ICON_ID       = 3;      // RT_ICON
    RT_GROUP_ICON_ID = 14;     // RT_GROUP_ICON
    RES_LANG         = 1033;   // en-US; icons behave language-neutrally in the shell

{*******************************************************************************
* intRes — the integer-id form of a resource type/name (MAKEINTRESOURCE).
*******************************************************************************}
function intRes(aId: Word): PWideChar;
begin
    Result := PWideChar(PtrUInt(aId));
end;

{*******************************************************************************
* loadFile — reads a whole file into a byte array.
*******************************************************************************}
function loadFile(const aPath: string; out aData: TBytes): Boolean;
var
    fs: TFileStream;
begin
    Result := False;
    if not FileExists(aPath) then
        Exit;
    try
        fs := TFileStream.Create(aPath, fmOpenRead or fmShareDenyWrite);
        try
            SetLength(aData, fs.Size);
            if fs.Size > 0 then
                fs.ReadBuffer(aData[0], fs.Size);
        finally
            fs.Free;
        end;
        Result := True;
    except
        Result := False;
    end;
end;

{*******************************************************************************
* peOverlayStart
* Returns the file offset where the PE overlay begins (data appended after the last
* section), or Length(aData) when there is none. FPC's linker appends a ~1 MB symbol
* table as an overlay; Windows' UpdateResource strips it, so it must be preserved.
*******************************************************************************}
function peOverlayStart(const aData: TBytes): Integer;
var
    i: Integer;
    s: Integer;
    peOff: Integer;
    secTab: Integer;
    numSec: Integer;
    optSize: Integer;
    endOff: DWORD;
    maxEnd: DWORD;
    rawPtr: DWORD;
    rawSize: DWORD;
begin
    Result := Length(aData);   // assume no overlay
    if Length(aData) < 64 then
        Exit;
    peOff := PInteger(@aData[$3C])^;
    if (peOff <= 0) or (peOff + 24 > Length(aData)) then
        Exit;
    if (aData[peOff] <> Ord('P')) or (aData[peOff + 1] <> Ord('E')) then
        Exit;
    numSec := PWord(@aData[peOff + 6])^;
    optSize := PWord(@aData[peOff + 20])^;
    secTab := peOff + 24 + optSize;
    if (numSec <= 0) or (secTab + numSec * 40 > Length(aData)) then
        Exit;
    maxEnd := 0;
    for i := 0 to numSec - 1 do
    begin
        s := secTab + i * 40;
        rawSize := PDWord(@aData[s + 16])^;
        rawPtr := PDWord(@aData[s + 20])^;
        endOff := rawPtr + rawSize;
        if endOff > maxEnd then
            maxEnd := endOff;
    end;
    if (maxEnd > 0) and (maxEnd < DWORD(Length(aData))) then
        Result := Integer(maxEnd);
end;

{*******************************************************************************
* stampIcon
* Parses the .ico in aIco and writes each image as an RT_ICON resource (ids 1..N)
* plus one RT_GROUP_ICON (id 1) that references them, into aExe. Image bytes are copied
* verbatim, so both classic DIB and PNG-compressed (256x256) entries carry over.
*******************************************************************************}
function stampIcon(const aExe: string; const aIco: TBytes): Boolean;
var
    i: Integer;
    ent: Integer;         // offset of the current 16-byte ICONDIRENTRY
    cnt: Word;            // number of icon images
    upd: HANDLE;          // BeginUpdateResource handle
    grp: TMemoryStream;   // RT_GROUP_ICON buffer being built
    word16: Word;
    imgLen: DWORD;
    imgOff: DWORD;
begin
    Result := False;
    // ICONDIR header: reserved(0) type(1=icon) count.
    if Length(aIco) < 6 then
        Exit;
    if (PWord(@aIco[0])^ <> 0) or (PWord(@aIco[2])^ <> 1) then
        Exit;
    cnt := PWord(@aIco[4])^;
    if (cnt = 0) or (Length(aIco) < 6 + Integer(cnt) * 16) then
        Exit;

    upd := BeginUpdateResourceW(PWideChar(aExe), False);   // keep other resources
    if upd = 0 then
        Exit;

    grp := TMemoryStream.Create;
    try
        // GRPICONDIR header: reserved(0) type(1) count.
        word16 := 0; grp.WriteBuffer(word16, 2);
        word16 := 1; grp.WriteBuffer(word16, 2);
        grp.WriteBuffer(cnt, 2);

        for i := 0 to cnt - 1 do
        begin
            ent := 6 + i * 16;
            imgLen := PDWord(@aIco[ent + 8])^;    // dwBytesInRes
            imgOff := PDWord(@aIco[ent + 12])^;   // dwImageOffset
            if (imgOff = 0) or (imgLen = 0) or (imgOff + imgLen > DWORD(Length(aIco))) then
            begin
                EndUpdateResource(upd, True);     // discard
                Exit;
            end;
            if not UpdateResourceW(upd, intRes(RT_ICON_ID), intRes(Word(i + 1)),
                RES_LANG, @aIco[imgOff], imgLen) then
            begin
                EndUpdateResource(upd, True);
                Exit;
            end;
            // GRPICONDIRENTRY = first 12 bytes of the ICONDIRENTRY (bWidth..dwBytesInRes)
            // followed by the RT_ICON id (WORD) instead of the file offset.
            grp.WriteBuffer(aIco[ent], 12);
            word16 := Word(i + 1);
            grp.WriteBuffer(word16, 2);
        end;

        if not UpdateResourceW(upd, intRes(RT_GROUP_ICON_ID), intRes(1),
            RES_LANG, grp.Memory, DWORD(grp.Size)) then
        begin
            EndUpdateResource(upd, True);
            Exit;
        end;
    finally
        grp.Free;
    end;

    Result := EndUpdateResource(upd, False);   // commit
end;

var
    ico: TBytes;
    exe: TBytes;
    fs: TFileStream;
    overlay: TBytes;
    ovStart: Integer;
begin
    if ParamCount < 2 then
    begin
        Writeln('Usage: IconStamp <target.exe> <icon.ico>');
        Halt(2);
    end;
    if not loadFile(ParamStr(1), exe) then
    begin
        Writeln('ERROR: cannot read exe: ', ParamStr(1));
        Halt(1);
    end;
    if not loadFile(ParamStr(2), ico) then
    begin
        Writeln('ERROR: cannot read icon: ', ParamStr(2));
        Halt(1);
    end;
    // Capture the PE overlay (FPC appends one) BEFORE stamping, because Windows'
    // UpdateResource rewrites the PE and drops any overlay.
    ovStart := peOverlayStart(exe);
    SetLength(overlay, Length(exe) - ovStart);
    if Length(overlay) > 0 then
        Move(exe[ovStart], overlay[0], Length(overlay));

    if not stampIcon(ParamStr(1), ico) then
    begin
        Writeln('ERROR: failed to stamp icon into: ', ParamStr(1));
        Halt(1);
    end;

    // Re-append the overlay at the new end of file (overlays are located EOF-relative).
    if Length(overlay) > 0 then
    begin
        try
            fs := TFileStream.Create(ParamStr(1), fmOpenReadWrite or fmShareDenyWrite);
            try
                fs.Seek(0, soEnd);
                fs.WriteBuffer(overlay[0], Length(overlay));
            finally
                fs.Free;
            end;
        except
            Writeln('ERROR: icon stamped but failed to restore overlay: ', ParamStr(1));
            Halt(1);
        end;
        Writeln('OK: icon written, overlay preserved (', Length(overlay), ' bytes): ', ParamStr(1));
    end
    else
        Writeln('OK: icon written to ', ParamStr(1));
end.
