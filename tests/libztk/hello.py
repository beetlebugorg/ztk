import tkinter as tk
from tkinter import ttk
root = tk.Tk()
root.title("Hello from tkinter")
print("tk_version", root.tk.getvar("tk_version"), "ws", root.tk.call("tk", "windowingsystem"))
v = tk.StringVar(value="start")
lab = ttk.Label(root, textvariable=v)
lab.pack(padx=20, pady=10)
clicks = []
b = ttk.Button(root, text="Click", command=lambda: clicks.append(1))
b.pack()
e = ttk.Entry(root); e.pack(); e.insert(0, "hello")
print("entry", e.get(), "class", root.winfo_class())
b.invoke()
v.set("changed")
print("clicks", len(clicks), "label", lab.cget("text"), "big", root.tk.call("expr", "2**80"))
root.after(300, root.destroy)
root.mainloop()
print("done")
