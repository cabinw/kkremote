#include "stereo_player.h"
#include <3ds.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { eye_bytes = 400 * 240 * 3, max_payload = 200000 };
static unsigned char jpeg[max_payload], pair[2*eye_bytes];
static void put32(unsigned char *p, uint32_t x) {
    p[0]=x>>24; p[1]=x>>16; p[2]=x>>8; p[3]=x;
}
static uint32_t get32(const unsigned char *p) {
    return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3];
}
static uint64_t usec(void) {
    uint64_t tick=svcGetSystemTick();
    return tick/SYSCLOCK_ARM11*1000000ULL + tick%SYSCLOCK_ARM11*1000000ULL/SYSCLOCK_ARM11;
}
static bool feedback(mbedtls_ssl_context *ssl, uint32_t id, uint64_t presented, uint32_t decode, uint32_t draw) {
    unsigned char pkt[24];
    put32(pkt,id); put32(pkt+4,presented>>32); put32(pkt+8,presented);
    put32(pkt+12,decode); put32(pkt+16,draw);
    put32(pkt+20,(uint32_t)lroundf(fminf(1.0f,fmaxf(0.0f,osGet3DSliderState()))*255));
    return lanTransfer(ssl,true,pkt,sizeof(pkt));
}
static void jpegReceive(mbedtls_ssl_context *ssl, tjhandle decoder) {
    if (!feedback(ssl,0,0,0,0)) return;
    linkStatus("Receiving stereo video",0);
    uint32_t previous=0;
    for (;;) {
        unsigned char hdr[8];
        if (!lanTransfer(ssl,false,hdr,sizeof(hdr))) return;
        uint32_t id=get32(hdr), size=get32(hdr+4);
        if(id<=previous || !size || size>max_payload) { linkStatus("Invalid stereo frame",0); return; }
        if (!lanTransfer(ssl,false,jpeg,size)) return;
        uint64_t received=usec();
        int w,h,subsamp,colors;
        if(tjDecompressHeader3(decoder,jpeg,size,&w,&h,&subsamp,&colors) || w!=240 || h!=800 ||
           tjDecompress2(decoder,jpeg,size,pair,w,0,h,TJPF_BGR,TJFLAG_FASTDCT|TJFLAG_FASTUPSAMPLE)) {
            linkStatus("Stereo JPEG decode failed",0); return;
        }
        uint64_t decoded=usec();
        memcpy(gfxGetFramebuffer(GFX_TOP,GFX_LEFT,NULL,NULL), pair, eye_bytes);
        memcpy(gfxGetFramebuffer(GFX_TOP,GFX_RIGHT,NULL,NULL), pair+eye_bytes, eye_bytes);
        gfxFlushBuffers();
        gfxSwapBuffers();
        gspWaitForVBlank();
        uint64_t presented=usec();
        if(!feedback(ssl,id,presented,decoded-received,presented-decoded)) return;
        previous=id;
    }
}

// The encoder uses Baseline, no B-frames. Before each IDR the host includes
// SPS and PPS. MVD expects linear memory and a three-byte Annex B prefix.
typedef struct { u8 bytes[256]; size_t size; } Parameter;
static Result decodeAVC(Parameter saved[2], MVDSTD_Config *cfg, u8 *scratch, const u8 *packet, size_t size) {
    size_t offset=0, used=0;
    while(offset+4<=size) {
        uint32_t n=get32(packet+offset);
        offset+=4;
        if (!n || n>size-offset) return -100;
        u8 kind=packet[offset]&31;
        if (kind==7 || kind==8 || kind==1 || kind==5) {
            bool parameter=kind==7 || kind==8;
            if(parameter && used) return -101;
            if(parameter) {
                Parameter *last = &saved[kind-7];
                if (last->size == n && !memcmp(last->bytes,packet+offset,n)) {
                    offset += n;
                    continue;
                }
                if (n <= sizeof(last->bytes)) {
                    memcpy(last->bytes,packet+offset,n);
                    last->size = n;
                } else last->size = 0;
            }
            scratch[used++]=0; scratch[used++]=0; scratch[used++]=1;
            memcpy(scratch+used,packet+offset,n); used+=n;
            if(parameter) {
                GSPGPU_FlushDataCache(scratch,used);
                Result r=mvdstdProcessVideoFrame(scratch,used,0,NULL);
                if(!MVD_CHECKNALUPROC_SUCCESS(r)) return r;
                used=0;
            }
        }
        offset+=n;
    }
    if(offset!=size || !used) return -102;
    GSPGPU_FlushDataCache(scratch,used);
    Result r=mvdstdProcessVideoFrame(scratch,used,0,NULL);
    if(!MVD_CHECKNALUPROC_SUCCESS(r)) return r;
    // Bound retries so START can still shut down a stalled decoder.
    for(int i=0;i<50;i++) {
        r=mvdstdRenderVideoFrame(cfg,false);
        if(r!=MVD_STATUS_BUSY) return r;
        svcSleepThread(500000);
    }
    return r;
}

// One producer decodes into a free slot. One consumer owns the top framebuffers.
enum { picture_slots = 10, receipt_slots = 32, eye_pixels = 400 * 240 };
typedef struct {
    uint32_t id, decode_us, signature;
    uint64_t pts;
} Picture;
typedef struct {
    Picture picture;
    uint64_t display_us;
    uint32_t draw_us;
} Receipt;
typedef struct {
    LightLock lock;
    bool stop;
    unsigned head, count, receipt_head, receipt_count;
    Picture pictures[picture_slots];
    Receipt receipts[receipt_slots];
    u16 *pixels;
} Cinema;

static void transposeAVC(const u16 *source, u16 *destination) {
    for(int eye=0;eye<2;eye++) {
        u16 *fb=destination+eye*eye_pixels;
        // Blocking the transpose keeps both source and destination near cache.
        for(int y0=0;y0<240;y0+=8) for(int x0=0;x0<400;x0+=8)
            for(int dx=0;dx<8;dx++) for(int dy=0;dy<8;dy++)
                fb[(x0+dx)*240+239-y0-dy]=source[(y0+dy)*800+eye*400+x0+dx];
    }
}
static void presentMovie(void *arg) {
    Cinema *c = arg;
    uint64_t first_pts = 0, anchor = 0, submitted = 0;
    Picture previous = {0};
    for (;;) {
        gspWaitForVBlank();
        uint64_t now = usec();
        LightLock_Lock(&c->lock);
        if (c->stop) { LightLock_Unlock(&c->lock); return; }
        if (previous.id) {
            // The host limits outstanding frames to sixteen, below receipt_slots.
            unsigned tail = (c->receipt_head + c->receipt_count) % receipt_slots;
            c->receipts[tail] = (Receipt){previous, now, now-submitted};
            c->receipt_count++;
            previous.id = 0;
        }
        unsigned slot = c->head;
        Picture next = c->pictures[slot];
        bool ready = c->count > 0;
        if (ready && !anchor) {
            anchor = now + 220000;
            first_pts = next.pts;
        }
        // Swap for the upcoming refresh if it is the nearest refresh to the film PTS.
        ready = ready && now + 25000 >= anchor + (next.pts - first_pts);
        LightLock_Unlock(&c->lock);
        if (!ready) continue;
        submitted = now;
        const u16 *source = c->pixels + slot*2*eye_pixels;
        memcpy(gfxGetFramebuffer(GFX_TOP,GFX_LEFT,NULL,NULL), source, 2*eye_pixels);
        memcpy(gfxGetFramebuffer(GFX_TOP,GFX_RIGHT,NULL,NULL), source+eye_pixels, 2*eye_pixels);
        gfxFlushBuffers();
        gfxSwapBuffers();
        previous = next;
        LightLock_Lock(&c->lock);
        c->head = (slot+1) % picture_slots;
        c->count--;
        LightLock_Unlock(&c->lock);
    }
}

static bool sendReceipts(Cinema *c, mbedtls_ssl_context *ssl) {
    for (;;) {
        LightLock_Lock(&c->lock);
        if (!c->receipt_count) { LightLock_Unlock(&c->lock); return true; }
        Receipt r = c->receipts[c->receipt_head];
        c->receipt_head = (c->receipt_head+1) % receipt_slots;
        c->receipt_count--;
        LightLock_Unlock(&c->lock);
        unsigned char pkt[32];
        put32(pkt,r.picture.id);
        put32(pkt+4,r.display_us>>32); put32(pkt+8,r.display_us);
        put32(pkt+12,r.picture.decode_us); put32(pkt+16,r.draw_us);
        put32(pkt+20,(uint32_t)lroundf(fminf(1,fmaxf(0,osGet3DSliderState()))*255));
        put32(pkt+24,r.picture.signature); put32(pkt+28,usec()-r.display_us);
        if (!lanTransfer(ssl,true,pkt,sizeof(pkt))) return false;
    }
}

static void avcReceive(mbedtls_ssl_context *ssl, int fd) {
    Cinema cinema = {0};
    LightLock_Init(&cinema.lock);
    Thread presenter = NULL;
    cinema.pixels = malloc(picture_slots * 2 * eye_pixels * sizeof(u16));
    u8 *scratch=linearAlloc(max_payload+64);
    u16 *rgb=linearAlloc(800*240*sizeof(*rgb));
    Result r=-103;
    bool initialized=false;
    if(!scratch || !rgb || !cinema.pixels) goto fail;
    r=mvdstdInit(MVDMODE_VIDEOPROCESSING,MVD_INPUT_H264,MVD_OUTPUT_BGR565,MVD_DEFAULT_WORKBUF_SIZE,NULL);
    if(R_FAILED(r)) goto fail;
    initialized=true;
    Parameter saved[2] = {0};
    MVDSTD_Config cfg;
    mvdstdGenerateDefaultConfig(&cfg,800,240,800,240,NULL,(u32*)rgb,NULL);
    r=MVDSTD_SetConfig(&cfg);
    if(r!=MVD_STATUS_OK) goto fail;
    presenter = threadCreate(presentMovie, &cinema, 16*1024, 0x29, -2, false);
    if (!presenter) { r=-105; goto fail; }
    if(!feedback(ssl,0,0,0,0)) goto out;
    linkStatus("H.264 paced stereo",0);
    uint32_t previous=0;
    for (;;) {
        if (!sendReceipts(&cinema, ssl)) break;
        if (!lanReadable(ssl, fd)) continue;
        unsigned char hdr[16];
        if(!lanTransfer(ssl,false,hdr,sizeof(hdr))) break;
        uint32_t id=get32(hdr),size=get32(hdr+4);
        if(id<=previous || !size || size>max_payload) { r=-104; goto fail; }
        uint64_t pts=(uint64_t)get32(hdr+8)<<32 | get32(hdr+12);
        if(!lanTransfer(ssl,false,jpeg,size)) break;
        uint64_t received=usec();
        r=decodeAVC(saved,&cfg,scratch,jpeg,size);
        if(r!=MVD_STATUS_OK) goto fail;
        GSPGPU_InvalidateDataCache(rgb,800*240*2);
        uint64_t decoded=usec();
        unsigned slot;
        for (;;) {
            LightLock_Lock(&cinema.lock);
            slot = (cinema.head + cinema.count) % picture_slots;
            bool full = cinema.count == picture_slots;
            LightLock_Unlock(&cinema.lock);
            if (!full) break;
            if (!sendReceipts(&cinema, ssl)) goto out;
            svcSleepThread(2000000);
        }
        u16 *pixels = cinema.pixels + slot*2*eye_pixels;
        transposeAVC(rgb, pixels);
        uint32_t signature = 2166136261u;
        for (int i=0; i<2*eye_pixels; i+=97)
            signature = (signature ^ pixels[i]) * 16777619u;
        LightLock_Lock(&cinema.lock);
        cinema.pictures[slot] = (Picture){id, decoded-received, signature, pts};
        cinema.count++;
        LightLock_Unlock(&cinema.lock);
        previous=id;
    }
    goto out;
fail:
    linkStatus("MVD decoder error",(int)r);

out:
    if (presenter) {
        LightLock_Lock(&cinema.lock);
        cinema.stop = true;
        LightLock_Unlock(&cinema.lock);
        threadJoin(presenter, UINT64_MAX);
        threadFree(presenter);
    }
    free(cinema.pixels);
    if(initialized) mvdstdExit();
    if(rgb) linearFree(rgb);
    if(scratch) linearFree(scratch);
}
void stereoReceive(mbedtls_ssl_context *ssl, tjhandle decoder, bool avc, int fd) {
    if(avc) avcReceive(ssl,fd); else jpegReceive(ssl,decoder);
}
