#import "../common.h"
#import <notify.h>

// Inject vao app nguoi dung: nhan yeu cau xoay tu SpringBoard
%group APPS

static int orientationOverride = -1;
// Huong app TU XIN (vd YouTube bam fullscreen video -> xin ngang). 0 = khong xin gi, dung huong cua ngan.
// Khi app xin huong khac, uu tien huong app xin; khi app xin lai doc / cho phep moi huong -> ve huong cua ngan.
static long long appWantsOrientation = 0;
// Huong "thiet bi" gia, theo hinh dang ngan (SpringBoard gui): 3 = ngan rong -> app coi nhu may nam ngang
// (YouTube bam fullscreen se xoay ngang that), 1 = ngan cao. 0 = chua biet, dung huong that.
static int fakeDeviceOrientation = 0;
static NSUInteger SCPAppEffectiveMask(void);
// Phat su kien "thiet bi vua xoay" (gia) sau `delay` giay
static void SCPPostFakeDeviceRotation(double delay)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (fakeDeviceOrientation <= 0) return;
        NSUInteger m = SCPAppEffectiveMask();
        if (!(m & UIInterfaceOrientationMaskPortrait)) { SCPLog("bo qua su kien xoay gia: app dang chi cho mask %lu", (unsigned long)m); return; }
        SCPLog("phat su kien xoay gia (%d)", fakeDeviceOrientation);
        [[NSNotificationCenter defaultCenter] postNotificationName:UIDeviceOrientationDidChangeNotification object:[UIDevice currentDevice]];
    });
}

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
    int newOverride = [note.userInfo[@"orientation"] intValue];
    BOOL changed = (newOverride != orientationOverride);
    orientationOverride = newOverride;
    appWantsOrientation = 0;
    fakeDeviceOrientation = (orientationOverride > 0) ? [note.userInfo[@"device"] intValue] : 0;
    SCPLog("thiet bi gia -> %d (huong ngan %d, doi=%d)", fakeDeviceOrientation, orientationOverride, (int)changed);
    if (!changed) return;   // khong co gi doi -> khong ep xoay, khong phat su kien xoay (tranh YouTube tu vao/ra fullscreen)
    // YouTube chi xin xoay ngang khi bam fullscreen neu truoc do no DA nhan 1 su kien xoay thiet bi (log 13:22 vs 13:51).
    // Phat vai lan sau khi app len (observer cua app co the chua dang ky luc nhan thong bao nay).
    if (fakeDeviceOrientation > 0) for (NSNumber *d in @[@0.3, @1.5, @4.0]) SCPPostFakeDeviceRotation(d.doubleValue);

    int o = orientationOverride;
    if (o == -1) o = MAX(1, (int)[[UIDevice currentDevice] orientation]);
    // Khong ep sang huong ma app dang khong cho phep (vd dang fullscreen video chi ngang)
    NSUInteger mask = SCPAppEffectiveMask();
    if (o > 0 && !(mask & (1u << o))) { SCPLog("bo qua ep xoay %d: app chi cho mask %lu", o, (unsigned long)mask); return; }
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

// Mask huong ma app DANG cho phep: lay tu view controller tren cung cua chuoi present
// (YouTube fullscreen present mot VC chi cho ngang; root VC van tra loi "moi huong").
static NSUInteger SCPEffectiveMask(UIWindow *w)
{
    UIViewController *vc = w.rootViewController;
    if (!vc) return UIInterfaceOrientationMaskAll;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    NSUInteger mask = vc.supportedInterfaceOrientations;
    return mask ? mask : UIInterfaceOrientationMaskAll;
}

// Bao cho SpringBoard: app nay vua doi yeu cau xoay (o = huong muon, 0 = ve huong ngan, 0xFF = chi "lay" lai).
// SpringBoard se gui lai scene settings -> UIKit trong app tinh lai huong dung theo app (giong luc keo num chia).
// Dung Darwin notify + state vi distributed notification co the bi sandbox cua app chan.
// Duyet cay VC (con + presented) dang hien trong cua so: neu co VC nao chi cho NGANG (khong co doc) -> tra mask do.
// YouTube fullscreen: VC gốc van tra "doc", nhung YTWatchFullscreenViewController (la VC con) tra "ngang".
static NSUInteger SCPLandscapeOnlyMaskInTree(UIViewController *vc, int depth)
{
    if (!vc || depth > 12) return 0;
    if (vc.isViewLoaded && vc.view.window && !vc.view.hidden) {
        NSUInteger m = vc.supportedInterfaceOrientations;
        if (m && !(m & UIInterfaceOrientationMaskPortrait) && (m & UIInterfaceOrientationMaskLandscape)) return m;
    }
    if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        NSUInteger m = SCPLandscapeOnlyMaskInTree(vc.presentedViewController, depth + 1);
        if (m) return m;
    }
    for (UIViewController *c in vc.childViewControllers) {
        NSUInteger m = SCPLandscapeOnlyMaskInTree(c, depth + 1);
        if (m) return m;
    }
    return 0;
}

// Mask hieu luc cua ca app: cua so key (hoac cua so dau tien co root VC). Uu tien VC chi-cho-ngang dang hien.
static NSUInteger SCPAppEffectiveMask(void)
{
    UIWindow *best = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (!w.rootViewController || w.hidden) continue;
            if (w.isKeyWindow) { best = w; break; }
            if (!best) best = w;
        }
        if (best && best.isKeyWindow) break;
    }
    if (!best) return UIInterfaceOrientationMaskAll;
    NSUInteger landscapeOnly = SCPLandscapeOnlyMaskInTree(best.rootViewController, 0);
    if (landscapeOnly) return landscapeOnly;
    return SCPEffectiveMask(best);
}

static void SCPTellSpringBoardNow(long long o);
static void SCPTellSpringBoard(long long o)
{
    static dispatch_block_t pending = nil;
    // Gom cac lan goi lien tiep (app doi mask nhieu buoc): cho 0.15s roi gui mask CUOI CUNG
    if (pending) { dispatch_block_cancel(pending); pending = nil; }
    pending = dispatch_block_create((dispatch_block_flags_t)0, ^{
        pending = nil;
        SCPTellSpringBoardNow(o);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), pending);
}

static void SCPTellSpringBoardNow(long long o)
{
    static int token = 0;
    if (!token) notify_register_check(SCP_DARWIN_APP_ORIENT, &token);
    NSUInteger mask = SCPAppEffectiveMask();
    uint64_t state = (SCPBundleHash([[NSBundle mainBundle] bundleIdentifier]) << 24) | (((uint64_t)mask & 0xFFFF) << 8) | ((uint64_t)o & 0xFF);
    notify_set_state(token, state);
    notify_post(SCP_DARWIN_APP_ORIENT);
    SCPLog("bao SpringBoard: ma %lld, mask %lu", o, (unsigned long)mask);
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
    NSUInteger mask = SCPEffectiveMask(self);
    // Chi ep ve huong cua ngan khi app con cho phep huong do. App dang chi cho ngang (fullscreen video)
    // -> de UIKit xoay theo y app.
    BOOL canForce = target > 0 && (mask & (1u << target)) != 0;
    SCPLog("rotate: UIKit xin %lld, override=%d appWants=%lld mask=%lu -> ap %lld (force=%d)", orientation, orientationOverride,
           appWantsOrientation, (unsigned long)mask, (canForce ? target : orientation), (int)force);
    if (canForce && orientation != target) return %orig(target, duration, force);
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
// App bat dau lang nghe xoay -> phat ngay 1 su kien gia de app biet "huong hien tai"
- (void)beginGeneratingDeviceOrientationNotifications
{
    %orig;
    if (fakeDeviceOrientation > 0) SCPPostFakeDeviceRotation(0.2);
}
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
    if (appWantsOrientation > 0) return appWantsOrientation;   // gia tri so trung nhau giua UIInterface/UIDeviceOrientation
    if (fakeDeviceOrientation > 0) return fakeDeviceOrientation;
    return %orig;
}
%end

%end // APPS

// =====================================================================
//  Quet toc do trong Vietmap Live: tim cac nhan so dang hien tren man hinh.
//  - Toc do hien tai: nhan so co co chu LON NHAT (khong nam trong khung tron)
//  - Gioi han: nhan so nam trong view tron (cornerRadius ~ nua canh) -> bien bao
//  Gui sang SpringBoard moi 1s (Darwin notify + state). Ghi log ung vien moi 20s de chinh heuristic.
// =====================================================================
static BOOL SCPIsNumeric(NSString *t)
{
    if (t.length == 0 || t.length > 3) return NO;
    for (NSUInteger i = 0; i < t.length; i++) { unichar c = [t characterAtIndex:i]; if (c < '0' || c > '9') return NO; }
    return YES;
}

static BOOL SCPViewVisible(UIView *v)
{
    if (!v.window) return NO;
    for (UIView *x = v; x; x = x.superview) { if (x.hidden || x.alpha < 0.05) return NO; }
    CGRect r = [v convertRect:v.bounds toView:nil];
    return r.size.width > 4 && r.size.height > 4 && CGRectIntersectsRect(r, v.window.bounds);
}

// View tron: vuong (gan bang), cornerRadius >= nua canh - 2, canh 24..140
static BOOL SCPIsCircle(UIView *v)
{
    if (!v) return NO;
    CGSize s = v.bounds.size;
    if (s.width < 24 || s.width > 140 || fabs(s.width - s.height) > 3) return NO;
    return v.layer.cornerRadius >= MIN(s.width, s.height) / 2 - 2;
}

static void SCPCollectLabels(UIView *v, NSMutableArray<UILabel *> *out, int depth)
{
    if (depth > 40) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (SCPIsNumeric(l.text) && SCPViewVisible(l)) [out addObject:l];
    }
    for (UIView *c in v.subviews) SCPCollectLabels(c, out, depth + 1);
}

static void SCPScanSpeed(void)
{
    UIWindow *win = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) { if (w.isKeyWindow) { win = w; break; } if (!win && w.rootViewController) win = w; }
    }
    if (!win) return;
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    SCPCollectLabels(win, labels, 0);

    UILabel *speedL = nil, *limitL = nil;
    for (UILabel *l in labels) {
        BOOL circle = SCPIsCircle(l.superview) || SCPIsCircle(l.superview.superview);
        if (circle) { if (!limitL || l.font.pointSize > limitL.font.pointSize) limitL = l; }
        else        { if (!speedL || l.font.pointSize > speedL.font.pointSize) speedL = l; }
    }
    int speed = speedL ? speedL.text.intValue : -1;
    int limit = limitL ? limitL.text.intValue : -1;
    if (speed > 300) speed = -1;
    if (limit > 200 || limit < 5) limit = -1;

    static int token = 0;
    if (!token) notify_register_check(SCP_DARWIN_SPEED, &token);
    uint64_t flags = (speed >= 0 ? 1 : 0) | (limit >= 0 ? 2 : 0);
    uint64_t state = (flags << 16) | ((uint64_t)(speed < 0 ? 0 : speed) << 8) | (uint64_t)(limit < 0 ? 0 : limit);
    if (speed >= 0) { notify_set_state(token, state); notify_post(SCP_DARWIN_SPEED); }

    static CFAbsoluteTime lastLog = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastLog > 20) {
        lastLog = now;
        NSMutableString *desc = [NSMutableString string];
        for (UILabel *l in labels) {
            UIView *sup = l.superview;
            [desc appendFormat:@" %@(f%.0f %@%@)", l.text, l.font.pointSize, NSStringFromClass([sup class]),
                 (SCPIsCircle(sup) || SCPIsCircle(sup.superview)) ? @" tron" : @""];
        }
        SCPLog("speed scan: toc do=%d gioi han=%d; ung vien:%@", speed, limit, desc);
    }
}

static void SCPStartSpeedScanner(void)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SCPLog("speed scan: bat dau");
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { SCPScanSpeed(); }];
    });
}

%ctor
{
    NSString *path = [[NSBundle mainBundle] bundlePath];
    NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
    if ([path containsString:@".app"] && bid && ![bid hasPrefix:@"com.apple."]) {
        %init(APPS);
        if ([bid isEqualToString:SCP_SPEED_APP]) SCPStartSpeedScanner();
    }
}
