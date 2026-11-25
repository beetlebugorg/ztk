# Menus on each platform

This page is the design of the menus of task 12. The user decided on 2026-11-25 that each platform shows its own kind of menu. The core keeps the Tk menu model on each platform. Each backend shows the menus in one of two ways.

## The split

The core has the model of Tk:

- the `menu` widget with its entries, its options, and its subcommands;
- `menubutton`, `ttk::menubutton`, `tk_popup`, and the `-menu` option of a toplevel;
- `invoke`, the variables of the check and radio entries, `-postcommand`, and `<<MenuSelect>>`;
- the class bindings and the keys of the menus.

A backend shows the menus:

| Platform | Menu bar | Popup and cascade |
|---|---|---|
| macOS | The system menu bar (`NSMenu`) | `NSMenu` popup |
| Windows | The menu bar of the window (`HMENU`) | `TrackPopupMenuEx` |
| Linux (Wayland, X11) | Drawn by the core in the window, as Tk does on X11 | A popup surface that the core draws (`xdg_popup` on Wayland) |
| Web | Drawn by the core in the page canvas | A canvas in a layer above the page canvas |
| Headless | Drawn, or native for a test | Drawn into a popup window, or native for a test |

## The native menus

A backend with native menus sets `Platform.native_menus` and has the menu functions of the table in `src/platform/platform.zig`:

1. `menuSet` defines a menu or replaces each entry of it. The core gives each `menu` widget a `MenuId`. It calls `menuSet` for a menu before the menu is in a bar, in a cascade, or posted, and again after a change. The tearoff entry of Tk is not in the list. The core maps the Tk index to the index in the list.
2. `menuEntrySet` changes one entry and keeps the count, for example the indicator of a check entry after a write of its variable.
3. `menuDrop` removes a menu after the core removed it from each bar and cascade.
4. `setMenuBar` sets the bar of a window. The cascades of the menu are the menus of the bar. On macOS the system bar shows the bar of the key window.
5. `postMenu` shows a popup at a point of the window in logical pixels. The entry index is a hint: when it is 0 or more, the backend puts that entry at the point when it can, as `post x y index` does in Tk. macOS can (`popUpMenuPositioningItem:atLocation:inView:`). Windows ignores the hint, because `TrackPopupMenuEx` cannot put an entry at the point. A backend with a modal menu loop returns after the menu closes and queues the events of the menu.
6. `unpostMenu` closes a posted menu and its cascades.
7. `setMenuHandler` gives the backend the handler of the core. The core calls it one time, before the first menu call. The backend calls the handler on the UI thread, inside its menu loop, for the actions `opening` and `select` (below). Windows calls it from `WM_INITMENUPOPUP` and `WM_MENUSELECT`. macOS calls it from `menuNeedsUpdate:` and `menu:willHighlightItem:`.

The core sets the `role` of a menu from its path name, as Tk on macOS does. In the menu bar, a cascade with the menu `.apple` (for example `.menubar.apple`) is `app`: its entries go at the top of the application menu. `.help` is `help`, the Help menu of the system. `.window` is `window`, the Window menu of the system. A backend without these menus ignores the role. Windows can put the `help` menu at the right end of the bar.

The strings of a `MenuEntry` are valid only during the call. The backend copies what it keeps.

The backend answers with the `menu` event or with a call of the handler. The `entry` is an index into the list of the last `menuSet` of that menu, or -1. The actions are:

- `opening`: a menu opens from a bar or a cascade. The core runs `-postcommand` and calls `menuSet` when the entries changed. Inside a call of the handler, this happens before the call returns, so the menu shows its new entries the first time. A backend without the handler queues the event and can show the old entries.
- `select`: the highlighted entry changed. The core sends `<<MenuSelect>>` to the menu widget, with the entry as the active entry. Inside a call of the handler, the binding runs before the call returns.
- `invoke`: the user chose the entry. The backend queues it. The core runs the entry as `invoke` does: it sets the variable, then runs `-command`.
- `closed`: the menu closed. The backend queues it.

The application menu of macOS has About, Settings, and Quit. The backend sends them as the `app_command` event, which has no window, because Quit can come with no window open. The core maps them as Tk on macOS does:

- `about` calls `tkAboutDialog` when the script has it.
- `settings` calls `::tk::mac::ShowPreferences` when the script has it.
- `quit` calls `::tk::mac::Quit` when the script has it. Else the core closes `.` as a `close` event does: it runs the `WM_DELETE_WINDOW` script, or destroys `.`.

Services, Hide, Hide Others, and Show All stay in AppKit.

The Windows backend shows system menus with the light look for now. Menus that the backend draws itself (owner-draw), with the dark scheme, come later.

In Tk, `-accelerator` only shows text, and a binding of the script handles the key. So a backend shows the accelerator text and gives the key to the core as a `key` event. It does not invoke the entry from the key.

## The drawn menus

A backend without native menus gets the menus that the core draws. The bar is a row at the top of the window, as Tk on X11 has it. A popup and a cascade each go in a popup surface when the backend sets `Platform.popups`: `createWindow` with `WindowOptions.popup` gives a window next to an anchor rectangle of its parent window. The popup can extend past the edges of the parent. The backend flips or slides it when the screen has no room on the side that the core asked for. The backend sends `close` for the popup window when the system dismissed it. A backend without popups gets the menu drawn inside the parent window.

A drawn menu opens with a fade and a short slide from its anchor, as the list of a combobox does.

## The PRs

1. This page, the interface in `src/platform/platform.zig`, the `menu` and `app_command` events, the map of the application commands, and the record of the calls in the headless backend. The core ignores the `menu` event until PR 2.
2. The menu model, the drawn menus in popup windows of the headless backend, and the native path against the record of the headless backend.
3. The popup surfaces of the Wayland backend and the popup layer of the web backend.

The macOS and Windows backends fill the native functions in their own PRs.
