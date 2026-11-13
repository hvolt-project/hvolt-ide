#!/bin/sh
# Packs the IDE's own source into the bundle so the running app can edit and rebuild itself.
#
# Excluded on purpose:
#   signing/   the keystore and its passwords. An archive inside the app hands out the ability to
#              sign packages as this app, and this archive is committed to a public repository.
#   sdk/       API declarations copied from the HarmonyOS SDK.
#   build/     artifacts.
#   resources/rawfile/self/  the archive being produced. Without this the previous source.zip is
#              packed into the new one, so every repack roughly doubles the bundle.
#
# src/libs/arm64-v8a/*.so IS included: the device has no cmake, clang or NDK, so the native module
# and the two prebuilt libraries cannot be produced there. Shipping them is what makes the source
# buildable on the phone at all.
#
# Usage: scripts/pack-self.sh   (from the repository root)
set -e
cd "$(dirname "$0")/.."
out=app/resources/rawfile/self/source.zip
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
rsync -a \
  --exclude='build/' \
  --exclude='sdk/' \
  --exclude='signing/' \
  --exclude='.hvigor/' \
  --exclude='app/resources/rawfile/self/' \
  app "$staging"/
# zip updates an existing archive in place: entries dropped by the excludes above would stay
# behind, so the archive is recreated from scratch every time.
rm -f "$out"
(cd "$staging/app" && zip -qr "$OLDPWD/$out" . -x '*.DS_Store')
echo "packed $out"
