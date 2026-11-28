# The widget reference: button. The format is the format of ztcl
# (docs/dev/reference-format.md in the ztcl repository).

command button {
    area widgets
    kind widget
    since 1.0.0-beta.1
    synopsis {button PATHNAME ?OPTION VALUE ...?}
    summary {Makes a push button: a widget with a text or an image that runs a script when the user clicks it.}
    description {
        Makes a button widget with the name PATHNAME and the options of the call, and makes the command PATHNAME for the widget commands below. A click on the button runs the script of `-command`. The button shows its `-text`, the value of its `-textvariable`, or its `-image`.

        The parent of PATHNAME must exist, and PATHNAME must not. A button is a `Button` in CSS and for the option database, and `ztk::class` gives it a style class for a stylesheet.

        The theme draws the border and the padding, so `-borderwidth`, `-padx`, and `-pady` default to 0, and a value of the script overrides the theme. Some options for the look of Tk on X11 are stored with no effect in the modern theme, such as `-highlightthickness`, `-activebackground`, and `-overrelief`. [Differences from Tk](differences/) lists them, and the theme `classic` has the look of Tk on X11.

        An option needs its full name or a short form of its own, such as `-bg` for `-background`: `-tex` is an unknown option, in ztk and in Tk 8.6.16.
    }
    returns {PATHNAME.}
    difference {`flash` gives an empty result and shows no change in ztk. In Tk 8.6.16 it shows the active and the normal colors in turn before it returns.}
    difference {The size in a `-font` description can have a fraction, such as `{Helvetica 12.5}`. Tk 8.6.16 needs an integer.}
    see {label checkbutton radiobutton ttk::button {button invoke} {button configure}}
    example {
        button .save -text Save -command {set ::saved 1}
        .save invoke
        set saved
    } 1
    example {winfo class [button .go -text Go]} Button
    error {button .x -text a -foo b} {unknown option "-foo"} {TK LOOKUP OPTION -foo}
    error {
        button .twice
        button .twice
    } {window name "twice" already exists in parent} {TK VALUE WINDOW EXISTS}
    error {button .no.b} {bad window path name ".no"} {TK LOOKUP WINDOW .no} -note {The parent .no does not exist.}
    error {button} {wrong # args: should be "button pathName ?-option value ...?"} {TCL WRONGARGS}
    option -activebackground {
        value COLOR
        type color
        default {#ececec}
        dbname activeBackground
        dbclass Foreground
        summary {The background color under the pointer, in the look of Tk on X11.}
        description {
            The background of the button while the pointer is over it, or while `-state` is `active`. A color is a name such as `red`, or `#RGB`, `#RRGGBB`, or `#RRRRGGGGBBBB`. The modern theme stores the value with no effect.
        }
        example {
            button .ab -activebackground #ff0000
            .ab cget -activebackground
        } {#ff0000}
        error {button .ab2 -activebackground nocolor} {unknown color name "nocolor"} {TK LOOKUP COLOR nocolor}
    }
    option -activeforeground {
        value COLOR
        type color
        default {#000000}
        dbname activeForeground
        dbclass Background
        summary {The text color under the pointer, in the look of Tk on X11.}
        description {
            The color of the text while the pointer is over the button, or while `-state` is `active`. The class in the option database is `Background`, as in Tk.
        }
        example {
            button .af -activeforeground white
            .af cget -activeforeground
        } white
        error {button .af2 -activeforeground nocolor} {unknown color name "nocolor"} {TK LOOKUP COLOR nocolor}
    }
    option -anchor {
        value ANCHOR
        type anchor
        default center
        dbname anchor
        dbclass Anchor
        summary {The place of the text or the image in a button larger than it.}
        description {
            When the button is larger than its text or image, such as with `-width` or a geometry manager that stretches it, the anchor puts the content at that side or corner. `center` puts it in the middle.
        }
        values {n ne e se s sw w nw center}
        example {
            button .an -text Go -anchor w
            .an cget -anchor
        } w
        error {button .an2 -anchor middle} {bad anchor "middle": must be n, ne, e, se, s, sw, w, nw, or center} {TCL LOOKUP INDEX anchor middle}
    }
    option -background {
        value COLOR
        type color
        default {#d9d9d9}
        dbname background
        dbclass Background
        summary {The background color of the button.}
        description {
            The color behind the text. `-bg` is the same option. With no value from the script, `cget` gives the color of the theme, which can differ from the default of the option database: `.b configure -background` lists both.
        }
        example {
            button .bg -bg red
            .bg cget -background
        } red
        example {
            button .bg3
            lindex [.bg3 configure -background] 3
        } {#d9d9d9} -note {The default of the option database.}
        error {button .bg2 -background nocolor} {unknown color name "nocolor"} {TK LOOKUP COLOR nocolor}
    }
    option -bitmap {
        value BITMAP
        type {bitmap name}
        default {}
        dbname bitmap
        dbclass Bitmap
        summary {A bitmap name of Tk to show in place of the text.}
        description {
            The name of a built-in bitmap of Tk: `error`, `gray12`, `gray25`, `gray50`, `gray75`, `hourglass`, `info`, `questhead`, `question`, or `warning`. A value that starts with `@` names a file. ztk stores the value for `cget` and shows no bitmap.
        }
        error {button .bm2 -bitmap nobitmap} {bitmap "nobitmap" not defined} {TK LOOKUP BITMAP nobitmap}
        example {
            button .bm -bitmap error
            .bm cget -bitmap
        } error
    }
    option -borderwidth {
        value DISTANCE
        type {screen distance}
        default 0
        dbname borderWidth
        dbclass BorderWidth
        summary {The width of the border, in place of the border of the theme.}
        description {
            The width of the border around the button. `-bd` is the same option. The default 0 leaves the border to the theme, and a value of the script replaces it. A distance is a count of pixels, or a number with `c`, `i`, `m`, or `p` for centimeters, inches, millimeters, or points.
        }
        example {
            button .bw -text Save
            button .bw6 -text Save -borderwidth 6
            expr {[winfo reqwidth .bw6] > [winfo reqwidth .bw]}
        } 1
        example {
            button .bd -bd 3
            .bd cget -borderwidth
        } 3
        error {button .bw2 -borderwidth x} {bad screen distance "x"} {TK VALUE PIXELS}
    }
    option -command {
        value SCRIPT
        type script
        default {}
        dbname command
        dbclass Command
        summary {The script that a click or `invoke` runs.}
        description {
            The script runs at the global level when the user clicks the button, and when a script calls `invoke`. Its result is the result of `invoke`, and an error of the script is the error of `invoke`. A button with `-state disabled` runs no script. An empty script runs no command.
        }
        example {
            set n 0
            button .cm -command {incr ::n}
            .cm invoke
            .cm invoke
            set n
        } 2
        example {
            button .cm3 -command {list a b}
            .cm3 invoke
        } {a b}
        error {
            button .cm2 -command {error boom}
            .cm2 invoke
        } boom NONE
    }
    option -compound {
        value PLACE
        type compound
        default none
        dbname compound
        dbclass Compound
        summary {Shows the image and the text together, with the image at that side.}
        description {
            With `none`, a button with an `-image` shows only the image. Each other value shows the image and the text, with the image at that side of the text, or under the text with `center`.
        }
        values {none bottom center left right top}
        example {
            image create photo pic -width 40 -height 20
            button .ci -image pic -text Save
            button .cl -image pic -text Save -compound left
            expr {[winfo reqwidth .cl] > [winfo reqwidth .ci]}
        } 1
        error {button .co -compound sideways} {bad compound "sideways": must be bottom, center, left, none, right, or top} {TCL LOOKUP INDEX compound sideways}
    }
    option -cursor {
        value CURSOR
        type {cursor name}
        default {}
        dbname cursor
        dbclass Cursor
        summary {The shape of the pointer over the button.}
        description {
            A cursor name of Tk, such as `hand2`, as the first word of a list. The names are the names of the cursor font of X and the names of Tk on Windows, such as `size_we`, in any case. A value that starts with `@` names a file. An empty value uses the cursor of the parent.
        }
        error {button .cu2 -cursor nocursor} {bad cursor spec "nocursor"} {TK VALUE CURSOR}
        example {
            button .cu -cursor hand2
            .cu cget -cursor
        } hand2
    }
    option -default {
        value STATE
        type state
        default disabled
        dbname default
        dbclass Default
        summary {Marks the default button of a dialog.}
        description {
            `active` marks the button as the default of its dialog, the one that the Return key of the dialog runs. `normal` is a button that can be the default, and `disabled` is a button that never is. The value has no effect on the size of the button.
        }
        values {active disabled normal}
        example {
            button .de -text OK -default active
            .de cget -default
        } active
        example {
            button .de2 -text OK
            button .de3 -text OK -default active
            expr {[winfo reqwidth .de2] == [winfo reqwidth .de3]}
        } 1
        error {button .de4 -default maybe} {bad default "maybe": must be active, disabled, or normal} {TCL LOOKUP INDEX default maybe}
    }
    option -disabledforeground {
        value COLOR
        type color
        default {#a3a3a3}
        dbname disabledForeground
        dbclass DisabledForeground
        summary {The text color while the state is disabled.}
        description {The color of the text while `-state` is `disabled`.}
        example {
            button .df -disabledforeground gray50
            .df cget -disabledforeground
        } gray50
        error {button .df2 -disabledforeground nocolor} {unknown color name "nocolor"} {TK LOOKUP COLOR nocolor}
    }
    option -font {
        value FONT
        type font
        default TkDefaultFont
        dbname font
        dbclass Font
        summary {The font of the text.}
        description {
            A font name, such as `TkDefaultFont`, or a font description, such as `{Helvetica 12 bold}` or `{-family Helvetica -size 12}`. A larger font makes a larger button. A family that does not exist falls back to a font of the system.
        }
        error {button .fo4 -font {Helvetica 12 weird}} {unknown font style "weird"} {TK LOOKUP FONT_STYLE weird}
        error {button .fo5 -font {Helvetica big}} {expected integer but got "big"} {TCL VALUE NUMBER}
        error {button .fo6 -font {-family Helvetica -weight heavy}} {bad -weight value "heavy": must be normal, or bold} {TK LOOKUP -weight heavy}
        error {button .fo7 -font {}} {font "" doesn't exist} {TK LOOKUP FONT {}}
        example {
            button .fo -text Save
            button .fo2 -text Save -font {Helvetica 24}
            expr {[winfo reqheight .fo2] > [winfo reqheight .fo]}
        } 1
        example {
            button .fo3 -font {Helvetica 12 bold}
            .fo3 cget -font
        } {Helvetica 12 bold}
    }
    option -foreground {
        value COLOR
        type color
        default {#000000}
        dbname foreground
        dbclass Foreground
        summary {The color of the text.}
        description {The color of the text and of a bitmap. `-fg` is the same option.}
        example {
            button .fg -fg #123456
            .fg cget -foreground
        } {#123456}
        error {button .fg2 -foreground nocolor} {unknown color name "nocolor"} {TK LOOKUP COLOR nocolor}
    }
    option -height {
        value LINES
        type integer
        default 0
        dbname height
        dbclass Height
        summary {The height of the button in lines of text, or in pixels for an image.}
        description {
            For a button with text, the height in lines of the font. For a button with an image, the height in pixels. 0 makes the button as tall as its content.
        }
        example {
            button .he -text Save
            button .he3 -text Save -height 3
            expr {[winfo reqheight .he3] > 2 * [winfo reqheight .he]}
        } 1
        error {button .he2 -height x} {expected integer but got "x"} {TCL VALUE NUMBER}
    }
    option -highlightbackground {
        value COLOR
        type color
        default {#d9d9d9}
        dbname highlightBackground
        dbclass HighlightBackground
        summary {The color of the focus ring while the button has no focus, in the look of Tk on X11.}
        description {The color of the highlight ring of `-highlightthickness` while the button does not have the focus.}
        example {
            button .hb -highlightbackground white
            .hb cget -highlightbackground
        } white
        error {button .hb2 -highlightbackground nocolor} {unknown color name "nocolor"} {TK LOOKUP COLOR nocolor}
    }
    option -highlightcolor {
        value COLOR
        type color
        default {#000000}
        dbname highlightColor
        dbclass HighlightColor
        summary {The color of the focus ring while the button has the focus, in the look of Tk on X11.}
        description {The color of the highlight ring of `-highlightthickness` while the button has the focus.}
        example {
            button .hc -highlightcolor blue
            .hc cget -highlightcolor
        } blue
        error {button .hc2 -highlightcolor nocolor} {unknown color name "nocolor"} {TK LOOKUP COLOR nocolor}
    }
    option -highlightthickness {
        value DISTANCE
        type {screen distance}
        default 1
        dbname highlightThickness
        dbclass HighlightThickness
        summary {The width of the focus ring, in the look of Tk on X11.}
        description {
            The width of the ring around the button that shows the focus. The modern theme draws the focus with the stylesheet, so it stores the value with no effect on the size.
        }
        example {
            button .ht -text Save
            button .ht5 -text Save -highlightthickness 5
            expr {[winfo reqwidth .ht5] == [winfo reqwidth .ht]}
        } 1
        error {button .ht2 -highlightthickness x} {bad screen distance "x"} {TK VALUE PIXELS}
    }
    option -image {
        value IMAGE
        type {image name}
        default {}
        dbname image
        dbclass Image
        summary {An image to show in place of the text.}
        description {
            The name of an image of `image create`. With an image and `-compound none`, the button shows the image and no text. The image must exist when the option is set.
        }
        example {
            image create photo icon -width 40 -height 20
            button .im -image icon -text Save
            button .im2 -image icon
            expr {[winfo reqwidth .im] == [winfo reqwidth .im2]}
        } 1 -note {The text does not show, so the two buttons have the same width.}
        error {button .im3 -image noimage} {image "noimage" doesn't exist} {TK LOOKUP IMAGE noimage}
    }
    option -justify {
        value SIDE
        type justification
        default center
        dbname justify
        dbclass Justify
        summary {The alignment of the lines of a text of more than one line.}
        description {
            How the lines of a text with more than one line line up with each other. A text breaks into lines at each newline and at `-wraplength`.
        }
        values {left center right}
        example {
            button .ju -text "one\ntwo" -justify left
            .ju cget -justify
        } left
        error {button .ju2 -justify middle} {bad justification "middle": must be left, right, or center} {TCL LOOKUP INDEX justification middle}
    }
    option -overrelief {
        value RELIEF
        type relief
        default {}
        dbname overRelief
        dbclass OverRelief
        summary {The relief under the pointer, in the look of Tk on X11.}
        description {
            The relief of the button while the pointer is over it. An empty value keeps `-relief`. The modern theme stores the value with no effect.
        }
        error {button .or2 -overrelief bumpy} {bad relief "bumpy": must be flat, groove, raised, ridge, solid, or sunken} {TCL LOOKUP INDEX relief bumpy}
        example {
            button .or -overrelief raised
            .or cget -overrelief
        } raised
    }
    option -padx {
        value DISTANCE
        type {screen distance}
        default 0
        dbname padX
        dbclass Pad
        summary {The space at the left and the right of the content, in place of the padding of the theme.}
        description {
            The default 0 leaves the padding to the theme, and a value of the script replaces the padding of the theme at both sides.
        }
        example {
            button .px -text Save
            button .px20 -text Save -padx 20
            expr {[winfo reqwidth .px20] > [winfo reqwidth .px]}
        } 1
        error {button .px2 -padx x} {bad screen distance "x"} {TK VALUE PIXELS}
    }
    option -pady {
        value DISTANCE
        type {screen distance}
        default 0
        dbname padY
        dbclass Pad
        summary {The space above and below the content, in place of the padding of the theme.}
        description {
            The default 0 leaves the padding to the theme, and a value of the script replaces the padding of the theme above and below.
        }
        example {
            button .py -text Save
            button .py10 -text Save -pady 10
            expr {[winfo reqheight .py10] > [winfo reqheight .py]}
        } 1
        error {button .py2 -pady x} {bad screen distance "x"} {TK VALUE PIXELS}
    }
    option -relief {
        value RELIEF
        type relief
        default flat
        dbname relief
        dbclass Relief
        summary {The 3-D look of the border.}
        description {
            The style of the border: `raised` and `sunken` look 3-D, and `groove` and `ridge` are lines. The theme draws the border, and the CSS of the theme can give a relief its own look with `border-style`.
        }
        values {flat groove raised ridge solid sunken}
        example {
            button .re -text Go -relief groove
            .re cget -relief
        } groove
        error {button .re2 -relief bumpy} {bad relief "bumpy": must be flat, groove, raised, ridge, solid, or sunken} {TCL LOOKUP INDEX relief bumpy}
    }
    option -repeatdelay {
        value MS
        type integer
        default 0
        dbname repeatDelay
        dbclass RepeatDelay
        summary {The time in milliseconds before a held button starts to repeat its command.}
        description {
            In Tk, a value above 0 makes a held button run its command again after this time, and then each `-repeatinterval`. ztk stores the value for `cget`. The effect on a held button is not checked on this page.
        }
        example {
            button .rd -repeatdelay 400
            .rd cget -repeatdelay
        } 400
        error {button .rd2 -repeatdelay x} {expected integer but got "x"} {TCL VALUE NUMBER}
    }
    option -repeatinterval {
        value MS
        type integer
        default 0
        dbname repeatInterval
        dbclass RepeatInterval
        summary {The time in milliseconds between two repeats of a held button.}
        description {
            The time between two runs of the command of a held button, after `-repeatdelay`. ztk stores the value for `cget`. The effect on a held button is not checked on this page.
        }
        example {
            button .ri -repeatinterval 100
            .ri cget -repeatinterval
        } 100
        error {button .ri2 -repeatinterval x} {expected integer but got "x"} {TCL VALUE NUMBER}
    }
    option -state {
        value STATE
        type state
        default normal
        dbname state
        dbclass State
        summary {Whether the button works: normal, active, or disabled.}
        description {
            A `disabled` button ignores clicks, and `invoke` on it runs no script and gives an empty string. Set the state back to `normal` to turn the button on again.
        }
        choice normal {The button works and has its normal look.}
        choice active {The button has the look of a button under the pointer.}
        choice disabled {The button runs no command, with a click or with `invoke`, and has the text color of `-disabledforeground`.}
        example {
            button .st -state disabled -command {set ::hit 1}
            .st invoke
            info exists ::hit
        } 0
        example {
            .st configure -state normal
            .st invoke
        } 1
        error {button .st2 -state busy} {bad state "busy": must be active, disabled, or normal} {TCL LOOKUP INDEX state busy}
    }
    option -takefocus {
        value VALUE
        type {boolean, empty, or script}
        default {}
        dbname takeFocus
        dbclass TakeFocus
        summary {Whether the Tab key can move the focus to the button.}
        description {
            `1` puts the button in the order of the Tab key, `0` leaves it out, and an empty value uses the default rule of Tk for the widget. In Tk the value can also be a script, and its result is the answer. ztk stores each value with no check.
        }
        noerrors {ztk stores each value of the option with no check.}
        example {
            button .tf -takefocus 0
            .tf cget -takefocus
        } 0
    }
    option -text {
        value TEXT
        type string
        default {}
        dbname text
        dbclass Text
        summary {The text of the button.}
        description {
            The text that the button shows. A newline starts a new line. A longer text makes a wider button, unless `-width` sets the width. With `-textvariable`, the variable sets the text.
        }
        noerrors {Each string is a valid text.}
        example {
            button .tx -text Save
            set w [winfo reqwidth .tx]
            .tx configure -text "Save as"
            expr {[winfo reqwidth .tx] > $w}
        } 1
    }
    option -textvariable {
        value VAR
        type {variable name}
        default {}
        dbname textVariable
        dbclass Variable
        summary {A global variable whose value is the text of the button.}
        description {
            The button shows the value of the global variable VAR, and changes its text when the variable changes. When VAR has no value, the button sets it to its `-text`. The variable stays after the button is destroyed.
        }
        noerrors {Each name is a valid variable name.}
        example {
            button .tv -textvariable label
            set label Open
            .tv cget -text
        } Open
        example {
            button .tv2 -textvariable start -text Start
            set start
        } Start
    }
    option -underline {
        value INDEX
        type integer
        default -1
        dbname underline
        dbclass Underline
        summary {The index of a character of the text to underline, for a keyboard shortcut.}
        description {
            The index from 0 of the character of `-text` to underline. -1 underlines no character. The underline is a hint for a shortcut key, and the script binds the key itself.
        }
        example {
            button .un -text Save -underline 0
            .un cget -underline
        } 0
        error {button .un2 -underline x} {expected integer but got "x"} {TCL VALUE NUMBER}
    }
    option -width {
        value CHARS
        type integer
        default 0
        dbname width
        dbclass Width
        summary {The width of the button in characters of the font, or in pixels for an image.}
        description {
            For a button with text, the width in average characters of the font. For a button with an image, the width in pixels. 0 makes the button as wide as its content.
        }
        example {
            button .wi -text Hi
            button .wi10 -text Hi -width 10
            expr {[winfo reqwidth .wi10] > [winfo reqwidth .wi]}
        } 1
        error {button .wi2 -width x} {expected integer but got "x"} {TCL VALUE NUMBER}
    }
    option -wraplength {
        value DISTANCE
        type {screen distance}
        default 0
        dbname wrapLength
        dbclass WrapLength
        summary {The longest line of the text before it breaks into a new line.}
        description {
            A text longer than this distance breaks at a space into more lines. 0 breaks no line, so the text is one line long unless it has newlines.
        }
        example {
            button .wr -text "one two three four five six"
            button .wr60 -text "one two three four five six" -wraplength 60
            expr {[winfo reqheight .wr60] > [winfo reqheight .wr] && [winfo reqwidth .wr60] < [winfo reqwidth .wr]}
        } 1
        error {button .wr2 -wraplength x} {bad screen distance "x"} {TK VALUE PIXELS}
    }

    subcommand invoke {
        synopsis {PATHNAME invoke}
        summary {Runs the command of the button, as a click does.}
        description {
            Runs the `-command` script of the button at the global level and gives its result. A button with `-state disabled` runs no script and gives an empty string. An error of the script is the error of `invoke`. The command runs also with no window on the screen, so a test can drive a button with `invoke`.
        }
        returns {The result of the `-command` script, or an empty string.}
        see {button {button configure}}
        example {
            button .iv -command {list a b}
            .iv invoke
        } {a b}
        example {
            button .iv2 -command {list a b} -state disabled
            .iv2 invoke
        } {}
        error {button .iv3; .iv3 invoke x} {wrong # args: should be ".iv3 invoke"} {TCL WRONGARGS}
    }

    subcommand flash {
        synopsis {PATHNAME flash}
        summary {Flashes the button between its active and normal colors.}
        description {
            In Tk, `flash` shows the button a few times in its active and its normal colors and then returns. In ztk the command shows no change. It runs no script.
        }
        returns {An empty string.}
        see {{button invoke}}
        example {
            button .fl
            .fl flash
        } {}
        error {button .fl2; .fl2 flash now} {wrong # args: should be ".fl2 flash"} {TCL WRONGARGS}
    }

    subcommand cget {
        synopsis {PATHNAME cget OPTION}
        summary {Gives the value of an option of the button.}
        description {
            Gives the value of OPTION, with its full name. With no value from the script, the value is the value of the theme or the default of the option database. A short form such as `-bg` works.
        }
        returns {The value of the option.}
        see {{button configure}}
        example {
            button .cg -text Save
            .cg cget -text
        } Save
        example {
            button .cg2 -fg red
            .cg2 cget -fg
        } red
        error {button .cg3; .cg3 cget -tex} {unknown option "-tex"} {TK LOOKUP OPTION -tex}
        error {button .cg4; .cg4 cget} {wrong # args: should be ".cg4 cget option"} {TCL WRONGARGS}
    }

    subcommand configure {
        synopsis {PATHNAME configure}
        synopsis {PATHNAME configure OPTION}
        synopsis {PATHNAME configure OPTION VALUE ?OPTION VALUE ...?}
        summary {Gives or sets the options of the button.}
        description {
            With no argument, gives a list with an entry for each option. With one OPTION, gives its entry: the option, its database name, its database class, the default, and the value. A short form such as `-bd` has the entry `{-bd -borderwidth}`.

            With pairs of options and values, sets each option in order and gives an empty string. A bad value stops at that option with an error.
        }
        returns {An entry, a list of entries, or an empty string.}
        see {{button cget}}
        example {
            button .cf -text Save
            .cf configure -text
        } {-text text Text {} Save}
        example {
            button .cf2
            .cf2 configure -text Open -width 10
            list [.cf2 cget -text] [.cf2 cget -width]
        } {Open 10}
        example {
            button .cf3
            llength [.cf3 configure]
        } 35
        error {button .cf4; .cf4 configure -text a -width} {value for "-width" missing} {TK VALUE_MISSING}
        error {button .cf5; .cf5 configure -bogus 1} {unknown option "-bogus"} {TK LOOKUP OPTION -bogus}
    }
}
