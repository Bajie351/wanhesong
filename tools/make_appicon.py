# -*- coding: utf-8 -*-
"""生成 iOS AppIcon（1024x1024）。

与 PWA 图标（deploy/ui/app/make_icons.py）同一套视觉：
橙红对角渐变 + 白色播放三角。

iOS 要求：
  ① AppIcon 必须是 1024x1024 的 PNG
  ② **不能带 alpha 通道**（带 alpha 会在 Xcode 上传时报 ITMS-90717）
  ③ 不要自己画圆角 —— 系统会套自己的圆角遮罩，自己画会被裁成双层
所以这里统一 convert("RGB") 后再保存。
"""
import os

from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "TingShu", "Assets.xcassets", "AppIcon.appiconset",
)

ACCENT_A = (255, 122, 92)   # #FF7A5C
ACCENT_B = (232, 67, 42)    # #E8432A


def gradient(size):
    """对角线性渐变。"""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2.0 * (size - 1))
            px[x, y] = tuple(
                int(ACCENT_A[i] + (ACCENT_B[i] - ACCENT_A[i]) * t) for i in range(3)
            )
    return img


def triangle_mask(size):
    """白色播放三角（作为 alpha 遮罩）。

    尺寸沿用 PWA 版：w=0.34 / h=0.42。iOS 图标四角圆角半径约 22%，
    这个尺寸离边缘足够远，不会被圆角切到。
    """
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    w, h = size * 0.34, size * 0.42
    cx, cy = size * 0.525, size * 0.5
    pts = [
        (cx - w / 2, cy - h / 2),
        (cx - w / 2, cy + h / 2),
        (cx + w / 2, cy),
    ]
    d.polygon(pts, fill=255)
    return m.filter(ImageFilter.GaussianBlur(size * 0.012))


def build(size):
    base = gradient(size).convert("RGBA")
    tri = triangle_mask(size)
    layer = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    layer.putalpha(tri)
    layer.paste((255, 255, 255, 255), (0, 0), tri)
    base.alpha_composite(layer)
    # 关键：转 RGB 去掉 alpha，否则 App Store / Xcode 校验不通过
    return base.convert("RGB")


def main():
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "AppIcon-1024.png")
    img = build(1024)
    img.save(path, "PNG", optimize=True)
    print("AppIcon-1024.png  1024x1024  %d bytes  mode=%s" % (os.path.getsize(path), img.mode))


if __name__ == "__main__":
    main()
