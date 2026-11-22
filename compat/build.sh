#!/usr/bin/env bash
# Build Haotian-XOS-Compat.apk (LSPosed module) on Linux/macOS — manual toolchain, no Gradle.
# Same flow as the upstream pandora-airdrop compat/build.sh.
#
# Required environment:
#   SDK_STUB      path to platforms/<api>/android.jar (e.g. .../platforms/android-37.0/android.jar)
#   BUILD_TOOLS   path to the build-tools directory (e.g. .../build-tools/36.0.0)
# Optional:
#   JAVA_HOME     JDK 17+ whose bin/ contains javac, keytool, java (used by d8/apksigner)
#   SIGN_KEYSTORE keystore path (default: $HOME/.haotian-xoscompat.jks)
#
# Output: dist/Haotian-XOS-Compat.apk (+ SHA-256 printed on success)
set -euo pipefail
cd "$(dirname "$0")"

JAVAC="${JAVAC:-javac}"
KEYTOOL="${KEYTOOL:-keytool}"
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ]; then
    JAVAC="$JAVA_HOME/bin/javac"
fi
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/keytool" ]; then
    KEYTOOL="$JAVA_HOME/bin/keytool"
fi

: "${SDK_STUB:?SDK_STUB is required (path to platforms/<api>/android.jar)}"
: "${BUILD_TOOLS:?BUILD_TOOLS is required (path to the build-tools directory)}"
[ -f "$SDK_STUB" ] || { echo "BUILD FAILED: SDK_STUB not found: $SDK_STUB" >&2; exit 1; }
for tool in d8 aapt2 apksigner; do
    [ -x "$BUILD_TOOLS/$tool" ] || { echo "BUILD FAILED: missing build tool: $BUILD_TOOLS/$tool" >&2; exit 1; }
done

# 1. clean
rm -rf build dist
mkdir -p build/stubs build/classes build/dex dist

# 2. compile the Xposed API stubs, then the module against the SDK stub
mapfile -t STUB_SOURCES < <(find stubs -name '*.java' | sort)
mapfile -t MODULE_SOURCES < <(find src/org/haotian/xoscompat -maxdepth 1 -name '*.java' | sort)
[ "${#STUB_SOURCES[@]}" -gt 0 ] || { echo "BUILD FAILED: no Xposed API stub sources" >&2; exit 1; }
[ "${#MODULE_SOURCES[@]}" -gt 0 ] || { echo "BUILD FAILED: no module sources" >&2; exit 1; }
"$JAVAC" --release 8 -encoding UTF-8 -Xlint:-options -d build/stubs "${STUB_SOURCES[@]}"
"$JAVAC" --release 8 -encoding UTF-8 -Xlint:-options \
    -cp "$SDK_STUB:build/stubs" -d build/classes "${MODULE_SOURCES[@]}"

# 3. dex
"$BUILD_TOOLS/d8" --lib "$SDK_STUB" --classpath build/stubs --min-api 33 \
    --output build/dex build/classes/org/haotian/xoscompat/*.class
test -f build/dex/classes.dex || { echo "BUILD FAILED: d8 produced no classes.dex" >&2; exit 1; }

# 4. resources + manifest
"$BUILD_TOOLS/aapt2" compile --dir res -o build/res.zip
"$BUILD_TOOLS/aapt2" link -I "$SDK_STUB" --manifest AndroidManifest.xml \
    -A assets -o build/unsigned.apk build/res.zip
test -f build/unsigned.apk || { echo "BUILD FAILED: aapt2 link produced no APK" >&2; exit 1; }

# 5. add classes.dex at the archive root (zip preferred, python3 zipfile fallback)
if command -v zip >/dev/null 2>&1; then
    (cd build/dex && zip -q ../unsigned.apk classes.dex)
elif command -v python3 >/dev/null 2>&1; then
    python3 - build/unsigned.apk build/dex/classes.dex <<'PY'
import os, sys, zipfile
apk, dex = sys.argv[1], sys.argv[2]
tmp = apk + '.rebuild'
with zipfile.ZipFile(apk, 'r') as zin, zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        if item.filename == 'classes.dex':
            continue
        zout.writestr(item, zin.read(item.filename))
    zout.write(dex, 'classes.dex')
os.replace(tmp, apk)
PY
else
    echo "BUILD FAILED: need either 'zip' or 'python3' to add classes.dex to the APK" >&2
    exit 1
fi

# 6. sign + verify
KS="${SIGN_KEYSTORE:-$HOME/.haotian-xoscompat.jks}"
if [ ! -f "$KS" ]; then
    "$KEYTOOL" -genkeypair -keystore "$KS" -storepass haotian-local -keypass haotian-local \
        -alias haotian -dname "CN=HaotianXosCompat" -keyalg RSA -keysize 2048 -validity 3650
fi
"$BUILD_TOOLS/apksigner" sign --ks "$KS" --ks-pass pass:haotian-local --ks-key-alias haotian \
    --out dist/Haotian-XOS-Compat.apk build/unsigned.apk
rm -f dist/*.idsig
"$BUILD_TOOLS/apksigner" verify --verbose --print-certs dist/Haotian-XOS-Compat.apk
test -f dist/Haotian-XOS-Compat.apk || { echo "BUILD FAILED: no APK produced" >&2; exit 1; }

# 7. self checks: manifest package/version + assets/xposed_init + classes.dex
"$BUILD_TOOLS/aapt2" dump badging dist/Haotian-XOS-Compat.apk \
    | grep -q "name='org.haotian.xoscompat' versionCode='2' versionName='0.2.0'" \
    || { echo "BUILD FAILED: manifest package/version mismatch (want org.haotian.xoscompat 2 / 0.2.0)" >&2; exit 1; }

check_init() {
    local init="$1"
    init="$(printf '%s' "$init" | tr -d '\r\n')"
    [ "$init" = "org.haotian.xoscompat.Hook" ] || {
        echo "BUILD FAILED: assets/xposed_init = '$init'" >&2
        exit 1
    }
    echo "    assets/xposed_init = $init"
}

if command -v unzip >/dev/null 2>&1; then
    check_init "$(unzip -p dist/Haotian-XOS-Compat.apk assets/xposed_init)"
elif command -v python3 >/dev/null 2>&1; then
    check_init "$(python3 - dist/Haotian-XOS-Compat.apk <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    names = z.namelist()
    assert 'classes.dex' in names, 'classes.dex missing'
    sys.stdout.write(z.read('assets/xposed_init').decode('utf-8'))
PY
)"
else
    echo "WARNING: neither unzip nor python3 available, skipping xposed_init self-check" >&2
fi

if command -v sha256sum >/dev/null 2>&1; then
    SHA256="$(sha256sum dist/Haotian-XOS-Compat.apk | awk '{print $1}')"
else
    SHA256="$(shasum -a 256 dist/Haotian-XOS-Compat.apk | awk '{print $1}')"
fi

echo
echo "BUILD OK"
echo "    APK    : $(pwd)/dist/Haotian-XOS-Compat.apk"
echo "    size   : $(wc -c < dist/Haotian-XOS-Compat.apk) bytes"
echo "    sha256 : $SHA256"
