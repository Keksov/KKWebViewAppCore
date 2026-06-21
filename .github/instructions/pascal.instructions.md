---
applyTo: "**/*.{pas,pp,inc}"
description: "Pascal / FreePascal conventions for AppCore source files: compilation, naming, formatting, memory and file-handling rules. Read this before editing any .pas/.pp/.inc file."
---

# Pascal Files (.pas, .pp, .inc)

## Compilation

AppCore is built with the vendored FreePascal toolchain, **not** a global FPC.

- Compiler: `..\..\..\..\KKMindWave\VendorsCore\fpc\fpc-main\bin\x86_64-win64\fpc.exe`
  (override with the `FPC_EXE_x64` environment variable).
- Config: `build\win_x64\fpc-x64.cfg` (relative paths; output to `dcu\` and `bin\`).
- Build via the scripts, do not invoke fpc ad-hoc:
  - `build\win_x64\build_webview.bat` — builds `libwebview.dll` (CMake + MinGW).
  - `build\win_x64\build_app.bat` — compiles the application.
- Target platform: **x64** (`-Twin64 -Px86_64`).
- Language mode: `{$mode delphiunicode}` guarded by `{$IFDEF FPC}` so the code
  also compiles under Delphi (where `String` is natively `UnicodeString`).

# Pascal Code Conventions

Don't change line ending and don't change code page of files.

## Naming Conventions

### Local Variables
- All local variables must start with a lowercase letter
- Use camelCase for multi-word variable names
- Sort local variables declarations by string length (shortest first)

**Examples:**
```pascal
var
    len: Integer;
    offset: Integer;
    plainData: TBytes;
    encryptedData: TBytes;
    userNameBytes, eMailBytes, hwIDBytes: TBytes;
```

**Bad (unsorted):**
```pascal
var
    encryptedData: TBytes;
    plainData: TBytes;
    offset: Integer;
    userNameBytes, eMailBytes, hwIDBytes: TBytes;
    len: Integer;
```

### Class Fields (Private)
- Private fields should use the F-prefix notation
- Use camelCase for the rest of the name
- First letter after F should be lowercased
- Fields should be indented with 4 spaces
- Colon should be aligned at position 33 (column 33)

**Example:**
```pascal
private
    FuserName               : string;
    FexpirationDate         : TDateTime;
    FuserData               : TBytes;
```

### Properties
- Properties should follow PascalCase (first letter uppercase)
- Provide read/write access via getter/setter methods
- First letter of property name should be UpperCase

**Example:**
```pascal
public
    property UserName: string read FuserName write FUserName;
    property ExpirationDate: TDateTime read FexpirationDate write FExpirationDate;
```

### Instance Methods
- All instance method names (except `Create`, `Destroy`, and class methods) should start with a lowercase letter
- Use camelCase for multi-word method names
- In method declarations, the method name should start at column 17 (4 spaces indent + "function"/"procedure" + spaces)

**Examples:**
```pascal
    function    dateTimeToBytes(const aDateTime: TDateTime): TBytes;
    function    generateLicense(const aInfo: TLicenseInfo): string;
    function    parseLicense(const aLicense: string; out aInfo: TLicenseInfo): Boolean;
    procedure   validateLicense(const aLicense: string);
```

### Standalone Routines
- Unit-level (non-method) functions and procedures follow the same rule:
  start with a lowercase letter, camelCase for multi-word names
- Routine names bound to an external C API keep the exact exported name
  (e.g. `webview_create`) — those names are fixed by linkage

### Parameters
- All parameters must use the 'a' prefix
- Use `const` for read-only parameters

**Examples:**
```pascal
procedure foo(const aUserName: string);
function boo(aDigit: integer);
function parseLicense(const aLicense: string; out aInfo: TLicenseInfo): Boolean;
```

## Memory Management

### Classes
- Always implement constructor and destructor for classes
- Constructor should initialize all private fields
- Destructor should clean up dynamically allocated memory

**Example:**
```pascal
constructor TLicenseInfo.Create;
begin
    inherited Create;
    FuserName := '';
    FuserData := nil;
end;

destructor TLicenseInfo.Destroy;
begin
    FUserName := '';
    SetLength(FuserData, 0);
    inherited Destroy;
end;
```

### Dynamic Objects in Functions and Class Cleanup
- When creating object instances that are passed as out parameters, always free them after use
- Use `FreeAndNil(obj)` procedure instead of manual checking and freeing
- Do not use the pattern: `if Assigned(obj) then begin obj.Free; obj := nil; end;`

**Examples:**

Good:
```pascal
function validateLicense(const aLicense: string): Boolean;
var
    info: TLicenseInfo;
begin
    Result := parseLicense(aLicense, info);
    FreeAndNil(info);
end;

destructor MyClass.Destroy;
begin
    FreeAndNil(FblackList);
    FreeAndNil(FserialUtils);
    inherited Destroy;
end;
```

Bad (avoid this):
```pascal
if Assigned(FblackList) then
begin
    FblackList.Free;
    FblackList := nil;
end;
```

## Class Declaration Style

### Structure and Layout
- Class declaration keyword on same line as type name: `TClassName = class`
- Access modifiers (`private`, `protected`, `public`, `published`) aligned flush left (no indentation)
- Multiple `private` sections allowed (one for fields, one for methods)
- 4-space indentation for all members within class
- Blank line after closing `end;` statement

### Field Declarations
- Fields use F-prefix (FfieldName)
- First letter after F is lowercase
- Type information aligned (colons aligned to same column)
- Format: `FfieldName : FieldType` with proper spacing

### Method Declarations
- Instance methods (except `Create`/`Destroy`) start with lowercase
- `Create` and `Destroy` use PascalCase (exceptions to lowercase rule)
- Method names start at column 17 for readability
- Pattern: `procedure methodName(params);` or `function methodName(params): ReturnType;`
- Parameters always use 'a' prefix with const where appropriate

### Property Declarations
- Properties use PascalCase (first letter uppercase)
- Use comment `public // property` to mark property section
- Format: `property PropertyName: PropertyType read FpropertyField [write FpropertyField];`
- Align colons after property names
- Reference backing F-prefixed fields

### Comments in Class Declaration
- Section header comment: `{-- SectionName ...--}`
- Class name comment above declaration:
```pascal
{***************************************************************************
* ClassName
***************************************************************************}
```
- Use consistent comment formatting

**Example:**
```pascal
{-- TVMProtectSDK -------------------------------------------------------------}

    {***************************************************************************
     * TRSACryptoProvider
     ***************************************************************************}
    TRSACryptoProvider = class
private
    FkeySize                : Cardinal;
    FisInitialized          : Boolean;
    FkeyPair                : TAsymetricKeyPair;
    FRSAEngine              : TRSA_Engine;

private
    procedure   initializeEngine();
    function    validateKeyPair(): Boolean;

public
    constructor Create(aKeySize: Cardinal = 2048);
    destructor  Destroy(); override;

    procedure   generateKeyPair();
    procedure   loadPrivateKey(aStream: TStream);
    procedure   loadPublicKey(aStream: TStream);
    procedure   savePrivateKey(aStream: TStream);
    procedure   savePublicKey(aStream: TStream);

    function    signData(const aDataText: string; var aSignatureText: string): Boolean; overload;
    function    signData(const aData: TStream; const aSignature: TStream): Boolean; overload;

    function    verifySignature(const aDataText: string; const aSignatureText: string): Boolean; overload;
    function    verifySignature(const aData: TStream; const aSignature: TStream): Boolean; overload;

public // property
    property KeySize: Cardinal read FkeySize;
    property KeyPair: TAsymetricKeyPair read FkeyPair;
    property IsInitialized: Boolean read FisInitialized;

    end;
```

## Code Style

- Use 4-space indentation
- Follow existing code patterns in the file
- Add comments for complex logic
- Keep functions focused and readable

### Function/Procedure Headers
- Add a header comment before each function/procedure implementation
- Use the following format with a line of asterisks above and below

**Example:**
```pascal
{*******************************************************************************
* FunctionName
*******************************************************************************}
function TMyClass.FunctionName(const aParam: string): Boolean;
begin
    // implementation
end;

{*******************************************************************************
* ValidateLicense
*******************************************************************************}
function TMyClass.ValidateLicense(const aLicense: string): Boolean;
var
    info: TLicenseInfo;
begin
    Result := ParseLicense(aLicense, info);
    FreeAndNil(info);
end;
```
