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

// Gui toc do/gioi han sang SpringBoard (Darwin notify + state)
static void SCPSendSpeed(int speed, int limit)
{
    static int token = 0;
    if (!token) notify_register_check(SCP_DARWIN_SPEED, &token);
    uint64_t flags = (speed >= 0 ? 1 : 0) | (limit >= 0 ? 2 : 0);
    uint64_t state = (flags << 16) | ((uint64_t)(speed < 0 ? 0 : speed) << 8) | (uint64_t)(limit < 0 ? 0 : limit);
    notify_set_state(token, state); notify_post(SCP_DARWIN_SPEED);
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

// View tron bao quanh nhan (chinh no hoac view cha 2 cap)
static UIView *SCPCircleAround(UIView *v)
{
    for (UIView *x = v.superview; x && x != v.window; x = x.superview) {
        if (SCPIsCircle(x)) return x;
        if (x.superview && x.superview.superview == nil) break;
        if (x == v.superview.superview.superview) break;   // toi da 3 cap
    }
    return nil;
}

// Mau vien cua vong tron: layer.borderColor, hoac CAShapeLayer strokeColor, hoac view con tron co vien
static UIColor *SCPRingColor(UIView *v, int depth)
{
    if (!v || depth > 2) return nil;
    if (v.layer.borderWidth >= 1 && v.layer.borderColor) return [UIColor colorWithCGColor:v.layer.borderColor];
    for (CALayer *l in v.layer.sublayers) {
        if ([l isKindOfClass:[CAShapeLayer class]]) {
            CAShapeLayer *sh = (CAShapeLayer *)l;
            if (sh.lineWidth >= 1 && sh.strokeColor) return [UIColor colorWithCGColor:sh.strokeColor];
        }
    }
    for (UIView *c in v.subviews) {
        if ([c isKindOfClass:[UILabel class]]) continue;
        UIColor *col = SCPRingColor(c, depth + 1);
        if (col) return col;
    }
    return nil;
}

// 1 = do (gioi han), 2 = xanh duong (toc do), 0 = khong ro
static int SCPClassifyRing(UIColor *c)
{
    if (!c) return 0;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { CGFloat w = 0; if ([c getWhite:&w alpha:&a]) return 0; }
    if (r > 0.55 && g < 0.45 && b < 0.45) return 1;
    if (b > 0.5 && r < 0.45) return 2;
    return 0;
}

// Trong vong tron co nhan "km/h" (Vietmap: vong xanh "0 km/h")
static BOOL SCPHasUnitLabel(UIView *circle)
{
    for (UIView *c in circle.subviews) {
        if ([c isKindOfClass:[UILabel class]] && [[((UILabel *)c).text lowercaseString] containsString:@"km"]) return YES;
        for (UIView *cc in c.subviews) if ([cc isKindOfClass:[UILabel class]] && [[((UILabel *)cc).text lowercaseString] containsString:@"km"]) return YES;
    }
    return NO;
}

// ---------------------------------------------------------------------
//  App Flutter (Vietmap Live = process "Runner"): khong co UILabel, moi thu ve bang Skia.
//  Flutter chi xuat cay ngu nghia (semantics) cho iOS khi thay co cong cu tro nang dang chay
//  -> gia "Switch Control dang chay" trong RIENG tien trinh nay, roi doc cac phan tu accessibility
//  (label/value + khung tren man hinh) cua FlutterView.
// ---------------------------------------------------------------------
static BOOL (*orig_UIAccessibilityIsSwitchControlRunning)(void);
static BOOL hook_UIAccessibilityIsSwitchControlRunning(void) { return YES; }

static void SCPEnableFlutterSemantics(void)
{
    void *fn = dlsym(RTLD_DEFAULT, "UIAccessibilityIsSwitchControlRunning");
    if (!fn) { SCPLog("speed scan: khong tim thay UIAccessibilityIsSwitchControlRunning"); return; }
    MSHookFunction(fn, (void *)hook_UIAccessibilityIsSwitchControlRunning, (void **)&orig_UIAccessibilityIsSwitchControlRunning);
    // Flutter nghe thong bao nay de bat/tat semantics -> phat lai vai lan sau khi app len
    for (NSNumber *d in @[@2.0, @6.0, @12.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:UIAccessibilitySwitchControlStatusDidChangeNotification object:nil];
        });
    }
}

// Thu thap phan tu accessibility co chu: @{ @"t": text, @"f": NSValue(CGRect man hinh) }
static void SCPCollectAX(id node, NSMutableArray<NSDictionary *> *out, NSMutableSet *seen, int depth)
{
    if (!node || depth > 80 || out.count > 600) return;
    NSValue *key = [NSValue valueWithNonretainedObject:node];
    if ([seen containsObject:key]) return;
    [seen addObject:key];

    @try {
        NSString *label = [node respondsToSelector:@selector(accessibilityLabel)] ? [node accessibilityLabel] : nil;
        NSString *value = [node respondsToSelector:@selector(accessibilityValue)] ? [node accessibilityValue] : nil;
        NSMutableString *text = [NSMutableString string];
        if ([label isKindOfClass:[NSString class]] && label.length) [text appendString:label];
        if ([value isKindOfClass:[NSString class]] && value.length) { if (text.length) [text appendString:@" "]; [text appendString:value]; }
        if (text.length && ![node isKindOfClass:[UIView class]]) {   // UIView thuong la container; phan tu that la UIAccessibilityElement
            CGRect f = [node respondsToSelector:@selector(accessibilityFrame)] ? [node accessibilityFrame] : CGRectZero;
            [out addObject:@{@"t": [text copy], @"f": [NSValue valueWithCGRect:f]}];
        }
        NSArray *els = [node respondsToSelector:@selector(accessibilityElements)] ? [node accessibilityElements] : nil;
        if ([els isKindOfClass:[NSArray class]] && els.count) {
            for (id e in els) SCPCollectAX(e, out, seen, depth + 1);
        } else if ([node respondsToSelector:@selector(accessibilityElementCount)]) {
            NSInteger n = [node accessibilityElementCount];
            if (n != NSNotFound && n > 0 && n < 400) {
                for (NSInteger i = 0; i < n; i++) SCPCollectAX([node accessibilityElementAtIndex:i], out, seen, depth + 1);
            }
        }
    } @catch (NSException *e) {}
    if ([node isKindOfClass:[UIView class]]) for (UIView *c in ((UIView *)node).subviews) SCPCollectAX(c, out, seen, depth + 1);
}

// Cac so (toi da 3 chu so) xuat hien TRUOC chu "km/h" trong chuoi, theo thu tu
static NSArray<NSNumber *> *SCPNumbersBeforeKmh(NSString *t)
{
    NSString *l = [t lowercaseString];
    NSRange kr = [l rangeOfString:@"km"];
    NSString *head = (kr.location == NSNotFound) ? t : [t substringToIndex:kr.location];
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    NSScanner *sc = [NSScanner scannerWithString:head];
    while (!sc.isAtEnd) {
        [sc scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:nil];
        int v = 0;
        if ([sc scanInt:&v]) { if (v >= 0 && v <= 999) [out addObject:@(v)]; } else break;
    }
    return out;
}

static BOOL SCPMentionsKmh(NSString *t)
{
    NSString *l = [[t lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
    return [l containsString:@"km/h"] || [l containsString:@"kmh"] || [l containsString:@"km/g"];
}

// Tu cay accessibility (Flutter): toc do = phan tu "NN km/h" (hoac so gan nhan "km/h"); gioi han = so 5..200
// nam cung hang, ben trai toc do (bo cuc Vietmap: [vong do gioi han] [vong xanh toc do]).
static BOOL SCPScanSpeedAX(UIWindow *win, int *outSpeed, int *outLimit, NSString **outDesc)
{
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    SCPCollectAX(win, items, [NSMutableSet set], 0);
    if (!items.count) return NO;

    // Flutter gop ca cum thanh 1 phan tu, vd Vietmap: "60 | 0 | km/h" (3 dong) = [gioi han] [toc do] km/h.
    // -> toc do = so dung NGAY TRUOC "km/h"; so con lai (neu co) = gioi han.
    NSDictionary *speedItem = nil; int speed = -1, limitFromSame = -1;
    for (NSDictionary *it in items) {
        NSString *t = it[@"t"];
        if (!SCPMentionsKmh(t)) continue;
        NSArray<NSNumber *> *nums = SCPNumbersBeforeKmh(t);
        if (!nums.count) continue;
        speedItem = it; speed = nums.lastObject.intValue;
        if (nums.count >= 2) { int cand = nums[nums.count - 2].intValue; if (cand >= 5 && cand <= 200) limitFromSame = cand; }
        break;
    }
    if (!speedItem) {
        // "km/h" dung rieng -> so gan no nhat
        NSDictionary *unit = nil;
        for (NSDictionary *it in items) if (SCPMentionsKmh(it[@"t"])) { unit = it; break; }
        if (unit) {
            CGRect uf = [unit[@"f"] CGRectValue]; CGFloat best = 1e9;
            for (NSDictionary *it in items) {
                NSString *t = [it[@"t"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (!SCPIsNumeric(t)) continue;
                CGRect f = [it[@"f"] CGRectValue];
                CGFloat d = hypot(CGRectGetMidX(f) - CGRectGetMidX(uf), CGRectGetMidY(f) - CGRectGetMidY(uf));
                if (d < best) { best = d; speedItem = it; speed = t.intValue; }
            }
        }
    }
    int limit = limitFromSame;
    if (speedItem && limit < 0) {
        CGRect sf = [speedItem[@"f"] CGRectValue]; CGFloat best = 1e9;
        for (NSDictionary *it in items) {
            if (it == speedItem) continue;
            NSString *t = [it[@"t"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!SCPIsNumeric(t)) continue;
            int v = t.intValue; if (v < 5 || v > 200) continue;
            CGRect f = [it[@"f"] CGRectValue];
            CGFloat dy = fabs(CGRectGetMidY(f) - CGRectGetMidY(sf));
            if (dy > MAX(sf.size.height, f.size.height) * 1.2) continue;   // phai cung hang
            CGFloat dx = fabs(CGRectGetMidX(f) - CGRectGetMidX(sf));
            if (dx < best) { best = dx; limit = v; }
        }
    }
    if (outDesc) {
        NSMutableString *d = [NSMutableString stringWithFormat:@"AX %lu phan tu:", (unsigned long)items.count];
        int shown = 0;
        for (NSDictionary *it in items) {
            NSString *t = it[@"t"];
            if ([t rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location == NSNotFound) continue;
            CGRect f = [it[@"f"] CGRectValue];
            [d appendFormat:@" \"%@\"@(%.0f,%.0f %.0fx%.0f)", [t length] > 24 ? [[t substringToIndex:24] stringByAppendingString:@"…"] : t,
                 f.origin.x, f.origin.y, f.size.width, f.size.height];
            if (++shown >= 25) { [d appendString:@" …"]; break; }
        }
        *outDesc = d;
    }
    *outSpeed = speed; *outLimit = limit;
    return speed >= 0;
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

    static CFAbsoluteTime lastLog = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL doLog = (now - lastLog > 20);
    if (doLog) lastLog = now;

    // App Flutter (khong co UILabel): doc cay accessibility
    if (labels.count == 0) {
        int axSpeed = -1, axLimit = -1; NSString *axDesc = nil;
        BOOL ok = SCPScanSpeedAX(win, &axSpeed, &axLimit, doLog ? &axDesc : NULL);
        if (doLog) SCPLog("speed scan (AX): toc do=%d gioi han=%d; %@", axSpeed, axLimit, axDesc ?: @"(khong co phan tu)");
        if (ok) SCPSendSpeed(axSpeed, axLimit);
        return;
    }

    // Vietmap Live: 2 vong tron canh nhau - vien DO = gioi han, vien XANH (+ "km/h") = toc do hien tai
    UILabel *speedL = nil, *limitL = nil, *bigPlain = nil;
    NSMutableString *desc = [NSMutableString string];
    for (UILabel *l in labels) {
        UIView *circle = SCPCircleAround(l);
        int kind = 0;
        if (circle) {
            kind = SCPClassifyRing(SCPRingColor(circle, 0));
            if (kind == 0 && SCPHasUnitLabel(circle)) kind = 2;
        }
        [desc appendFormat:@" %@(f%.0f %@%@)", l.text, l.font.pointSize, NSStringFromClass([l.superview class]),
             circle ? (kind == 1 ? @" vong-do" : (kind == 2 ? @" vong-xanh" : @" vong")) : @""];
        if (kind == 1)      { if (!limitL || l.font.pointSize > limitL.font.pointSize) limitL = l; }
        else if (kind == 2) { if (!speedL || l.font.pointSize > speedL.font.pointSize) speedL = l; }
        else if (!circle)   { if (!bigPlain || l.font.pointSize > bigPlain.font.pointSize) bigPlain = l; }
    }
    if (!speedL) speedL = bigPlain;   // du phong: khong nhan ra vong xanh -> so to nhat ngoai vong tron
    int speed = speedL ? speedL.text.intValue : -1;
    int limit = limitL ? limitL.text.intValue : -1;
    if (speed > 300) speed = -1;
    if (limit > 200 || limit < 5) limit = -1;

    if (speed >= 0) SCPSendSpeed(speed, limit);
    if (doLog) SCPLog("speed scan: toc do=%d gioi han=%d; ung vien:%@", speed, limit, desc);
}

static void SCPStartSpeedScanner(void)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SCPLog("speed scan: bat dau");
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { SCPScanSpeed(); }];   // cap nhat lien tuc
    });
}

%ctor
{
    NSString *path = [[NSBundle mainBundle] bundlePath];
    NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
    if ([path containsString:@".app"] && bid && ![bid hasPrefix:@"com.apple."]) {
        %init(APPS);
        if ([bid isEqualToString:SCP_SPEED_APP]) { SCPEnableFlutterSemantics(); SCPStartSpeedScanner(); }
    }
}
