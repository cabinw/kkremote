// Experimental host-side workspace. Private CoreGraphics runtime interfaces;
// deliberately separate from the shipping iOS application and public transport.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <signal.h>

@interface NSObject (KKWorkspaceRuntime)
- (id)initWithDescriptor:(id)descriptor;
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate transferFunction:(unsigned int)function;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
@end

static id retainedDisplay;
static dispatch_source_t stopSource;
static BOOL supports(Class c, NSString *selector) {
    return c && class_getInstanceMethod(c,NSSelectorFromString(selector)) != NULL;
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=2 && !(argc==3 && strcmp(argv[2],"--hdr")==0)) return 2;
        BOOL wantsHDR=argc==3;
        NSString *output=[NSString stringWithUTF8String:argv[1]];
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        // Preserve the user's displays and place only our workspace at the
        // right edge. The automatic left-side placement can steal a left Dock.
        uint32_t count=0;CGDirectDisplayID ids[32];
        if(CGGetActiveDisplayList(32,ids,&count)!=kCGErrorSuccess || count==0 || count==32) return 9;
        NSMutableArray *originals=[NSMutableArray array];CGRect rightmost=CGRectZero;
        CGDirectDisplayID originalMain=CGMainDisplayID();
        for(uint32_t i=0;i<count;i++){
            if(CGDisplayIsInMirrorSet(ids[i])) return 9;
            CGRect bounds=CGDisplayBounds(ids[i]);CGDisplayModeRef m=CGDisplayCopyDisplayMode(ids[i]);
            if(!m) return 9;
            [originals addObject:@{@"id":@(ids[i]),@"bounds":[NSValue valueWithRect:NSRectFromCGRect(bounds)],
                @"pixelWidth":@(CGDisplayModeGetPixelWidth(m)),@"pixelHeight":@(CGDisplayModeGetPixelHeight(m)),@"hz":@(CGDisplayModeGetRefreshRate(m))}];
            if(i==0 || CGRectGetMaxX(bounds)>CGRectGetMaxX(rightmost)) rightmost=bounds;
            CGDisplayModeRelease(m);
        }
        int32_t workspaceX=(int32_t)CGRectGetMaxX(rightmost),workspaceY=(int32_t)CGRectGetMinY(rightmost);
        Class descriptorClass=NSClassFromString(@"CGVirtualDisplayDescriptor"),modeClass=NSClassFromString(@"CGVirtualDisplayMode"),settingsClass=NSClassFromString(@"CGVirtualDisplaySettings"),displayClass=NSClassFromString(@"CGVirtualDisplay");
        NSArray *setters=@[@"setName:",@"setQueue:",@"setMaxPixelsWide:",@"setMaxPixelsHigh:",@"setSizeInMillimeters:",@"setVendorID:",@"setProductID:",@"setSerialNum:",@"setWhitePoint:",@"setRedPrimary:",@"setGreenPrimary:",@"setBluePrimary:"];
        for(NSString *selector in setters) if(!supports(descriptorClass,selector)) return 3;
        if(!supports(modeClass,@"initWithWidth:height:refreshRate:") || !supports(settingsClass,@"setModes:") || !supports(settingsClass,@"setHiDPI:") || !supports(displayClass,@"initWithDescriptor:") || !supports(displayClass,@"applySettings:") || !supports(displayClass,@"displayID")) return 3;
        if(wantsHDR && !supports(modeClass,@"initWithWidth:height:refreshRate:transferFunction:")) return 3;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                id descriptor=[descriptorClass new];
                [descriptor setValue:wantsHDR ? @"KKRemote HDR Native Workspace":@"KKRemote Native Workspace" forKey:@"name"];
                [descriptor setValue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0) forKey:@"queue"];
                [descriptor setValue:@2560 forKey:@"maxPixelsWide"];[descriptor setValue:@2880 forKey:@"maxPixelsHigh"];
                [descriptor setValue:[NSValue valueWithSize:NSMakeSize(295.56,332.51)] forKey:@"sizeInMillimeters"];
                [descriptor setValue:@0x4b4b forKey:@"vendorID"];[descriptor setValue:@0x1001 forKey:@"productID"];[descriptor setValue:@41141001 forKey:@"serialNum"];
                for(NSArray *pair in @[@[@"whitePoint",[NSValue valueWithPoint:NSMakePoint(0.3127,0.329)]],@[@"redPrimary",[NSValue valueWithPoint:NSMakePoint(0.64,0.33)]],@[@"greenPrimary",[NSValue valueWithPoint:NSMakePoint(0.30,0.60)]],@[@"bluePrimary",[NSValue valueWithPoint:NSMakePoint(0.15,0.06)]]]) [descriptor setValue:pair[1] forKey:pair[0]];
                if(wantsHDR){
                    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.68,0.32)] forKey:@"redPrimary"];
                    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.265,0.69)] forKey:@"greenPrimary"];
                }
                id display=[[displayClass alloc] initWithDescriptor:descriptor];
                id settings=[settingsClass new];[settings setValue:@1 forKey:@"hiDPI"];
                // Runtime-observed unsigned-int parameter on this host. Mode 1
                // is experimental HDR; require observed EDR capability below.
                id mode=wantsHDR ? [[modeClass alloc] initWithWidth:1280 height:1440 refreshRate:60 transferFunction:1]
                                 : [[modeClass alloc] initWithWidth:1280 height:1440 refreshRate:60];
                if(!display || !mode) exit(4);
                [settings setValue:@[mode] forKey:@"modes"];
                if(![display applySettings:settings]) exit(5);
                retainedDisplay=display;
                CGDisplayConfigRef transaction=NULL;
                if(CGBeginDisplayConfiguration(&transaction)!=kCGErrorSuccess) exit(9);
                for(NSDictionary *before in originals){
                    CGRect bounds=NSRectToCGRect([before[@"bounds"] rectValue]);
                    if(CGConfigureDisplayOrigin(transaction,[before[@"id"] unsignedIntValue],(int32_t)bounds.origin.x,(int32_t)bounds.origin.y)!=kCGErrorSuccess){CGCancelDisplayConfiguration(transaction);exit(9);}
                }
                if(CGConfigureDisplayOrigin(transaction,[display displayID],workspaceX,workspaceY)!=kCGErrorSuccess){CGCancelDisplayConfiguration(transaction);exit(9);}
                if(CGCompleteDisplayConfiguration(transaction,kCGConfigureForAppOnly)!=kCGErrorSuccess) exit(9);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
                    BOOL unchanged=CGMainDisplayID()==originalMain;
                    for(NSDictionary *before in originals){
                        CGDirectDisplayID id=[before[@"id"] unsignedIntValue];CGDisplayModeRef m=CGDisplayCopyDisplayMode(id);
                        unchanged=unchanged && CGRectEqualToRect(CGDisplayBounds(id),NSRectToCGRect([before[@"bounds"] rectValue])) && m &&
                            CGDisplayModeGetPixelWidth(m)==[before[@"pixelWidth"] unsignedIntegerValue] && CGDisplayModeGetPixelHeight(m)==[before[@"pixelHeight"] unsignedIntegerValue] &&
                            fabs(CGDisplayModeGetRefreshRate(m)-[before[@"hz"] doubleValue])<0.01;
                        if(m) CGDisplayModeRelease(m);
                    }
                    CGRect workspaceBounds=CGDisplayBounds([display displayID]);
                    if(!unchanged || workspaceBounds.origin.x!=workspaceX || workspaceBounds.origin.y!=workspaceY){fprintf(stderr,"Display placement verification failed\n");exit(9);}
                    NSScreen *found=nil;
                    for(NSScreen *screen in NSScreen.screens) if([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]==[display displayID]) found=screen;
                    if(!found || (wantsHDR && found.maximumPotentialExtendedDynamicRangeColorComponentValue<=1)){fprintf(stderr,"Requested display capability unavailable\n");exit(8);}
                    CGDisplayModeRef actual=CGDisplayCopyDisplayMode([display displayID]);
                    NSDictionary *state=@{@"pid":@(getpid()),@"displayID":@([display displayID]),@"name":found.localizedName,
                        @"logicalSize":@[@(CGDisplayModeGetWidth(actual)),@(CGDisplayModeGetHeight(actual))],
                        @"pixelSize":@[@(CGDisplayModeGetPixelWidth(actual)),@(CGDisplayModeGetPixelHeight(actual))],
                        @"refreshRate":@(CGDisplayModeGetRefreshRate(actual)),@"backingScale":@(found.backingScaleFactor),
                        @"hdrRequested":@(wantsHDR),@"transferFunction":@(wantsHDR ? 1:0),
                        @"potentialEDR":@(found.maximumPotentialExtendedDynamicRangeColorComponentValue),@"currentEDR":@(found.maximumExtendedDynamicRangeColorComponentValue),
                        @"colorSpace":found.colorSpace.localizedName ?: @"unknown",@"experimentalPrivateAPI":@YES,
                        @"origin":@[@(workspaceBounds.origin.x),@(workspaceBounds.origin.y)],@"placement":@"right-of-existing-displays",@"existingDisplaysUnchanged":@YES};
                    CGDisplayModeRelease(actual);
                    NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:&error];
                    if(!data || ![data writeToFile:output options:NSDataWritingAtomic error:&error]) exit(6);
                    printf("NATIVE_WORKSPACE_READY %u hdr=%d\n",[display displayID],wantsHDR);fflush(stdout);
                });
            } @catch(NSException *error) {fprintf(stderr,"Workspace unavailable: %s\n",error.name.UTF8String);exit(7);}
        });
        signal(SIGTERM,SIG_IGN);stopSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(stopSource, ^{retainedDisplay=nil;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{exit(0);});});dispatch_resume(stopSource);
        [NSApp run];
    }
    return 0;
}
