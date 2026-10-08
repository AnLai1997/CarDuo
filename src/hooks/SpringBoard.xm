#import "../common.h"
#import "../SCPSplitWindow.h"
#import "../SCPPrefs.h"
#import "../SCPCarSplit.h"
#import <notify.h>

#define SCP_DARWIN_OPEN     "com.anlai97.carduo.open"      // tu app URL scheme (Shortcuts / Siri)

// Dat CBWindow cua CarBridge (SpringBoard) = khung ngan split CarPlay. w = 0 -> an cua so (ngan dang an).
static void SCPApplyCarBridgeFrame(CGRect r, NSString *bid, int attempt)
{
    Class mc = objc_getClass("CBBridgeManager");
    id mgr = (mc && [mc respondsToSelector:@selector(sharedInstance)]) ? objcInvoke(mc, @"sharedInstance") : nil;
    id win = nil;
    @try { win = mgr ? objcInvoke(mgr, @"window") : nil; } @catch (NSException *e) {}
    if (!win) {
        if (attempt < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SCPApplyCarBridgeFrame(r, bid, attempt + 1);
            });
        } else {
            SCPLog("CarBridge: khong thay CBWindow de dat khung %@ (%@) -> bao CarPlay chieu lai", NSStringFromCGRect(r), bid);
            if (bid && r.size.width >= 2)
                [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
                    postNotificationName:SCP_NOTIF_CBLOST object:nil userInfo:@{@"identifier": bid}];
        }
        return;
    }
    UIWindow *root = nil;
    @try { root = objcInvoke(win, @"rootWindow"); } @catch (NSException *e) {}
    if (r.size.width < 2 || r.size.height < 2) {
        root.hidden = YES;
        SCPLog("CarBridge: ngan dang an -> an CBWindow");
        return;
    }
    @try {
        ((void (*)(id, SEL, CGRect))objc_msgSend)(win, NSSelectorFromString(@"setAppFrame:"), r);
        @try { [mgr setValue:[NSValue valueWithCGRect:r] forKey:@"appFrame"]; } @catch (NSException *e) {}
        objcInvoke(win, @"resizeWindows");
    } @catch (NSException *e) { SCPLog("CarBridge: dat khung loi %@", e); return; }
    root.hidden = NO;
    SCPLog("CarBridge: CBWindow %@ -> %@ (rootWindow %@)", bid, NSStringFromCGRect(r), root ? NSStringFromCGRect(root.frame) : @"nil");
}

// Inject vao SpringBoard: nhan yeu cau tu CarPlay process / Settings / app URL, giu app song khi khoa may
%group SPRINGBOARD

// Gui yeu cau sang process CarPlay: split hien giao dien CarPlay cua app (SCPCarSplit)
static void SCPPostNative(NSDictionary *info)
{
    SCPLog("-> split CarPlay: %@", info);
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:SCP_NOTIF_NATIVE object:nil userInfo:info];
}

// Mo cap app mac dinh (LeftApp/RightApp trong Settings) thanh split CarPlay tren xe.
static void SCPOpenConfiguredPair(void)
{
    NSString *left = [SCPPrefs leftApp], *right = [SCPPrefs rightApp];
    SCPLog("mo cap app mac dinh: left=%@ right=%@", left, right);
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:@"pair" forKey:@"action"];
    if (left) d[@"left"] = left;
    if (right) d[@"right"] = right;
    SCPPostNative(d);
}

// Yeu cau tu app URL scheme: carduo://open|fav|close
static void SCPHandlePendingRequest(void)
{
    NSDictionary *req = [SCPPrefs takePendingRequest];
    if (!req) return;
    NSString *action = req[@"action"];
    SCPLog("yeu cau tu URL: %@", req);
    if ([action isEqualToString:@"close"]) {
        [[SCPSplitWindow current] dismiss];
        if (SCPGetCarPlayCADisplay()) SCPPostNative(@{@"action": @"close"});
        return;
    }
    NSString *l = req[@"left"], *r = req[@"right"];
    if (l) [SCPPrefs setLeftApp:l];
    if (r) [SCPPrefs setRightApp:r];
    if (!SCPGetCarPlayCADisplay()) { SCPLog("chua ket noi xe -> bo qua yeu cau %@", action); return; }
    if ([action hasPrefix:@"fav"]) {
        SCPPostNative(@{@"action": @"fav", @"index": @([[action substringFromIndex:3] integerValue])});
    } else {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:@"pair" forKey:@"action"];
        if (l ?: [SCPPrefs leftApp]) d[@"left"] = l ?: [SCPPrefs leftApp];
        if (r ?: [SCPPrefs rightApp]) d[@"right"] = r ?: [SCPPrefs rightApp];
        SCPPostNative(d);
    }
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)app
{
    %orig;
    SCPLogTrim();
    SCPLog("SpringBoard ready, dang ky notification");

    // CarPlay process -> app KHONG co CarPlay (khi bat "Cho phep app iPhone"): chieu giao dien iPhone vao cua so rieng
    NSNotificationCenter *dnc = [objc_getClass("NSDistributedNotificationCenter") defaultCenter];
    [dnc addObserverForName:SCP_NOTIF_LAUNCH object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *note) {
        if (![SCPPrefs enabled]) return;
        NSString *bundleID = note.userInfo[@"identifier"];
        int slot = note.userInfo[@"slot"] ? [note.userInfo[@"slot"] intValue] : SCPSlotAuto;
        SCPLog("yeu cau mo %@ slot=%d", bundleID, slot);
        @try {
            SCPSplitWindow *w = [SCPSplitWindow currentOrCreate];
            if (!w) { SCPLog("khong tao duoc cua so (CarPlay chua ket noi?)"); return; }
            [w launchApp:bundleID inSlot:(SCPSlot)slot];
        } @catch (NSException *e) {
            SCPLog("launch that bai: %@\n%@", e, e.callStackSymbols);
        }
    }];

    // Process CarPlay: dat cua so CarBridge (CBWindow) dung khung ngan split. CBWindow chi co khi CarBridge
    // dang chieu -> thu lai vai lan neu chua co.
    [dnc addObserverForName:SCP_NOTIF_CBFRAME object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *note) {
        NSDictionary *u = note.userInfo;
        CGRect r = CGRectMake([u[@"x"] doubleValue], [u[@"y"] doubleValue], [u[@"w"] doubleValue], [u[@"h"] doubleValue]);
        SCPApplyCarBridgeFrame(r, u[@"identifier"], 0);
    }];

    // Dong log tu app nguoi dung (sandbox) -> ghi vao file chung
    [dnc addObserverForName:SCP_NOTIF_LOG object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *note) {
        NSString *line = note.userInfo[@"line"];
        if ([line isKindOfClass:[NSString class]]) SCPLogAppendRelayed(line);
    }];

    // Settings / app URL -> Darwin notification
    int tokOpen = 0, tokOrient = 0;
    // App dang host vua doi yeu cau xoay (YouTube fullscreen) -> lay lai scene settings cua ngan do
    notify_register_dispatch(SCP_DARWIN_APP_ORIENT, &tokOrient, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0; notify_get_state(t, &state);
        uint64_t hash = state >> 24; NSUInteger mask = (state >> 8) & 0xFFFF; int code = (int)(state & 0xFF);
        SCPLog("darwin apporient: hash=%llu ma=%d mask=%lu (co cua so: %d)", (unsigned long long)hash, code, (unsigned long)mask, [SCPSplitWindow current] != nil);
        [[SCPSplitWindow current] appOrientationChangedWithHash:hash orientation:code supportedMask:mask];
    });
    notify_register_dispatch(SCP_DARWIN_OPEN,  &tokOpen,  dispatch_get_main_queue(), ^(int t) { SCPHandlePendingRequest(); });

    // Xe ket noi / ngat ket noi
    [[NSNotificationCenter defaultCenter] addObserverForName:@"CarPlayIsConnectedDidChange" object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        BOOL connected = SCPGetCarPlayCADisplay() != nil;
        SCPLog("CarPlay connected=%d", connected);
        SCPSplitWindow *w = [SCPSplitWindow current];
        if (!connected) {
            [SCPLauncherButton hide];
            if (w) { SCPLog("CarPlay ngat -> dismiss"); [w dismiss]; }
            return;
        }
        if (![SCPPrefs enabled]) return;
        // Nut "chia man hinh" tren man xe, hien sau khi dashboard CarPlay len
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (SCPGetCarPlayCADisplay()) [SCPLauncherButton showOnCarDisplay];
        });
        if ([SCPPrefs autoLaunch] && !w) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (SCPGetCarPlayCADisplay() && ![SCPSplitWindow current]) SCPOpenConfiguredPair();
            });
        }
    }];
}

%end

// Khong cho app bi background khi khoa may
%hook SBSuspendedUnderLockManager
- (BOOL)_shouldBeBackgroundUnderLockForScene:(id)scene withSettings:(id)settings
{
    BOOL r = %orig;
    if (r) {
        NSString *bid = objcInvoke(objcInvoke(scene, @"clientProcess"), @"bundleIdentifier");   // iOS 16: FBScene.clientProcess
        NSArray *assertions = objc_getAssociatedObject([UIApplication sharedApplication], kSCPKey_lockAssertions);
        if (bid && [assertions containsObject:bid]) r = NO;
    }
    return r;
}
%end

// Khong cho scene cua app dang host bi dua ve background khi mo app khac tren man chinh
%hook FBScene
- (void)updateSettings:(id)settings withTransitionContext:(id)ctx completion:(void *)completion
{
    id process = objcInvoke(self, @"clientProcess");
    if (process) {
        NSString *bid = objcInvoke(process, @"bundleIdentifier");
        NSArray *assertions = objc_getAssociatedObject([UIApplication sharedApplication], kSCPKey_lockAssertions);
        if (bid && [assertions containsObject:bid] && !objcInvokeT(settings, @"isForeground", BOOL)) {
            return;
        }
    }
    %orig;
}
%end

// Scene view crash neu orientation la face-up/face-down -> ep ve landscape
%hook SBSceneView
- (void)_updateReferenceSize:(CGSize)size andOrientation:(long long)orientation
{
    if (orientation > 4) return %orig(size, 3);
    %orig;
}
%end

%end // SPRINGBOARD

// Man hinh iPhone tat khi dang host app tren XE -> tat roi bat lai "blank" de app van render.
static int hook_BKSDisplayServicesSetScreenBlanked(int blanked)
{
    SCPSplitWindow *w = [SCPSplitWindow current];
    if (blanked == 1 && w && w.panes.count > 0) {
        orig_BKSDisplayServicesSetScreenBlanked(1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            orig_BKSDisplayServicesSetScreenBlanked(0);
        });
        return 0;
    }
    return orig_BKSDisplayServicesSetScreenBlanked(blanked);
}

%ctor
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
    SCPLog("loaded into SpringBoard");
    %init(SPRINGBOARD);
    void *fn = dlsym(RTLD_DEFAULT, "BKSDisplayServicesSetScreenBlanked");
    if (fn) {
        MSHookFunction(fn, (void *)hook_BKSDisplayServicesSetScreenBlanked, (void **)&orig_BKSDisplayServicesSetScreenBlanked);
    } else {
        SCPLog("khong tim thay BKSDisplayServicesSetScreenBlanked");
    }
}
