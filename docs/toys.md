# Toys

Three games made with ztk. Each one runs in the page as WebAssembly, and a widget of Tk is part of its play: the tabs of a `ttk::notebook` are the streets of Lamplighter, a `listbox` is the bag of Skate Pond, and a `ttk::scale` is the burner of Tin Moon. Each game is a short Tcl script, and you can read and change its code under the frame.

<!-- toy-picker -->

## Play

- Click the frame, or press Enter on its button, to give the game the keys. A ring shows that the game has them.
- The arrow keys or W, A, S, and D move. Space or Z is A, and X is B. Enter starts.
- Escape or P pauses the game and gives the keys back to the page. The page scrolls as usual while the game has no keys.
- A gamepad works while the game has the keys. A touch screen shows a pad and two buttons in the frame.
- The sound and the music are off until you turn them on under the frame. "Shake off" turns off the screen shake and the flashes.
- Each game keeps your open levels and your best scores in this browser only.

## How the games are made

Each game is one Tcl script for ztk, from 400 to 600 lines. The design notes give the goals, the controls, the levels, and the checks of each game:

- [Lamplighter](build/lamplighter.md)
- [Skate Pond](build/skatepond.md)
- [Tin Moon](build/tinmoon.md)

The sound is made at run time in the page, with oscillators and noise of the Web Audio API. No game uses a sample, a font of its own, or an image file.
