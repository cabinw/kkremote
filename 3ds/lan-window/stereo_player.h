#pragma once
#include <stdbool.h>
#include <mbedtls/ssl.h>
#include <turbojpeg.h>

bool lanReadable(mbedtls_ssl_context *ssl, int fd);
bool lanTransfer(mbedtls_ssl_context *ssl, bool write, unsigned char *p, size_t size);
void linkStatus(const char *s, int code);
void stereoReceive(mbedtls_ssl_context *ssl, tjhandle decoder, bool avc, int fd);
