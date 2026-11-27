# A widget-heavy window: 40 rows of label, entry, combobox, check, and
# scale, a treeview with 500 rows, a text with 200 lines, and a notebook.
# tools/libztk/bench.sh runs it with --exit, which prints the time.
import tkinter as tk, sys, time
from tkinter import ttk
t0 = time.perf_counter()
root = tk.Tk(); root.title("Widgets")
nb = ttk.Notebook(root); nb.pack(fill="both", expand=True)
f1 = ttk.Frame(nb); nb.add(f1, text="Form")
for i in range(40):
    ttk.Label(f1, text=f"Field {i}").grid(row=i, column=0, sticky="w")
    e = ttk.Entry(f1); e.insert(0, f"value {i}"); e.grid(row=i, column=1)
    ttk.Combobox(f1, values=["a", "b", "c"]).grid(row=i, column=2)
    ttk.Checkbutton(f1, text="on").grid(row=i, column=3)
    ttk.Scale(f1, from_=0, to=100).grid(row=i, column=4)
f2 = ttk.Frame(nb); nb.add(f2, text="Tree")
tv = ttk.Treeview(f2, columns=("a", "b"))
for i in range(500):
    tv.insert("", "end", text=f"row {i}", values=(i, i * i))
tv.pack(fill="both", expand=True)
f3 = ttk.Frame(nb); nb.add(f3, text="Text")
tx = tk.Text(f3)
for i in range(200):
    tx.insert("end", f"line {i} of the text widget\n")
tx.pack(fill="both", expand=True)
root.update()
import resource
print(f"built in {time.perf_counter() - t0:.3f} s rss {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss} KB", file=sys.stderr)
if "--exit" in sys.argv:
    root.destroy()
else:
    root.mainloop()
