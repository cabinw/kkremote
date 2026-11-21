#!/bin/bash
# Prepare the pinned Core ML model, optimized executable and reference movie.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
name=DepthAnythingV2SmallF16
revision=cfef6f6f2a70783dedc0bfae40cecbc2052285d3
base="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/$revision/$name.mlpackage"
fetch() {
    if [[ ! -f "$2" ]]; then
        mkdir -p "$(dirname "$2")"
        curl --fail --location --silent --show-error --retry 2 "$1" -o "$2.part"
        mv "$2.part" "$2"
    fi
}
for path in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    fetch "$base/$path" ".build/$name.mlpackage/$path"
done
if [[ ! -d ".build/$name.mlmodelc" ]]; then
    xcrun coremlcompiler compile ".build/$name.mlpackage" .build
fi
fetch https://media.w3.org/2010/05/sintel/trailer.mp4 .build/sintel.mp4
echo 'b670602fa00934ca27c4351bb0efe7ea7a07fae57284e44226025eeed7c51254  .build/sintel.mp4' | shasum -a 256 -c -
swiftc -O -whole-module-optimization Converter.swift Encoder.swift Stereo.swift -o .build/stereo
