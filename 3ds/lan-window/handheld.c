#include <3ds.h>
#include "stereo_player.h"
#include <3ds/services/sslc.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <errno.h>
#include <fcntl.h>
#include <malloc.h>
#include <mbedtls/ssl.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/net_sockets.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <turbojpeg.h>
#include <unistd.h>

enum { W=400, H=240, MAX_JPEG=150000, QUEUE=8 };
typedef struct { uint8_t action; int x,y; } Input;
static LightLock lock;
static bool stopping, displayed, stereo_mode, stereo_avc;
static int remote_fd=-1, cursor_x=W/2, cursor_y=H/2, count, head;
static Input queue[QUEUE];
static char status_text[64]="Opening connection";
static unsigned frames;
static struct in_addr address;
static unsigned short port;
static unsigned char key[32], jpeg[MAX_JPEG], decoded[W*H*3], top_image[W*H*3];
static int image_w, image_h;
void linkStatus(const char *s, int code) {
    LightLock_Lock(&lock);
    if (code) snprintf(status_text,sizeof(status_text),"%s (%d)",s,code);
    else snprintf(status_text,sizeof(status_text),"%s",s);
    LightLock_Unlock(&lock);
}
static int clamp(int v,int hi) { return v<0?0:v>hi?hi:v; }
static void push(unsigned char action) {
    LightLock_Lock(&lock);
    if (count<QUEUE && image_w) {
        queue[(head+count)%QUEUE]=(Input){action,cursor_x,cursor_y}; count++;
    }
    LightLock_Unlock(&lock);
}
bool lanReadable(mbedtls_ssl_context *ssl, int fd) {
    if (mbedtls_ssl_check_pending(ssl)) return true;
    fd_set reads;
    FD_ZERO(&reads);
    FD_SET(fd, &reads);
    struct timeval timeout = {0, 5000};
    return select(fd + 1, &reads, NULL, NULL, &timeout) != 0;
}
bool lanTransfer(mbedtls_ssl_context *ssl, bool write, unsigned char *p, size_t size) {
    while (size) {
        int n=write ? mbedtls_ssl_write(ssl,p,size) : mbedtls_ssl_read(ssl,p,size);
        if (n==MBEDTLS_ERR_SSL_WANT_READ || n==MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (n<=0) { linkStatus("Link closed",n); return false; }
        size-=(size_t)n; p+=n;
    }
    return true;
}
static bool receive_frames(mbedtls_ssl_context *ssl, tjhandle decoder) {
    for (;;) {
        LightLock_Lock(&lock);
        bool done=stopping;
        Input in={0,cursor_x,cursor_y};
        if (count) { in=queue[head]; head=(head+1)%QUEUE; count--; }
        unsigned char mark=displayed ? 0x32 : 0x31;
        LightLock_Unlock(&lock);
        if (done) return true;
        unsigned char req[]={mark,in.action,in.x>>8,in.x&255,in.y>>8,in.y&255}, hdr[5];
        if (!lanTransfer(ssl,true,req,sizeof(req)) || !lanTransfer(ssl,false,hdr,sizeof(hdr))) return false;
        uint32_t size=((uint32_t)hdr[1]<<24)|((uint32_t)hdr[2]<<16)|((uint32_t)hdr[3]<<8)|hdr[4];
        if (size>MAX_JPEG || hdr[0]>1) { linkStatus("Bad frame header",0); return false; }
        if (hdr[0]) linkStatus("Click refused on Mac",0);
        else if (in.action) linkStatus("Input accepted",0);
        if (size) {
            if (!lanTransfer(ssl,false,jpeg,size)) return false;
            int w,h,subsamp,colors;
            if (tjDecompressHeader3(decoder,jpeg,size,&w,&h,&subsamp,&colors) || w<1 || h<1 || w>W || h>H ||
                tjDecompress2(decoder,jpeg,size,decoded,w,0,h,TJPF_BGR,TJFLAG_FASTDCT|TJFLAG_FASTUPSAMPLE)) {
                linkStatus("Invalid JPEG",0); return false;
            }
            LightLock_Lock(&lock);
            memcpy(top_image,decoded,(size_t)w*h*3);
            image_w=w; image_h=h; frames++;
            LightLock_Unlock(&lock);
        }
        svcSleepThread(1000000000LL/16);
    }
}
static void network(void *unused) {
    (void)unused;
    mbedtls_ssl_context ssl; mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config cfg; mbedtls_ssl_config_init(&cfg);
    mbedtls_ctr_drbg_context rng; mbedtls_ctr_drbg_init(&rng);
    mbedtls_entropy_context entropy; mbedtls_entropy_init(&entropy);
    mbedtls_net_context net; mbedtls_net_init(&net);
    tjhandle decoder=tjInitDecompress();
    if (!decoder) { linkStatus("JPEG init failed",0); goto end; }
    struct sockaddr_in server={.sin_family=AF_INET,.sin_port=htons(port),.sin_addr=address};
    net.fd=socket(AF_INET,SOCK_STREAM,0);
    if(net.fd<0) { linkStatus("Socket failed",errno); goto end; }
    LightLock_Lock(&lock); remote_fd=net.fd; LightLock_Unlock(&lock);
    if(connect(net.fd,(struct sockaddr*)&server,sizeof(server))<0) {linkStatus("Cannot connect to Mac",errno); goto end;}
    int no_delay=1;
    setsockopt(net.fd,IPPROTO_TCP,TCP_NODELAY,&no_delay,sizeof(no_delay));
    linkStatus("TLS handshake",0);
    int r=mbedtls_ctr_drbg_seed(&rng,mbedtls_entropy_func,&entropy,(unsigned char*)"KKRemote3DS",11);
    if (!r) r=mbedtls_ssl_config_defaults(&cfg,MBEDTLS_SSL_IS_CLIENT,MBEDTLS_SSL_TRANSPORT_STREAM,MBEDTLS_SSL_PRESET_DEFAULT);
    static const int suites[]={MBEDTLS_TLS_PSK_WITH_AES_128_GCM_SHA256,0};
    if(!r) {
        mbedtls_ssl_conf_rng(&cfg,mbedtls_ctr_drbg_random,&rng);
        mbedtls_ssl_conf_ciphersuites(&cfg,suites);
        mbedtls_ssl_conf_min_version(&cfg,3,3);
        r=mbedtls_ssl_conf_psk(&cfg,key,sizeof(key),(const unsigned char*)"kk3ds",5);
    }
    if (!r) r=mbedtls_ssl_setup(&ssl,&cfg);
    if (!r) {
        mbedtls_ssl_set_bio(&ssl,&net,mbedtls_net_send,mbedtls_net_recv,NULL);
        do {r=mbedtls_ssl_handshake(&ssl);} while(r==MBEDTLS_ERR_SSL_WANT_READ || r==MBEDTLS_ERR_SSL_WANT_WRITE);
    }
    if(r) linkStatus("TLS error",r);
    else { linkStatus("Connected",0); if(stereo_mode) stereoReceive(&ssl,decoder,stereo_avc,net.fd); else receive_frames(&ssl,decoder); }
end:
    LightLock_Lock(&lock); remote_fd=-1; LightLock_Unlock(&lock);
    mbedtls_net_free(&net);
    mbedtls_ssl_free(&ssl); mbedtls_ssl_config_free(&cfg);
    mbedtls_ctr_drbg_free(&rng); mbedtls_entropy_free(&entropy);
    if(decoder) tjDestroy(decoder);
}
static void render(void) {
    u8 *fb=gfxGetFramebuffer(GFX_TOP,GFX_LEFT,NULL,NULL);
    LightLock_Lock(&lock);
    int w=image_w,h=image_h,left=(W-w)/2,top=(H-h)/2;
    // libctru's top framebuffer stores columns bottom-to-top, packed BGR.
    memset(fb,0,W*H*3);
    for(int x=0;x<w;x++) for(int y=0;y<h;y++)
        memcpy(fb+((x+left)*H+H-1-(y+top))*3,top_image+(y*w+x)*3,3);
    if(w && h) {
        int cx=left+cursor_x*w/W,cy=top+cursor_y*h/H;
        for(int dy=-5;dy<=5;dy++) for(int dx=-5;dx<=5;dx++) {
            int x=cx+dx,y=cy+dy;
            if(x<0 || x>=W || y<0 || y>=H || (abs(dx)>1 && abs(dy)>1)) continue;
            u8 *pixel=fb+(x*H+H-1-y)*3;
            pixel[0]=0; pixel[1]=dx==0||dy==0?255:12; pixel[2]=dx==0||dy==0?255:12;
        }
    }
    LightLock_Unlock(&lock);
}
static int hex(char c) {
    if(c>='0'&&c<='9') return c-'0';
    if(c>='a'&&c<='f') return c-'a'+10;
    return -1;
}
int main(int argc,char **argv) {
    stereo_avc=argc==5 && !strcmp(argv[4],"stereo-avc");
    stereo_mode=stereo_avc || (argc==5 && !strcmp(argv[4],"stereo"));
    gfxInit(stereo_avc?GSP_RGB565_OES:GSP_BGR8_OES,GSP_BGR8_OES,false); gfxSet3D(stereo_mode);
    if(stereo_mode) osSetSpeedupEnable(true);
    consoleInit(GFX_BOTTOM,NULL);
    LightLock_Init(&lock);
    if (stereo_mode) printf("KKRemote | Sintel 3D\n\nMove the 3D slider up for stereo.\nSTART: return to Homebrew Launcher\n");
    else printf("\x1b[1;1HKKRemote | LAN window\n\nSlide: move pointer\nTap / A: left click   B: right click\nD-pad up / down: scroll\nSTART: return to Homebrew Launcher\n");
    bool paired=(argc==4 || stereo_mode) && inet_aton(argv[1],&address) && strlen(argv[3])==64;
    if(paired) {
        long value=strtol(argv[2],NULL,10); paired=value>0 && value<=65535; port=(unsigned short)value;
        for(int i=0;paired && i<32;i++){
            int hi=hex(argv[3][i*2]),lo=hex(argv[3][i*2+1]);
            paired=hi>=0 && lo>=0; if(paired) key[i]=(hi<<4)|lo;
        }
    }
    u32 *memory=memalign(0x1000,0x100000);
    bool soc=paired && memory && R_SUCCEEDED(socInit(memory,0x100000));
    bool crypto=soc && R_SUCCEEDED(sslcInit(0));
    Thread worker=crypto?threadCreate(network,NULL,96*1024,0x30,-2,false):NULL;
    if(!worker) linkStatus(paired?"Network init failed":"Launch with Mac deployment command",0);
    touchPosition last={0}; int travel=0; u64 began=0; unsigned ticks=0;
    while(aptMainLoop()) {
        hidScanInput(); u32 down=hidKeysDown(),held=hidKeysHeld(),up=hidKeysUp();
        if(down&KEY_START) break;
        if(stereo_mode) {
            if(ticks++%8==0) {
                LightLock_Lock(&lock); printf("\x1b[7;1H%-38.38s",status_text); LightLock_Unlock(&lock);
                printf("\x1b[9;1H3D slider: %3d%%", (int)(osGet3DSliderState()*100));
            }
            svcSleepThread(16000000);
            continue;
        }
        if(held&KEY_TOUCH) {
            touchPosition p; hidTouchRead(&p);
            if(down&KEY_TOUCH) {travel=0; began=osGetTime();}
            else {
                int dx=(int)p.px-last.px,dy=(int)p.py-last.py;
                travel+=abs(dx)+abs(dy);
                LightLock_Lock(&lock); cursor_x=clamp(cursor_x+dx,W-1); cursor_y=clamp(cursor_y+dy,H-1); LightLock_Unlock(&lock);
            }
            last=p;
        }
        if((up&KEY_TOUCH) && travel<7 && osGetTime()-began<360) push(1);
        if(down&KEY_A) push(1);
        if(down&KEY_B) push(2);
        if(down&KEY_DUP) push(3);
        if(down&KEY_DDOWN) push(4);
        render();
        if((ticks++%10)==0) {
            LightLock_Lock(&lock);
            printf("\x1b[9;1H%-38.38s\nFrames: %-10u\nPointer: %3d, %3d   ",status_text,frames,cursor_x,cursor_y);
            LightLock_Unlock(&lock);
        }
        gfxFlushBuffers(); gfxSwapBuffers(); gspWaitForVBlank();
        LightLock_Lock(&lock); if(image_w && ticks>2) displayed=true; LightLock_Unlock(&lock);
    }
    LightLock_Lock(&lock); stopping=true; if(remote_fd>=0) shutdown(remote_fd,SHUT_RDWR); LightLock_Unlock(&lock);
    if(worker) {
        if(R_FAILED(threadJoin(worker,3000000000LL))) svcExitProcess();
        threadFree(worker);
    }
    if(crypto) sslcExit();
    if(soc) socExit();
    free(memory); gfxExit(); return 0;
}
