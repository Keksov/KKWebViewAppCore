unit AppConfig;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TAppMode = (amProd, amDev);

  TAppConfig = record
    Mode: TAppMode;
    BunExe: string;          // path to bun.exe (resolved absolute)
    ServerDir: string;       // server project dir (package.json, server.ts)
    UiDir: string;           // UI project dir (quasar)
    ServerPort: Integer;     // backend port
    DevUrl: string;          // URL opened in dev mode (e.g. quasar dev)
    BuildUi: Boolean;        // prod: run `bun run build` before starting
    FullScreen: Boolean;     // open the window borderless fullscreen
    ReadyTimeoutSec: Integer;// max seconds to wait for the port
    // Resolved at load time:
    ReadyPort: Integer;      // port to poll before opening the window
    StartUrl: string;        // URL the WebView2 window opens
  end;

{ Loads a KEY=VALUE config file (UTF-8/ANSI, '#' comments). Relative paths are
  resolved against the directory of aPath. Returns False with aError set on
  any fatal problem. }
function LoadAppConfig(const aPath: string; out aCfg: TAppConfig; out aError: string): Boolean;

implementation

function IsAbsolutePath(const aPath: string): Boolean;
begin
  Result := ((Length(aPath) >= 2) and (aPath[2] = ':')) or
            ((Length(aPath) >= 2) and (aPath[1] = '\') and (aPath[2] = '\'));
end;

function ResolvePath(const aBaseDir, aPath: string): string;
begin
  if aPath = '' then
    Exit('');
  if IsAbsolutePath(aPath) then
    Result := aPath
  else
    Result := ExpandFileName(IncludeTrailingPathDelimiter(aBaseDir) + aPath);
end;

{ Like ResolvePath, but a bare command name with no path separator (e.g. 'bun')
  is kept as-is so it is found via PATH instead of being anchored to aBaseDir. }
function ResolveExe(const aBaseDir, aValue: string): string;
begin
  if aValue = '' then
    Exit('');
  if (Pos('\', aValue) = 0) and (Pos('/', aValue) = 0) then
    Result := aValue
  else
    Result := ResolvePath(aBaseDir, aValue);
end;

function ParseBool(const aValue: string; aDefault: Boolean): Boolean;
var
  v: string;
begin
  v := LowerCase(Trim(aValue));
  if (v = 'true') or (v = '1') or (v = 'yes') or (v = 'on') then
    Result := True
  else if (v = 'false') or (v = '0') or (v = 'no') or (v = 'off') then
    Result := False
  else
    Result := aDefault;
end;

{ Extracts the TCP port from an http(s) URL, e.g. http://localhost:9000/ -> 9000.
  Returns aDefault when no explicit port is present. }
function PortFromUrl(const aUrl: string; aDefault: Integer): Integer;
var
  s: string;
  schemePos, slashPos, colonPos: Integer;
  portStr: string;
  code: Integer;
begin
  Result := aDefault;
  s := aUrl;
  schemePos := Pos('://', s);
  if schemePos > 0 then
    Delete(s, 1, schemePos + 2);
  // s is now host[:port][/...]
  slashPos := Pos('/', s);
  if slashPos > 0 then
    s := Copy(s, 1, slashPos - 1);
  colonPos := Pos(':', s);
  if colonPos > 0 then
  begin
    portStr := Copy(s, colonPos + 1, Length(s));
    Val(portStr, Result, code);
    if code <> 0 then
      Result := aDefault;
  end
  else if LowerCase(Copy(aUrl, 1, 6)) = 'https:' then
    Result := 443
  else
    Result := 80;
end;

function LoadAppConfig(const aPath: string; out aCfg: TAppConfig; out aError: string): Boolean;
var
  lines: TStringList;
  i, eqPos: Integer;
  baseDir, line, key, value: string;
begin
  Result := False;
  aError := '';

  if not FileExists(aPath) then
  begin
    aError := 'Config file not found: ' + aPath;
    Exit;
  end;

  baseDir := ExtractFileDir(ExpandFileName(aPath));

  // Defaults
  aCfg.Mode := amProd;
  aCfg.BunExe := 'bun';
  aCfg.ServerDir := '';
  aCfg.UiDir := '';
  aCfg.ServerPort := 0;
  aCfg.DevUrl := '';
  aCfg.BuildUi := True;
  aCfg.FullScreen := False;
  aCfg.ReadyTimeoutSec := 30;

  lines := TStringList.Create;
  try
    try
      lines.LoadFromFile(aPath);
    except
      on E: Exception do
      begin
        aError := 'Cannot read config: ' + E.Message;
        Exit;
      end;
    end;

    for i := 0 to lines.Count - 1 do
    begin
      line := Trim(lines[i]);
      if (line = '') or (line[1] = '#') or (line[1] = ';') then
        Continue;
      eqPos := Pos('=', line);
      if eqPos <= 0 then
        Continue;
      key := LowerCase(Trim(Copy(line, 1, eqPos - 1)));
      value := Trim(Copy(line, eqPos + 1, Length(line)));

      if key = 'mode' then
      begin
        if LowerCase(value) = 'dev' then aCfg.Mode := amDev else aCfg.Mode := amProd;
      end
      else if key = 'bunexe' then aCfg.BunExe := ResolveExe(baseDir, value)
      else if key = 'serverdir' then aCfg.ServerDir := ResolvePath(baseDir, value)
      else if key = 'uidir' then aCfg.UiDir := ResolvePath(baseDir, value)
      else if key = 'serverport' then aCfg.ServerPort := StrToIntDef(value, 0)
      else if key = 'devurl' then aCfg.DevUrl := value
      else if key = 'buildui' then aCfg.BuildUi := ParseBool(value, True)
      else if key = 'fullscreen' then aCfg.FullScreen := ParseBool(value, False)
      else if key = 'readytimeoutsec' then aCfg.ReadyTimeoutSec := StrToIntDef(value, 30);
    end;
  finally
    lines.Free;
  end;

  // Validation
  if aCfg.ServerPort <= 0 then
  begin
    aError := 'ServerPort is missing or invalid in: ' + aPath;
    Exit;
  end;

  // Resolve URL + readiness port
  if aCfg.Mode = amDev then
  begin
    if aCfg.DevUrl = '' then
      aCfg.DevUrl := Format('http://localhost:%d/', [aCfg.ServerPort]);
    aCfg.StartUrl := aCfg.DevUrl;
    aCfg.ReadyPort := PortFromUrl(aCfg.DevUrl, aCfg.ServerPort);
  end
  else
  begin
    aCfg.StartUrl := Format('http://localhost:%d/', [aCfg.ServerPort]);
    aCfg.ReadyPort := aCfg.ServerPort;
  end;

  Result := True;
end;

end.
