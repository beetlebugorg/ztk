# The time from import tkinter to the first update of a Tk(), and the
# largest resident set. tools/libztk/bench.sh runs it.
import time, sys
t0 = time.perf_counter()
import tkinter
import resource
r = tkinter.Tk()
r.update()
print(f"startup {time.perf_counter() - t0:.3f} s rss {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss} KB", file=sys.stderr)
r.destroy()
