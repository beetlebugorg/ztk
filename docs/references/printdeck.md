# Lessons from Printdeck

Printdeck is a touch screen and print server for Klipper printers. https://github.com/beetlebugorg/printdeck

**License:** AGPL-3.0. ztk has no code of Printdeck. This page states ideas and measured facts in new words. The implementer of ztk reads this page and does not open the Printdeck source.

**What Printdeck has:** its own UI framework in Go for a Raspberry Pi with a small touch display. It draws each frame on the CPU and writes it to the Linux framebuffer. It reads the touch panel from `evdev`. It has no display server and no GPU code. The same UI also shows in a browser.

The planner read these parts on 2026-11-23: the framebuffer package, the drawing package and its recording, the touch package, the layout and input package, the run loop of the UI, and the commit messages of these parts.

## What ztk uses

| # | Lesson of Printdeck | Fact | Where ztk uses it |
|---|---|---|---|
| 1 | A UI can draw directly to the framebuffer, with `evdev` for input. The code is small. | The framebuffer package has 143 lines and the `evdev` reader has 119 lines. | The direct backend: [task 20](../tasks/20-direct.md), and decision D21 of the plan. ztk adds a GPU output with Vulkan on the display. |
| 2 | Write only the rows that changed to the display. Framebuffer memory is slow to write, and most frames change few rows. | With music playing, the deck used 22 % of one core of a Raspberry Pi 5. After a cache for a scaled image and the changed-rows rule, it used 3.5 %. | `changedRows` in task 06, the `--cpu` path of task 17, task 20 |
| 3 | Cache a scaled image. Do not scale it again in each frame. | Part of the same measurement. | Images, Stage 2 |
| 4 | Convert to the panel format and turn the frame in the present step. The drawing code sees one upright RGBA canvas. | The panel formats are 16 bits (RGB565) and 32 bits. The rotations are 0, 90, 180, and 270 degrees. | Task 20 |
| 5 | Set the console to graphics mode, or the text console draws over the UI. Set it back at the exit. | | Task 20 |
| 6 | One list of drawing commands can make pixels, or go to a browser that draws it at its own pixel density. | The recording has ten command kinds: rectangles, rounded rectangles, polygons, text, images, a clip, and a link. | The scene of ztk is this list. The remote display: decision D22 of the plan |
| 7 | A UI on a canvas in a browser has only pixels. A link needs a real element over its rectangle. | Printdeck added a link command with a rectangle and an address. | The web backend puts real elements over the canvas for links and for the accessibility tree (Stage 3 and Stage 8) |
| 8 | Draw a frame, then wait, then handle all waiting events, then draw one frame. | The loop collects a burst of events before the next frame. | The pass of `App.doOneEvent`, tasks 04 and 11 |
| 9 | Never drop input. Keep the newest move when the UI is busy. | Fast typing lost keys when the queue held 16 changes. A dropped move made a swipe look like a tap. | Task 12, step 10, and task 20 |
| 10 | Log a slow frame at once, with the time of each part. | The limit is 100 ms, with the draw time and the present time. | Task 18 |
| 11 | A touch is not a click. It needs limits that come from measurement. | A lift of more than 12 pixels from the start is a scroll and never a tap. A flick of 250 pixels in each second or more continues and slows with a time constant of 0.35 seconds. A resistive panel loses contact for 4 to 25 ms inside one touch, so a touch ends only after 80 ms with no contact. | `src/platform/touch.zig` in task 20. The scroll and the fling come in Stage 2. |
| 12 | The size of text depends on the size of a pixel in millimeters, and not on the pixel count. | A pixel of 0.13 mm made text of 12 to 17 pixels hard to read. A pixel of 0.19 mm did not. | Section 4.11 of the plan: the scale of the framebuffer backend comes from the size of the panel or from a setting |
| 13 | Place each glyph from its exact advance. Rounded advances move a long line out of its box at a scale of 1.5. | | Task 07: glyph positions at the device size, and the test at three scales |
| 14 | A label is never cut. The layout gives it more room, a second line, or a smaller font. Check with large text. | | The scene checks of task 19: `text_clipped`, also at 1.5 times the font size |
| 15 | Test the contrast of the theme colors in the unit tests. | The limits are the WCAG ratios 4.5 and 7. | The scene checks of task 19: `low_contrast` |
| 16 | Keep the layout and input code free of dependencies, so that it can be a project of its own. | The package uses only the standard library. | The core of ztk, its text code, and the direct backend link no library. The dependency rule of the plan (section 6) states it for each platform. |
| 17 | Put the display behind one small interface: the panel, or no display at all. | The interface has four functions. | `Platform` in task 05, with the headless backend |
| 18 | One UI must fit a tall and a wide screen. | The layout divides rectangles by fixed sizes and by shares of the free space. | The geometry managers of Tk do this in ztk. The demo test resizes the window. |

## What ztk does differently

- Printdeck draws the complete UI again in each frame and collects the touch areas while it draws. ztk keeps a widget tree, because Tk scripts create widgets that stay.
- Printdeck draws its text with the font package of the Go project. ztk has its own font engine in Zig.
- Printdeck draws on the CPU only. ztk also has GPU renderers, and the direct backend can use the GPU. The CPU renderer of ztk is a product path for the framebuffer output, and the reference for the tests.
