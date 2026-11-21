#include "desk.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { CARD_W=78, CARD_H=62, STEP=84, KEYBOARD_TOP=85, KEY_H=155, MAX_WINDOWS=128,
       MAX_KEYS=56, MAX_ACTIONS=48, W=400, H=240 };
typedef struct { int x,y,w,h,code; } Key;
typedef struct { unsigned count; Key keys[MAX_KEYS]; u8 pixels[320*KEY_H*3]; } Keyboard;
typedef struct { int count,initial; u8 *cards; Keyboard pages[3]; } Catalog;
typedef struct { u8 action,value; int x,y; } Event;
typedef struct { u8 *bytes; size_t size; } Reader;
static LightLock mutex;
static Catalog *catalog;
static int deskImageWidth,deskImageHeight;
static int selected, page, generation, queueHead, queued;
static bool refresh=true, ready, shown, hover, pad;
static float pointerX=200, pointerY=120, scroll;
static Event events[MAX_ACTIONS];
static u8 image[W*H*3], scratch[W*H*3], compressed[150000];
static char notice[44]="Connecting";
static int pressed=-1, originX, originY, lastX, lastY, gesture;
static float originScroll;
static bool dragged;
static int lastDX,lastDY;
static u64 directionSince,lastUpdate;

static int limit(int n,int lo,int hi) { return n<lo?lo:n>hi?hi:n; }
static void freeCatalog(Catalog *c) { if (c) { free(c->cards); free(c); } }
void deskInit(void) { LightLock_Init(&mutex); }
void deskExit(void) { freeCatalog(catalog); }
static u8 *take(Reader *r,size_t n) {
    if(n>r->size) return NULL;
    u8 *p=r->bytes; r->bytes+=n; r->size-=n;
    return p;
}
static unsigned be16(const u8 *p) { return p[0]*256u+p[1]; }
// Images are cached in the 3DS framebuffer's column-major, bottom-up order.
static bool decode(tjhandle decoder,u8 *src,int size,int w,int h,u8 *out) {
    int iw,ih,sub,color;
    if(tjDecompressHeader3(decoder,src,size,&iw,&ih,&sub,&color) || iw!=w || ih!=h ||
       tjDecompress2(decoder,src,size,scratch,w,0,h,TJPF_BGR,TJFLAG_FASTDCT|TJFLAG_FASTUPSAMPLE)) return false;
    for(int x=0;x<w;x++) for(int y=0;y<h;y++)
        memcpy(out+(x*h+h-1-y)*3,scratch+(y*w+x)*3,3);
    return true;
}
static bool art(Reader *r,tjhandle decoder,int w,int h,u8 *out) {
    u8 *length=take(r,2);
    if(!length) return false;
    int size=be16(length);
    u8 *p=take(r,size);
    return p && size && decode(decoder,p,size,w,h,out);
}
static Catalog *unpack(Reader r,tjhandle decoder) {
    u8 *header=take(&r,2);
    if(!header || header[0]>MAX_WINDOWS || (header[0] && header[1]>=header[0])) return NULL;
    Catalog *c=calloc(1,sizeof(*c));
    if(!c) return NULL;
    c->count=header[0]; c->initial=header[1];
    if(c->count) {
        c->cards=malloc(c->count*CARD_W*CARD_H*3);
        if(!c->cards) goto fail;
    }
    for(int i=0;i<c->count;i++)
        if(!art(&r,decoder,CARD_W,CARD_H,c->cards+i*CARD_W*CARD_H*3)) goto fail;
    for(int pageIndex=0;pageIndex<3;pageIndex++) {
        Keyboard *k=&c->pages[pageIndex];
        u8 *count=take(&r,1);
        if(!count || *count>MAX_KEYS) goto fail;
        k->count=*count;
        for(unsigned i=0;i<k->count;i++) {
            u8 *p=take(&r,6);
            if(!p) goto fail;
            Key key={be16(p),p[2],p[3],p[4],p[5]};
            if(key.x+key.w>320 || key.y+key.h>KEY_H) goto fail;
            k->keys[i]=key;
        }
        if(!art(&r,decoder,320,KEY_H,k->pixels)) goto fail;
    }
    if(!r.size) return c;
fail:
    freeCatalog(c); return NULL;
}

static void selectWindow(int next) {
    if(!catalog || !catalog->count) return;
    next=(next+catalog->count)%catalog->count;
    scroll=next;
    if(next==selected) return;
    generation++;
    selected=next; ready=false; shown=false; queued=0; hover=false;
    pointerX=200; pointerY=120;
    strcpy(notice,"Opening window");
}
static void enqueue(u8 action,u8 value) {
    if(!shown || refresh) return;
    if(queued==MAX_ACTIONS) { strcpy(notice,"Input queue full"); return; }
    events[(queueHead+queued)%MAX_ACTIONS]=(Event){action,value,lroundf(pointerX),lroundf(pointerY)};
    queued++;
}
void deskReceive(mbedtls_ssl_context *ssl,tjhandle decoder) {
    u8 *rotated=malloc(W*H*3);
    if(!rotated) { linkStatus("Out of memory",0); return; }
    for(;;) {
        LightLock_Lock(&mutex);
        int id=selected, revision=generation;
        bool listing=refresh, reported=shown;
        Event event={0,0,lroundf(pointerX),lroundf(pointerY)};
        if(listing) { event.action=255; refresh=false; }
        else if(queued) { event=events[queueHead]; queueHead=(queueHead+1)%MAX_ACTIONS; queued--; }
        else if(hover && shown) { event.action=4; hover=false; }
        LightLock_Unlock(&mutex);
        u8 req[]={reported?0x45:0x44,id,event.action,event.value,event.x>>8,event.x&255,event.y>>8,event.y&255};
        u8 hdr[5];
        if(!lanTransfer(ssl,true,req,sizeof(req)) || !lanTransfer(ssl,false,hdr,sizeof(hdr))) break;
        uint32_t size=(uint32_t)hdr[1]<<24|(uint32_t)hdr[2]<<16|(uint32_t)hdr[3]<<8|hdr[4];
        if(listing) {
            if(hdr[0] || !size || size>2000000) break;
            u8 *bytes=malloc(size);
            Catalog *next=NULL;
            if(bytes && lanTransfer(ssl,false,bytes,size)) next=unpack((Reader){bytes,size},decoder);
            free(bytes);
            if(!next) { linkStatus("Bad control layout",0); break; }
            LightLock_Lock(&mutex);
            Catalog *old=catalog; catalog=next; selected=next->initial; scroll=selected;
            generation++; ready=false; shown=false; queued=0; hover=false; gesture=0; pressed=-1;
            strcpy(notice,next->count?"Opening window":"No windows - SELECT to refresh");
            LightLock_Unlock(&mutex);
            freeCatalog(old); continue;
        }
        if(size>sizeof(compressed) || hdr[0]>3) break;
        int w=0,h=0,sub,color;
        if(size && (!lanTransfer(ssl,false,compressed,size) ||
           tjDecompressHeader3(decoder,compressed,size,&w,&h,&sub,&color) || w<1 || w>W || h<1 || h>H ||
           !decode(decoder,compressed,size,w,h,rotated))) break;
        LightLock_Lock(&mutex);
        if(generation==revision) {
            if(size) {
                memset(image,0,sizeof(image));
                for(int x=0;x<w;x++)
                    memcpy(image+(((W-w)/2+x)*H+(H-h+1)/2)*3,rotated+x*h*3,h*3);
                // The reticle is normalized to the actual window, including portrait/letterboxed windows.
                deskImageWidth=w; deskImageHeight=h; ready=true;
            }
            if(hdr[0]==3) { shown=false; ready=false; strcpy(notice,"Unavailable - SELECT to refresh"); }
            else if(hdr[0]==2) strcpy(notice,"View only - input unavailable");
            else if(hdr[0]==1) strcpy(notice,"Input refused - click field again");
            else if(size && (event.action || !shown)) strcpy(notice,"L/R Window   Y Click   A Right   X Pad");
        }
        bool waiting=!catalog || !catalog->count;
        LightLock_Unlock(&mutex);
        svcSleepThread(waiting?150000000:6000000);
    }
    free(rotated);
    LightLock_Lock(&mutex); shown=false; ready=false; strcpy(notice,"Disconnected - START to exit"); LightLock_Unlock(&mutex);
}
static void moveBy(float dx,float dy) {
    int x=lroundf(pointerX),y=lroundf(pointerY);
    pointerX=fminf(399,fmaxf(0,pointerX+dx)); pointerY=fminf(239,fmaxf(0,pointerY+dy));
    if(x!=lroundf(pointerX) || y!=lroundf(pointerY)) hover=true;
}
static void direction(u32 held,u64 now) {
    int dx=!!(held&KEY_DRIGHT)-!!(held&KEY_DLEFT),dy=!!(held&KEY_DDOWN)-!!(held&KEY_DUP);
    float dt=fminf(0.05f,(now-lastUpdate)/1000.0f); lastUpdate=now;
    if(dx!=lastDX || dy!=lastDY) {
        directionSince=now; lastDX=dx; lastDY=dy;
        moveBy(dx,dy); return;
    }
    if((!dx && !dy) || now-directionSince<155) return;
    float t=fminf(1,(now-directionSince-155)/760.0f);
    float pixels=dt*(36+340*t*t*(3-2*t))*(dx&&dy?0.707107f:1);
    moveBy(dx*pixels,dy*pixels);
}
static int hitKey(int x,int y) {
    if(!catalog) return -1;
    Keyboard *k=&catalog->pages[page];
    for(unsigned i=0;i<k->count;i++) {
        Key b=k->keys[i];
        if(x>=b.x && x<b.x+b.w && y>=KEYBOARD_TOP+b.y && y<KEYBOARD_TOP+b.y+b.h) return i;
    }
    return -1;
}
static void touch(u32 down,u32 held,u32 up) {
    if(!catalog) return;
    if(held&KEY_TOUCH) {
        touchPosition p; hidTouchRead(&p);
        if(down&KEY_TOUCH) {
            originX=lastX=p.px; originY=lastY=p.py; dragged=false; originScroll=scroll;
            gesture=p.py<68?1:p.py<KEYBOARD_TOP?0:pad?3:2;
            pressed=gesture==2?hitKey(p.px,p.py):-1;
        } else {
            if(abs(p.px-originX)>6 || abs(p.py-originY)>6) dragged=true;
            if(gesture==1 && dragged && catalog->count)
                scroll=fmaxf(0,fminf(catalog->count-1,originScroll+(originX-(int)p.px)/(float)STEP));
            if(gesture==3) moveBy((int)p.px-lastX,(int)p.py-lastY);
            lastX=p.px; lastY=p.py;
        }
    }
    if(!(up&KEY_TOUCH)) return;
    if(gesture==1 && catalog->count) {
        int index=dragged?lroundf(scroll):lroundf(scroll+(lastX-160)/(float)STEP);
        selectWindow(limit(index,0,catalog->count-1));
    } else if(gesture==3 && !dragged) enqueue(1,0);
    else if(gesture==2 && pressed>=0 && hitKey(lastX,lastY)==pressed) {
        int code=catalog->pages[page].keys[pressed].code;
        if(code==128) page=page==1?0:1;
        else if(code==129) page=page==2?0:2;
        else { enqueue(3,code); if(page==1) page=0; }
    }
    pressed=-1; gesture=0;
}
static void pixel(u8 *fb,int x,int y,u32 rgb) {
    u8 *p=fb+(x*H+H-1-y)*3;
    p[0]=rgb; p[1]=rgb>>8; p[2]=rgb>>16;
}
static void box(u8 *fb,int x,int y,int w,int h,u32 rgb) {
    for(int i=limit(x,0,320);i<limit(x+w,0,320);i++)
        for(int j=limit(y,0,240);j<limit(y+h,0,240);j++) pixel(fb,i,j,rgb);
}
static void text(u8 *fb,int x,int y,const char *str,u32 color) {
    ConsoleFont f=consoleGetDefault()->font;
    for(;*str && x<=312;str++,x+=8) {
        int idx=(unsigned char)*str-f.asciiOffset;
        if(idx<0 || idx>=f.numChars) continue;
        for(int row=0;row<8;row++)
            for(int col=0;col<8;col++)
                if(f.gfx[idx*8+row]&(0x80>>col)) pixel(fb,x+col,y+row,color);
    }
}
static void blit(u8 *fb,const u8 *src,int x,int y,int w,int h) {
    for(int i=limit(-x,0,w);i<limit(320-x,0,w);i++)
        memcpy(fb+((i+x)*H+H-y-h)*3,src+i*h*3,h*3);
}
static void drawBottom(u8 *fb,const char *connection) {
    memset(fb,0,320*240*3);
    if(!catalog) { text(fb,10,106,connection,0x76eed5); return; }
    int nearest=lroundf(scroll);
    for(int i=limit(nearest-3,0,catalog->count);i<limit(nearest+4,0,catalog->count);i++) {
        int x=lroundf(160-CARD_W/2+(i-scroll)*STEP);
        blit(fb,catalog->cards+i*CARD_W*CARD_H*3,x,2,CARD_W,CARD_H);
        if(i==selected) box(fb,x+7,65,CARD_W-14,3,0x68e7cf);
    }
    text(fb,5,73,notice,0xade8dc);
    if(pad) {
        box(fb,3,KEYBOARD_TOP,314,KEY_H-3,0x223443);
        text(fb,64,147,"Slide to move  Tap to click",0xedf4f5);
        text(fb,91,171,"X  Show keyboard",0x75e1cb);
    } else {
        Keyboard *k=&catalog->pages[page];
        blit(fb,k->pixels,0,KEYBOARD_TOP,320,KEY_H);
        if(pressed>=0 && (unsigned)pressed<k->count) {
            Key key=k->keys[pressed];
            box(fb,key.x+3,KEYBOARD_TOP+key.y+key.h-4,key.w-6,2,0x72ffe0);
        }
    }
}
void deskUpdate(u32 down,u32 held,u32 up,const char *connection) {
    LightLock_Lock(&mutex);
    if(down&KEY_SELECT) { refresh=true; ready=shown=false; queued=0; generation++; }
    if(down&KEY_L) selectWindow(selected-1);
    if(down&KEY_R) selectWindow(selected+1);
    if(down&KEY_X) { pad=!pad; gesture=0; pressed=-1; }
    touch(down,held,up);
    direction(held,osGetTime());
    if(down&KEY_Y) enqueue(1,0);
    if(down&KEY_A) enqueue(2,0);
    u8 *top=gfxGetFramebuffer(GFX_TOP,GFX_LEFT,NULL,NULL);
    if(ready) {
        memcpy(top,image,sizeof(image));
        int cx=(W-deskImageWidth)/2+lroundf(pointerX*(deskImageWidth-1)/399);
        int cy=(H-deskImageHeight)/2+lroundf(pointerY*(deskImageHeight-1)/239);
        for(int dy=-5;dy<=5;dy++) for(int dx=-5;dx<=5;dx++) {
            if(abs(dx)>1 && abs(dy)>1) continue;
            int x=cx+dx,y=cy+dy;
            if(x>=0 && y>=0 && x<W && y<H) pixel(top,x,y,dx==0||dy==0?0x8bffdf:0x11242c);
        }
    } else memset(top,0,sizeof(image));
    drawBottom(gfxGetFramebuffer(GFX_BOTTOM,GFX_LEFT,NULL,NULL),connection);
    int revision=generation;
    bool drew=ready;
    LightLock_Unlock(&mutex);
    gfxFlushBuffers(); gfxSwapBuffers(); gspWaitForVBlank();
    LightLock_Lock(&mutex);
    if(revision==generation && drew && ready) shown=true;
    LightLock_Unlock(&mutex);
}
