#import "../common.h"
#import "../SCPSplitWindow.h"
#import "../SCPPrefs.h"
#import "../SCPSpeedBubble.h"
#import "../SCPCarSplit.h"
#import <notify.h>

#define SCP_DARWIN_TEST     "com.anpham.splitcarplay.test"      // nut "Mo split thu" trong Settings
#define SCP_DARWIN_CLOSE    "com.anpham.splitcarplay.close"     // nut "Dong split"
#define SCP_DARWIN_CLEARLOG "com.anpham.splitcarplay.clearlog"
#define SCP_DARWIN_OPEN     "com.anpham.splitcarplay.open"      // tu app URL scheme (Shortcuts / Siri)

// Inject vao SpringBoard: nhan yeu cau tu CarPlay process / Settings / app URL, giu app song khi khoa may
%group SPRINGBOARD

// Gui yeu cau sang process CarPlay: split hien giao dien CarPlay cua app (SCPCarSplit)
static void SCPPostNative(NSDictionary *info)
{
    SCPLog("-> split CarPlay: %@", info);
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:SCP_NOTIF_NATIVE object:nil userInfo:info];
}

// Mo cap app mac dinh (LeftApp/RightApp trong Settings).
// Tren xe: split CarPlay (giao dien CarPlay cua app). Che do thu tren iPhone: cua so chieu giao dien iPhone.
static void SCPOpenConfiguredPair(BOOL onMainScreen)
{
    NSString *left = [SCPPrefs leftApp], *right = [SCPPrefs rightApp];
    SCPLog("mo cap app mac dinh (mainScreen=%d): left=%@ right=%@", onMainScreen, left, right);
    if (!onMainScreen) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:@"pair" forKey:@"action"];
        if (left) d[@"left"] = left;
        if (right) d[@"right"] = right;
        SCPPostNative(d);
        return;
    }
    @try {
        SCPSplitWindow *w = [SCPSplitWindow currentOrCreateOnMainScreen:onMainScreen];
        if (!w) { SCPLog("khong tao duoc cua so (CarPlay chua ket noi?)"); return; }
        if (!left && !right) { [w showAppPickerForSlot:SCPSlotLeft]; return; }
        [w launchPairLeft:left right:right];
    } @catch (NSException *e) {
        SCPLog("mo cap app that bai: %@\n%@", e, e.callStackSymbols);
    }
}

// Yeu cau tu app URL scheme: splitcarplay://open|fav|close
static void SCPHandlePendingRequest(void)
{
    NSDictionary *req = [SCPPrefs takePendingRequest];
    if (!req) return;
    NSString *action = req[@"action"];
    SCPLog("yeu cau tu URL: %@", req);
    BOOL car = SCPGetCarPlayCADisplay() != nil;
    if (car) {   // tren xe: split CarPlay
        if ([action isEqualToString:@"close"]) {
            [[SCPSplitWindow current] dismiss];
            SCPPostNative(@{@"action": @"close"});
        } else if ([action hasPrefix:@"fav"]) {
            SCPPostNative(@{@"action": @"fav", @"index": @([[action substringFromIndex:3] integerValue])});
        } else {
            NSString *l = req[@"left"], *r = req[@"right"];
            if (l) [SCPPrefs setLeftApp:l];
            if (r) [SCPPrefs setRightApp:r];
            NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:@"pair" forKey:@"action"];
            if (l ?: [SCPPrefs leftApp]) d[@"left"] = l ?: [SCPPrefs leftApp];
            if (r ?: [SCPPrefs rightApp]) d[@"right"] = r ?: [SCPPrefs rightApp];
            SCPPostNative(d);
        }
        return;
    }
    @try {
        if ([action isEqualToString:@"close"]) { [[SCPSplitWindow current] dismiss]; return; }
        SCPSplitWindow *w = [SCPSplitWindow currentOrCreateOnMainScreen:!car];   // khong co xe -> thu tren iPhone
        if (!w) return;
        if ([action hasPrefix:@"fav"]) {
            [w applyFavorite:[[action substringFromIndex:3] integerValue]];
        } else {
            NSString *l = req[@"left"], *r = req[@"right"];
            if (l) [SCPPrefs setLeftApp:l];
            if (r) [SCPPrefs setRightApp:r];
            [w launchPairLeft:l ?: [SCPPrefs leftApp] right:r ?: [SCPPrefs rightApp]];
        }
    } @catch (NSException *e) {
        SCPLog("URL request that bai: %@", e);
    }
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)app
{
    %orig;
    SCPLog("SpringBoard ready, dang ky notification");
    if ([SCPPrefs carSceneInProgress]) {
        // Lan truoc SpringBoard chet khi dang tao scene CarPlay tren iPhone -> tat tinh nang thu nghiem
        SCPLog("CarScene: SpringBoard da crash khi tao scene CarPlay tren iPhone -> tu tat 'Thu giao dien CarPlay'");
        [SCPPrefs setCarSceneInProgress:NO];
        [SCPPrefs setDemoCarPlayUI:NO];
    }

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

    // Process CarPlay bao app nao dang hien trong ngan split CarPlay -> bong bong toc do
    [dnc addObserverForName:SCP_NOTIF_NATIVE_STATE object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *note) {
        NSArray *bundles = note.userInfo[@"bundles"];
        [[SCPSpeedBubble shared] setNativeVisibleBundles:[bundles isKindOfClass:[NSArray class]] ? bundles : @[]];
    }];

    // Dong log tu app nguoi dung (sandbox) -> ghi vao file chung
    [dnc addObserverForName:SCP_NOTIF_LOG object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *note) {
        NSString *line = note.userInfo[@"line"];
        if ([line isKindOfClass:[NSString class]]) SCPLogAppendRelayed(line);
    }];

    // Settings / app URL -> Darwin notification
    int tok = 0, tokClose = 0, tokClear = 0, tokOpen = 0, tokOrient = 0, tokSpeed = 0;
    // Vietmap Live gui toc do + gioi han -> bong bong
    notify_register_dispatch(SCP_DARWIN_SPEED, &tokSpeed, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0; notify_get_state(t, &state);
        int flags = (int)((state >> 16) & 0xFF), speed = (int)((state >> 8) & 0xFF), limit = (int)(state & 0xFF);
        [[SCPSpeedBubble shared] updateSpeed:((flags & 1) ? speed : -1) limit:((flags & 2) ? limit : -1)];
    });
    // App dang host vua doi yeu cau xoay (YouTube fullscreen) -> lay lai scene settings cua ngan do
    notify_register_dispatch(SCP_DARWIN_APP_ORIENT, &tokOrient, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0; notify_get_state(t, &state);
        uint64_t hash = state >> 24; NSUInteger mask = (state >> 8) & 0xFFFF; int code = (int)(state & 0xFF);
        SCPLog("darwin apporient: hash=%llu ma=%d mask=%lu (co cua so: %d)", (unsigned long long)hash, code, (unsigned long)mask, [SCPSplitWindow current] != nil);
        [[SCPSplitWindow current] appOrientationChangedWithHash:hash orientation:code supportedMask:mask];
    });
    notify_register_dispatch(SCP_DARWIN_TEST,  &tok,      dispatch_get_main_queue(), ^(int t) { SCPOpenConfiguredPair(YES); });
    notify_register_dispatch(SCP_DARWIN_CLOSE, &tokClose, dispatch_get_main_queue(), ^(int t) {
        [[SCPSplitWindow current] dismiss];
        if (SCPGetCarPlayCADisplay()) SCPPostNative(@{@"action": @"close"});
        [[SCPSpeedBubble shared] refresh];
    });
    notify_register_dispatch(SCP_DARWIN_CLEARLOG, &tokClear, dispatch_get_main_queue(), ^(int t) { SCPLogClear(); SCPLog("log cleared"); });
    notify_register_dispatch(SCP_DARWIN_OPEN,  &tokOpen,  dispatch_get_main_queue(), ^(int t) { SCPHandlePendingRequest(); });
    if ([SCPPrefs testOnMainScreen]) {
        [SCPPrefs setTestOnMainScreen:NO];   // chi chay 1 lan, tranh ket sau moi respring
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SCPOpenConfiguredPair(YES);
        });
    }

    // Xe ket noi / ngat ket noi
    [[NSNotificationCenter defaultCenter] addObserverForName:@"CarPlayIsConnectedDidChange" object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        BOOL connected = SCPGetCarPlayCADisplay() != nil;
        SCPLog("CarPlay connected=%d", connected);
        SCPSplitWindow *w = [SCPSplitWindow current];
        if (!connected) {
            [SCPLauncherButton hide];
            if (w && !w.onMainScreen) { SCPLog("CarPlay ngat -> dismiss"); [w dismiss]; }
            return;
        }
        if (![SCPPrefs enabled]) return;
        // Nut "chia man hinh" tren man xe, hien sau khi dashboard CarPlay len
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (SCPGetCarPlayCADisplay()) [SCPLauncherButton showOnCarDisplay];
        });
        if ([SCPPrefs autoLaunch] && !w) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (SCPGetCarPlayCADisplay() && ![SCPSplitWindow current]) SCPOpenConfiguredPair(NO);
            });
        }
    }];
}

%end

// Che do thu tren iPhone: bam nut Home -> thoat cua so thu (loi thoat khi bi ket)
%hook SBUIController
- (BOOL)handleHomeButtonSinglePressUpForWindowScene:(id)scene withSourceType:(unsigned long long)type
{
    SCPSplitWindow *w = [SCPSplitWindow current];
    if (w && w.onMainScreen) { SCPLog("demo: Home -> thoat"); [w dismiss]; return YES; }
    return %orig;
}
- (BOOL)handleHomeButtonSinglePressUpForWindowScene:(id)scene
{
    SCPSplitWindow *w = [SCPSplitWindow current];
    if (w && w.onMainScreen) { SCPLog("demo: Home -> thoat"); [w dismiss]; return YES; }
    return %orig;
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
// Che do thu tren man iPhone (onMainScreen) thi KHONG can thiep: de iOS tat/bat man binh thuong,
// neu khong man se den va khong phan hoi.
static int hook_BKSDisplayServicesSetScreenBlanked(int blanked)
{
    SCPSplitWindow *w = [SCPSplitWindow current];
    if (blanked == 1 && w && !w.onMainScreen && w.panes.count > 0) {
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
