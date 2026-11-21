#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
swiftc -O -whole-module-optimization ../stereo-mac/Converter.swift ../stereo-mac/Encoder.swift Live.swift -o .build/live
