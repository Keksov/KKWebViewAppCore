# popup-window — window.open() без адресной строки (патч вендоренного webview)

**Запрос (KKMindWave panel-window, owner 2026-07-13):** detached-панели MindWave открываются из
SPA через `window.open()`. Дефолтное поведение WebView2 (`NewWindowRequested` не обработан)
создаёт popup **с адресной строкой браузера** — проверено владельцем в exe. Требование: адресной
строки быть не должно; окно — обычное нативное (только title bar).

Ledger (authoritative): [popup-window-progress.json](popup-window-progress.json).
Контекст на стороне MindWave: `KKMindWave/MindWaveCore/docs/panel-window/` (PW4.2, plan B).

## Решение

Патч **вендоренной** библиотеки webview — `webview/core/include/webview/detail/backends/
win32_edge.hh` (C++, а не Pascal: обработчик — полноценный COM-объект, на C++ с официальным
`WebView2.h` это естественно; альтернатива на raw-vtable из Pascal была бы заметно объёмнее и
более хрупкой):

- `webview2_new_window_handler` подписывается на `add_NewWindowRequested` основного webview
  (в `embed()`, после настроек; отписка/Release в деструкторе движка).
- На каждый `window.open()` создаётся `webview2_popup_window`: голое `WS_OVERLAPPEDWINDOW`
  (без браузерного UI), контроллер WebView2 из **того же environment**
  (`ICoreWebView2_2::get_Environment`) → тот же профиль и браузерный процесс, поэтому
  `BroadcastChannel` / `localStorage` / `window.close()` между opener и popup работают как в
  дефолтном popup. Запрос берётся через `GetDeferral` + `put_NewWindow` + `put_Handled(TRUE)`.
- Уважаются `WindowFeatures` (width/height/left/top из строки features `window.open`),
  `AdjustWindowRect` — чтобы размеры были размером контента.
- `document.title` → заголовок окна (`add_DocumentTitleChanged`); `window.close()` →
  `DestroyWindow` (`add_WindowCloseRequested`); иконки наследуются от главного окна
  (`WM_GETICON`/`WM_SETICON`, т.е. брендинг AppBranding подхватывается); тёмная тема title bar —
  `apply_window_theme`. `WM_SIZE` → `put_Bounds`; `WM_DESTROY` → `Close()` контроллера + Release.
- Отказоустойчивость: если перехват не удался на раннем этапе (нет `ICoreWebView2_2` на старом
  runtime и т.п.) — запрос НЕ помечается handled и срабатывает старый дефолтный popup (окно с
  адресной строкой лучше, чем потерянное окно).

## Важно: закрепление патча

`webview/` — **вложенный git-клон апстрима** (webview/webview, есть свой `.git`), внешний репо
его файлы трекать не может. Патч закреплён дважды:

1. Во вложенном репо `webview/` — коммит на ветке **`appcore-patches`** (поверх master
   апстрима). При обновлении апстрима: `git fetch` + rebase ветки.
2. Копия диффа — [win32_edge-newwindow.patch](win32_edge-newwindow.patch) в этой папке
   (внешний репо AppCore); при потере вложенного клона: `cd webview && git apply
   ../docs/popup-window/win32_edge-newwindow.patch`.

Все места патча помечены комментарием `AppCore patch (KKMindWave panel-window...)`: классы после
`webview2_user_script_added_handler`, подписка в `embed()`, отписка в деструкторе + члены движка.

## Сборка / деплой

`build\win_x64\build_webview.bat` → `build\win_x64\build_app.bat`. Деплой в MindWaveCore/server
при запущенном приложении падает (файл занят) — не страшно: `ExeAutoUpdate` в app.cfg подтянет
свежие бинарники из `build\win_x64\bin` при следующем запуске.

## Память места именованного попапа (translab, баг владельца 2026-10-15)

**Симптом:** панель в отдельном окне развёрнута на второй монитор → закрыта → открыта снова:
окно висит на двух мониторах сразу и не развёрнуто.

**Причина:** страница сохраняет `screenX/innerWidth` в DIP Chromium, а процесс (Per-Monitor-V2)
ставит окно в физических пикселях. При разных масштабах (основной 3072px @125%, второй с
физического x=3072 @100%) второй монитор в DIP начинается с 2458 → окно ставилось на физический
x=2458, т.е. 622px оставалось на основном. Развёрнутость через features `window.open` не передать
вообще.

**Решение:** `popup_placement_store` в патче. Попап с простым именем (`window.open(url,
'tl-panel-orig', …)`; `_blank`/пустое — по-старому) пишет свой `GetWindowPlacement`
(rcNormalPosition + развёрнут ли) в `AppCore.popups` рядом с exe (иначе `%TEMP%`) на
WM_EXITSIZEMOVE / WM_SIZE / WM_MOVE вне перетаскивания / WM_DESTROY; при следующем
`window.open` с тем же именем берёт это место вместо left/top/width/height из features и
показывает `SW_SHOWMAXIMIZED`, если окно было развёрнуто. Место отбрасывается, если ни один
монитор не показывает от него хотя бы 120×60px (монитор отключили) — тогда снова features.

**Проверка (red/green):** опенер на libwebview.dll открывает `tl-test` с features
`left=2458,top=23,width=1920,height=1129`; скрипт через Win32 разворачивает попап на втором
мониторе, шлёт WM_CLOSE, ждёт переоткрытия, затем перезапускает опенер. Старая DLL: окно
`(2449,-15)-(4387,1161)`, не развёрнуто (red). Новая: развёрнуто на втором мониторе и после
закрытия, и после холодного старта (green).
