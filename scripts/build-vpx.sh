#!/usr/bin/env bash
# Builds the WebM dependencies from pinned source into build/vendor:
#   libvpx  (VP9 encoder + decoder, BSD-3-Clause)  → lib/libvpx.a, include/vpx/
#   libwebm (mkvmuxer + mkvparser, BSD-3-Clause)  → lib/libwebm.a, include/libwebm/
# Static, universal (arm64 + x86_64), macOS 15+. The app links only the encoder and
# muxer; the decoder and parser are used by scripts/export-check.sh to verify files.
#
# x86_64 SIMD needs nasm (brew install nasm). Without it the Intel slice is built
# with libvpx's portable C target: correct, but VP9 encoding on Intel Macs is several
# times slower. Release builds should have nasm installed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/build/vendor"
SRC="$ROOT/build/vendor-src"
MIN_MACOS=15.0

VPX_VERSION=1.15.0
VPX_URL="https://github.com/webmproject/libvpx/archive/refs/tags/v${VPX_VERSION}.tar.gz"
VPX_SHA256=e935eded7d81631a538bfae703fd1e293aad1c7fd3407ba00440c95105d2011e

WEBM_VERSION=1.0.0.31
WEBM_URL="https://github.com/webmproject/libwebm/archive/refs/tags/libwebm-${WEBM_VERSION}.tar.gz"
WEBM_SHA256=616cfdca1c869222dc60d5a49d112c1464040390e3876afca4d385347c6ce55e

ARCHS="${ARCHS:-arm64 x86_64}"
STAMP="$VENDOR/.stamp"
WANT="vpx=$VPX_VERSION webm=$WEBM_VERSION archs=$ARCHS min=$MIN_MACOS"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$WANT" && "${FORCE:-0}" != "1" ]]; then
  echo "==> Vendor libraries up to date ($WANT)"
  exit 0
fi

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)"
mkdir -p "$SRC"

fetch() { # url sha256 file
  local url=$1 sha=$2 file="$SRC/$3"
  if [[ ! -f "$file" ]]; then
    echo "==> Downloading $url"
    curl -fsSL -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  local got
  got="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$got" != "$sha" ]]; then
    echo "error: checksum mismatch for $file" >&2
    echo "  expected $sha" >&2
    echo "  got      $got" >&2
    rm -f "$file"
    exit 1
  fi
}

fetch "$VPX_URL" "$VPX_SHA256" "libvpx-$VPX_VERSION.tar.gz"
fetch "$WEBM_URL" "$WEBM_SHA256" "libwebm-$WEBM_VERSION.tar.gz"

rm -rf "$VENDOR" && mkdir -p "$VENDOR/lib" "$VENDOR/include/libwebm"

vpx_libs=()
webm_libs=()
for arch in $ARCHS; do
  WORK="$ROOT/build/vendor-work/$arch"
  rm -rf "$WORK" && mkdir -p "$WORK"

  # --- libvpx ---------------------------------------------------------------
  echo "==> libvpx $VPX_VERSION ($arch)"
  tar xzf "$SRC/libvpx-$VPX_VERSION.tar.gz" -C "$WORK"
  pushd "$WORK/libvpx-$VPX_VERSION" >/dev/null
  vpx_target="$arch-darwin23-gcc"
  vpx_env=()
  if [[ "$arch" == "x86_64" ]] && ! command -v nasm >/dev/null && ! command -v yasm >/dev/null; then
    echo "warning: nasm not found; building x86_64 libvpx as portable C (slow on Intel Macs)" >&2
    vpx_target=generic-gnu
    vpx_env=(CC="xcrun clang -arch x86_64" CXX="xcrun clang++ -arch x86_64" AR="xcrun ar" LD="xcrun clang -arch x86_64")
  fi
  vpx_flags=(
    --target="$vpx_target"
    --prefix="$WORK/install"
    --extra-cflags="-mmacosx-version-min=$MIN_MACOS -O2"
    --extra-cxxflags="-mmacosx-version-min=$MIN_MACOS -O2"
    --disable-vp8 --enable-vp9
    --disable-examples --disable-tools --disable-docs --disable-unit-tests --disable-install-docs
    --disable-shared --enable-static --enable-pic
    --enable-runtime-cpu-detect
  )
  env ${vpx_env[@]+"${vpx_env[@]}"} ./configure "${vpx_flags[@]}" > "$WORK/configure.log" 2>&1 \
    || { tail -20 "$WORK/configure.log"; exit 1; }
  env ${vpx_env[@]+"${vpx_env[@]}"} make -j"$JOBS" > "$WORK/make.log" 2>&1 || { tail -40 "$WORK/make.log"; exit 1; }
  make install > /dev/null
  popd >/dev/null
  vpx_libs+=("$WORK/install/lib/libvpx.a")
  [[ -d "$VENDOR/include/vpx" ]] || cp -R "$WORK/install/include/vpx" "$VENDOR/include/vpx"

  # --- libwebm (muxer + parser only) ------------------------------------------
  echo "==> libwebm $WEBM_VERSION ($arch)"
  tar xzf "$SRC/libwebm-$WEBM_VERSION.tar.gz" -C "$WORK"
  W="$WORK/libwebm-libwebm-$WEBM_VERSION"
  mkdir -p "$WORK/webm-obj"
  for f in mkvmuxer/mkvmuxer.cc mkvmuxer/mkvmuxerutil.cc mkvmuxer/mkvwriter.cc \
           mkvparser/mkvparser.cc mkvparser/mkvreader.cc; do
    xcrun clang++ -arch "$arch" -mmacosx-version-min="$MIN_MACOS" -std=c++17 -O2 -fPIC -w \
      -I"$W" -c "$W/$f" -o "$WORK/webm-obj/$(basename "$f" .cc).o"
  done
  xcrun ar rcs "$WORK/libwebm.a" "$WORK"/webm-obj/*.o
  webm_libs+=("$WORK/libwebm.a")
  if [[ ! -d "$VENDOR/include/libwebm/mkvmuxer" ]]; then
    for d in mkvmuxer mkvparser common; do
      mkdir -p "$VENDOR/include/libwebm/$d"
      cp "$W/$d"/*.h "$VENDOR/include/libwebm/$d/"
    done
    cp "$W"/*.hpp "$VENDOR/include/libwebm/"
    cp "$W/LICENSE.TXT" "$VENDOR/LICENSE-libwebm.txt"
    cp "$W/PATENTS.TXT" "$VENDOR/PATENTS-libwebm.txt"
    cp "$WORK/libvpx-$VPX_VERSION/LICENSE" "$VENDOR/LICENSE-libvpx.txt"
    cp "$WORK/libvpx-$VPX_VERSION/PATENTS" "$VENDOR/PATENTS-libvpx.txt"
  fi
done

xcrun lipo -create "${vpx_libs[@]}" -output "$VENDOR/lib/libvpx.a"
xcrun lipo -create "${webm_libs[@]}" -output "$VENDOR/lib/libwebm.a"
echo "$WANT" > "$STAMP"
ls -lh "$VENDOR/lib" | awk 'NR>1 {print "==> " $9 " " $5}'
