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
static bool refresh=true, ready, shown, hover, pad, detail;
static int cropX,cropY;
static float pointerX=200, pointerY=120, scroll;
static Event events[MAX_ACTIONS];
static u8 image[W*H*3], scratch[W*H*3], compressed[150000];
static char notice[44];
static int pressed=-1, originX, originY, lastX, lastY, gesture;
static float originScroll;
static bool dragged;
static u64 lastUpdate;

static int limit(int n,int lo,int hi) { return n<lo?lo:n>hi?hi:n; }
static void freeCatalog(Catalog *c) { if (c) { free(c->cards); free(c); } }
void deskInit(void) { LightLock_Init(&mutex); hidSetRepeatParameters(26,5); }
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
    events[(queueHead+queued)%MAX_ACTIONS]=(Event){action,value,lroundf(pointerX*2),lroundf(pointerY*2)};
    queued++;
}
void deskReceive(mbedtls_ssl_context *ssl,tjhandle decoder) {
    u8 *rotated=malloc(W*H*3);
    if(!rotated) { linkStatus("Out of memory",0); return; }
    for(;;) {
        LightLock_Lock(&mutex);
        int id=selected, revision=generation;
        bool listing=refresh, reported=shown, zoom=detail;
        Event event={0,0,lroundf(pointerX*2),lroundf(pointerY*2)};
        if(listing) { event.action=255; refresh=false; }
        else if(queued) { event=events[queueHead]; queueHead=(queueHead+1)%MAX_ACTIONS; queued--; }
        else if(hover && shown) { event.action=4; hover=false; }
        LightLock_Unlock(&mutex);
        u8 req[]={(u8)(0x54+(zoom?2:0)+reported),id,event.action,event.value,event.x>>8,event.x&255,event.y>>8,event.y&255};
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
                deskImageWidth=w; deskImageHeight=h;
                cropX=zoom?limit(event.x-200,0,400):0;
                cropY=zoom?limit(event.y-120,0,240):0;
                ready=true;
            }
            if(hdr[0]==3) { shown=false; ready=false; strcpy(notice,"Unavailable - SELECT to refresh"); }
            else if(hdr[0]==2) strcpy(notice,"View only - input unavailable");
            else if(hdr[0]==1) strcpy(notice,"Input refused - click field again");
            else if(size && (event.action || !shown)) notice[0]=0;
        }
        bool waiting=!catalog || !catalog->count;
        LightLock_Unlock(&mutex);
        svcSleepThread(waiting?150000000:6000000);
    }
    free(rotated);
    LightLock_Lock(&mutex); shown=false; ready=false; strcpy(notice,"Disconnected - START to exit"); LightLock_Unlock(&mutex);
}
static void moveBy(float dx,float dy) {
    int x=lroundf(pointerX*2),y=lroundf(pointerY*2);
    if(detail) { dx*=0.5f; dy*=0.5f; }
    pointerX=fminf(399.5f,fmaxf(0,pointerX+dx)); pointerY=fminf(239.5f,fmaxf(0,pointerY+dy));
    if(x!=lroundf(pointerX*2) || y!=lroundf(pointerY*2)) hover=true;
}
static void circlePointer(u64 now) {
    float dt=fminf(0.05f,(now-lastUpdate)/1000.0f); lastUpdate=now;
    circlePosition stick;
    hidCircleRead(&stick);
    float radius=hypotf(stick.dx,stick.dy);
    if(radius>18) {
        // Radial dead zone and progressive gain give the same speed on diagonals.
        float amount=fminf(1.0f,(radius-18.0f)/132.0f);
        float step=dt*(25.0f*amount+435.0f*amount*amount)/radius;
        moveBy(stick.dx*step,-stick.dy*step);
    }
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
// The top-left tip is the host click hotspot. White edging remains visible on dark windows.
static void drawCursor(u8 *fb,int cx,int cy) {
    static const char *const rows[] = {
        "w", "ww", "wbw", "wbbw", "wbbbw", "wbbbbw", "wbbbbbw",
        "wbbbbbbw", "wbbbbbbbw", "wbbbbbbbbw", "wbbbbw wwww",
        "wbbwbbw", "wbw wbbw", "ww  wbbw", "     wbbw", "      ww"
    };
    for(unsigned y=0;y<sizeof(rows)/sizeof(rows[0]) && cy+(int)y<H;y++)
        for(int x=0;rows[y][x] && cx+x<W;x++) {
            if(rows[y][x]!=' ') pixel(fb,cx+x,cy+y,rows[y][x]=='w'?0xffffff:0x121212);
        }
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
static void drawBottom(u8 *fb) {
    memset(fb,0,320*240*3);
    if(!catalog) return;
    int nearest=lroundf(scroll);
    for(int i=limit(nearest-3,0,catalog->count);i<limit(nearest+4,0,catalog->count);i++) {
        int x=lroundf(160-CARD_W/2+(i-scroll)*STEP);
        blit(fb,catalog->cards+i*CARD_W*CARD_H*3,x,2,CARD_W,CARD_H);
        if(i==selected) box(fb,x+7,65,CARD_W-14,3,0x68e7cf);
    }
    if(pad) {
        box(fb,3,KEYBOARD_TOP,314,KEY_H-3,0x223443);
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
    if(down&KEY_B) {
        detail=!detail; generation++; ready=shown=false;
        strcpy(notice,detail?"Opening 2x detail":"Opening full window");
    }
    if((down&KEY_ZR) && shown && !refresh) {
        queued=0;
        enqueue(5,0);
        generation++; ready=shown=false; hover=false;
    }
    if(down&KEY_ZL) { pad=!pad; gesture=0; pressed=-1; }
    touch(down,held,up);
    circlePointer(osGetTime());
    u32 repeat=hidKeysDownRepeat() | down;
    static const struct { u32 button; u8 code; } arrows[] = {
        {KEY_DLEFT,130},{KEY_DRIGHT,131},{KEY_DUP,132},{KEY_DDOWN,133}
    };
    for(unsigned i=0;i<sizeof(arrows)/sizeof(arrows[0]);i++) {
        if((repeat & held & arrows[i].button) && ((down & arrows[i].button) || !queued))
            enqueue(3,arrows[i].code);
    }
    if(down&KEY_X) enqueue(3,13);
    if(down&KEY_Y) enqueue(1,0);
    if(down&KEY_A) enqueue(2,0);
    u8 *top=gfxGetFramebuffer(GFX_TOP,GFX_LEFT,NULL,NULL);
    if(ready) {
        memcpy(top,image,sizeof(image));
        int vx=detail?400:800, vy=detail?240:480;
        int cx=(W-deskImageWidth)/2+limit((int)((pointerX*2-cropX+0.5f)*deskImageWidth/vx),0,deskImageWidth-1);
        int cy=(H-deskImageHeight)/2+limit((int)((pointerY*2-cropY+0.5f)*deskImageHeight/vy),0,deskImageHeight-1);
        drawCursor(top,cx,cy);
    } else memset(top,0,sizeof(image));
    if(!catalog || notice[0]) {
        const char *message=catalog?notice:connection;
        text(top,5,ready?228:112,message,0xade8dc);
    }
    drawBottom(gfxGetFramebuffer(GFX_BOTTOM,GFX_LEFT,NULL,NULL));
    int revision=generation;
    bool drew=ready;
    LightLock_Unlock(&mutex);
    gfxFlushBuffers(); gfxSwapBuffers(); gspWaitForVBlank();
    LightLock_Lock(&mutex);
    if(revision==generation && drew && ready) shown=true;
    LightLock_Unlock(&mutex);
}
