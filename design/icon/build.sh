#!/bin/sh
# Regenerates every packaged SwiftGreen icon from swiftgreen-mark.svg via render.swift. Run from anywhere.
set -e
cd "$(dirname "$0")"
ROOT=../..
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for m in full mac bg fg mono stat; do swift render.swift - "$T/$m.png" $m; done
cp "$T/full.png" swiftgreen-icon-1024.png

# macOS asset catalog (full bleed: macOS 26 applies its own shape)
A=$ROOT/macos/SwiftGreen/SwiftGreen/Assets.xcassets/AppIcon.appiconset
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/mac.png" --out "$A/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$T/mac.png" --out "$A/icon_${s}x${s}@2x.png" >/dev/null
done

# Android adaptive icon layers (108 dp) and the status-bar icon (24 dp)
R=$ROOT/android/app/src/main/res
for pair in mdpi:1 hdpi:1.5 xhdpi:2 xxhdpi:3 xxxhdpi:4; do
  d=${pair%%:*}; f=${pair##*:}
  px=$(echo "108*$f/1" | bc); st=$(echo "24*$f/1" | bc)
  for l in bg:background fg:foreground mono:monochrome; do
    sips -z $px $px "$T/${l%%:*}.png" --out "$R/mipmap-$d/ic_launcher_${l##*:}.png" >/dev/null
  done
  sips -z $st $st "$T/stat.png" --out "$R/drawable-$d/ic_stat_swift.png" >/dev/null
done
echo "icons regenerated"
