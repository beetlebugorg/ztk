# Famous Tcl/Tk apps on ztk

This page is the table of #222: well-known Tcl/Tk apps that run on ztcl and ztk. Each app has a pinned release and a script in `tests/apps` that drives it with `ztk::inject`, as a person does. `tests/famous-apps.sh` runs all the scripts, and the 6-hour full CI run runs it.

## How to run them

```sh
zig build
tools/fetch-apps.sh          # the pinned releases into .apps-src/
tests/famous-apps.sh shots   # each app, with its PNG images in shots/
```

The program runs each app as `ztk --headless --windowingsystem x11 --allow package,clock,event,env,exec,interp`. The flag `--windowingsystem x11` is necessary: these apps test `tk windowingsystem` for `x11`, `win32`, or `aqua`.

The release archives are data. `tools/fetch-apps.sh` checks the SHA-256 of each archive (`tests/apps/pins.txt`) and runs no file of it. gitk, git gui, and TkDiff have the GPL: the scripts only run them, and no code of them goes into ztk or ztcl.

## The table

| App | Version | Launches | Main flows in the script | Status | Gaps |
|---|---|---|---|---|---|
| Tk widget demo | 8.6.16 | Yes | A click on each of the 60 demo lines opens its demo window with no error, except the known gaps. | Works with gaps | #249 text peers, #250 Tk in a child interpreter, #251 canvas bitmaps from a file, #252 hscale and vscale |
| tkcon | 2.5 | Yes | Type `expr`, `set`, an unknown command, and Up for the history; the console shows each result. | Works | |
| BWidget demo | 1.10.1 | Yes | A click on each of the 6 notebook tabs shows its page; typing into an entry; a click on a button. | Works | |
| Tablelist demos | 7.12 | Yes | dirViewer, styles, embeddedWindows, config, browse, browseTree: a click selects a row, a click on a label sorts, a double click opens a folder. | Works | miscWidgets needs other packages (Iwidgets, combobox) |
| tklib | 0.9 | Yes | 19 Plotchart examples draw their charts; tooltip on a hover, ctext colors a typed keyword, datefield takes a typed date. | Works | |
| gitk | git 2.56.0 | Yes | The list shows three commits; a click on a commit shows its diff; the key Up selects the commit above. | Works | #258 snapshot after a long vwait |
| TkDiff | 5.7 | Yes | The toolbar and the diff count show. | In progress | #253 the text panes do not show |
| git gui | git 2.56.0 | Not tried | | In progress | #254 |

## Comparison with wish 8.6.16

`wish` 8.6.16 is on the development machine. A screenshot of an app in `wish` comes from `xvfb-run wish` and `import -window`. The Tablelist demo dirViewer looks the same in both, apart from the fonts and the scrollbars of the modern theme. The other apps were compared by their behavior: the same results in the console of tkcon, the same commits and diffs in gitk, and the same pages in BWidget.

## What changed in ztk and ztcl for these apps

- ztk: the package Tk and `tk_version`; the commands `font`, `option` (the option database, a source of `ztk::debug why`), `selection` (inside the app), `bell`, `tk_optionMenu`, `tk_focusNext` and `tk_focusPrev` in Tcl, `event add`, `tk busy`, `tk fontchooser`, `tk appname`, and the helpers of the Tk library that apps call (`::tk::AmpMenuArgs`, `::tk::PlaceWindow`, `::ttk::cursor`, and others).
- ztk: GIF, PPM, and all PNG color types for photos; `image create bitmap`; photo `read` and `put` of image data; the color names of Tk; the other subcommands of `winfo` and `wm`; the options of `label`, `button`, and `frame` that were missing, with `-wraplength`; prefixes of subcommands, anchors, and menu entry types; `pack -in` and panes that are not children; the Visibility event; `tkwait visibility`; `fileevent` in the loop of ztk.
- ztcl: msgcat, `auto_path` and `pkgIndex.tcl`, `auto_load`, `history`, the free form and relative items of `clock scan`, `~` in paths, `open wb`, and global names of `interp alias`.

## Next

- git gui (#254) and TkDiff (#253).
- The Tcl candidates of #222: the test suites of tcllib and tklib, TclHttpd, Wapp, tcltest.
- The apps with C packages after the C package loader of ztcl.
