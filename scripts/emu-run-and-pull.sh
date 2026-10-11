#!/usr/bin/env bash
# Run attach_test on the connected emulator WHILE pulling the in-test
# screenshots concurrently: the flutter test runner UNINSTALLS the app (and
# deletes its data dir) as soon as the run returns, so any post-hoc pull
# finds nothing. Emulator builds are userdebug => `adb root` works and can
# read the app's private files directly.
set -u
OUT="${1:-shots}"
mkdir -p "$OUT"
adb root >/dev/null 2>&1 || true
adb wait-for-device || exit 1

cd app || exit 1
flutter pub get || exit 1
flutter test   integration_test/attach_test.dart   integration_test/app_test.dart   integration_test/video_test.dart   integration_test/ux_test.dart   -d emulator-5554 --reporter expanded &
TPID=$!

PKG=""
for _ in $(seq 1 120); do
  PKG=$(adb shell pm list packages 2>/dev/null | tr -d '\r' |
    grep -i bitte | head -1 | cut -d: -f2)
  [ -n "$PKG" ] && break
  sleep 2
done
echo "app package: $PKG"

for f in shot-log.txt shot-chat-inline.png shot-jump-chip.png; do
  got=""
  for _ in $(seq 1 150); do
    for base in "/data/data/$PKG/files" \
                "/storage/emulated/0/Android/data/$PKG/files"; do
      adb shell cat "$base/$f" > "$OUT/$f" 2>/dev/null || true
      if [ -s "$OUT/$f" ]; then got="$base"; break; fi
    done
    [ -n "$got" ] && break
    # test process gone => data dir is about to be wiped; last grace period
    kill -0 "$TPID" 2>/dev/null || { sleep 3; break; }
    sleep 2
  done
  echo "$f: pulled from ${got:-<none>} ($(stat -c%s "$OUT/$f" 2>/dev/null || echo 0) bytes)"
done
# release the test process (it holds the install alive for us)
adb shell touch "/storage/emulated/0/Android/data/$PKG/files/pull-done" 2>/dev/null || true
adb shell touch "/data/data/$PKG/files/pull-done" 2>/dev/null || true

wait $TPID
RC=$?
echo "attach_test exit code: $RC"
exit $RC
