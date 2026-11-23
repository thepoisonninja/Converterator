#!/bin/zsh
# Builds "Converterator.app" next to this script.
# Ad-hoc signed by default. Set SIGN_IDENTITY (e.g. "Developer ID Application") to sign for
# distribution; notarize.sh does that for you.
# ./build.sh --fetch-only downloads the bundled tools into vendor/ and stops (the GitHub tests use this).
set -euo pipefail
cd "${0:A:h}"

APP="Converterator.app"
PSX_VERSION="v1.8.0"
# chdman, built from MAME's source by .github/workflows/chdman.yml and published as a release of this repo.
CHDMAN_VERSION="0.289"
CHDMAN_SHA256="7a46959ffe42669e844348449b00e4fd09c268750e3f64939d0af951acf82cf7"
# dolphin-tool, for GameCube and Wii discs (RVZ), built from Dolphin's source by .github/workflows/dolphin-tool.yml.
DOLPHIN_VERSION="2609b"
DOLPHIN_SHA256="04336ad3421256f1019ff1831d3274460782f22c20b828daa5b904455aa26ef0"
# xdelta3, for applying xdelta patches: the project's own dependency-free macOS builds (Apache 2.0).
XDELTA_VERSION="3.2.2"
XDELTA_SHA256_ARM64="27dcf763beb075ed28061ef136613f4bc6ea3999cb424f23a7d59f18ca2d7c8b"
XDELTA_SHA256_X86_64="e217f4d0f92357ee890f9d8b5571f7eb836a86ff87e8834bed0b9d9b38630f86"
# maxcso, for CSO and ZSO (PSP and PS2 hardware), built from its source by .github/workflows/maxcso.yml.
MAXCSO_VERSION="1.13.0"
MAXCSO_SHA256="f85872029cffa5db20ab1595887949d5aa7f53e513daca81c5c188707b27a63c"
# 7-Zip (7zz), for .7z and .rar archives: the official macOS builds by Igor Pavlov (LGPL, unRAR restriction).
SEVENZIP_VERSION="26.06"
SEVENZIP_SHA256_ARM64="b6f17920b4240940461dac8ef4009891881ac44d2a5ead625ede2ec8472185dd"
SEVENZIP_SHA256_X86_64="3af68b124052da7fc2a246c96b0bea6a68bfee389baa788f4cead1a133445586"

# PSXPackager isn't stored in this repo; fetch both macOS release builds once into vendor/.
# It's a .NET single-file app, which can't be merged with lipo, so the app carries one per CPU.
fetch_psx() {   # $1 = release platform (osx-arm64 / osx-x64)
  if [[ ! -x "vendor/$1/psxpackager" ]]; then
    echo "Downloading PSXPackager $PSX_VERSION ($1)…"
    mkdir -p vendor
    curl -fsSL -o "vendor/$1.tar.gz" \
      "https://github.com/RupertAvery/PSXPackager/releases/download/$PSX_VERSION/psxpackager-$1.tar.gz"
    tar -xzf "vendor/$1.tar.gz" -C vendor
    rm -rf "vendor/$1"
    mv "vendor/psxpackager-$1" "vendor/$1"
    rm -f "vendor/$1.tar.gz"
  fi
}
fetch_psx osx-arm64
fetch_psx osx-x64
# PSXPackager is MIT-licensed; its license must travel with the copy bundled in the app.
if [[ ! -f vendor/LICENSE-psxpackager ]]; then
  curl -fsSL -o vendor/LICENSE-psxpackager \
    "https://raw.githubusercontent.com/RupertAvery/PSXPackager/$PSX_VERSION/LICENSE"
fi

# chdman: download the universal build once into vendor/, and check it's exactly the one published.
if [[ ! -x "vendor/chdman-$CHDMAN_VERSION/chdman" ]]; then
  echo "Downloading chdman $CHDMAN_VERSION…"
  mkdir -p vendor
  curl -fsSL -o "vendor/chdman-$CHDMAN_VERSION.zip" \
    "https://github.com/thepoisonninja/Converterator/releases/download/chdman-$CHDMAN_VERSION/chdman-universal.zip"
  if [[ "$(shasum -a 256 "vendor/chdman-$CHDMAN_VERSION.zip" | cut -d' ' -f1)" != "$CHDMAN_SHA256" ]]; then
    echo "chdman download doesn't match the expected SHA-256"; rm -f "vendor/chdman-$CHDMAN_VERSION.zip"; exit 1
  fi
  rm -rf "vendor/chdman-$CHDMAN_VERSION"
  ditto -x -k "vendor/chdman-$CHDMAN_VERSION.zip" "vendor/chdman-$CHDMAN_VERSION"
  rm -f "vendor/chdman-$CHDMAN_VERSION.zip"
fi

# xdelta3: both official macOS builds, checked against their SHA-256s, merged into one universal program.
XD="vendor/xdelta3-$XDELTA_VERSION"
if [[ ! -x "$XD/xdelta3" ]]; then
  echo "Downloading xdelta3 $XDELTA_VERSION…"
  rm -rf "$XD"; mkdir -p "$XD/download"
  for pair in "arm64:$XDELTA_SHA256_ARM64" "x86_64:$XDELTA_SHA256_X86_64"; do
    arch=${pair%%:*} sha=${pair#*:}
    tgz="$XD/download/xdelta3-$arch.tar.gz"
    curl -fsSL -o "$tgz" "https://github.com/jmacd/xdelta/releases/download/v$XDELTA_VERSION/xdelta3-$XDELTA_VERSION-macos-$arch.tar.gz"
    [[ "$(shasum -a 256 "$tgz" | cut -d' ' -f1)" == "$sha" ]] || { echo "xdelta3 ($arch) doesn't match the expected SHA-256"; rm -rf "$XD"; exit 1; }
    tar -xzf "$tgz" -C "$XD/download"
  done
  lipo -create "$XD/download/xdelta3-$XDELTA_VERSION-macos-arm64/xdelta3" "$XD/download/xdelta3-$XDELTA_VERSION-macos-x86_64/xdelta3" -output "$XD/xdelta3"
  curl -fsSL -o "$XD/LICENSE" "https://raw.githubusercontent.com/jmacd/xdelta/v$XDELTA_VERSION/xdelta3/LICENSE"
  printf 'xdelta3 %s (https://github.com/jmacd/xdelta), the official macOS builds for Apple Silicon and Intel\nfrom https://github.com/jmacd/xdelta/releases/tag/v%s, combined with lipo. Apache License 2.0 (see LICENSE).\n' \
    "$XDELTA_VERSION" "$XDELTA_VERSION" > "$XD/SOURCE.txt"
  rm -rf "$XD/download"
fi

# 7-Zip: both official macOS builds (Apple Silicon and Intel), checked against their SHA-256s, merged with lipo.
SZ="vendor/7zz-$SEVENZIP_VERSION"
if [[ ! -x "$SZ/7zz" ]]; then
  echo "Downloading 7-Zip $SEVENZIP_VERSION…"
  rm -rf "$SZ"; mkdir -p "$SZ/download/arm64" "$SZ/download/x86_64"
  V=${SEVENZIP_VERSION//./}
  for pair in "arm64:mac:$SEVENZIP_SHA256_ARM64" "x86_64:mac-x64:$SEVENZIP_SHA256_X86_64"; do
    arch=${pair%%:*} rest=${pair#*:}; flavour=${rest%%:*} sha=${rest#*:}
    txz="$SZ/download/7z$V-$flavour.tar.xz"
    curl -fsSL -o "$txz" "https://github.com/ip7z/7zip/releases/download/$SEVENZIP_VERSION/7z$V-$flavour.tar.xz"
    [[ "$(shasum -a 256 "$txz" | cut -d' ' -f1)" == "$sha" ]] || { echo "7-Zip ($arch) doesn't match the expected SHA-256"; rm -rf "$SZ"; exit 1; }
    tar -xf "$txz" -C "$SZ/download/$arch"
  done
  lipo -create "$SZ/download/arm64/7zz" "$SZ/download/x86_64/7zz" -output "$SZ/7zz"
  cp "$SZ/download/arm64/License.txt" "$SZ/License.txt"
  printf '7-Zip %s by Igor Pavlov (https://www.7-zip.org), the official macOS builds for Apple Silicon and Intel\nfrom https://github.com/ip7z/7zip/releases/tag/%s, unmodified, combined with lipo. The source code is\navailable from https://www.7-zip.org and https://github.com/ip7z/7zip. Licenses: see License.txt.\n' \
    "$SEVENZIP_VERSION" "$SEVENZIP_VERSION" > "$SZ/SOURCE.txt"
  rm -rf "$SZ/download"
fi

# dolphin-tool: download the universal build once into vendor/, and check it's exactly the one published.
DT="vendor/dolphin-tool-$DOLPHIN_VERSION"
if [[ ! -x "$DT/dolphin-tool" ]]; then
  echo "Downloading dolphin-tool $DOLPHIN_VERSION…"
  mkdir -p vendor
  curl -fsSL -o "$DT.zip" "https://github.com/thepoisonninja/Converterator/releases/download/dolphin-tool-$DOLPHIN_VERSION/dolphin-tool-universal.zip"
  if [[ "$(shasum -a 256 "$DT.zip" | cut -d' ' -f1)" != "$DOLPHIN_SHA256" ]]; then
    echo "dolphin-tool download doesn't match the expected SHA-256"; rm -f "$DT.zip"; exit 1
  fi
  rm -rf "$DT"; ditto -x -k "$DT.zip" "$DT"; rm -f "$DT.zip"
fi

# maxcso: download the universal build once into vendor/, and check it's exactly the one published.
MC="vendor/maxcso-$MAXCSO_VERSION"
if [[ ! -x "$MC/maxcso" ]]; then
  echo "Downloading maxcso $MAXCSO_VERSION…"
  mkdir -p vendor
  curl -fsSL -o "$MC.zip" "https://github.com/thepoisonninja/Converterator/releases/download/maxcso-$MAXCSO_VERSION/maxcso-universal.zip"
  if [[ "$(shasum -a 256 "$MC.zip" | cut -d' ' -f1)" != "$MAXCSO_SHA256" ]]; then
    echo "maxcso download doesn't match the expected SHA-256"; rm -f "$MC.zip"; exit 1
  fi
  rm -rf "$MC"; ditto -x -k "$MC.zip" "$MC"; rm -f "$MC.zip"
fi

[[ "${1:-}" == "--fetch-only" ]] && { echo "Tools are in vendor/."; exit 0; }

rm -rf "$APP" build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources/psxpackager"

# Universal app: compile each architecture, then merge them with lipo.
for ARCH in arm64 x86_64; do
  swiftc -parse-as-library -swift-version 5 -O \
    -target "$ARCH-apple-macos14" \
    Sources/*.swift -o "build/Converterator-$ARCH"
done
lipo -create build/Converterator-arm64 build/Converterator-x86_64 \
  -output "$APP/Contents/MacOS/Converterator"

PSX="$APP/Contents/Resources/psxpackager"
cp vendor/osx-arm64/psxpackager "$PSX/psxpackager-arm64"
cp vendor/osx-x64/psxpackager "$PSX/psxpackager-x86_64"
cp -R vendor/osx-arm64/Resources "$PSX/Resources"   # identical in both builds
cp vendor/LICENSE-psxpackager "$PSX/LICENSE"
printf 'PSXPackager %s by RupertAvery (https://github.com/RupertAvery/PSXPackager), the official macOS builds for\nApple Silicon and Intel from https://github.com/RupertAvery/PSXPackager/releases/tag/%s. MIT License (see LICENSE).\n' \
  "$PSX_VERSION" "$PSX_VERSION" > "$PSX/SOURCE.txt"
cp LICENSE "$APP/Contents/Resources/LICENSE"
# chdman with MAME's licenses and a note on exactly which source it was built from
ditto "vendor/chdman-$CHDMAN_VERSION" "$APP/Contents/Resources/chdman"
ditto "$XD" "$APP/Contents/Resources/xdelta3"
ditto "$DT" "$APP/Contents/Resources/dolphin-tool"
ditto "$SZ" "$APP/Contents/Resources/7zz"
ditto "$MC" "$APP/Contents/Resources/maxcso"

# App icon: compile the Icon Composer icon (light + dark variants, made by make_icon.swift).
# actool writes Assets.car (used by macOS for appearance-aware icons) and AppIcon.icns (fallback).
xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist build/actool-info.plist \
  --output-format human-readable-text --notices --warnings --errors | grep -v "^/\* com.apple.actool" || true
[[ -f "$APP/Contents/Resources/Assets.car" ]] || { echo "actool failed to build the icon"; exit 1; }

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Converterator</string>
  <key>CFBundleDisplayName</key><string>Converterator</string>
  <key>CFBundleIdentifier</key><string>local.converterator</string>
  <key>CFBundleExecutable</key><string>Converterator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.22.0</string>
  <key>CFBundleVersion</key><string>30</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Disc Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>pbp</string><string>cue</string><string>bin</string><string>gdi</string><string>iso</string><string>chd</string><string>zip</string><string>7z</string><string>rar</string><string>ecm</string><string>gcm</string><string>wbfs</string><string>ciso</string><string>gcz</string><string>wia</string><string>rvz</string></array>
    </dict>
  </array>
  <key>NSAppTransportSecurity</key>
  <dict>
    <!-- redump.org only serves plain HTTP; allow it for that one site, for downloading DAT files. -->
    <key>NSExceptionDomains</key>
    <dict>
      <key>redump.org</key>
      <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
    </dict>
  </dict>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Convert with Converterator</string></dict>
      <key>NSMessage</key><string>convertFiles</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key>
      <array><string>public.folder</string><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Developer ID signing for notarization: hardened runtime + secure timestamp on every executable.
  # PSXPackager is a .NET app, which needs JIT and unsigned executable memory under hardened runtime.
  for bin in "$PSX"/psxpackager-*; do
    codesign --force --timestamp --options runtime \
      --entitlements psxpackager.entitlements --sign "$SIGN_IDENTITY" "$bin"
  done
  for tool in chdman xdelta3 dolphin-tool 7zz maxcso; do
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/$tool/$tool"
  done
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
  echo "Signed with: $SIGN_IDENTITY"
else
  codesign --force --sign - "$APP"   # ad-hoc: fine for your own Mac, not for distribution
fi
rm -rf build
echo "Built $APP"
