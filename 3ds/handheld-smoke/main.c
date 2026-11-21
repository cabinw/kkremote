#include <3ds.h>
#include <stdio.h>

int main(void) {
    PrintConsole top, bottom;
    gfxInitDefault();
    consoleInit(GFX_TOP, &top);
    consoleInit(GFX_BOTTOM, &bottom);
    consoleSelect(&bottom);
    printf("\x1b[2;2HKKRemote | Input test");
    printf("\x1b[5;2HTap anywhere on this screen.");
    printf("\x1b[7;2HPress START to return to hbmenu.");

    consoleSelect(&top);
    printf("\x1b[2;2HKKRemote | New 3DS LL");
    printf("\x1b[4;2HHomebrew launch OK");
    printf("\x1b[7;2HTaps: 0");

    unsigned taps = 0;
    while (aptMainLoop()) {
        hidScanInput();
        const u32 pressed = hidKeysDown();
        if (pressed & KEY_START) break;
        if (pressed & KEY_TOUCH) {
            touchPosition point;
            hidTouchRead(&point);
            printf("\x1b[7;2HTaps: %u\x1b[9;2HLast touch: X=%3u  Y=%3u", ++taps,
                   (unsigned)point.px, (unsigned)point.py);
        }
        gfxFlushBuffers();
        gfxSwapBuffers();
        gspWaitForVBlank();
    }
    gfxExit();
    return 0;
}
