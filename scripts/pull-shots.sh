#!/usr/bin/env bash
# Pull integration-test forensics (screenshots + status log) from the
# emulator after a test run. The test framework force-stops the app when
# `flutter test` returns, so captures must be written BY the test into the
# app's own storage and pulled afterwards (run-as works on debug builds).
set -u
OUT="${1:-shots}"
mkdir -p "$OUT"
PKG=$(adb shell pm list packages | tr -d '\r' | grep -i bitte | head -1 | cut -d: -f2)
echo "app package: $PKG"
for f in shot-log.txt shot-chat-inline.png shot-jump-chip.png \
         shot-chat-inline-error.txt shot-jump-chip-error.txt; do
  for loc in "files/$f" "/storage/emulated/0/Android/data/$PKG/files/$f"; do
    tmp=$(mktemp)
    adb shell "run-as $PKG cat $loc" > "$tmp" 2>/dev/null || true
    if [ -s "$tmp" ]; then
      cp "$tmp" "$OUT/$f"
      echo "pulled $f from $loc ($(stat -c%s "$OUT/$f") bytes)"
      rm -f "$tmp"
      break
    fi
    rm -f "$tmp"
  done
done
ls -la "$OUT" || true
