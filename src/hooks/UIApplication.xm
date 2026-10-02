#import "../common.h"
#import <notify.h>

// Inject vao app nguoi dung: nhan yeu cau xoay tu SpringBoard
%group APPS

static int orientationOverride = -1;
// Huong app TU XIN (vd YouTube bam fullscreen video -> xin ngang). 0 = khong xin gi, dung huong cua ngan.
// Khi app xin huong khac, uu tien huong app xin; khi app xin lai doc / cho phep moi huong -> ve huong cua ngan.
static long long appWantsOrientation = 0;

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
    appWantsOrientation = 0;
    int o = orientationOverride;
    if (o == -1) o = MAX(1, (int)[[UIDevice currentDevice] orientation]);
    SCPLog("app xoay -> %d", o);
    UIWindow *key = objcInvoke([UIApplication sharedApplication], @"keyWindow");
    // iOS 16.5: -_setRotatableViewOrientation:(long long)duration:(double)force:(BOOL)
    ((void (*)(id, SEL, long long, double, BOOL))objc_msgSend)(key,
        NSSelectorFromString(@"_setRotatableViewOrientation:duration:force:"), (long long)o, 0.0, YES);
}
%end

static long long SCPEffectiveOrientation(void)
{
    return appWantsOrientation > 0 ? appWantsOrientation : orientationOverride;
}

// Bao cho SpringBoard: app nay vua doi yeu cau xoay (o = huong muon, 0 = ve huong ngan, 0xFF = chi "lay" lai).
// SpringBoard se gui lai scene settings -> UIKit trong app tinh lai huong dung theo app (giong luc keo num chia).
// Dung Darwin notify + state vi distributed notification co the bi sandbox cua app chan.
static void SCPTellSpringBoard(long long o)
{
    static int token = 0;
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (o == 0xFF && now - last < 0.7) return;   // chan vong lap: app doi khung -> goi lai -> lay lai...
    last = now;
    if (!token) notify_register_check(SCP_DARWIN_APP_ORIENT, &token);
    uint64_t state = (SCPBundleHash([[NSBundle mainBundle] bundleIdentifier]) << 8) | ((uint64_t)o & 0xFF);
    notify_set_state(token, state);
    notify_post(SCP_DARWIN_APP_ORIENT);
    SCPLog("bao SpringBoard: huong %lld", o);
}

// Tu mask huong app xin -> 1 huong cu the. Co dọc thi coi nhu "tra ve binh thuong" (0).
static long long SCPOrientationFromMask(NSUInteger mask)
{
    if (mask & UIInterfaceOrientationMaskPortrait) return 0;
    if (mask & UIInterfaceOrientationMaskLandscapeLeft)  return UIInterfaceOrientationLandscapeLeft;
    if (mask & UIInterfaceOrientationMaskLandscapeRight) return UIInterfaceOrientationLandscapeRight;
    if (mask & UIInterfaceOrientationMaskPortraitUpsideDown) return UIInterfaceOrientationPortraitUpsideDown;
    return 0;
}

%hook UIWindow
- (void)_setRotatableViewOrientation:(long long)orientation duration:(double)duration force:(BOOL)force
{
    long long target = SCPEffectiveOrientation();
    SCPLog("rotate: UIKit xin %lld, override=%d appWants=%lld -> ap %lld (force=%d, root=%@)", orientation, orientationOverride,
           appWantsOrientation, (target > 0 ? target : orientation), (int)force, NSStringFromClass([self.rootViewController class]));
    if (target > 0 && orientation != target) return %orig(target, duration, force);
    %orig;
}
%end

// iOS 16: app xin xoay bang requestGeometryUpdateWithPreferences: (YouTube fullscreen dung cai nay)
%hook UIWindowScene
- (void)requestGeometryUpdateWithPreferences:(id)prefs errorHandler:(id)handler
{
    if (orientationOverride > 0 && [prefs respondsToSelector:@selector(interfaceOrientations)]) {
        NSUInteger mask = ((NSUInteger (*)(id, SEL))objc_msgSend)(prefs, @selector(interfaceOrientations));
        appWantsOrientation = SCPOrientationFromMask(mask);
        SCPLog("app xin huong mask=%lu -> %lld", (unsigned long)mask, appWantsOrientation);
        SCPTellSpringBoard(appWantsOrientation);
    }
    %orig;
}
%end

// App doi danh sach huong ho tro (iOS 16) -> cung can lay lai scene
%hook UIViewController
- (void)setNeedsUpdateOfSupportedInterfaceOrientations
{
    %orig;
    if (orientationOverride > 0) {
        SCPLog("%@ doi huong ho tro -> mask=%lu", NSStringFromClass([self class]), (unsigned long)self.supportedInterfaceOrientations);
        SCPTellSpringBoard(0xFF);
    }
}
%end

// App cu: ep xoay bang [UIDevice setOrientation:] (KVC "orientation")
%hook UIDevice
- (void)setOrientation:(long long)orientation animated:(BOOL)animated
{
    if (orientationOverride > 0) {
        appWantsOrientation = (orientation == UIInterfaceOrientationLandscapeLeft || orientation == UIInterfaceOrientationLandscapeRight) ? orientation : 0;
        SCPLog("app setOrientation %lld -> %lld", orientation, appWantsOrientation);
        SCPTellSpringBoard(appWantsOrientation);
    }
    %orig;
}

// App hoi "thiet bi dang xoay huong nao" -> tra loi theo huong dang ap (ngan hoac app xin),
// khong theo huong that cua iPhone dang gan tren xe.
- (long long)orientation
{
    long long o = SCPEffectiveOrientation();
    if (o > 0) return o;   // gia tri so trung nhau giua UIInterface/UIDeviceOrientation
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
