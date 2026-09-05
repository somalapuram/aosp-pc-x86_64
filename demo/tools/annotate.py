#!/usr/bin/env python3
"""Annotate a screenshot: dim everything, spotlight regions, add callouts."""
import sys, subprocess
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ACCENT = (232, 160, 66)      # amber
INK    = (18, 20, 24)
WHITE  = (255, 255, 255)

def font(sz, bold=False):
    q = "DejaVuSans-Bold" if bold else "DejaVuSans"
    try:
        p = subprocess.run(["fc-match","-f","%{file}", q], capture_output=True, text=True).stdout.strip()
        return ImageFont.truetype(p, sz)
    except Exception:
        return ImageFont.load_default()

def annotate(src, dst, regions, dim=0.55):
    """regions: list of (box, label, side) ; box=(x1,y1,x2,y2), side='left'|'right'"""
    im = Image.open(src).convert("RGB")
    W, H = im.size
    # dim layer
    out = Image.blend(im, Image.new("RGB", (W,H), INK), dim)
    # spotlight each region back to full brightness
    for box, _, _ in regions:
        out.paste(im.crop(box), box[:2])
    d = ImageDraw.Draw(out, "RGBA")
    fb, fs = font(30, True), font(25)
    for (box, label, side) in regions:
        x1,y1,x2,y2 = box
        for w,a in ((6,255),(12,70)):
            d.rectangle([x1-w//2, y1-w//2, x2+w//2, y2+w//2], outline=ACCENT+(a,), width=w)
        # callout
        lines = label.split("\n")
        tw = max(d.textlength(l, font=fb if i==0 else fs) for i,l in enumerate(lines))
        pad, lh = 20, 40
        bw, bh = int(tw)+pad*2, lh*len(lines)+pad
        by = max(12, min(H-bh-12, (y1+y2)//2 - bh//2))
        bx = x2 + 40 if side=="right" else x1 - bw - 40
        bx = max(12, min(W-bw-12, bx))
        d.rectangle([bx, by, bx+bw, by+bh], fill=ACCENT+(242,))
        # leader line
        ax = bx if side=="right" else bx+bw
        d.line([(x2 if side=="right" else x1), (y1+y2)//2, ax, by+bh//2], fill=ACCENT, width=5)
        for i,l in enumerate(lines):
            d.text((bx+pad, by+pad//2+i*lh), l, font=(fb if i==0 else fs), fill=INK)
    out.save(dst, "PNG")
    print(f"  wrote {dst}")

if __name__ == "__main__":
    pass
