#!/bin/zsh
# scripts/make-icon.swift로 그린 1024px 그림에서 Resources/AppIcon.icns와 docs/icon.png를 만든다.
set -e
cd "$(dirname "$0")/.."
mkdir -p build docs
swift scripts/make-icon.swift build/icon-1024.png

iconset=build/AppIcon.iconset
rm -rf "$iconset"
mkdir -p "$iconset"
for px in 16 32 128 256 512; do
    sips -z $px $px build/icon-1024.png --out "$iconset/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) build/icon-1024.png --out "$iconset/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
sips -z 256 256 build/icon-1024.png --out docs/icon.png >/dev/null
echo Resources/AppIcon.icns
echo docs/icon.png
