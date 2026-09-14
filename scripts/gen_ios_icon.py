# -*- coding: utf-8 -*-
"""从 assets/images/app_icon_3.jpg 生成 iOS 全幅 1024x1024 图标。

源图是圆角图标悬浮在浅色背景上；iOS 会自行裁切圆角，
因此需要把渐变背景延展到整个画布，避免四角露出浅色底。
"""
from PIL import Image, ImageFilter

SRC = "assets/images/app_icon_3.jpg"
DST = "ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png"

src = Image.open(SRC).convert("RGB")
w, h = src.size  # 1024x1024

# 1) 定位圆角图标内容：浅色背景接近白/灰，图标饱和度明显更高
import colorsys

small = src.resize((128, 128))
px = small.load()
min_x, min_y, max_x, max_y = 128, 128, 0, 0
for y in range(128):
    for x in range(128):
        r, g, b = px[x, y]
        mx, mn = max(r, g, b), min(r, g, b)
        sat = (mx - mn) / mx if mx else 0
        # 背景饱和度极低，图标渐变饱和度高
        if sat > 0.25 or (mx < 200 and sat > 0.15):
            min_x, min_y = min(min_x, x), min(min_y, y)
            max_x, max_y = max(max_x, x), max(max_y, y)
# 映射回原尺寸，留 2% 余量
scale = w / 128
pad = int(0.02 * w)
box = (
    max(0, int(min_x * scale) - pad),
    max(0, int(min_y * scale) - pad),
    min(w, int((max_x + 1) * scale) + pad),
    min(h, int((max_y + 1) * scale) + pad),
)
content = src.crop(box)
cw, ch = content.size

# 2) 生成全幅渐变背景：取图标四角+四边中点颜色，做双线性渐变近似。
#    简化：水平方向按左/右边缘平均色渐变，再与垂直方向叠加
def edge_avg(im, side):
    im2 = im.resize((10, 10))
    p = im2.load()
    cs = []
    for i in range(10):
        if side == "left":
            cs.append(p[0, i])
        elif side == "right":
            cs.append(p[9, i])
        elif side == "top":
            cs.append(p[i, 0])
        else:
            cs.append(p[i, 9])
    n = len(cs)
    return tuple(sum(c[k] for c in cs) // n for k in range(3))

L, R = edge_avg(content, "left"), edge_avg(content, "right")
T, B = edge_avg(content, "top"), edge_avg(content, "bottom")

bg = Image.new("RGB", (w, h))
bp = bg.load()
for y in range(h):
    fy = y / (h - 1)
    for x in range(w):
        fx = x / (w - 1)
        # 水平渐变 + 垂直渐变各取一半权重
        cx = tuple(int(L[k] * (1 - fx) + R[k] * fx) for k in range(3))
        cy = tuple(int(T[k] * (1 - fy) + B[k] * fy) for k in range(3))
        bp[x, y] = tuple((cx[k] + cy[k]) // 2 for k in range(3))
bg = bg.filter(ImageFilter.GaussianBlur(2))

# 3) 图标内容放大铺满画布（内容为方形，等比放大到 1024）
side = max(cw, ch)
if cw != ch:
    content = content.crop((0, 0, side, side)) if ch >= cw else content
content = content.resize((w, h), Image.LANCZOS)

# 4) 粘贴：图标自身圆角之外的区域由延展渐变填充，与 iOS 蒙皮圆角基本重合
bg.paste(content, (0, 0))
bg.save(DST, "PNG")
print("OK ->", DST, bg.size)
