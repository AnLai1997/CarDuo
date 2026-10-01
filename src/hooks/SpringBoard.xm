#import "../common.h"
#import "../SCPSplitWindow.h"
#import "../SCPPrefs.h"
#import <notify.h>

#define SCP_DARWIN_TEST  "com.anpham.splitcarplay.test"    // nut "Mo split test ngay" trong Settings
#define SCP_DARWIN_CLOSE "com.anpham.splitcarplay.close"   // nut "Dong split"
#define SCP_DARWIN_CLEARLOG "com.anpham.splitcarplay.clearlog"

// Inject vao SpringBoard: nhan yeu cau tu CarPlay process / Settings, giu app song khi khoa may
%group SPRINGBOARD

// Mo cap app mac dinh (LeftApp/RightApp trong Settings) vao cua so split
static void SCPOpenConfiguredPair(BOOL onMainScreen)
{
    NSString *left = [SCPPrefs leftApp], *right = [SCPPrefs rightApp];
    SCPLog("mo cap app mac dinh (mainScreen=%d): left=%@ right=%@", onMainScreen, left, right);
    if (!left && !right) { SCPLog("chua chon app nao trong Settings"); return; }
    @try {
        SCPSplitWindow *w = [SCPSplitWindow currentOrCreateOnMainScreen:onMainScreen];
        if (!w) { SCPLog("khong tao duoc cua so (CarPlay chua ket noi?)"); return; }
        if (left)  [w launchApp:left  inSlot:SCPSlotLeft];
        if (right) [w launchApp:right inSlot:SCPSlotRight];
    } @catch (NSException *e) {
        SCPLog("mo cap app that bai: %@\n%@", e, e.callStackSymbols);
    }
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)app
{
    %orig;
    SCPLog("SpringBoard ready, dang ky notification");

    // CarPlay process -> mo 1 app vao 1 ngan (long-press icon tren dashboard)
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

    // Settings -> test tren man iPhone / dong
    int tok = 0, tokClose = 0, tokClear = 0;
    notify_register_dispatch(SCP_DARWIN_CLEARLOG, &tokClear, dispatch_get_main_queue(), ^(int t) { SCPLogClear(); SCPLog("log cleared"); });
    notify_register_dispatch(SCP_DARWIN_TEST, &tok, dispatch_get_main_queue(), ^(int t) {
        SCPOpenConfiguredPair(YES);
    });
    notify_register_dispatch(SCP_DARWIN_CLOSE, &tokClose, dispatch_get_main_queue(), ^(int t) {
        [[SCPSplitWindow current] dismiss];
    });
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
            if (w && !w.onMainScreen) { SCPLog("CarPlay ngat -> dismiss"); [w dismiss]; }
            return;
        }
        if ([SCPPrefs enabled] && [SCPPrefs autoLaunch] && !w) {
            // cho dashboard CarPlay len xong roi moi phu cua so split
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (SCPGetCarPlayCADisplay() && ![SCPSplitWindow current]) SCPOpenConfiguredPair(NO);
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

// Man hinh iPhone tat khi dang host app -> tat roi bat lai "blank" de app van render
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
