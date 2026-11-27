# ztk::limit and ztk::clock

`ztk::limit` runs one script with a lower compute limit and memory limit. `ztk::clock` reads the clock of the animations, and sets it in the headless backend for tests.

## Synopsis

```tcl
ztk::limit ?-compute UNITS? ?-memory BYTES? script
ztk::clock get
ztk::clock set MS
```

## ztk::limit

The command runs `script` in the frame of the caller with the lower limits. `-compute UNITS` allows the script at most `UNITS` compute units. `-memory BYTES` allows the script at most `BYTES` more than the memory in use when it starts. The compute units that the script uses count against the limit of the caller too. The old memory limit comes back at the end. A script inside cannot catch the end of its limit, and the caller of `ztk::limit` can.

A child interpreter gets the limits of its caller, so `ztk::limit` also bounds a script in a child:

```tcl
interp create -safe c
if {[catch {ztk::limit -compute 1000 {interp eval c $text}} err]} {
    puts "stopped: $err"
}
```

A limit above the limit of the caller has no effect: the command keeps the lower one. [The compute limit](https://beetlebug.org/ztcl/limits/#the-compute-limit) of ztcl defines a compute unit.

## ztk::clock

`get` gives the time of the animation clock in milliseconds. `set MS` sets it. Only the headless backend can set the clock. A test sets the time to move each [animation](../animation.md) to a known point.

```tcl
ztk::animate .l -background #2563eb -duration 400
ztk::clock set [expr {[ztk::clock get] + 200}]   ;# halfway, in a headless run
```

## Errors

- `wrong # args: should be "ztk::limit ?-compute units? ?-memory bytes? script"`.
- `compute limit reached` and the memory error of ztcl, from the script inside, to the caller.
- `ztk::clock set needs the headless backend`.
- `bad option "-X": must be -compute or -memory`, `expected a count of 0 or more but got "N"`.
