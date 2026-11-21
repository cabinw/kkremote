#!/bin/sh
set -eu
cd "$(dirname "$0")"
: "${DEVKITPRO:?Set DEVKITPRO to a devkitPro installation with 3ds-dev}"
: "${DEVKITARM:=$DEVKITPRO/devkitARM}"
mkdir -p .build
target=.build/KKRemote-Smoke
"$DEVKITARM/bin/arm-none-eabi-gcc" -Os -Wall -Wextra -Werror -D__3DS__ \
    -march=armv6k -mtune=mpcore -mfloat-abi=hard -mtp=soft -mword-relocations \
    -ffunction-sections -fdata-sections -I"$DEVKITPRO/libctru/include" \
    -specs=3dsx.specs -Wl,--gc-sections main.c -L"$DEVKITPRO/libctru/lib" -lctru -lm \
    -o "$target.elf"
"$DEVKITPRO/tools/bin/smdhtool" --create "KKRemote Smoke" "Dual screen and touch check" \
    "KKRemote" "$DEVKITPRO/libctru/default_icon.png" "$target.smdh"
"$DEVKITPRO/tools/bin/3dsxtool" "$target.elf" "$target.3dsx" --smdh="$target.smdh"
