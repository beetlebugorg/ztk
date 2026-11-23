# Task 15: `entry`

This task uses the loop of task 04 for the caret timer. It does not depend on the loop of ztcl.

## Goal

The `entry` widget edits one line of left-to-right text with the keyboard and the pointer, shows a caret and a selection, and links to a variable.

## Files

- `src/text/edit.zig`: the edit model, with no dependence on a widget
- `src/widgets/entry.zig`
- `src/cmds.zig`: the registration and the class bindings
- `src/themes/modern.css`: the `Entry` rules

## Interfaces

```zig
// src/text/edit.zig. All indexes count characters (code points).
pub const Edit = struct {
    pub fn init(gpa: std.mem.Allocator) Edit;
    pub fn deinit(e: *Edit) void;
    pub fn text(e: *const Edit) []const u8;          // UTF-8
    pub fn len(e: *const Edit) usize;                // characters
    pub fn setText(e: *Edit, utf8: []const u8) !void; // clamps the caret and clears the selection
    pub fn insert(e: *Edit, index: usize, utf8: []const u8) !void;
    pub fn delete(e: *Edit, first: usize, last: usize) void; // [first, last)
    caret: usize = 0,
    /// The selection is [sel_first, sel_last). Both 0 and equal: none.
    sel_first: usize = 0,
    sel_last: usize = 0,
    anchor: usize = 0,
    pub fn hasSelection(e: *const Edit) bool;
    pub fn select(e: *Edit, first: usize, last: usize) void;
    pub fn clearSelection(e: *Edit) void;
    /// Moves the caret. With `extend`, the selection goes from the anchor
    /// to the new caret.
    pub fn moveTo(e: *Edit, index: usize, extend: bool) void;
    pub const Step = enum { prev_char, next_char, prev_word, next_word, line_start, line_end };
    pub fn target(e: *const Edit, step: Step) usize;
    /// Replaces the selection, or inserts at the caret.
    pub fn typeText(e: *Edit, utf8: []const u8) !void;
    pub fn backspace(e: *Edit) void;     // deletes the selection, or the character before the caret
    pub fn deleteForward(e: *Edit) void;
    pub fn wordAt(e: *const Edit, index: usize) [2]usize;
    /// The byte offset of a character index.
    pub fn byteOf(e: *const Edit, index: usize) usize;
};

// src/widgets/entry.zig
pub const class: Class;   // command "entry", type name "Entry", focusable
```

## Steps

1. Read `doc/entry.n`: the sections "WIDGET-SPECIFIC OPTIONS", "INDICES", "WIDGET COMMAND", and "DEFAULT BINDINGS".
2. The edit model is a pure data structure. A word is a run of letters, digits, and `_`. `prev_word` and `next_word` go to the start of the word before the caret and to the end of the word after it. Stage 4 changes the word and character rules to UAX #29.
3. The options of Stage 1: `-textvariable`, `-show`, `-state` (`normal`, `disabled`, `readonly`), `-width` (in characters, default 20), `-font`, `-foreground` and `-fg`, `-background` and `-bg`, `-borderwidth` and `-bd`, `-relief`, `-justify` (only `left` works), `-insertwidth` (default 2), `-insertontime` (default 600), `-insertofftime` (default 300), `-selectbackground`, `-selectforeground`, `-exportselection` (stored), `-takefocus`, `-cursor`. Each other option of the Tk entry gives `unknown option`. Add them to `docs/stage1-limits.md`.
4. The widget subcommands, with the messages of `wish`:
   - `get`
   - `insert index text`. `wish` gives `wrong # args: should be ".e insert index text"` for a wrong count.
   - `delete first ?last?`. With no `last`, it deletes one character.
   - `icursor index`
   - `index index`. It gives a number.
   - `selection clear`, `selection present`, `selection range start end`. The other words (`adjust`, `from`, `to`) give `selection <word> is not supported in this stage`. A wrong word gives `bad selection option "bogus": must be adjust, clear, from, present, range, or to`.
   - `bbox`, `scan`, `validate`, and `xview` give `<name> is not supported in this stage`.
   - A wrong name gives `bad option "bogus": must be bbox, cget, configure, delete, get, icursor, index, insert, scan, selection, validate, or xview`.
5. The index forms: a number, `end`, `insert`, `anchor`, `sel.first`, `sel.last`, and `@x` (the character at that x in the widget). A number below 0 is 0, and a number above the length is the length: `wish` gives `5` for `.e index 99` with five characters. `sel.first` with no selection gives `selection isn't in widget .e`. A wrong form gives `bad entry index "bogus"`.
6. `insert` and `delete` have no effect in the `disabled` and `readonly` states, and give no error. `wish` leaves the text as it is for `.e insert end zzz` on a readonly entry.
7. `-textvariable`. On creation and on `configure`, when the variable exists, the entry shows its value. When it does not exist, the entry creates it with its text. Each edit writes the variable. A write to the variable by a script changes the text: use the script trace of task 11 with a flag that stops the loop when the entry itself writes. `wish` gives `init` for `.e get` after `set tv init; .e configure -textvariable tv`.
8. `-show c` draws the first character of the value in place of each character. `get` still gives the real text.
9. Measure: the width is `-width` times the width of `0`, plus the insets of the style. The height is the line height plus the insets.
10. The scroll offset. The entry keeps `left`, the logical pixel offset of the text. After each change of the caret, change `left` so that the caret is inside the content rectangle. When the text is shorter than the rectangle, `left` is 0.
11. Paint, in this order: the box, a clip of the content rectangle, the selection box (the style of the part `::selection`: its `background-color` and `color`), the text, and the caret. The caret is a box of `-insertwidth` logical pixels in the `caret-color`, with the height of the line. The glyphs inside the selection have the selection text color: make two clips, or split the run at the selection.
12. The caret shows only when the entry has the `focus` bit and the state is `normal`. It is on for `-insertontime` and off for `-insertofftime`, with `Loop.addNative`. An off time of 0 means no blink. Each key and each click starts the on time again. When the focus leaves, cancel the timer.
13. The class bindings on the tag `Entry`. Each script is one call of `::ztk::priv::entry <action> %W` with the fields it needs:

    | Pattern | Action |
    |---|---|
    | `<Button-1>` | Set the caret at `%x`, clear the selection, set the anchor, take the focus |
    | `<B1-Motion>` | Extend the selection to `%x` |
    | `<Double-Button-1>` | Select the word at `%x` |
    | `<Triple-Button-1>` | Select all |
    | `<Shift-Button-1>` | Extend the selection to `%x` |
    | `<Key-Left>`, `<Key-Right>` | Move one character and clear the selection |
    | `<Shift-Key-Left>`, `<Shift-Key-Right>` | Move one character and extend |
    | `<Control-Key-Left>`, `<Control-Key-Right>` | Move one word |
    | `<Key-Home>`, `<Key-End>` | Move to the start or the end |
    | `<Shift-Key-Home>`, `<Shift-Key-End>` | Move and extend |
    | `<Key-BackSpace>`, `<Key-Delete>` | Delete |
    | `<Control-Key-a>` | Move to the start, as Tk on X11 does |
    | `<Control-Key-e>` | Move to the end |
    | `<Control-Key-slash>` | Select all |
    | `<Key>` | Insert `%A` when it is not empty and is not a control character |
    | `<Control-Key>`, `<Alt-Key>`, `<Key-Return>`, `<Key-Escape>`, `<Key-Tab>` | No edit. The script is a comment (`# no edit`). It is more specific than `<Key>`, so the `<Key>` binding does not insert the character. `wish` lists the same five patterns in `bind Entry`. |

    Tk uses virtual events (`<<PrevChar>>`, `<<SelectAll>>`) for many of these. Stage 2 changes to them when `event add` exists. The clipboard bindings are Stage 2.
14. A key that the entry handled keeps the default flow: the tags `.` and `all` still run, so `Tab` still moves the focus and a `<Return>` binding of the script on the entry runs.
15. The `Entry` rules of the modern theme: the field background, a 1 pixel border, the radius, the padding `5px 8px`, a `:focus` border in the accent color, a `:disabled` look, and `Entry::selection` with the accent background and its text color.

## Tests

```sh
zig build test -Dtest-filter=edit
zig build test -Dtest-filter=entry
```

Unit tests of `Edit`:

- `insert(0, "héllo")` gives the length 5. `byteOf(2)` is 3.
- `delete(1, 3)` of `hello` gives `hlo`.
- `typeText` with a selection replaces it and clears the selection.
- `backspace` at index 0 has no effect. `backspace` after `é` deletes two bytes.
- `target(.prev_word)` in `foo bar|` is 4. `target(.next_word)` in `|foo bar` is 3.
- `moveTo(3, true)` from the caret 1 with the anchor 1 selects [1, 3). `moveTo(0, true)` then selects [0, 1).
- `wordAt(5)` in `foo bar baz` is [4, 7).
- `setText` with a shorter text clamps the caret.

Script tests with a `Harness`. The values are from `wish` 8.6.16.

- `.e insert 0 hello; .e index end` gives `5`. `.e icursor 2; .e index insert` gives `2`.
- `.e selection range 1 3; list [.e selection present] [.e index sel.first] [.e index sel.last]` gives `1 1 3`.
- `.e delete sel.first sel.last; .e get` gives `hlo`.
- `.e selection clear; .e index sel.first` gives the error of step 5.
- `.e delete 0 end; .e insert end abc; .e insert 1 XY; .e get` gives `aXYbc`. `.e delete 2; .e get` gives `aXbc`.
- `.e index 99` gives `4`. `.e index -5` gives `0`. `.e index bogus` gives the error.
- The readonly and disabled states do not change the text.
- `-textvariable` in both directions: `set tv init`, configure, `get` gives `init`. `.e insert end Q; set tv` gives `initQ`. `set tv new; .e get` gives `new`.
- `-show *`: `get` gives the real text, and the scene dump has only the glyph of `*`.
- `focus .e` and `h.head.typeText("Ada")`: `get` gives `Ada`.
- `Left`, `Left`, `x`: `Axda`. `BackSpace`: `Ada`. `Home`, `Delete`: `da`. `End`, `!`: `da!`.
- `Shift-Left` two times and `x` replaces two characters.
- `Control-a` and then `z` inserts at the start.
- A click at the x of the middle of the text sets the caret there (compare with `Run.indexAt`).
- A press, a move, and a release select the characters between the two points.
- A double click on a word selects it.
- `bind .e <Return> {set got [.e get]}` runs on `h.head.press("Return")`, and the text has no new character.
- `Tab` moves the focus to the next widget, and the text has no tab character.
- A long text: after 60 characters in an entry of 20, the caret x in the scene dump is inside the content rectangle.
- The caret: with the manual clock, the scene has the caret quad at 0 ms, has no caret quad at 700 ms, and has it again at 950 ms. An entry with no focus has no caret quad and no timer.
- An entry with no focus and no pending change draws no frame in 5 000 ms of the manual clock.

Golden images and scene dumps, with the modern theme, 260 by 60:

- `entry-empty-focus`: the caret at the start and the focus border.
- `entry-text`: a text and no focus.
- `entry-selection`: a part of the text is selected.
- `entry-scrolled`: a long text with the caret at the end.
- `entry-disabled`
- `entry-show`: a password with `-show *`.

## Acceptance

- All tests pass.
- The reviewer opens the six images. The caret has the height of the line. The selection covers the selected characters exactly. No glyph is outside the field.
- `src/text/edit.zig` imports no widget code and no ztcl.
- Each key of a test goes through `dispatch.handle` and the class bindings. No test calls the edit model directly for a key.

## Out of scope

- The clipboard, the primary selection, and `-exportselection`.
- Validation (`-validate`, `-validatecommand`, `-invalidcommand`).
- `xview`, `-xscrollcommand`, `scan`, and `bbox`.
- `-justify center` and `right`.
- Input methods, right-to-left text, and undo.
