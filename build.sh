#!/bin/zsh
# Builds Voicer.app into ./build.
# First run fetches whisper.cpp (pinned) and the model; later runs reuse both.
#
#   ./build.sh          build build/Voicer.app
#   ./build.sh --zip    also package build/Voicer-<version>.zip for GitHub Releases
set -euo pipefail
cd "$(dirname "$0")"

# Whisper Large v3 Turbo, full precision — the only model Voicer ships with.
MODEL=Models/ggml-large-v3-turbo.bin
MODEL_URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
MODEL_SHA=1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69

# whisper.cpp revision Voicer is built and tested against.
WHISPER_REPO=https://github.com/ggml-org/whisper.cpp.git
WHISPER_REV=d09f61a708f3487afa956ff578e60eae5e7a233c

for tool in cmake swiftc git curl; do
  command -v $tool >/dev/null || { echo "Missing '$tool'. See README → Requirements." >&2; exit 1; }
done

if [[ ! -f $MODEL ]]; then
  mkdir -p Models
  echo "Downloading Whisper Large v3 Turbo (1.6 GB)…"
  curl -L --fail --progress-bar -o $MODEL.part $MODEL_URL
  mv $MODEL.part $MODEL
fi
if [[ ! -f $MODEL.verified ]]; then
  echo "Verifying model checksum…"
  [[ "$(shasum -a 256 $MODEL | cut -d' ' -f1)" == $MODEL_SHA ]] || { echo "Model checksum mismatch: delete $MODEL and rebuild." >&2; exit 1; }
  touch $MODEL.verified
fi

W=vendor/whisper.cpp
if [[ ! -d $W/.git ]]; then
  echo "Fetching whisper.cpp @ ${WHISPER_REV:0:7}…"
  rm -rf $W && mkdir -p $W
  git -C $W init -q
  git -C $W fetch -q --depth 1 $WHISPER_REPO $WHISPER_REV
  git -C $W checkout -q FETCH_HEAD
fi
if [[ ! -f $W/build/src/libwhisper.a ]]; then
  cmake -S $W -B $W/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
  cmake --build $W/build -j "$(sysctl -n hw.ncpu)"
fi

APP=build/Voicer.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources

swiftc -O -swift-version 5 \
  -target arm64-apple-macos26.0 -sdk "$(xcrun --show-sdk-path)" \
  -I Sources/CWhisper -Xcc -I$W/include -Xcc -I$W/ggml/include \
  -L$W/build/src -L$W/build/ggml/src -L$W/build/ggml/src/ggml-metal \
  -lwhisper -lggml -lggml-base -lggml-cpu -lggml-metal -lc++ \
  -framework Metal -framework MetalKit -framework Accelerate \
  Sources/Voicer/*.swift -o $APP/Contents/MacOS/Voicer

cp Resources/Info.plist $APP/Contents/
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns $APP/Contents/Resources/
# APFS clone: instant and takes no extra disk space.
cp -c $MODEL $APP/Contents/Resources/ 2>/dev/null || cp $MODEL $APP/Contents/Resources/

# Ad-hoc by default. Set SIGN_ID to a stable identity so macOS keeps the
# Accessibility permission across rebuilds (see CONTRIBUTING.md).
codesign --force --sign "${SIGN_ID:--}" --identifier io.github.kimagedon.voicer $APP
echo "→ $APP"

if [[ "${1:-}" == "--zip" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  ZIP=build/Voicer-$VERSION.zip
  rm -f $ZIP
  ditto -c -k --keepParent --norsrc $APP $ZIP
  echo "→ $ZIP ($(du -h $ZIP | cut -f1))"
fi
