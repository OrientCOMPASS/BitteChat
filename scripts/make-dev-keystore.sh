#!/usr/bin/env bash
# Local DEV release signing (v0.5.18+): the repository no longer commits a
# public release key — CI signs with the KEYSTORE_* repository secrets.
# This helper generates a PERSONAL, gitignored keystore + key.properties so
# `flutter build apk` works on a dev machine. APKs signed with it are for
# DEVELOPMENT ONLY (they cannot be published or upgrade real installs).
set -euo pipefail
cd "$(dirname "$0")/.."

PROPS=app/android/key.properties
if [ -f "$PROPS" ]; then
  echo "refusing to overwrite existing $PROPS" >&2
  exit 1
fi
if ! command -v keytool >/dev/null 2>&1; then
  echo "keytool not found - install a JDK first" >&2
  exit 1
fi

KS=app/android/keystore/dev-local.p12
ALIAS=dev-local
# alnum-only password: safe for the java Properties format used by key.properties
PW=$(python3 -c 'import secrets,string;print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))')
mkdir -p app/android/keystore
keytool -genkeypair -noprompt -keystore "$KS" -storetype PKCS12 \
  -alias "$ALIAS" -keyalg RSA -keysize 2048 -validity 3650 \
  -storepass "$PW" -keypass "$PW" -dname "CN=BitteChat Dev Local"
{
  echo "storeFile=keystore/dev-local.p12"
  echo "storePassword=$PW"
  echo "keyAlias=$ALIAS"
  echo "keyPassword=$PW"
} > "$PROPS"
chmod 600 "$PROPS"
echo "created $KS + $PROPS (both gitignored) — DEV-ONLY signing key"
