#pragma once
#include "stereo_player.h"
#include <3ds.h>

void deskInit(void);
void deskReceive(mbedtls_ssl_context *ssl, tjhandle decoder);
void deskUpdate(u32 down, u32 held, u32 up, const char *connection);
void deskExit(void);
