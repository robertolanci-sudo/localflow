#!/bin/bash
# Builds a universal static whisper-server (arm64 + x86_64, Metal library embedded) into vendor/bin.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=v1.9.5
mkdir -p vendor/bin
[ -d vendor/whisper.cpp ] || git clone --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp.git vendor/whisper.cpp
cd vendor/whisper.cpp
for ARCH in arm64 x86_64; do
  EXTRA=""
  # Every Intel Mac supported by macOS 13+ has AVX2/FMA.
  [ "$ARCH" = x86_64 ] && EXTRA="-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON"
  cmake -B "build-$ARCH" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_SDL2=OFF -DWHISPER_BUILD_EXAMPLES=ON $EXTRA
  cmake --build "build-$ARCH" --config Release -j 10 --target whisper-server
done
lipo -create build-arm64/bin/whisper-server build-x86_64/bin/whisper-server -output ../bin/whisper-server
file ../bin/whisper-server
