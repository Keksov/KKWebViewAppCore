# Native Pixie/Direct2D loading splash before WebView2 startup

## Problem

On launch, AppCore creates the WebView2 window first and shows an HTML splash
*inside* it. WebView2's environment init is the slow part, so the window (and
therefore any feedback) appears with a noticeable delay — it looks like the app
did not start.

## Goal

Show a **native, frameless rectangular banner window immediately** at startup,
drawn with **Pixie (Direct2D/DirectWrite)**, displaying live loading status. Start
the services + WebView2 in the background; when the app URL is ready, switch to the
WebView2 window and close the splash. No perceived "did it start?" gap.

## Feasibility (gating) — Pixie from plain FPC, no Lazarus

"Pixie" here is the Free-Pascal/Delphi HTML/CSS/graphics engine vendored at
`EchoScript/EchoRecorder/vendors/pixie` (NOT the Nim library).

Findings (static analysis, to be confirmed by the PS0.2 compile spike):
- The drawing core is framework-agnostic:
  - `Pixie.Canvas.pas` (base `TPixieCanvas`) uses only `Classes, Generics.Collections`.
  - `Pixie.Canvas.D2D.pas` (`TPixieD2DCanvas`) uses only
    `Windows, ActiveX, SysUtils, Classes, Math, Generics.Collections` + `Pixie.*`
    (`Pixie.Types/WebColor/Borders/GradientLayer/FontDescription/Canvas/D2DHeaders`).
    **No LCL, VCL, FMX, or Graphics.**
  - `Pixie.DrawingCanvas.pas` provides a `TCanvas`-like wrapper (`TPixieDrawingCanvas`).
- `TPixieD2DCanvas` renders **directly to an HDC** via `ID2D1DCRenderTarget.BindDC(HDC, R)`
  (and offscreen to `IWICBitmap` via `CreateWicBitmapRenderTarget`). So a plain Win32
  frameless window's DC is a valid target — no LCL control needed.
- LCL/VCL/FMX appear only in the component files (`Pixie.PaintBox.VCL.pas`,
  `Pixie.*.FMX.pas`, `Pixie.Canvas.Cairo.pas`, `Pixie.*ControlBase*`), which are excluded.

Conclusion: **feasible.** PS0.2 makes it definitive by compiling the minimal D2D unit
set under AppCore's plain FPC and rendering text into a frameless window via BindDC.

## Decisions

- **PS-D1** Use Pixie's framework-agnostic D2D core only:
  `Pixie.Canvas`, `Pixie.Canvas.D2D`, `Pixie.DrawingCanvas`, `Pixie.D2DHeaders`,
  `Pixie.Types`, `Pixie.WebColor`, `Pixie.Borders`, `Pixie.GradientLayer`,
  `Pixie.FontDescription` (+ whatever transitive units the spike reveals). Exclude all
  `*.VCL.*`, `*.FMX.*`, `*.Cairo.*`, `*ControlBase*`, HTML/SVG/Markdown units unless needed.
- **PS-D2** Splash is a native Win32 frameless top-level window drawn with Pixie D2D
  (`BindDC` on the window DC), created and shown **before** `webview_create`, so it
  appears instantly and is decoupled from WebView2 init.
- **PS-D3** Vendoring follows the repo convention (as with uos in SoundCore): Pixie lives
  in a shared, git-ignored `vendors\pixie`; a provision script in the AppCore repo
  fetches it; **no third-party binaries/sources committed**. Only source search paths
  are added to `build\win_x64\fpc-x64.cfg`.
- **PS-D4** Localization reuses the existing `SplashLang` cfg key (ru default / en);
  status labels mirror the current splash phases (Building interface / Starting
  server / Waiting for services / Ready, etc.).
- **PS-D5** Process (as in appcore-launch): plan + ledger; per-step atomic commits
  prefixed with the step id; **NO push**; an approval gate (PS0.3) before
  vendoring/building; the visual launch check is a manual gate.
- **PS-D6** OPEN (resolve at PS0.3):
  (a) provisioning method — shared `..\vendors\pixie` + script (default) vs git subtree;
  (b) retire the in-WebView HTML splash entirely vs keep it as a fallback;
  (c) splash visuals — spinner + step checklist (mirrors today) vs a minimal logo+status.

## Phases & steps

- **Phase 0 — Plan & feasibility**
  - PS0.1 Plan & ledger (this).
  - PS0.2 Feasibility spike (GATING): compile the minimal Pixie D2D unit set under plain
    FPC in an AppCore test; render "Loading…" to a frameless window via `BindDC`;
    confirm no LCL is pulled in and that the window appears effectively instantly.
  - PS0.3 Approval gate (PS-D6) — PAUSE before vendoring/implementation.
- **Phase 1 — Vendoring**
  - PS1.1 Provision Pixie into git-ignored `vendors\pixie` + provision script; add the
    minimal source paths to `fpc-x64.cfg`; document the unit set.
  - PS1.2 Confirm `AppMain.exe` still builds cleanly with Pixie on the search path.
- **Phase 2 — Splash window + rendering**
  - PS2.1 `AppSplash.pas`: frameless top-level window (rectangular, centered), lifecycle.
  - PS2.2 Pixie D2D rendering into the splash DC: background, app title, spinner, step
    checklist; `splashSetPhase(text)` API; localized ru/en.
  - PS2.3 Animation + thread-safe status updates (WM_TIMER spinner; status set from the
    worker thread).
  - PS2.4 Per-monitor DPI awareness for the splash (scale by monitor DPI; center on the
    primary/active monitor).
- **Phase 3 — Startup reorder**
  - PS3.1 Show the native splash first (before `webview_create`); run services +
    WebView2 in the worker; push status to the splash; on ready, create/navigate the
    WebView2 window and destroy the splash.
  - PS3.2 Retire (or gate behind a flag) the in-WebView HTML splash.
- **Phase 4 — Finish**
  - PS4.1 Build + deploy to SoundTrainer/MindWaveCore; visual gate (splash instant,
    statuses update, clean swap to the UI).
  - PS4.2 STATUS/docs update; final commit.

## Verification

Each step has a `verify` line in the ledger. Overall done-when: launching the app shows
a native banner within ~1 frame, its status advances through the startup phases, and it
is replaced by the app UI once ready — with no visible "blank/no-window" gap.
