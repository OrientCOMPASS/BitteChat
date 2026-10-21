#!/usr/bin/env bash
# Run the integration suite on the connected emulator WHILE pulling the
# in-test screenshots concurrently: the flutter test runner UNINSTALLS the
# app (and deletes its data dir) as soon as the run returns, so any post-hoc
# pull finds nothing. Emulator builds are userdebug => `adb root` works and
# can read the app's private files directly.
set -u
OUT="${1:-shots}"
mkdir -p "$OUT"
adb root >/dev/null 2>&1 || true
adb wait-for-device || exit 1

cd app || exit 1
flutter pub get || exit 1
flutter test   integration_test/attach_test.dart   integration_test/app_test.dart   integration_test/video_test.dart   integration_test/ux_test.dart   -d emulator-5554 --reporter expanded &
TPID=$!

# Detect the package lazily AND re-detect inside the pull loop: the test
# compile+install can take longer than any fixed pre-wait (a 240 s pre-wait
# once raced a ~270 s install and every subsequent cat hit an empty package
# path, silently producing 0-byte artifacts).
detect_pkg() {
  adb shell pm list packages 2>/dev/null | tr -d '\r' |
    grep -i bitte | head -1 | cut -d: -f2
}
PKG="$(detect_pkg)"

pull_one() {
  # pull_one <file> -> writes $OUT/<file>; echoes the base dir on success
  local f="$1" base
  local -a bases=()
  if [ -n "$PKG" ]; then
    bases=("/data/data/$PKG/files" "/storage/emulated/0/Android/data/$PKG/files")
  else
    # package unknown (install still running): glob on-device; adb shell
    # expands the wildcard in the device shell
    bases=("/data/data/*/files" "/storage/emulated/0/Android/data/*/files")
  fi
  for base in "${bases[@]}"; do
    adb shell cat "$base/$f" > "$OUT/$f" 2>/dev/null || true
    if [ -s "$OUT/$f" ]; then
      echo "$base"
      return 0
    fi
  done
  return 1
}

for f in shot-log.txt shot-chat-inline.png shot-jump-chip.png; do
  got=""
  for _ in $(seq 1 400); do
    [ -n "$PKG" ] || PKG="$(detect_pkg)"
    got="$(pull_one "$f" || true)"
    [ -n "$got" ] && break
    # test process gone => data dir is about to be wiped; last grace period
    kill -0 "$TPID" 2>/dev/null || { sleep 3; pull_one "$f" >/dev/null 2>&1 || true; break; }
    sleep 2
  done
  echo "$f: pulled from ${got:-<none>} ($(stat -c%s "$OUT/$f" 2>/dev/null || echo 0) bytes)"
  if [ ! -s "$OUT/$f" ]; then
    echo "::warning::screenshot harness: $f never appeared (package='${PKG:-<none>}')"
  fi
done
echo "app package: ${PKG:-<none>}"
# release the test process (it holds the install alive for us)
if [ -n "$PKG" ]; then
  adb shell touch "/storage/emulated/0/Android/data/$PKG/files/pull-done" 2>/dev/null || true
  adb shell touch "/data/data/$PKG/files/pull-done" 2>/dev/null || true
else
  adb shell touch "/storage/emulated/0/Android/data/*/files/pull-done" 2>/dev/null || true
  adb shell touch "/data/data/*/files/pull-done" 2>/dev/null || true
fi

wait $TPID
RC=$?
echo "attach_test exit code: $RC"
exit $RC
