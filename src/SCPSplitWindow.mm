#import "SCPSplitWindow.h"
#import "SCPPrefs.h"

// =====================================================================
//  SCPSplitWindow - cua so tren man CarPlay, host 2 app cua iPhone
//  Co che: port tu carplay-cast (EthanArbuckle) - iOS 14, chinh cho 16.5 + ARC
// =====================================================================

int (*orig_BKSDisplayServicesSetScreenBlanked)(int) = NULL;
const void *kSCPKey_splitWindow   = &kSCPKey_splitWindow;
const void *kSCPKey_lockAssertions = &kSCPKey_lockAssertions;

// Tim CADisplay cua man hinh xe
id SCPGetCarPlayCADisplay(void)
{
    id carplayDevice = objcInvoke(objc_getClass("AVExternalDevice"), @"currentCarPlayExternalDevice");
    if (!carplayDevice) return nil;
    NSArray *screenIDs = objcInvoke(carplayDevice, @"screenIDs");
    if (screenIDs.count == 0) return nil;
    NSString *carplayScreenID = screenIDs[0];
    for (id display in objcInvoke(objc_getClass("CADisplay"), @"displays")) {
        if ([carplayScreenID isEqualToString:objcInvoke(display, @"uniqueId")]) return display;
    }
    return nil;
}

static NSMutableArray *lockAssertions(void)
{
    NSMutableArray *a = objc_getAssociatedObject([UIApplication sharedApplication], kSCPKey_lockAssertions);
    if (!a) {
        a = [NSMutableArray array];
        objc_setAssociatedObject([UIApplication sharedApplication], kSCPKey_lockAssertions, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return a;
}

static CGRect boundsForOrientation(UIScreen *screen, int orientation)
{
    CGFloat w = screen.bounds.size.width, h = screen.bounds.size.height;
    CGRect r = CGRectZero;
    if (UIInterfaceOrientationIsLandscape((UIInterfaceOrientation)orientation))
        r.size = CGSizeMake(MAX(w, h), MIN(w, h));
    else
        r.size = CGSizeMake(MIN(w, h), MAX(w, h));
    return r;
}

@implementation SCPAppPane
@end

@interface SCPSplitWindow ()
@property (nonatomic, strong) UIButton *homeButton;
@property (nonatomic, strong) UIButton *swapButton;
- (instancetype)initOnMainScreen:(BOOL)mainScreen;
@end

@implementation SCPSplitWindow

+ (instancetype)current
{
    return objc_getAssociatedObject([UIApplication sharedApplication], kSCPKey_splitWindow);
}

+ (instancetype)currentOrCreate
{
    return [self currentOrCreateOnMainScreen:NO];
}

+ (instancetype)currentOrCreateOnMainScreen:(BOOL)mainScreen
{
    SCPSplitWindow *w = [self current];
    if (w) return w;
    w = [[SCPSplitWindow alloc] initOnMainScreen:mainScreen];
    if (w) objc_setAssociatedObject([UIApplication sharedApplication], kSCPKey_splitWindow, w, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return w;
}

- (instancetype)initOnMainScreen:(BOOL)mainScreen
{
    if (!(self = [super init])) return nil;
    self.onMainScreen = mainScreen;

    if (mainScreen) {
        // CHE DO TEST: cua so tren man iPhone, xoay ngang de giong man xe
        self.rootWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        self.rootWindow.windowLevel = UIWindowLevelStatusBar + 50;
        ((void (*)(id, SEL, long long, BOOL, double, BOOL))objc_msgSend)(self.rootWindow,
            NSSelectorFromString(@"_rotateWindowToOrientation:updateStatusBar:duration:skipCallbacks:"),
            (long long)UIInterfaceOrientationLandscapeRight, YES, 0.0, NO);
        SCPLog("TEST window tren man chinh, frame=%@ bounds=%@",
               NSStringFromCGRect(self.rootWindow.frame), NSStringFromCGRect(self.rootWindow.bounds));
    } else {
        id carDisplay = SCPGetCarPlayCADisplay();
        if (!carDisplay) { SCPLog("khong tim thay CADisplay cua CarPlay"); return nil; }

        id displayConfig = objcInvoke_2([objc_getClass("FBSDisplayConfiguration") alloc],
                                        @"initWithCADisplay:isMainDisplay:", carDisplay, 0);
        expectClass(displayConfig, "FBSDisplayConfiguration");

        // Cua so nam tren man hinh xe
        self.rootWindow = objcInvoke_1([objc_getClass("UIRootSceneWindow") alloc],
                                       @"initWithDisplayConfiguration:", displayConfig);
        expectClass(self.rootWindow, "UIRootSceneWindow");
        SCPLog("root window frame=%@ screen=%@", NSStringFromCGRect(self.rootWindow.frame), self.rootWindow.screen);
    }

    self.rootWindow.backgroundColor = [UIColor blackColor];
    [self setupDock];

    self.rootWindow.alpha = 0;
    self.rootWindow.hidden = NO;
    // "unblank" de video/animation van render khi may dang khoa
    if (orig_BKSDisplayServicesSetScreenBlanked) orig_BKSDisplayServicesSetScreenBlanked(0);
    [UIView animateWithDuration:0.5 animations:^{ self.rootWindow.alpha = 1; }];
    return self;
}

- (NSArray<SCPAppPane *> *)panes
{
    NSMutableArray *a = [NSMutableArray array];
    if (self.leftPane) [a addObject:self.leftPane];
    if (self.rightPane) [a addObject:self.rightPane];
    return a;
}

// ---------------------------------------------------------------------
//  Dock ben trai: nut Home (dong split) + nut doi cho 2 ngan
// ---------------------------------------------------------------------
- (void)setupDock
{
    CGRect f = self.rootWindow.bounds;
    CGFloat dockX = ([SCPPrefs dockSide] == 1) ? f.size.width - SCP_DOCK_WIDTH : 0;
    self.dockView = [[UIView alloc] initWithFrame:CGRectMake(dockX, 0, SCP_DOCK_WIDTH, f.size.height)];
    self.dockView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
    [self.rootWindow addSubview:self.dockView];

    id cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
    CGFloat sz = 32, x = (SCP_DOCK_WIDTH - sz) / 2;

    self.homeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.homeButton setImage:[UIImage systemImageNamed:@"xmark.circle" withConfiguration:cfg] forState:UIControlStateNormal];
    self.homeButton.tintColor = [UIColor whiteColor];
    self.homeButton.frame = CGRectMake(x, f.size.height - sz - 8, sz, sz);
    [self.homeButton addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [self.dockView addSubview:self.homeButton];

    self.swapButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.swapButton setImage:[UIImage systemImageNamed:@"arrow.left.arrow.right" withConfiguration:cfg] forState:UIControlStateNormal];
    self.swapButton.tintColor = [UIColor whiteColor];
    self.swapButton.frame = CGRectMake(x, 8, sz, sz);
    [self.swapButton addTarget:self action:@selector(swapPanes) forControlEvents:UIControlEventTouchUpInside];
    [self.dockView addSubview:self.swapButton];
}

- (CGRect)frameForSlot:(SCPSlot)slot
{
    CGRect f = self.rootWindow.bounds;
    CGFloat avail = f.size.width - SCP_DOCK_WIDTH;
    CGFloat leftW = floor(avail * [SCPPrefs splitRatio]);
    CGFloat rightW = avail - leftW;
    CGFloat x0 = ([SCPPrefs dockSide] == 1) ? 0 : SCP_DOCK_WIDTH;
    if (slot == SCPSlotLeft) return CGRectMake(x0, 0, leftW, f.size.height);
    return CGRectMake(x0 + leftW, 0, rightW, f.size.height);
}

// ---------------------------------------------------------------------
//  Mo app vao ngan
// ---------------------------------------------------------------------
- (void)launchApp:(NSString *)bundleID inSlot:(SCPSlot)slot
{
    if (slot == SCPSlotAuto) {
        if (!self.leftPane) slot = SCPSlotLeft;
        else if (!self.rightPane) slot = SCPSlotRight;
        else slot = SCPSlotRight; // ca 2 day -> thay ngan phai
    }
    // Neu app da dang o ngan kia thi thoi
    for (SCPAppPane *p in self.panes) {
        if ([p.bundleIdentifier isEqualToString:bundleID]) { SCPLog("%@ da dang mo", bundleID); return; }
    }
    [self closeSlot:slot];

    SCPAppPane *pane = [SCPAppPane new];
    pane.bundleIdentifier = bundleID;
    pane.orientation = (int)[SCPPrefs paneOrientation]; // 1 portrait / 3 landscape (Settings)

    pane.application = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"),
                                    @"applicationWithBundleIdentifier:", bundleID);
    expectClass(pane.application, "SBApplication");

    pane.containerView = [[UIView alloc] initWithFrame:[self frameForSlot:slot]];
    pane.containerView.backgroundColor = [UIColor blackColor];
    pane.containerView.clipsToBounds = YES;
    [self.rootWindow addSubview:pane.containerView];

    @try {
        [self setupLiveAppViewForPane:pane];
    } @catch (NSException *e) {
        SCPLog("setupLiveAppView that bai: %@", e);
        [pane.containerView removeFromSuperview];
        return;
    }

    if (slot == SCPSlotLeft) self.leftPane = pane; else self.rightPane = pane;
    [self layoutPane:pane];
    SCPLog("da mo %@ vao ngan %d", bundleID, slot);
}

// Port tu CRCarplayWindow -setupLiveAppView
- (void)setupLiveAppViewForPane:(SCPAppPane *)pane
{
    NSString *appID = pane.bundleIdentifier;
    [lockAssertions() addObject:appID];

    id sceneManager = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    expectClass(sceneManager, "SBMainDisplaySceneManager");

    id layoutStateManager = objcInvoke(sceneManager, @"layoutStateManager");   // iOS 16: khong co dau _
    id displayIdentity    = objcInvoke(sceneManager, @"displayIdentity");
    expectClass(displayIdentity, "FBSDisplayIdentity");

    // iOS 16.5: -sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:
    id sceneIdentity = objcInvoke_3(sceneManager, @"sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:",
                                    pane.application, 1, UIWindowSceneSessionRoleApplication);
    expectClass(sceneIdentity, "FBSSceneIdentity");

    id request = objcInvoke_3(objc_getClass("SBApplicationSceneHandleRequest"),
                              @"defaultRequestForApplication:sceneIdentity:displayIdentity:",
                              pane.application, sceneIdentity, displayIdentity);
    expectClass(request, "SBApplicationSceneHandleRequest");

    id sceneHandle = objcInvoke_1(sceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", request);
    expectClass(sceneHandle, "SBDeviceApplicationSceneHandle");

    id entity = objcInvoke_1([objc_getClass("SBDeviceApplicationSceneEntity") alloc], @"initWithApplicationSceneHandle:", sceneHandle);
    expectClass(entity, "SBDeviceApplicationSceneEntity");

    id appVC = objcInvoke_2([objc_getClass("SBAppViewController") alloc], @"initWithIdentifier:andApplicationSceneEntity:", appID, entity);
    expectClass(appVC, "SBAppViewController");
    pane.appViewController = appVC;

    objcInvoke_1(appVC, @"setIgnoresOcclusions:", 0);
    setIvar(appVC, @"_currentMode", @(2));
    objcInvoke(getIvar(appVC, @"_activationSettings"), @"clearActivationSettings");

    id transaction = objcInvoke_2(appVC, @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:", entity, 1);
    expectClass(transaction, "SBApplicationSceneUpdateTransaction");

    NSMutableSet *transitions = getIvar(appVC, @"_activeTransitions");   // iOS 16: NSMutableSet
    __weak SCPSplitWindow *weakSelf = self;
    int orientation = pane.orientation;
    objcInvoke_1(transaction, @"setCompletionBlock:", ^(int result) {
        [transitions removeObject:transaction];
        id launchTx = getIvar(transaction, @"_processLaunchTransaction");
        id process  = objcInvoke(launchTx, @"process");
        if (!process) { SCPLog("khong co FBProcess sau launch (result=%d)", result); return; }
        objcInvoke_1(process, @"_executeBlockAfterLaunchCompletes:", ^{
            // Bao app xoay theo huong cua ngan
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
                postNotificationName:SCP_NOTIF_ORIENTATION object:appID userInfo:@{@"orientation": @(orientation)}];
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf layoutPane:pane]; });
        });
    });
    [transitions addObject:transaction];
    objcInvoke(transaction, @"begin");
    objcInvoke(appVC, @"_createSceneViewController");

    id animFactory = objcInvoke(objc_getClass("SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
    id appView = objcInvoke(appVC, @"appView");
    objcInvoke_3(appView, @"setDisplayMode:animationFactory:completion:", 4, animFactory, (void *)0);

    UIView *v = [appVC view];
    v.backgroundColor = [UIColor clearColor];
    [pane.containerView addSubview:v];

    // Theo doi app chet -> dong ngan
    // iOS 16.5: -primarySceneIdentifierForBundleIdentifier:sceneSessionRole:displayIdentity:
    NSString *sceneID = objcInvoke_3(layoutStateManager, @"primarySceneIdentifierForBundleIdentifier:sceneSessionRole:displayIdentity:",
                                     appID, UIWindowSceneSessionRoleApplication, displayIdentity);
    if (sceneID) {
        pane.sceneMonitor = objcInvoke_1([objc_getClass("FBSceneMonitor") alloc], @"initWithSceneID:", sceneID);
        objcInvoke_1(pane.sceneMonitor, @"setDelegate:", self);
    }
}

// Port tu -resizeAppViewForOrientation: scale noi dung app (kich thuoc iPhone) vao ngan
- (void)layoutPane:(SCPAppPane *)pane
{
    if (!pane.appViewController) return;
    id deviceAppVC = getIvar(pane.appViewController, @"_deviceAppViewController");
    id sceneView   = getIvar(deviceAppVC, @"sceneView");   // property tren iOS 16
    UIView *hostingContentView = getIvar(sceneView, @"_sceneContentContainerView");
    if (!hostingContentView) { SCPLog("chua co _sceneContentContainerView"); return; }

    CGSize paneSize = pane.containerView.bounds.size;
    CGSize phoneSize = boundsForOrientation([UIScreen mainScreen], pane.orientation).size;
    CGFloat sx = paneSize.width / phoneSize.width;
    CGFloat sy = paneSize.height / phoneSize.height;

    hostingContentView.transform = CGAffineTransformMakeScale(sx, sy);
    [pane.appViewController view].frame = CGRectMake(0, 0, paneSize.width, paneSize.height);
    SCPLog("layout %@ pane=%@ phone=%@ scale=(%.2f,%.2f)", pane.bundleIdentifier,
           NSStringFromCGSize(paneSize), NSStringFromCGSize(phoneSize), sx, sy);
}

// FBSceneMonitor delegate: app process chet
- (void)sceneMonitor:(id)monitor sceneWasDestroyed:(id)scene
{
    for (SCPAppPane *p in self.panes) {
        if (p.sceneMonitor == monitor) {
            SCPLog("%@ da bi huy -> dong ngan", p.bundleIdentifier);
            [self closeSlot:(p == self.leftPane ? SCPSlotLeft : SCPSlotRight)];
        }
    }
}

// ---------------------------------------------------------------------
//  Dong ngan / doi cho / dong tat ca
// ---------------------------------------------------------------------
- (void)teardownPane:(SCPAppPane *)pane
{
    if (!pane) return;
    [pane.sceneMonitor invalidate];
    NSString *appID = pane.bundleIdentifier;

    // Bo ep huong xoay
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        postNotificationName:SCP_NOTIF_ORIENTATION object:appID userInfo:@{@"orientation": @(-1)}];

    objcInvoke_1(pane.appViewController, @"_setCurrentMode:", 0);
    [lockAssertions() removeObject:appID];

    // Dua app ve background neu no khong dang o man hinh chinh
    id appScene = objcInvoke(objcInvoke(pane.appViewController, @"sceneHandle"), @"sceneIfExists");
    if (appScene) {
        id frontmost = objcInvoke([UIApplication sharedApplication], @"_accessibilityFrontMostApplication");
        BOOL onMainScreen = frontmost && [objcInvoke(frontmost, @"bundleIdentifier") isEqualToString:appID];
        if (!onMainScreen) {
            // iOS 16: FBScene khong con -mutableSettings, dung -updateSettingsWithBlock:
            objcInvoke_1(appScene, @"updateSettingsWithBlock:", ^(id settings) {
                objcInvoke_1(settings, @"setBackgrounded:", 1);
                objcInvoke_1(settings, @"setForeground:", 0);
            });
        }
    }
    [pane.containerView removeFromSuperview];
}

- (void)closeSlot:(SCPSlot)slot
{
    SCPAppPane *pane = (slot == SCPSlotLeft) ? self.leftPane : self.rightPane;
    if (!pane) return;
    [self teardownPane:pane];
    if (slot == SCPSlotLeft) self.leftPane = nil; else self.rightPane = nil;
}

- (void)swapPanes
{
    SCPAppPane *l = self.leftPane, *r = self.rightPane;
    self.leftPane = r; self.rightPane = l;
    [UIView animateWithDuration:0.25 animations:^{
        if (self.leftPane)  self.leftPane.containerView.frame  = [self frameForSlot:SCPSlotLeft];
        if (self.rightPane) self.rightPane.containerView.frame = [self frameForSlot:SCPSlotRight];
    }];
}

- (void)dismiss
{
    SCPLog("dismiss split window");
    [self closeSlot:SCPSlotLeft];
    [self closeSlot:SCPSlotRight];

    id app = [UIApplication sharedApplication];
    // Tat man neu may dang khoa va man dang toi
    if (objcInvokeT(app, @"isLocked", BOOL)) {
        void *fn = dlsym(RTLD_DEFAULT, "BKSHIDServicesGetBacklightFactor");
        if (fn && orig_BKSDisplayServicesSetScreenBlanked) {
            float backlight = ((float (*)(void))fn)();
            if (backlight < 0.2) orig_BKSDisplayServicesSetScreenBlanked(1);
        }
    }

    objc_setAssociatedObject(app, kSCPKey_splitWindow, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIWindow *w = self.rootWindow;
    [UIView animateWithDuration:0.3 animations:^{ w.alpha = 0; } completion:^(BOOL done) {
        w.hidden = YES;
        [w removeFromSuperview];
    }];
    self.rootWindow = nil;

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        postNotificationName:SCP_NOTIF_SPLIT_CLOSED object:nil userInfo:nil];
}

@end
