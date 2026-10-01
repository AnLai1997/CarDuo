#import "../common.h"
#import "../SCPSplitWindow.h"

// Inject vao SpringBoard: nhan yeu cau tu CarPlay process, giu app song khi khoa may
%group SPRINGBOARD

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)app
{
    %orig;
    SCPLog("SpringBoard ready, dang ky notification");
    // NSDistributedNotificationCenter khong co trong SDK iOS -> dung qua NSNotificationCenter (lop cha)
    NSNotificationCenter *dnc = [objc_getClass("NSDistributedNotificationCenter") defaultCenter];
    [dnc addObserverForName:SCP_NOTIF_LAUNCH object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *note) {
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

    // Xe ngat ket noi -> dong cua so
    [[NSNotificationCenter defaultCenter] addObserverForName:@"CarPlayIsConnectedDidChange" object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        SCPSplitWindow *w = [SCPSplitWindow current];
        if (w && !SCPGetCarPlayCADisplay()) { SCPLog("CarPlay ngat -> dismiss"); [w dismiss]; }
    }];
}

%end

// Khong cho app bi background khi khoa may
%hook SBSuspendedUnderLockManager
- (BOOL)_shouldBeBackgroundUnderLockForScene:(id)scene withSettings:(id)settings
{
    BOOL r = %orig;
    if (r) {
        NSString *bid = objcInvoke(objcInvoke(objcInvoke(scene, @"client"), @"process"), @"bundleIdentifier");
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
    id client = objcInvoke(self, @"client");
    if ([client respondsToSelector:NSSelectorFromString(@"process")]) {
        NSString *bid = objcInvoke(objcInvoke(client, @"process"), @"bundleIdentifier");
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
