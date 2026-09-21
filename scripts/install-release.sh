#!/bin/sh
# Builds Echo in Release and replaces ~/Applications/echo.app with it.
#
# The Debug product is a 60 KB stub that dlopen's an 86 MB `echo.debug.dylib` built at
# `-Onone`, and it bundles the XCTest frameworks. Never ship that: it is several times
# slower on every hot path and pages in badly after the app has been idle.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
derived="$root/.derivedData"
product="$derived/Build/Products/Release/echo.app"
target="$HOME/Applications/echo.app"

echo "==> Building Release"
xcodebuild \
    -project "$root/echo/echo.xcodeproj" \
    -scheme echo \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    build

test -d "$product" || { echo "Release product missing: $product" >&2; exit 1; }

if [ -e "$product/Contents/Frameworks/XCTest.framework" ]; then
    echo "Release product still bundles XCTest — refusing to install." >&2
    exit 1
fi
if otool -L "$product/Contents/MacOS/echo" | grep -q 'echo.debug.dylib'; then
    echo "Release product still links echo.debug.dylib — refusing to install." >&2
    exit 1
fi

echo "==> Replacing $target"
killall echo 2>/dev/null || true
# Give the old process a moment to release the hotkey and the microphone.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x echo >/dev/null 2>&1 || break
    /bin/sleep 0.2
done
pgrep -x echo >/dev/null 2>&1 && killall -9 echo 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$target"
ditto "$product" "$target"

echo "==> Launching"
open "$target"

echo "==> Installed"
otool -L "$target/Contents/MacOS/echo" | sed -n '2,4p'
du -sh "$target"
