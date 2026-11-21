#!/bin/sh
set -eu
cd "$(dirname "$0")"
: "${DEVKITPRO:?Set DEVKITPRO or use devkitpro/devkitarm}"
: "${DEVKITARM:=$DEVKITPRO/devkitARM}"
libs="$DEVKITPRO/portlibs/3ds"
mkdir -p .build
target=.build/KKRemote-LAN
"$DEVKITARM/bin/arm-none-eabi-gcc" -O2 -Wall -Wextra -Werror -D__3DS__ \
    -march=armv6k -mtune=mpcore -mfloat-abi=hard -mtp=soft -mword-relocations \
    -ffunction-sections -fdata-sections -I"$DEVKITPRO/libctru/include" -I"$libs/include" \
    -specs=3dsx.specs -Wl,--gc-sections handheld.c stereo_player.c -L"$libs/lib" -L"$DEVKITPRO/libctru/lib" \
    -lturbojpeg -lmbedtls -lmbedx509 -lmbedcrypto -lctru -lm -o "$target.elf"
"$DEVKITPRO/tools/bin/smdhtool" --create "KKRemote LAN" "Mac window and touchpad" "KKRemote" \
    "$DEVKITPRO/libctru/default_icon.png" "$target.smdh"
"$DEVKITPRO/tools/bin/3dsxtool" "$target.elf" "$target.3dsx" --smdh="$target.smdh"
