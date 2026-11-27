# The photo C API of libztk through Pillow's ImageTk (Tk_FindPhoto,
# Tk_PhotoPutBlock, Tk_PhotoGetImage), when Pillow is installed.
import tkinter as tk
root = tk.Tk()
try:
    from PIL import Image, ImageTk
except ImportError:
    print("pillow absent")
    raise SystemExit(0)
img = Image.new("RGB", (8, 6), (255, 0, 0))
img.putpixel((2, 3), (0, 0, 255))
ph = ImageTk.PhotoImage(img)
print("size", ph.width(), ph.height())
name = str(ph)
print("pixel", root.tk.call(name, "get", 0, 0), root.tk.call(name, "get", 2, 3))
back = ImageTk.getimage(ph)
print("back", back.size, back.getpixel((2, 3)))
root.destroy()
