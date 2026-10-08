#import "../common.h"
#import "../SCPPrefs.h"
#import "../SCPCarSplit.h"
#import "../SCPBoot.h"

// Inject vao process CarPlay (com.apple.CarPlayApp, code trong DashBoard.framework, prefix DB).
// Split hien GIAO DIEN CARPLAY cua app: DashBoard tu mo scene CarPlay cua app (giong cham icon),
// tweak dua view controller cua scene do vao 1 ngan va bao kich thuoc ngan cho scene (xem SCPCarSplit.mm).
%group CARPLAY

// ---- Kich thuoc scene: app trong ngan nhan kich thuoc ngan, khong phai ca man xe ----
%hook DBDashboard

- (CGRect)sceneFrameForAppInfo:(id)info proxyAppInfo:(id)proxy
{
    CGRect r = %orig;
    CGSize s;
    NSString *bid = SCPRealBundleForInfos(info, proxy);
    if ([[SCPCarSplit shared] paneSize:&s forBundle:bid]) {
        r.size = s;
    }
    return r;
}

- (UIEdgeInsets)safeAreaInsetsForAppInfo:(id)info proxyAppInfo:(id)proxy
{
    UIEdgeInsets e = %orig;
    CGSize s;
    // Ngan khong nam duoi dock/status bar -> khong can chua le
    if ([[SCPCarSplit shared] paneSize:&s forBundle:SCPRealBundleForInfos(info, proxy)]) return UIEdgeInsetsZero;
    return e;
}

// Nut Home cua CarPlay khi dang split -> tat split (scene ve background) roi de DashBoard ve man chinh
- (void)_handleHomeEvent:(id)event
{
    SCPCarSplit *sp = [SCPCarSplit shared];
    if (sp.active && sp.bridgeStarting) SCPLog("CarSplit: Home trong luc CarBridge khoi dong -> giu split");
    else if (sp.active) [sp closeGoingHome:NO];
    %orig;
}

- (void)invalidate
{
    SCPBootReset();
    [[SCPCarSplit shared] dashboardInvalidated];
    %orig;
}

%end

// ---- DashBoard trinh bay app: dang split thi dua app vao ngan thay vi hien toan man ----
%hook DBDashboardRootViewController

- (void)presentBaseViewController:(id)vc animated:(BOOL)animated launchSource:(unsigned long long)source completion:(id)completion
{
    SCPCarSplit *sp = [SCPCarSplit shared];
    if (sp.active) {
        if ([sp wantsViewController:vc]) {
            @try {
                [sp adoptViewController:vc];
            } @catch (NSException *e) {
                SCPLog("CarSplit: adopt loi %@\n%@", e, e.callStackSymbols);
            }
            if (completion) ((void (^)(void))completion)();
            return;
        }
        SCPLog("CarSplit: DashBoard mo %@ toan man -> tat split", vc);
        [sp closeGoingHome:NO];
    }
    %orig;
    [sp refreshAppTabSoon];   // app vua mo toan man -> tab icon o mep tren
    // App tung nam trong ngan: DashBoard co the trinh bay lai view dang bi an -> man den, cham khong vao.
    // Doi animation mo xong, van la app dang hien ma view con an thi hien lai.
    if ([vc isKindOfClass:[UIViewController class]]) {
        __weak UIViewController *weakVC = vc;
        __weak id weakRoot = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *v = weakVC;
            id root = weakRoot;
            if (v && root && objcInvoke(root, @"currentBaseViewController") == v) [[SCPCarSplit shared] repairPresentedViewController:v];
        });
    }
    // Chan doan CarBridge: cay view cua app (khong phai Apple) khi mo toan man, 1 lan moi app
    if ([vc isKindOfClass:objc_getClass("DBApplicationSceneViewController")]) {
        NSString *b = SCPRealBundleForInfos(objcInvoke(vc, @"applicationInfo"), objcInvoke(vc, @"proxyApplicationInfo"));
        static NSMutableSet *dumped; if (!dumped) dumped = [NSMutableSet set];
        if (b && ![b hasPrefix:@"com.apple."] && ![dumped containsObject:b]) {
            [dumped addObject:b];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ SCPCDumpVC(vc, @"toan man"); });
        }
    }
}

- (void)dismissBaseViewControllerAnimated:(BOOL)animated completion:(id)completion
{
    SCPCarSplit *sp = [SCPCarSplit shared];
    // Dang split thi currentBaseViewController = nil; workspace ve man chinh -> tat split
    if (sp.active && !sp.bridgeStarting && !objcInvoke(self, @"currentBaseViewController")) {
        SCPLog("CarSplit: DashBoard ve man chinh -> tat split");
        [sp closeGoingHome:NO];
    }
    [sp removeAppTab];
    %orig;
    [sp refreshAppTabSoon];
}

- (void)viewDidLayoutSubviews
{
    %orig;
    [[SCPCarSplit shared] rootDidLayout];
}

// Man xe vua hien (cam xe): video khoi dong + cap nhat danh sach app CarPlay cho Settings
- (void)viewDidAppear:(BOOL)animated
{
    %orig;
    SCPBootShowIfNeeded((UIViewController *)self);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[SCPCarSplit shared] publishCarPlayApps];
    });
}

%end

// ---- Giu scene cua app trong ngan luon foreground (DashBoard tuong app da bi thay) ----
%hook DBApplicationSceneViewController

- (void)backgroundSceneWithCompletion:(id)completion
{
    if ([[SCPCarSplit shared] protectsViewController:self]) {
        SCPLog("CarSplit: chan background scene cua app trong ngan");
        if (completion) ((void (^)(void))completion)();
        return;
    }
    %orig;
}

- (void)deactivateSceneWithReasonMask:(unsigned long long)mask
{
    if ([[SCPCarSplit shared] protectsViewController:self]) {
        SCPLog("CarSplit: chan deactivate scene (mask=%llu) cua app trong ngan", mask);
        return;
    }
    %orig;
}

- (void)sceneManager:(id)manager didDestroyScene:(id)scene
{
    id own = [[SCPCarSplit shared] sceneOfViewController:self];   // lay truoc %orig (co the bi xoa)
    %orig;
    [[SCPCarSplit shared] scene:scene destroyedForViewController:self ownScene:own];
}

%end

%end // CARPLAY

// ---- CarBridge (app iPhone tren CarPlay): chieu vao ngan thay vi toan man ----
%group CARBRIDGE
%hook CBBridgeManagerDashboard

// Khung CBWindow: dang chieu vao ngan -> khung ngan
- (CGRect)getAppFrame
{
    CGRect r = [[SCPCarSplit shared] bridgeFrame];
    if (r.size.width > 1 && r.size.height > 1) return r;
    return %orig;
}

// Truoc khi chieu CarBridge dua CarPlay ve man chinh -> dang split thi bo qua (se dong split)
- (void)prepareHomeScreenForBridge:(id)completion
{
    if ([SCPCarSplit shared].active) {
        SCPLog("CarBridge: dang split -> bo qua ve man chinh");
        if (completion) ((void (^)(void))completion)();
        return;
    }
    %orig;
}

// CarBridge dong app CarPlay dang mo (vd Vietmap o ngan kia) -> dang split thi giu lai
- (void)closeOfficialTopApp:(id)arg
{
    if ([SCPCarSplit shared].active) {
        SCPLog("CarBridge: dang split -> giu app CarPlay o ngan kia");
        if (arg && [arg isKindOfClass:NSClassFromString(@"NSBlock")]) ((void (^)(void))arg)();
        return;
    }
    %orig;
}

%end
%end // CARBRIDGE

%ctor
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.CarPlayApp"]) return;
    SCPLog("loaded into CarPlay");
    %init(CARPLAY);
    if (objc_getClass("CBBridgeManagerDashboard")) { %init(CARBRIDGE); SCPLog("CarBridge: da noi vao CarBridge"); }
    else SCPLog("CarBridge: khong co (bo qua)");

    // SpringBoard: CarBridge da dong CBWindow cua app dang nam trong ngan -> chieu lai
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        addObserverForName:SCP_NOTIF_CBLOST object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [[SCPCarSplit shared] bridgeWindowLost:note.userInfo[@"identifier"]];
    }];

    // SpringBoard / Settings / URL scheme -> mo split CarPlay
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        addObserverForName:SCP_NOTIF_NATIVE object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSDictionary *u = note.userInfo;
        NSString *action = u[@"action"];
        SCPLog("CarSplit: yeu cau %@", u);
        SCPCarSplit *sp = [SCPCarSplit shared];
        @try {
            if ([action isEqualToString:@"close"]) {
                [sp closeGoingHome:YES];
            } else if ([action isEqualToString:@"closeApp"]) {
                [sp closeApp:u[@"identifier"]];
            } else if ([action isEqualToString:@"open"]) {
                [sp openApp:u[@"identifier"] slot:u[@"slot"] ? [u[@"slot"] intValue] : -1];
            } else if ([action isEqualToString:@"pair"]) {
                [sp openPairLeft:u[@"left"] right:u[@"right"]];
            } else if ([action isEqualToString:@"fav"]) {
                NSDictionary *fav = [SCPPrefs favorite:[u[@"index"] integerValue]];
                if (fav) [sp openPairLeft:fav[@"left"] right:fav[@"right"]];
            } else if ([action isEqualToString:@"picker"]) {
                if (sp.active) [sp closeGoingHome:YES]; else [sp showPickerForSlot:-1];
            }
        } @catch (NSException *e) {
            SCPLog("CarSplit: yeu cau loi %@\n%@", e, e.callStackSymbols);
        }
    }];
}
