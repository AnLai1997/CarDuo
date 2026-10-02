#import "../common.h"

// Inject vao app nguoi dung: nhan yeu cau xoay tu SpringBoard
%group APPS

static int orientationOverride = -1;

%hook UIApplication
- (id)init
{
    id _self = %orig;
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        addObserver:_self selector:NSSelectorFromString(@"scp_handleRotationRequest:")
               name:SCP_NOTIF_ORIENTATION object:[[NSBundle mainBundle] bundleIdentifier]];
    return _self;
}

%new
- (void)scp_handleRotationRequest:(NSNotification *)note
{
    orientationOverride = [note.userInfo[@"orientation"] intValue];
    int o = orientationOverride;
    if (o == -1) o = MAX(1, (int)[[UIDevice currentDevice] orientation]);
    SCPLog("app xoay -> %d", o);
    UIWindow *key = objcInvoke([UIApplication sharedApplication], @"keyWindow");
    // iOS 16.5: -_setRotatableViewOrientation:(long long)duration:(double)force:(BOOL)
    ((void (*)(id, SEL, long long, double, BOOL))objc_msgSend)(key,
        NSSelectorFromString(@"_setRotatableViewOrientation:duration:force:"), (long long)o, 0.0, YES);
}
%end

// Chi ep ve huong cua ngan khi app CHO PHEP huong do. Neu app dang chi ho tro huong khac
// (vd YouTube fullscreen video chi cho ngang) thi de UIKit xoay theo y app -> video khong bi bop doc.
static BOOL SCPRootSupports(UIWindow *w, long long orientation)
{
    UIViewController *vc = w.rootViewController;
    if (!vc) return YES;
    UIInterfaceOrientationMask mask = vc.supportedInterfaceOrientations;
    return (mask & (1 << orientation)) != 0;
}

%hook UIWindow
- (void)_setRotatableViewOrientation:(long long)orientation duration:(double)duration force:(BOOL)force
{
    if (orientationOverride > 0 && orientation != orientationOverride && SCPRootSupports(self, orientationOverride)) {
        return %orig(orientationOverride, duration, force);
    }
    %orig;
}
%end

// App hoi "thiet bi dang xoay huong nao" (YouTube dung de tu vao/ra fullscreen) -> tra loi theo huong cua ngan,
// khong theo huong that cua iPhone dang gan tren xe.
%hook UIDevice
- (long long)orientation
{
    if (orientationOverride > 0) return orientationOverride;   // gia tri so trung nhau giua UIInterface/UIDeviceOrientation
    return %orig;
}
%end

%end // APPS

%ctor
{
    NSString *path = [[NSBundle mainBundle] bundlePath];
    NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
    if ([path containsString:@".app"] && bid && ![bid hasPrefix:@"com.apple."]) {
        %init(APPS);
    }
}
