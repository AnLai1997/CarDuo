#import "../common.h"
#import "../SCPPrefs.h"
#import "../SCPCarSplit.h"

// Inject vao process CarPlay (com.apple.CarPlayApp, code trong DashBoard.framework, prefix DB).
// Split hien GIAO DIEN CARPLAY cua app: DashBoard tu mo scene CarPlay cua app (giong cham icon),
// tweak dua view controller cua scene do vao 1 ngan va bao kich thuoc ngan cho scene (xem SCPCarSplit.mm).
%group CARPLAY

// ---- Long-press icon tren man chinh CarPlay -> mo app do vao ngan (lan 1 trai, lan 2 phai) ----
%hook DBIconView

%new
- (void)scp_handleLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (![SCPPrefs enabled]) return;
    id icon = objcInvoke(self, @"icon");
    NSString *bid = objcInvoke(icon, @"applicationBundleID");
    SCPLog("long-press icon %@ -> split CarPlay", bid);
    [[SCPCarSplit shared] openApp:bid slot:-1];
}

- (id)initWithConfigurationOptions:(unsigned long long)opts listLayoutProvider:(id)provider
{
    id v = %orig;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:v action:NSSelectorFromString(@"scp_handleLongPress:")];
    lp.minimumPressDuration = 1.0;
    [v addGestureRecognizer:lp];
    return v;
}

%end

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
    if (sp.active) [sp closeGoingHome:NO];
    %orig;
}

- (void)invalidate
{
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
}

- (void)dismissBaseViewControllerAnimated:(BOOL)animated completion:(id)completion
{
    SCPCarSplit *sp = [SCPCarSplit shared];
    // Dang split thi currentBaseViewController = nil; workspace ve man chinh -> tat split
    if (sp.active && !objcInvoke(self, @"currentBaseViewController")) {
        SCPLog("CarSplit: DashBoard ve man chinh -> tat split");
        [sp closeGoingHome:NO];
    }
    %orig;
}

- (void)viewDidLayoutSubviews
{
    %orig;
    [[SCPCarSplit shared] rootDidLayout];
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
    %orig;
    [[SCPCarSplit shared] sceneDestroyedForViewController:self];
}

%end

%end // CARPLAY

%ctor
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.CarPlayApp"]) return;
    SCPLog("loaded into CarPlay");
    %init(CARPLAY);

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
