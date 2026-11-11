#!/usr/bin/env python3
"""
Animated test window for SpareScreen.

Creates a borderless, continuously-animating window at a chosen screen
position — handy to place on the virtual "SpareScreen" monitor and verify
that live motion really reaches the phone.

Usage:
    python3 demowindow.py [--x 1600] [--y 120] [--width 1500] [--height 800]
"""
import argparse
import math
import time
import tkinter as tk


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--x", type=int, default=1600)
    p.add_argument("--y", type=int, default=120)
    p.add_argument("--width", type=int, default=1500)
    p.add_argument("--height", type=int, default=800)
    args = p.parse_args()

    W, H = args.width, args.height
    root = tk.Tk()
    root.overrideredirect(True)          # borderless panel
    root.geometry(f"{W}x{H}+{args.x}+{args.y}")
    root.attributes("-topmost", False)

    canvas = tk.Canvas(root, width=W, height=H, bg="#0E1620", highlightthickness=0)
    canvas.pack()

    t0 = time.time()

    def tick() -> None:
        t = time.time() - t0
        canvas.delete("all")

        # slow background gradient sweep
        for i in range(12):
            shade = 20 + int(12 * math.sin(t * 1.2 + i))
            canvas.create_rectangle(
                i * W / 12, 0, (i + 1) * W / 12, H,
                fill=f"#{shade:02x}{shade + 10:02x}{shade + 24:02x}", outline="")

        # bouncing glowing ball
        x = W / 2 + (W / 2 - 140) * math.sin(t * 2.1)
        y = H / 2 + (H / 2 - 140) * math.cos(t * 1.7)
        for r, color in ((110, "#004d3d"), (85, "#00a878"), (60, "#00e5a0")):
            canvas.create_oval(x - r, y - r, x + r, y + r, fill=color, outline="")

        canvas.create_text(W / 2, 74, text="LIVE from your Mac",
                           fill="#FFFFFF", font=("Helvetica", 46, "bold"))
        canvas.create_text(W / 2, H - 66, text=time.strftime("%H:%M:%S"),
                           fill="#9FD3FF", font=("Menlo", 40))

        # sweeping progress bar
        bar_w = int((W - 200) * (0.5 + 0.5 * math.sin(t * 0.9)))
        canvas.create_rectangle(100, H - 130, 100 + bar_w, H - 118,
                                fill="#00E5A0", outline="")

        root.after(16, tick)             # ~60 fps

    tick()
    root.mainloop()


if __name__ == "__main__":
    main()
