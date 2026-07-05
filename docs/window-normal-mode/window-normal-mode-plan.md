# Normal (OS-decorated) window mode + runtime mode switching

## Problem

AppCore runs as a **kiosk**: the main window is borderless (`WS_POPUP`) and the only
window controls live in a custom floating **AppBar** (Move / Min / Max / Close, plus a
dev-tools button in dev mode). The AppBar's "Max" button toggles between true fullscreen
and a bordered-but-still-`WS_POPUP` "restored" size (`WS_POPUP or WS_THICKFRAME`) — it
never gives the window a real OS **title bar**, system menu, or the standard
minimize/maximize/close cluster in the top-right.

There *is* a second, older path — plain windowed mode — that keeps the WebView2 host
window's default OS-decorated style and persists its geometry (`win=`), but:
- it is chosen **at launch** (`cfg.FullScreen=false` / no `-FullScreen`), not at runtime;
- it is **unreachable from a running kiosk** (no toggle);
- it is not a named, first-class mode the app or user reasons about.

So today a user in the deployed kiosk cannot get a window that looks and behaves like an
ordinary Windows application.

## Goal

Add a first-class **Normal** display mode:
- The main window is a standard OS-decorated top-level window (`WS_OVERLAPPEDWINDOW`:
  caption/title bar, system menu, minimize/maximize/close top-right, sizing border, Aero
  snap, taskbar thumbnail menu).
- It can be **switched into and out of at runtime** (Kiosk ⇄ Normal), no restart.
- The chosen mode is **persisted** to the window-state file and restored next launch.
- The floating AppBar's role in Normal mode is decided (see WN-D2), and there is a clear
  **way back to kiosk** from Normal mode (see WN-D3).

## Current architecture (references)

- **AppMain.pas** — `useFullScreen` selects borderless `WS_POPUP` fullscreen
  ([AppMain.pas:457-465](../../src/AppMain.pas#L457-L465)) vs the default windowed style +
  `attachWindowState` ([AppMain.pas:466-476](../../src/AppMain.pas#L466-L476)).
  `showMainWindow` creates the AppBar **only** in fullscreen
  ([AppMain.pas:274-286](../../src/AppMain.pas#L274-L286)). Initial mode comes from
  `-FullScreen` (forced) or `cfg.FullScreen` ([AppMain.pas:343-389](../../src/AppMain.pas#L343-L389)).
  Windowed geometry is flushed on exit ([AppMain.pas:501-503](../../src/AppMain.pas#L501-L503)).
- **AppBar.pas** — floating RDP-style control bar. `applyMainGeometry` swaps the borderless
  window between fullscreen (`WS_POPUP or WS_VISIBLE`) and restored
  (`WS_POPUP or WS_THICKFRAME or WS_VISIBLE`) ([AppBar.pas:141-189](../../src/AppBar.pas#L141-L189));
  the Max button drives it and saves `kioskfull` ([AppBar.pas:382-389](../../src/AppBar.pas#L382-L389)).
  It **subclasses the main window** to track restored geometry
  ([AppBar.pas:425-438](../../src/AppBar.pas#L425-L438)) and hosts the dev-tools button.
- **AppWindowState.pas** — persists `win=<l t r b showCmd>` (windowed geometry + maximized
  state) via its own main-window subclass (`attachWindowState`/`stateWndProc`), plus the
  kiosk keys `kioskfull` / `kioskrect` / `kioskmon`. File: `AppCore.window` next to the exe
  (temp fallback).
- **AppConfig.pas** — `TAppMode = (amProd, amDev)`; `FullScreen: Boolean` (default false).

Note both **AppBar.mainWndProc** and **AppWindowState.stateWndProc** subclass the main
window; today only one is active because a run is either kiosk or windowed. Runtime
switching must not double-subclass (see WN-D5).

## Decisions (proposed — confirm before building)

- **WN-D1 — Explicit mode, persisted.** Introduce a display-mode value persisted as
  `dispmode=kiosk|normal` in `AppCore.window`. *Kiosk* keeps today's behavior exactly
  (borderless `WS_POPUP`, AppBar, fullscreen⇄restored sub-toggle, `kiosk*` keys). *Normal*
  is `WS_OVERLAPPEDWINDOW` with OS chrome and no AppBar, reusing the `win=` geometry key.
- **WN-D2 — AppBar is hidden in Normal mode.** The OS caption already provides
  minimize/maximize/close, dragging, and Aero snap, so the floating bar is redundant and
  would visually double up. In Normal mode the AppBar is not shown (kept created-but-hidden,
  or destroyed and re-created on switch back — decide in WN2.1).
- **WN-D3 — Way back to kiosk without the bar (RESOLVED: web-UI + system menu).** Because
  the bar is gone in Normal mode, the Kiosk⇄Normal toggle is provided by **both**:
  1. **Bound JS function** the web UI calls (like `__appcoreExit` via `webview_bind`); the
     SoundTrainer settings page hosts a "Режим окна" switch that works in both directions.
  2. **System-menu item** — `AppendMenu` to `GetSystemMenu`, handled via `WM_SYSCOMMAND`;
     works even without the web app and is discoverable from the title-bar icon in Normal
     mode. A "Полноэкранный режим" / "Обычное окно" item toggles the mode.
  (No global hotkey for now.)
- **WN-D4 — Runtime switch mechanics (no webview re-create).** Swap `GWL_STYLE`
  (`WS_POPUP` ⇄ `WS_OVERLAPPEDWINDOW`), `SetWindowPos(..., SWP_FRAMECHANGED)`, restore the
  target mode's saved geometry, re-layout the WebView2 child to the new **client** rect,
  show/hide the AppBar and sync its `gFull` flag. The WebView2 host window is reused (only
  its style/frame changes), so the page is not reloaded.
- **WN-D5 — Single geometry tracker.** Unify main-window geometry tracking so exactly one
  subclass is installed, routing to `win=` in Normal mode and `kioskrect` in kiosk mode.
  Avoid AppBar and AppWindowState both replacing `GWL_WNDPROC` and losing each other's
  original proc across a runtime switch.
- **WN-D6 — Launch precedence (RESOLVED: default Kiosk).** On launch the initial mode
  resolves as: `-FullScreen` (forced CLI) → Kiosk always; else the saved `dispmode` if
  present (so a user who switched to Normal stays in Normal, and one who switched back stays
  in Kiosk); else **Kiosk by default**. `cfg.FullScreen` stays the deployment knob and
  remains `true` for kiosk deployments; a first run with no saved `dispmode` comes up in
  Kiosk.
- **WN-D7 — Normal remembers maximized (RESOLVED: yes).** Normal mode persists and restores
  the maximized state, reusing the existing `win=<l t r b showCmd>` mechanism
  (`showCmd = SW_SHOWMAXIMIZED` when maximized) that the current windowed path already
  implements.
- **WN-D8 — DevTools reachable in Normal (RESOLVED: menu item).** In addition to F12 (dev
  mode), add a DevTools entry to the Normal-mode system menu when running in dev mode, since
  the AppBar's `</>` button is not shown there.

## Open questions — RESOLVED

1. **Toggle entry points** → web-UI switch **and** system-menu item (no hotkey). → WN-D3.
2. **Maximized memory** → yes, reuse `win=` `showCmd`. → WN-D7.
3. **Default for new installs** → Kiosk. → WN-D6.
4. **DevTools in Normal mode** → add a system-menu item (in dev mode), alongside F12. → WN-D8.

## Phases / steps (atomic)

- **Phase 0 — spec**
  - [x] WN0.1 This plan.
- **Phase 1 — mode model + styling**
  - [x] WN1.1 Persist display mode: `saveDispMode` / `loadDispMode` (`dispmode=kiosk|normal`)
        in AppWindowState; launch reads it.
  - [x] WN1.2 Normal styling primitive: `setKioskMode` / `setNormalMode` that swap
        `GWL_STYLE`, apply `SWP_FRAMECHANGED`, and restore the target geometry (factor out of
        `AppBar.applyMainGeometry`).
  - [x] WN1.3 Unify main-window geometry tracking into one subclass (WN-D5).
- **Phase 2 — runtime switching**
  - [x] WN2.1 Live toggle in AppMain: switch mode, hide/show AppBar, sync `gFull`, persist
        `dispmode`.
  - [ ] WN2.2 Toggle entry points (WN-D3): bound JS function (`__appcoreSetWindowMode` /
        toggle) + a system-menu item (`AppendMenu` + `WM_SYSCOMMAND`); add a DevTools
        system-menu item in dev mode (WN-D8).
  - [ ] WN2.3 Re-layout the WebView2 child to the client rect on switch (fills area under
        the caption in Normal, full window in kiosk).
- **Phase 3 — launch + config**
  - [ ] WN3.1 Initial-mode resolution per WN-D6 (`-FullScreen` / saved `dispmode` /
        `cfg.FullScreen`).
  - [ ] WN3.2 Web-UI control (cross-repo, SoundTrainer): a "Режим окна" toggle calling the
        bound native function.
- **Phase 4 — verify**
  - [ ] WN4.1 Switch both ways at runtime; geometry persists per mode across restart; DPI
        rescale on monitor move; multi-monitor; taskbar/Alt-Tab behavior sane in both modes;
        DevTools reachable (F12) in Normal.

## Verification (acceptance)

- From a running kiosk, the user switches to Normal and gets a real OS window (caption,
  min/max/close top-right, resizable, snappable); switching back restores the kiosk look.
- The chosen mode and per-mode geometry survive a restart.
- Only one window subclass is active at a time (no lost WndProc, no leaks across switches).
- The WebView2 content fills the client area correctly in both modes and after DPI changes.
