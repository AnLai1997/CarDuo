#import "SCPSplitWindow.h"
#import "SCPPrefs.h"

// =====================================================================
//  SCPSplitWindow - cua so tren man CarPlay, host 2 app cua iPhone
//  Co che: port tu carplay-cast (EthanArbuckle) - iOS 14, chinh cho 16.x + ARC
// =====================================================================

int (*orig_BKSDisplayServicesSetScreenBlanked)(int) = NULL;
const void *kSCPKey_splitWindow   = &kSCPKey_splitWindow;
const void *kSCPKey_lockAssertions = &kSCPKey_lockAssertions;

#define SCP_DIVIDER_WIDTH 4.0      // khe toi mong giua 2 ngan; num keo nam de len khe
#define SCP_DIVIDER_HIT   28.0     // vung cham moi ben cua duong ranh giua 2 ngan (tong 56pt, de dat ngon tay)
#define SCP_KNOB_W        18.0     // num keo: vien thuoc trang 18 x 56 co 3 cham den (⋮) nam giua duong ranh; cham de mo menu, keo de doi ti le
#define SCP_KNOB_H        56.0
#define SCP_KNOB_DOT      4.0
#define SCP_PIP_SCALE     0.36

// Khe phan cach mong nhung van de keo: nhan cham trong pham vi rong hon kich thuoc that
// Tab "..." nho nhung vung cham no rong 16pt moi phia (de bam tren xe)
@interface SCPTabView : UIView
@end
@implementation SCPTabView
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { return CGRectContainsPoint(CGRectInset(self.bounds, -18, -18), p); }
@end

@interface SCPDividerView : UIView
@end
@implementation SCPDividerView
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e
{
    if (CGRectContainsPoint(CGRectInset(self.bounds, -SCP_DIVIDER_HIT, -SCP_DIVIDER_HIT), p)) return YES;
    // num keo (subview) cung nhan cham, ke ca phan nhoi ra ngoai duong ranh
    for (UIView *sub in self.subviews) if (!sub.hidden && CGRectContainsPoint(CGRectInset(sub.frame, -10, -10), p)) return YES;
    return NO;
}
@end

@interface UIImage (SCPPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)format scale:(double)scale;
@end

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

// Tao UIRootSceneWindow tren man xe (nil neu xe chua ket noi)
static UIWindow *SCPMakeCarWindow(void)
{
    id carDisplay = SCPGetCarPlayCADisplay();
    if (!carDisplay) { SCPLog("khong tim thay CADisplay cua CarPlay"); return nil; }
    id displayConfig = objcInvoke_2([objc_getClass("FBSDisplayConfiguration") alloc],
                                    @"initWithCADisplay:isMainDisplay:", carDisplay, 0);
    expectClass(displayConfig, "FBSDisplayConfiguration");
    UIWindow *w = objcInvoke_1([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfig);
    expectClass(w, "UIRootSceneWindow");
    return w;
}

// Cua so tren man iPhone (che do thu / mirror)
static UIWindow *SCPMakePhoneWindow(BOOL landscape)
{
    CGRect sb = [UIScreen mainScreen].bounds;
    UIWindowScene *mainScene = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]] && ((UIWindowScene *)sc).screen == [UIScreen mainScreen]) {
            mainScene = (UIWindowScene *)sc; break;
        }
    }
    UIWindow *w = mainScene ? [[UIWindow alloc] initWithWindowScene:mainScene] : [[UIWindow alloc] initWithFrame:sb];
    w.frame = sb;
    w.windowLevel = UIWindowLevelStatusBar + 50;
    if (landscape && sb.size.width < sb.size.height) {
        w.transform = CGAffineTransformMakeRotation(M_PI_2);
        w.bounds = CGRectMake(0, 0, sb.size.height, sb.size.width);
    }
    return w;
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

// Danh sach app trong may: @{ @"id", @"name" }, app nguoi dung truoc, app Apple sau
static NSArray<NSDictionary *> *SCPInstalledApps(void)
{
    id controller = objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance");
    NSArray *apps = objcInvoke(controller, @"allInstalledApplications");
    NSMutableArray *user = [NSMutableArray array], *system = [NSMutableArray array];
    NSSet *skip = [NSSet setWithArray:@[@"com.apple.springboard", @"com.apple.CarPlayApp", @"com.apple.CarPlaySettings",
                                        @"com.apple.CarPlayTemplateUIHost", @"com.apple.webapp", @"com.apple.Preferences",
                                        @"com.anpham.splitcarplayapp"]];
    NSSet *appleAllowed = [NSSet setWithArray:@[@"com.apple.mobilesafari", @"com.apple.Music", @"com.apple.Maps", @"com.apple.podcasts",
                                                @"com.apple.mobileslideshow", @"com.apple.tv", @"com.apple.MobileSMS",
                                                @"com.apple.mobilephone", @"com.apple.Bridge", @"com.apple.mobilenotes"]];
    for (id app in apps) {
        NSString *bid = objcInvoke(app, @"bundleIdentifier");
        NSString *name = objcInvoke(app, @"displayName");
        if (!bid || !name.length || [skip containsObject:bid]) continue;
        if ([bid hasPrefix:@"com.apple."] && ![appleAllowed containsObject:bid] && objcInvokeT(app, @"isSystemApplication", BOOL)) continue;
        NSDictionary *d = @{@"id": bid, @"name": name};
        if ([bid hasPrefix:@"com.apple."]) [system addObject:d]; else [user addObject:d];
    }
    NSSortDescriptor *byName = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)];
    [user sortUsingDescriptors:@[byName]]; [system sortUsingDescriptors:@[byName]];
    return [user arrayByAddingObjectsFromArray:system];
}

static UIImage *SCPAppIcon(NSString *bid)
{
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        return [UIImage _applicationIconImageForBundleIdentifier:bid format:2 scale:2.0];
    }
    return nil;
}

@implementation SCPAppPane
@end

// =====================================================================
@interface SCPSplitWindow ()
@property (nonatomic, strong) UIView *dividerView, *dividerPill;
@property (nonatomic, strong) UIView *dividerMenu;           // menu kieu Xiaomi hien khi cham num keo
@property (nonatomic, strong) NSTimer *dividerMenuTimer;
@property (nonatomic) SCPSlot pendingSlot;                   // ngan dang cho chon app (bang chon chiem dung nua do)
@property (nonatomic, strong) UIView *pickerView;
@property (nonatomic, strong) UIButton *demoExitButton;    // che do thu: nut "Thoat thu" luon hien de khong bao gio bi ket
@property (nonatomic, strong) UIImageView *dragImage;
@property (nonatomic, strong) NSString *dragBundleID;
@property (nonatomic) SCPSlot pickerSlot;
@property (nonatomic) CGPoint pipOrigin;              // goc PiP trong vung ngan (ti le 0..1)
@property (nonatomic, strong) NSMutableArray<NSString *> *rightHistory;   // chong app ngan phai (vuot 2 ngon)
@property (nonatomic, strong) UIWindow *mirrorWindow;  // mirror ngan phai tren iPhone (thu nghiem)
@property (nonatomic, strong) id mirrorVC;
- (instancetype)initOnMainScreen:(BOOL)mainScreen;
- (void)setupActionsForPane:(SCPAppPane *)pane;
- (void)layoutActionsForPane:(SCPAppPane *)pane;
- (void)setActionsVisible:(BOOL)visible forPane:(SCPAppPane *)pane animated:(BOOL)animated;
- (void)scheduleActionsHideForPane:(SCPAppPane *)pane;
- (void)hideAllPaneActions;
- (SCPAppPane *)paneForView:(UIView *)v;
- (SCPSlot)slotForPane:(SCPAppPane *)pane;
- (void)setupDivider;
- (void)showDividerMenu;
- (void)hideDividerMenu;
- (void)scheduleDividerMenuHide;
- (void)exitOrStayInDemo;
- (NSString *)ratioSymbol;
- (void)layoutDividerMenu;
- (BOOL)singlePane;
- (void)logDiagnostics;
- (void)relayoutPanes;
- (void)relayoutPanesLive:(BOOL)live;
- (void)layoutPane:(SCPAppPane *)pane;
- (void)layoutPane:(SCPAppPane *)pane live:(BOOL)live;
- (int)deviceOrientationForPane:(SCPAppPane *)pane;
- (void)postOrientationToPane:(SCPAppPane *)pane;
- (void)layoutPipHandleForPane:(SCPAppPane *)pane;
- (CGRect)frameForSlot:(SCPSlot)slot;
- (CGRect)dividerFrame;
- (CGRect)pickerFrame;
- (CGRect)paneArea;
- (BOOL)vertical;
- (void)saveRatio;
- (void)applyPairRatioIfAny;
- (void)updatePaneActionStates;
- (void)layoutBarContentForPane:(SCPAppPane *)pane;
- (void)nudgePane:(SCPAppPane *)pane;
- (void)animateLayout:(void (^)(void))changes completion:(void (^)(void))done;
- (void)mirrorRightPaneIfEnabled;
- (void)teardownMirror;
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
    self.ratio = [SCPPrefs splitRatio];
    self.fullscreenSlot = SCPSlotAuto;
    self.pipSlot = SCPSlotAuto;
    self.pendingSlot = SCPSlotAuto;
    self.pipOrigin = CGPointMake(1, 1);   // goc duoi-phai
    self.rightHistory = [NSMutableArray array];

    if (mainScreen) {
        self.rootWindow = SCPMakePhoneWindow(YES);
        // Che do thu (demo) tren man iPhone: KHONG tu dong; chi thoat khi bam "Dong split thu" trong Settings
        // (hoac splitcarplay://close). Cac nut dong trong cua so chi dong app roi hien lai bang chon.
        SCPLog("TEST window tren man chinh, bounds=%@ (khong tu dong)", NSStringFromCGRect(self.rootWindow.bounds));
    } else {
        self.rootWindow = SCPMakeCarWindow();
        if (!self.rootWindow) return nil;
        SCPLog("root window tren man xe frame=%@ screen=%@", NSStringFromCGRect(self.rootWindow.frame), self.rootWindow.screen);
    }

    self.rootWindow.backgroundColor = [UIColor colorWithRed:0.02 green:0.03 blue:0.08 alpha:1];
    [self setupDivider];
    if (mainScreen) [self setupDemoExitButton];

    self.rootWindow.alpha = 0;
    self.rootWindow.hidden = NO;
    if (orig_BKSDisplayServicesSetScreenBlanked) orig_BKSDisplayServicesSetScreenBlanked(0);
    [UIView animateWithDuration:0.5 animations:^{ self.rootWindow.alpha = 1; }];
    __weak SCPSplitWindow *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf logDiagnostics];
    });
    return self;
}

- (NSArray<SCPAppPane *> *)panes
{
    NSMutableArray *a = [NSMutableArray array];
    if (self.leftPane) [a addObject:self.leftPane];
    if (self.rightPane) [a addObject:self.rightPane];
    return a;
}

- (BOOL)vertical { return [SCPPrefs splitDirection] == 1; }

// Che do thu tren iPhone: cua so phu kin man nen PHAI luon co loi thoat ngay trong cua so.
// Vien thuoc do "Thoat thu" o goc tren trai, luon nam tren cung (ke ca tren bang chon). Bam Home cung thoat.
- (void)setupDemoExitButton
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    id cfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
    [b setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:cfg] forState:UIControlStateNormal];
    [b setTitle:@" Thoát thử" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    b.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
    b.layer.cornerRadius = 16;
    b.frame = CGRectMake(10, 8, 112, 32);
    b.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    [b addTarget:self action:@selector(demoExitTapped) forControlEvents:UIControlEventTouchUpInside];
    self.demoExitButton = b;
    [self.rootWindow addSubview:b];
}

- (void)demoExitTapped
{
    SCPLog("demo: thoat bang nut Thoat thu");
    [self dismiss];
}

// ---------------------------------------------------------------------
//  Option rieng cua tung ngan: dau "..." o giua mep tren ngan, keo xuong / cham de hien
//  thanh nut nam tren mep ngan (an o y = -cao). Tu an sau vai giay.
// ---------------------------------------------------------------------
- (SCPSlot)slotForPane:(SCPAppPane *)pane
{
    return (pane == self.leftPane) ? SCPSlotLeft : SCPSlotRight;
}

// Tim ngan chua view (nut / handle / bar) bang cach di len superview toi containerView
- (SCPAppPane *)paneForView:(UIView *)v
{
    while (v) {
        for (SCPAppPane *p in self.panes) if (p.containerView == v) return p;
        v = v.superview;
    }
    return nil;
}

// Nut kieu HyperOS: hinh tron 52pt nen trang, icon hinh hoc den 24pt, khong nhan chu.
// Nut dang "bat" (fullscreen / PiP) doi sang xanh (icon xanh, nen xanh nhat) nhu HyperOS.
// Dung chung cho hang nut cua ngan, menu num keo va nut chia doi -> 1 kieu nut duy nhat.
#define SCP_BTN      52.0
#define SCP_BTN_GAP  10.0
static UIColor *SCPInk(void)     { return [UIColor colorWithWhite:0.13 alpha:1]; }
static UIColor *SCPAccent(void)  { return [UIColor colorWithRed:0.10 green:0.47 blue:1.0 alpha:1]; }
static id SCPActionSymbolConfig(void)
{
    static id cfg;
    if (!cfg) cfg = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium scale:UIImageSymbolScaleMedium];
    return cfg;
}

static void SCPSetIcon(UIButton *b, NSString *symbol)
{
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:SCPActionSymbolConfig()] forState:UIControlStateNormal];
}

static void SCPSetOn(UIButton *b, BOOL on)
{
    b.tintColor = on ? SCPAccent() : SCPInk();
    b.backgroundColor = on ? [UIColor colorWithRed:0.86 green:0.92 blue:1.0 alpha:1] : [UIColor colorWithWhite:1 alpha:0.96];
}

// Animation kieu MIUI: cac nut tron lan luot bat ra (scale 0.3 -> 1, lo xo), cach nhau `stagger` giay.
// Thu tu bat ra theo thu tu mang `views` (nut bi an thi bo qua).
static void SCPPopIn(NSArray<UIView *> *views, NSTimeInterval stagger)
{
    NSInteger i = 0;
    for (UIView *v in views) {
        if (v.hidden) continue;
        v.alpha = 0; v.transform = CGAffineTransformMakeScale(0.3, 0.3);
        [UIView animateWithDuration:0.5 delay:i * stagger usingSpringWithDamping:0.6 initialSpringVelocity:0.6
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ v.alpha = 1; v.transform = CGAffineTransformIdentity; } completion:nil];
        i++;
    }
}

// Thu lai nhanh (tat ca cung luc), xong goi `done`
static void SCPPopOut(NSArray<UIView *> *views, void (^done)(void))
{
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        for (UIView *v in views) { v.alpha = 0; v.transform = CGAffineTransformMakeScale(0.5, 0.5); }
    } completion:^(BOOL f) {
        for (UIView *v in views) { v.transform = CGAffineTransformIdentity; v.alpha = 1; }
        if (done) done();
    }];
}

- (UIButton *)roundButton:(NSString *)symbol action:(SEL)sel
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.bounds = CGRectMake(0, 0, SCP_BTN, SCP_BTN);
    b.layer.cornerRadius = SCP_BTN / 2;
    b.layer.shadowColor = [UIColor blackColor].CGColor;
    b.layer.shadowOpacity = 0.35; b.layer.shadowRadius = 6; b.layer.shadowOffset = CGSizeMake(0, 2);
    SCPSetOn(b, NO);
    SCPSetIcon(b, symbol);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [b addTarget:self action:@selector(actionButtonTouched:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// Animation bo cuc chung: lo xo nhe (khong bounce qua) cho moi lan doi ti le / doi cho / toan man / PiP
- (void)animateLayout:(void (^)(void))changes completion:(void (^)(void))done
{
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:changes completion:^(BOOL f) { if (done) done(); }];
}

- (void)setupActionsForPane:(SCPAppPane *)pane
{
    // Vien quanh app
    pane.containerView.layer.borderWidth = SCP_PANE_BORDER;
    pane.containerView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
    pane.containerView.layer.cornerRadius = 14;

    // The (grabber) trang tron o giua mep tren, kieu iOS sheet: khong chu, khong cham
    UIView *h = [[SCPTabView alloc] initWithFrame:CGRectMake(0, 0, SCP_PANE_HANDLE_WIDTH, SCP_PANE_HANDLE_HEIGHT)];
    h.backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
    h.layer.cornerRadius = SCP_PANE_HANDLE_HEIGHT / 2;
    h.layer.shadowColor = [UIColor blackColor].CGColor;
    h.layer.shadowOpacity = 0.35; h.layer.shadowRadius = 2; h.layer.shadowOffset = CGSizeMake(0, 1);
    [h addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(paneActionsPanned:)]];
    [h addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(paneHandleTapped:)]];
    pane.actionHandle = h;
    [pane.containerView addSubview:h];

    // Hang nut cua ngan (nen trong suot, chi thay cac nut tron): CHI viec cua ngan nay.
    // Viec cua ca cap (doi cho, ti le, cap yeu thich, ve CarPlay) nam o menu num keo -> khong lap.
    UIScrollView *bar = [[UIScrollView alloc] initWithFrame:CGRectMake(0, SCP_PANE_HANDLE_HEIGHT + 6, pane.containerView.bounds.size.width, SCP_PANE_BAR_HEIGHT)];
    bar.backgroundColor = [UIColor clearColor];
    bar.showsHorizontalScrollIndicator = NO;
    bar.alwaysBounceHorizontal = NO;
    bar.clipsToBounds = NO;
    bar.hidden = YES;
    pane.actionBar = bar;
    pane.actionsVisible = NO;
    [pane.containerView addSubview:bar];

    UIView *content = [[UIView alloc] init];
    content.tag = 1002;
    [bar addSubview:content];

    // Icon theo HyperOS: luoi app = doi app, o vuong dac = toan man, cua so noi = PiP, X trong o vuong = dong
    UIButton *b;
    b = [self roundButton:@"square.grid.2x2" action:@selector(paneChooseApp:)]; [content addSubview:b];
    // Chia doi: chi hien khi ngan nay mot minh het man. Bam: app nay ve nua TRAI, nua phai hien bang chon app.
    pane.splitButton = [self roundButton:@"rectangle.split.2x1" action:@selector(paneSplitTapped:)]; [content addSubview:pane.splitButton];
    pane.fullscreenButton = [self roundButton:@"square.fill" action:@selector(paneToggleFullscreen:)]; [content addSubview:pane.fullscreenButton];
    pane.pipButton = [self roundButton:@"pip" action:@selector(paneTogglePiP:)]; [content addSubview:pane.pipButton];
    b = [self roundButton:@"xmark.square" action:@selector(paneCloseApp:)]; [content addSubview:b];

    [self layoutActionsForPane:pane];
}

// Dat lai khung tab / hang nut theo kich thuoc ngan (goi moi lan relayout)
- (void)layoutActionsForPane:(SCPAppPane *)pane
{
    if (!pane.actionBar) return;
    CGSize s = pane.containerView.bounds.size;
    BOOL isPip = (self.pipSlot == [self slotForPane:pane]);
    // Dang PiP: mep tren danh cho thanh keo PiP, an tab + hang nut
    pane.actionHandle.hidden = isPip;
    if (isPip && pane.actionsVisible) { pane.actionsVisible = NO; [pane.actionsHideTimer invalidate]; pane.actionsHideTimer = nil; }
    pane.actionBar.hidden = isPip || !pane.actionsVisible;

    pane.actionHandle.bounds = CGRectMake(0, 0, SCP_PANE_HANDLE_WIDTH, SCP_PANE_HANDLE_HEIGHT);
    pane.actionHandle.center = CGPointMake(s.width / 2, 6 + SCP_PANE_HANDLE_HEIGHT / 2);
    pane.actionBar.frame = CGRectMake(0, SCP_PANE_HANDLE_HEIGHT + 12, s.width, SCP_PANE_BAR_HEIGHT);
    [self layoutBarContentForPane:pane];
    [pane.containerView bringSubviewToFront:pane.actionHandle];
    [pane.containerView bringSubviewToFront:pane.actionBar];
}

// Keo tab xuong -> hien, keo len -> an (khong keo theo tay; nut bat ra bang animation)
- (void)paneActionsPanned:(UIPanGestureRecognizer *)g
{
    SCPAppPane *pane = [self paneForView:g.view];
    if (!pane) return;
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGFloat ty = [g translationInView:pane.containerView].y, vy = [g velocityInView:pane.containerView].y;
    if (ty > 12 || vy > 200)       [self setActionsVisible:YES forPane:pane animated:YES];
    else if (ty < -12 || vy < -200) [self setActionsVisible:NO  forPane:pane animated:YES];
}

- (void)paneHandleTapped:(UITapGestureRecognizer *)g
{
    SCPAppPane *pane = [self paneForView:g.view];
    if (pane) [self setActionsVisible:!pane.actionsVisible forPane:pane animated:YES];
}

- (void)setActionsVisible:(BOOL)visible forPane:(SCPAppPane *)pane animated:(BOOL)animated
{
    if (!pane.actionBar) return;
    // Da o dung trang thai roi -> chi gia han bo dem tu an
    if (visible == pane.actionsVisible && pane.actionBar.hidden == !visible) { if (visible) [self scheduleActionsHideForPane:pane]; return; }
    pane.actionsVisible = visible;
    [pane.actionsHideTimer invalidate]; pane.actionsHideTimer = nil;
    [self updatePaneActionStates];
    NSArray *btns = [pane.actionBar viewWithTag:1002].subviews;
    // The gian ngang nhe khi hang nut dang mo (phan hoi cham)
    [UIView animateWithDuration:0.25 animations:^{ pane.actionHandle.transform = visible ? CGAffineTransformMakeScale(1.3, 1) : CGAffineTransformIdentity; }];
    if (visible) {
        [self hideDividerMenu];
        pane.actionBar.hidden = NO;
        if (animated) SCPPopIn(btns, 0.045);
        [self scheduleActionsHideForPane:pane];
    } else {
        __weak SCPAppPane *weakPane = pane;
        if (animated) SCPPopOut(btns, ^{ SCPAppPane *p = weakPane; if (p && !p.actionsVisible) p.actionBar.hidden = YES; });
        else pane.actionBar.hidden = YES;
    }
}

- (void)scheduleActionsHideForPane:(SCPAppPane *)pane
{
    [pane.actionsHideTimer invalidate];
    if (!pane.actionsVisible) return;
    __weak SCPSplitWindow *weakSelf = self;
    __weak SCPAppPane *weakPane = pane;
    pane.actionsHideTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *t) {
        if (weakPane) [weakSelf setActionsVisible:NO forPane:weakPane animated:YES];
    }];
}

- (void)hideAllPaneActions
{
    for (SCPAppPane *p in self.panes) if (p.actionsVisible) [self setActionsVisible:NO forPane:p animated:YES];
}

// Bam nut nao cung reset bo dem tu an
- (void)actionButtonTouched:(UIButton *)b
{
    SCPAppPane *pane = [self paneForView:b];
    if (pane) [self scheduleActionsHideForPane:pane];
    else if (self.dividerMenu) [self scheduleDividerMenuHide];
}

// Icon Toan man / PiP doi theo trang thai; dang bat thi xanh (nhu nut "cua so noi" trong HyperOS)
- (void)updatePaneActionStates
{
    for (SCPAppPane *p in self.panes) {
        if (!p.actionBar) continue;
        SCPSlot slot = [self slotForPane:p];
        BOOL isFull = (self.fullscreenSlot == slot), isPip = (self.pipSlot == slot);
        SCPSetIcon(p.fullscreenButton, isFull ? @"rectangle.split.2x1" : @"square.fill");   // dang toan man -> bam de ve 2 nua
        SCPSetOn(p.fullscreenButton, isFull);
        SCPSetIcon(p.pipButton, isPip ? @"pip.exit" : @"pip");
        SCPSetOn(p.pipButton, isPip);
        // 1 ngan mot minh: khong co gi de toan man / PiP -> an bot cho gon
        BOOL alone = (self.panes.count == 1);
        p.fullscreenButton.hidden = alone && !isFull;
        p.pipButton.hidden = alone && !isPip;
        p.splitButton.hidden = !([self singlePane] && !self.pickerView);   // chia doi: chi khi 1 app het man
        [self layoutBarContentForPane:p];
    }
}

// Xep cac nut con hien thanh 1 hang, can giua ngan (ngan hep thi cuon ngang). Dung bounds/center vi nut co the dang scale.
- (void)layoutBarContentForPane:(SCPAppPane *)pane
{
    UIView *content = [pane.actionBar viewWithTag:1002];
    CGFloat x = SCP_BTN_GAP, y = SCP_PANE_BAR_HEIGHT / 2;
    for (UIView *v in content.subviews) {
        if (v.hidden) continue;
        v.bounds = CGRectMake(0, 0, SCP_BTN, SCP_BTN);
        v.center = CGPointMake(x + SCP_BTN / 2, y);
        x += SCP_BTN + SCP_BTN_GAP;
    }
    CGFloat w = pane.actionBar.bounds.size.width;
    CGFloat pad = MAX(0, (w - x) / 2);
    content.frame = CGRectMake(pad, 0, x, SCP_PANE_BAR_HEIGHT);
    pane.actionBar.contentSize = CGSizeMake(MAX(x, w), SCP_PANE_BAR_HEIGHT);
}

// ---- hanh dong tu bar cua ngan ----
- (void)paneChooseApp:(UIButton *)b
{
    SCPAppPane *pane = [self paneForView:b];
    if (!pane) return;
    [self showAppPickerForSlot:[self slotForPane:pane]];
}

// Nut X: tat han app do. Con 1 ngan -> ngan do tu phong to het man; het ngan -> dong split, ve dashboard CarPlay
- (void)paneCloseApp:(UIButton *)b
{
    SCPAppPane *pane = [self paneForView:b];
    if (!pane) return;
    SCPSlot slot = [self slotForPane:pane];
    [self closeSlot:slot terminate:YES];
    if (self.panes.count == 0) { [self exitOrStayInDemo]; return; }
    [self animateLayout:^{ [self relayoutPanes]; } completion:nil];
}

- (void)paneToggleFullscreen:(UIButton *)b
{
    SCPAppPane *pane = [self paneForView:b];
    if (pane) [self toggleFullscreenForSlot:[self slotForPane:pane]];
}

- (void)paneTogglePiP:(UIButton *)b
{
    SCPAppPane *pane = [self paneForView:b];
    if (pane) [self togglePiPForSlot:[self slotForPane:pane]];
}

- (void)paneSplitTapped:(UIButton *)b
{
    [self beginSplitFromSinglePane];
}

// 1 ngan dang het man -> app do ve nua TRAI (tren), nua PHAI (duoi) hien bang chon app ngay trong nua do
- (void)beginSplitFromSinglePane
{
    if (self.panes.count != 1) { SCPLog("beginSplit: can dung 1 ngan, dang co %lu", (unsigned long)self.panes.count); return; }
    self.fullscreenSlot = SCPSlotAuto; self.pipSlot = SCPSlotAuto;
    [self hideAllPaneActions];
    if (self.rightPane && !self.leftPane) {   // app dang o ngan phai -> chuyen sang trai
        self.leftPane = self.rightPane; self.rightPane = nil;
        [SCPPrefs setLeftApp:self.leftPane.bundleIdentifier];
    }
    self.pendingSlot = SCPSlotRight;
    self.ratio = 0.5;
    SCPLog("split tu 1 ngan: %@ -> trai, cho chon app ngan phai", self.leftPane.bundleIdentifier);
    [self animateLayout:^{ [self relayoutPanes]; } completion:^{
        if (self.pendingSlot == SCPSlotRight) [self showAppPickerForSlot:SCPSlotRight];
    }];
}

// ---------------------------------------------------------------------
//  Bo cuc: trai/phai hoac tren/duoi, fullscreen, PiP
// ---------------------------------------------------------------------
// Ngan dung het cua so (option cua ngan nam trong chinh ngan do)
// Vung dat ngan: lui vao SCP_PANE_INSET moi phia de khung moi app noi ro tren nen toi
- (CGRect)paneArea
{
    return CGRectInset(self.rootWindow.bounds, SCP_PANE_INSET, SCP_PANE_INSET);
}

// Chi con 1 ngan dang chay (chua co special) -> ngan do chiem het man
- (BOOL)singlePane
{
    return self.panes.count == 1 && self.pendingSlot == SCPSlotAuto && self.fullscreenSlot == SCPSlotAuto && self.pipSlot == SCPSlotAuto;
}

- (CGRect)frameForSlot:(SCPSlot)slot
{
    CGRect a = [self paneArea];
    if (self.fullscreenSlot != SCPSlotAuto) {   // toan man tam: dung het cua so, khong lui mep
        return (slot == self.fullscreenSlot) ? self.rootWindow.bounds : CGRectMake(a.origin.x, a.origin.y, 0, 0);
    }
    if ([self singlePane]) {
        SCPAppPane *only = self.panes.firstObject;
        return (slot == [self slotForPane:only]) ? a : CGRectMake(a.origin.x, a.origin.y, 0, 0);
    }
    if (self.pipSlot != SCPSlotAuto) {
        if (slot != self.pipSlot) return a;
        CGFloat w = floor(a.size.width * SCP_PIP_SCALE), h = floor(a.size.height * SCP_PIP_SCALE);
        CGFloat x = a.origin.x + 8 + (a.size.width - w - 16) * self.pipOrigin.x;
        CGFloat y = a.origin.y + 8 + (a.size.height - h - 16) * self.pipOrigin.y;
        return CGRectMake(x, y, w, h);
    }
    BOOL v = [self vertical];
    CGFloat len = (v ? a.size.height : a.size.width) - SCP_DIVIDER_WIDTH;
    CGFloat first = floor(len * self.ratio), second = len - first;
    if (v) {
        if (slot == SCPSlotLeft) return CGRectMake(a.origin.x, a.origin.y, a.size.width, first);
        return CGRectMake(a.origin.x, a.origin.y + first + SCP_DIVIDER_WIDTH, a.size.width, second);
    }
    if (slot == SCPSlotLeft) return CGRectMake(a.origin.x, a.origin.y, first, a.size.height);
    return CGRectMake(a.origin.x + first + SCP_DIVIDER_WIDTH, a.origin.y, second, a.size.height);
}

- (CGRect)dividerFrame
{
    CGRect l = [self frameForSlot:SCPSlotLeft];
    CGRect a = [self paneArea];
    if ([self vertical]) return CGRectMake(a.origin.x, CGRectGetMaxY(l), a.size.width, SCP_DIVIDER_WIDTH);
    return CGRectMake(CGRectGetMaxX(l), a.origin.y, SCP_DIVIDER_WIDTH, a.size.height);
}

- (void)setupDivider
{
    // View rong 0 nam dung duong ranh giua 2 ngan, nhan pan doi ti le.
    // Num keo (dividerPill) kieu Xiaomi: thanh trang mong bo tron 6x40 nam de len duong ranh,
    // cham de mo menu (doi cho / bo cuc / dong), keo de doi ti le.
    self.dividerView = [[SCPDividerView alloc] initWithFrame:[self dividerFrame]];
    self.dividerView.backgroundColor = [UIColor clearColor];
    UIView *knob = [[UIView alloc] init];
    knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.92];
    knob.layer.shadowColor = [UIColor blackColor].CGColor;
    knob.layer.shadowOpacity = 0.55;
    knob.layer.shadowRadius = 3;
    knob.layer.shadowOffset = CGSizeZero;
    knob.userInteractionEnabled = NO;
    for (NSInteger i = 0; i < 3; i++) {   // 3 cham den
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, SCP_KNOB_DOT, SCP_KNOB_DOT)];
        dot.backgroundColor = SCPInk();
        dot.layer.cornerRadius = SCP_KNOB_DOT / 2;
        dot.tag = 300 + i;
        [knob addSubview:dot];
    }
    self.dividerPill = knob;
    [self.dividerView addSubview:knob];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dividerPanned:)];
    pan.maximumNumberOfTouches = 1;
    [self.dividerView addGestureRecognizer:pan];
    [self.dividerView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dividerTapped:)]];
    [self.rootWindow addSubview:self.dividerView];
    [self layoutDividerPill];
}

- (void)layoutDividerPill
{
    CGSize s = self.dividerView.bounds.size;
    BOOL v = [self vertical];
    CGFloat kw = v ? SCP_KNOB_H : SCP_KNOB_W, kh = v ? SCP_KNOB_W : SCP_KNOB_H;   // chia tren/duoi thi num nam ngang
    // dung bounds/center (khong dung frame) vi num co the dang scale khi keo
    self.dividerPill.bounds = CGRectMake(0, 0, kw, kh);
    self.dividerPill.center = CGPointMake(s.width / 2, s.height / 2);
    self.dividerPill.layer.cornerRadius = SCP_KNOB_W / 2;
    // 3 cham xep doc theo chieu dai num (⋮ khi chia trai/phai, ⋯ khi chia tren/duoi)
    for (NSInteger i = 0; i < 3; i++) {
        UIView *dot = [self.dividerPill viewWithTag:300 + i];
        CGFloat off = (i - 1) * 9;
        dot.center = v ? CGPointMake(kw / 2 + off, kh / 2) : CGPointMake(kw / 2, kh / 2 + off);
    }
}

// ---- menu cua num keo: viec cua CA CAP (doi cho | ti le | cap yeu thich | ve CarPlay) ----
- (void)dividerTapped:(UITapGestureRecognizer *)g
{
    // Chi nhan cham ngay tren num (noi rong 14pt moi phia); cham cho khac tren duong ranh thi bo qua
    CGPoint p = [g locationInView:self.dividerView];
    if (!CGRectContainsPoint(CGRectInset(self.dividerPill.frame, -14, -14), p)) return;
    if (self.dividerMenu) [self hideDividerMenu]; else [self showDividerMenu];
}

// Icon cua nut ti le = bo cuc SE AP khi bam (nhu icon nua tren/nua duoi trong HyperOS)
- (NSString *)ratioSymbol
{
    CGFloat r = self.ratio;
    BOOL special = (self.fullscreenSlot != SCPSlotAuto) || (self.pipSlot != SCPSlotAuto);
    CGFloat next = special ? 0.5 : (fabs(r - 0.5) < 0.05 ? 0.7 : (r > 0.6 ? 0.3 : 0.5));
    BOOL v = [self vertical];
    if (fabs(next - 0.5) < 0.01) return v ? @"rectangle.split.1x2" : @"rectangle.split.2x1";
    if (next > 0.5)              return v ? @"rectangle.tophalf.filled" : @"rectangle.lefthalf.filled";
    return v ? @"rectangle.bottomhalf.filled" : @"rectangle.righthalf.filled";
}

- (void)showDividerMenu
{
    [self hideDividerMenu];
    [self hideAllPaneActions];
    NSMutableArray<UIButton *> *btns = [NSMutableArray array];
    [btns addObject:[self roundButton:@"arrow.left.arrow.right" action:@selector(menuSwap)]];
    UIButton *ratio = [self roundButton:[self ratioSymbol] action:@selector(menuCycleLayout)];
    ratio.tag = 1010;
    [btns addObject:ratio];
    for (NSInteger i = 1; i <= 3; i++) {
        if (![SCPPrefs favorite:i]) continue;
        UIButton *f = [self roundButton:[NSString stringWithFormat:@"%ld.circle", (long)i] action:@selector(menuFavTapped:)];
        f.tag = i;
        [btns addObject:f];
    }
    [btns addObject:[self roundButton:(self.onMainScreen ? @"xmark.square" : @"house") action:@selector(menuCloseSplit)]];

    // Container trong suot, cac nut tron trang xep 1 hang; bat ra lan luot tu giua ra 2 ben (kieu MIUI)
    CGFloat w = btns.count * SCP_BTN + (btns.count - 1) * SCP_BTN_GAP, h = SCP_BTN;
    UIView *m = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    m.backgroundColor = [UIColor clearColor];
    CGFloat x = 0;
    for (UIButton *b in btns) {
        b.center = CGPointMake(x + SCP_BTN / 2, h / 2);
        [m addSubview:b];
        x += SCP_BTN + SCP_BTN_GAP;
    }
    self.dividerMenu = m;
    [self.rootWindow addSubview:m];
    [self layoutDividerMenu];
    NSArray *order = [btns sortedArrayUsingComparator:^NSComparisonResult(UIButton *a, UIButton *b) {
        CGFloat da = fabs(a.center.x - w / 2), db = fabs(b.center.x - w / 2);
        return da < db ? NSOrderedAscending : (da > db ? NSOrderedDescending : NSOrderedSame);
    }];
    SCPPopIn(order, 0.04);
    [self scheduleDividerMenuHide];
}

- (void)scheduleDividerMenuHide
{
    [self.dividerMenuTimer invalidate];
    __weak SCPSplitWindow *weakSelf = self;
    self.dividerMenuTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *t) { [weakSelf hideDividerMenu]; }];
}

// Menu nam ngay canh num keo, can giua duong ranh: phia tren num (chia trai/phai) hoac duoi num (chia tren/duoi)
- (void)layoutDividerMenu
{
    if (!self.dividerMenu) return;
    CGRect d = self.dividerView.frame, b = self.rootWindow.bounds;
    CGSize ms = self.dividerMenu.bounds.size;
    CGPoint c = CGPointMake(CGRectGetMidX(d), CGRectGetMidY(d));
    if ([self vertical]) c.y += SCP_KNOB_W / 2 + 14 + ms.height / 2;
    else                 c.y -= SCP_KNOB_H / 2 + 14 + ms.height / 2;
    c.x = MIN(CGRectGetMaxX(b) - ms.width / 2 - 8, MAX(ms.width / 2 + 8, c.x));
    c.y = MIN(CGRectGetMaxY(b) - ms.height / 2 - 8, MAX(ms.height / 2 + 8, c.y));
    self.dividerMenu.center = c;
}

- (void)hideDividerMenu
{
    [self.dividerMenuTimer invalidate]; self.dividerMenuTimer = nil;
    UIView *m = self.dividerMenu;
    if (!m) return;
    self.dividerMenu = nil;
    SCPPopOut(m.subviews, ^{ [m removeFromSuperview]; });
}

- (void)menuSwap        { [self hideDividerMenu]; [self swapPanes]; }
- (void)menuCloseSplit  { [self hideDividerMenu]; [self exitOrStayInDemo]; }
- (void)menuFavTapped:(UIButton *)b { [self hideDividerMenu]; [self applyFavorite:b.tag]; }

// Doi ti le: giu menu mo (cap nhat icon cho buoc ke tiep) de bam tiep neu chua vua y
- (void)menuCycleLayout
{
    [self cycleLayoutPreset];
    UIButton *ratio = (UIButton *)[self.dividerMenu viewWithTag:1010];
    if (ratio) SCPSetIcon(ratio, [self ratioSymbol]);
    [self scheduleDividerMenuHide];
}

// Thoat split: tren xe -> dong cua so ve dashboard CarPlay. Che do thu tren iPhone -> chi dong app,
// giu cua so va hien bang chon de thu tiep; thoat han bang nut trong Settings.
- (void)exitOrStayInDemo
{
    if (!self.onMainScreen) { [self dismiss]; return; }
    SCPLog("demo: dong app, giu cua so thu");
    [self closeSlot:SCPSlotLeft];
    [self closeSlot:SCPSlotRight];
    [self relayoutPanes];
    [self showAppPickerForSlot:SCPSlotLeft];
}

- (void)dividerPanned:(UIPanGestureRecognizer *)g
{
    // Keo theo do doi cua ngon tay tu ti le luc bat dau -> khong bi nhay khi cham lech khoi duong ranh
    static CGFloat startRatio = 0.5;
    CGRect a = [self paneArea];
    BOOL v = [self vertical];
    CGFloat len = (v ? a.size.height : a.size.width) - SCP_DIVIDER_WIDTH;
    if (g.state == UIGestureRecognizerStateBegan) {
        startRatio = self.ratio;
        [self hideDividerMenu];
        [UIView animateWithDuration:0.15 animations:^{ self.dividerPill.transform = CGAffineTransformMakeScale(1.15, 1.15); }];
    }
    CGPoint t = [g translationInView:self.rootWindow];
    CGFloat r = startRatio + (v ? t.y : t.x) / len;
    r = MIN(0.8, MAX(0.2, r));

    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [UIView animateWithDuration:0.15 animations:^{ self.dividerPill.transform = CGAffineTransformIdentity; }];
        for (NSNumber *snap in @[@0.3, @0.5, @0.7]) {
            if (fabs(r - snap.doubleValue) < 0.04) { r = snap.doubleValue; break; }
        }
        self.ratio = r;
        [self animateLayout:^{ [self relayoutPanesLive:NO]; } completion:nil];
        [self saveRatio];
        return;
    }
    self.ratio = r;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self relayoutPanesLive:YES];
    [CATransaction commit];
}

- (void)saveRatio
{
    [SCPPrefs setSplitRatio:self.ratio];
    if (self.leftPane && self.rightPane) {
        [SCPPrefs setRatio:self.ratio forPairLeft:self.leftPane.bundleIdentifier right:self.rightPane.bundleIdentifier];
    }
    SCPLog("ti le ngan trai = %.2f (da luu)", self.ratio);
}

- (void)applyPairRatioIfAny
{
    if (!self.leftPane || !self.rightPane) return;
    CGFloat r = [SCPPrefs ratioForPairLeft:self.leftPane.bundleIdentifier right:self.rightPane.bundleIdentifier];
    if (r > 0 && fabs(r - self.ratio) > 0.01) {
        self.ratio = r;
        [self animateLayout:^{ [self relayoutPanesLive:NO]; } completion:nil];
        SCPLog("ap ti le rieng cua cap: %.2f", r);
    }
}

- (void)relayoutPanes
{
    [self relayoutPanesLive:NO];
}

- (void)relayoutPanesLive:(BOOL)live
{
    BOOL special = (self.fullscreenSlot != SCPSlotAuto) || (self.pipSlot != SCPSlotAuto);
    self.dividerView.hidden = special || self.panes.count < 2;   // 1 ngan thi khong co gi de keo
    self.dividerView.frame = [self dividerFrame];
    [self layoutDividerPill];
    if (self.dividerView.hidden) [self hideDividerMenu]; else [self layoutDividerMenu];
    for (SCPAppPane *p in self.panes) {
        SCPSlot slot = (p == self.leftPane) ? SCPSlotLeft : SCPSlotRight;
        BOOL hidden = (self.fullscreenSlot != SCPSlotAuto && slot != self.fullscreenSlot);
        p.containerView.hidden = hidden;
        if (!hidden) { p.containerView.frame = [self frameForSlot:slot]; [self layoutPane:p live:live]; }
        if (slot == self.pipSlot) [self.rootWindow bringSubviewToFront:p.containerView];
        if (!live) { [self layoutActionsForPane:p]; [self layoutPipHandleForPane:p]; }
    }
    if (self.pickerView) self.pickerView.frame = [self pickerFrame];
    if (self.demoExitButton) [self.rootWindow bringSubviewToFront:self.demoExitButton];
    [self updatePaneActionStates];
}

// ---- bo cuc dat san ----
- (void)applyPresetRatio:(CGFloat)ratio
{
    self.fullscreenSlot = SCPSlotAuto;
    self.pipSlot = SCPSlotAuto;
    self.ratio = MIN(0.8, MAX(0.2, ratio));
    [self animateLayout:^{ [self relayoutPanes]; } completion:nil];
    [self saveRatio];
}

- (void)cycleLayoutPreset
{
    CGFloat r = self.ratio;
    BOOL special = (self.fullscreenSlot != SCPSlotAuto) || (self.pipSlot != SCPSlotAuto);
    CGFloat next = special ? 0.5 : (fabs(r - 0.5) < 0.05 ? 0.7 : (r > 0.6 ? 0.3 : 0.5));
    [self applyPresetRatio:next];
}

// ---- fullscreen tam ----
- (void)toggleFullscreenForSlot:(SCPSlot)slot
{
    self.pipSlot = SCPSlotAuto;
    self.fullscreenSlot = (self.fullscreenSlot == slot) ? SCPSlotAuto : slot;
    SCPLog("fullscreen slot = %d", (int)self.fullscreenSlot);
    [self animateLayout:^{ [self relayoutPanes]; } completion:nil];
}

// ---- Picture in Picture ----
- (void)togglePiPForSlot:(SCPSlot)slot
{
    SCPAppPane *pane = (slot == SCPSlotLeft) ? self.leftPane : self.rightPane;
    if (!pane && self.pipSlot == SCPSlotAuto) { SCPLog("khong co app o ngan %d de PiP", (int)slot); return; }
    self.fullscreenSlot = SCPSlotAuto;
    self.pipSlot = (self.pipSlot == slot) ? SCPSlotAuto : slot;
    SCPLog("pip slot = %d", (int)self.pipSlot);
    [self animateLayout:^{ [self relayoutPanes]; } completion:nil];
}

- (void)layoutPipHandleForPane:(SCPAppPane *)pane
{
    SCPSlot slot = (pane == self.leftPane) ? SCPSlotLeft : SCPSlotRight;
    BOOL isPip = (self.pipSlot == slot);
    if (!isPip) { pane.pipHandle.hidden = YES; return; }
    if (!pane.pipHandle) {
        UIView *h = [[UIView alloc] init];
        h.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        UIView *grip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 4)];
        grip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.8];
        grip.layer.cornerRadius = 2;
        grip.tag = 99;
        [h addSubview:grip];
        [h addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pipPanned:)]];
        [h addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pipTapped:)]];
        pane.pipHandle = h;
        [pane.containerView addSubview:h];
    }
    pane.pipHandle.hidden = NO;
    CGSize s = pane.containerView.bounds.size;
    pane.pipHandle.frame = CGRectMake(0, 0, s.width, 18);
    [pane.pipHandle viewWithTag:99].center = CGPointMake(s.width / 2, 9);
    [pane.containerView bringSubviewToFront:pane.pipHandle];
}

- (void)pipPanned:(UIPanGestureRecognizer *)g
{
    if (self.pipSlot == SCPSlotAuto) return;
    SCPAppPane *pane = (self.pipSlot == SCPSlotLeft) ? self.leftPane : self.rightPane;
    CGRect a = [self paneArea];
    CGPoint p = [g locationInView:self.rootWindow];
    CGSize s = pane.containerView.bounds.size;
    CGFloat nx = (p.x - a.origin.x - s.width / 2 - 8) / MAX(1, a.size.width - s.width - 16);
    CGFloat ny = (p.y - a.origin.y - 9 - 8) / MAX(1, a.size.height - s.height - 16);
    self.pipOrigin = CGPointMake(MIN(1, MAX(0, nx)), MIN(1, MAX(0, ny)));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    pane.containerView.frame = [self frameForSlot:self.pipSlot];
    [CATransaction commit];
}

- (void)pipTapped:(UITapGestureRecognizer *)g
{
    if (self.pipSlot != SCPSlotAuto) [self togglePiPForSlot:self.pipSlot];
}

// ---------------------------------------------------------------------
//  Bang chon app (luoi icon) + keo tha
// ---------------------------------------------------------------------
- (CGRect)pickerFrame
{
    // Dang cho chon app cho 1 ngan (split tu 1 ngan): bang chon chiem dung nua cua ngan do
    if (self.pendingSlot != SCPSlotAuto) return [self frameForSlot:self.pendingSlot];
    return [self paneArea];
}

- (void)showAppPickerForSlot:(SCPSlot)slot
{
    [self hideAppPicker];
    [self hideDividerMenu];
    self.pickerSlot = (slot == SCPSlotRight) ? SCPSlotRight : SCPSlotLeft;
    BOOL half = (self.pendingSlot != SCPSlotAuto);   // bang chon nam trong nua ngan, chi cham chon (khong keo tha)

    UIView *pv = [[UIView alloc] initWithFrame:[self pickerFrame]];
    pv.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.97];
    self.pickerView = pv;
    [self.rootWindow addSubview:pv];
    if (self.demoExitButton) [self.rootWindow bringSubviewToFront:self.demoExitButton];
    [self hideAllPaneActions];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 17, pv.bounds.size.width - 90, 30)];
    if (half) title.text = @"Chọn app để chia đôi";
    else title.text = (self.pickerSlot == SCPSlotLeft) ? @"Chọn app cho ngăn TRÁI  (giữ icon và kéo để thả vào ngăn)" : @"Chọn app cho ngăn PHẢI";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.adjustsFontSizeToFitWidth = YES;
    [pv addSubview:title];

    // Nut X: huy chon. Khong con app nao: che do thu -> an X (huy thi chi con cua so trong, nhin nhu man den);
    // tren xe -> X dong han split ve dashboard CarPlay.
    UIButton *cancel = [self roundButton:@"xmark" action:@selector(pickerCancelTapped)];
    cancel.center = CGPointMake(pv.bounds.size.width - 8 - SCP_BTN / 2, 6 + SCP_BTN / 2);
    cancel.hidden = (self.panes.count == 0 && self.onMainScreen);
    [pv addSubview:cancel];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 66, pv.bounds.size.width, pv.bounds.size.height - 66)];
    scroll.alwaysBounceVertical = YES;
    scroll.tag = 77;
    [pv addSubview:scroll];

    NSArray *apps = SCPInstalledApps();
    CGFloat cellW = 108, cellH = 104, iconSize = 60;
    NSInteger cols = MAX(1, (NSInteger)(scroll.bounds.size.width / cellW));
    CGFloat padX = (scroll.bounds.size.width - cols * cellW) / 2;
    NSInteger i = 0;
    for (NSDictionary *app in apps) {
        NSInteger row = i / cols, col = i % cols;
        CGFloat x = padX + col * cellW, y = 8 + row * cellH;

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(x, y, cellW, cellH);
        b.accessibilityIdentifier = app[@"id"];
        [b addTarget:self action:@selector(pickerAppTapped:) forControlEvents:UIControlEventTouchUpInside];
        if (!half) {
            UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pickerDrag:)];
            lp.minimumPressDuration = 0.35;
            [b addGestureRecognizer:lp];
        }

        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((cellW - iconSize) / 2, 6, iconSize, iconSize)];
        iv.image = SCPAppIcon(app[@"id"]);
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.layer.cornerRadius = 13; iv.clipsToBounds = YES;
        iv.backgroundColor = iv.image ? [UIColor clearColor] : [UIColor colorWithWhite:0.3 alpha:1];
        iv.userInteractionEnabled = NO;
        iv.tag = 78;
        [b addSubview:iv];

        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(2, iconSize + 10, cellW - 4, 30)];
        l.text = app[@"name"];
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:12];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 2;
        l.userInteractionEnabled = NO;
        [b addSubview:l];

        [scroll addSubview:b];
        i++;
    }
    NSInteger rows = (i + cols - 1) / cols;
    scroll.contentSize = CGSizeMake(scroll.bounds.size.width, 16 + rows * cellH);
    [self updatePaneActionStates];   // an nut chia doi khi bang chon dang mo
    // Bang chon truot len + mo dan; vai hang icon dau bat ra lan luot
    pv.alpha = 0; pv.transform = CGAffineTransformMakeTranslation(0, 24);
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.4 options:0
                     animations:^{ pv.alpha = 1; pv.transform = CGAffineTransformIdentity; } completion:nil];
    NSArray *firstCells = [scroll.subviews subarrayWithRange:NSMakeRange(0, MIN(scroll.subviews.count, (NSUInteger)(cols * 2)))];
    SCPPopIn(firstCells, 0.02);
    SCPLog("picker: %ld app, slot=%d, half=%d", (long)i, (int)self.pickerSlot, (int)half);
}

- (void)pickerAppTapped:(UIButton *)b
{
    NSString *bid = b.accessibilityIdentifier;
    SCPSlot slot = self.pickerSlot;
    if (self.pendingSlot != SCPSlotAuto && bid) {
        // split tu 1 ngan: mo app vao nua dang trong roi moi go bang chon (tranh nhay layout ve het man)
        [self launchApp:bid inSlot:slot];
        [self hideAppPicker];
        if (slot == SCPSlotLeft) [SCPPrefs setLeftApp:bid]; else [SCPPrefs setRightApp:bid];
        return;
    }
    [self hideAppPicker];
    if (!bid) return;
    [self launchApp:bid inSlot:slot];
    if (slot == SCPSlotLeft) {
        [SCPPrefs setLeftApp:bid];
        if (!self.rightPane) [self showAppPickerForSlot:SCPSlotRight];   // chon tiep ngan phai neu con trong
    } else {
        [SCPPrefs setRightApp:bid];
    }
}

// Giu icon -> keo -> tha vao nua trai/phai (hoac tren/duoi) cua bang
- (void)pickerDrag:(UILongPressGestureRecognizer *)g
{
    UIButton *b = (UIButton *)g.view;
    CGPoint p = [g locationInView:self.pickerView];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragBundleID = b.accessibilityIdentifier;
        UIImageView *src = (UIImageView *)[b viewWithTag:78];
        self.dragImage = [[UIImageView alloc] initWithImage:src.image];
        self.dragImage.frame = CGRectMake(0, 0, 64, 64);
        self.dragImage.center = p;
        self.dragImage.layer.cornerRadius = 14; self.dragImage.clipsToBounds = YES;
        self.dragImage.alpha = 0.9;
        [self.pickerView addSubview:self.dragImage];
        [self showDropZones:YES];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        self.dragImage.center = p;
        [self highlightDropZoneAt:p];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        NSString *bid = self.dragBundleID;
        [self.dragImage removeFromSuperview]; self.dragImage = nil; self.dragBundleID = nil;
        [self showDropZones:NO];
        if (g.state != UIGestureRecognizerStateEnded || !bid) return;
        CGSize s = self.pickerView.bounds.size;
        BOOL first = [self vertical] ? (p.y < s.height / 2) : (p.x < s.width / 2);
        SCPSlot slot = first ? SCPSlotLeft : SCPSlotRight;
        [self hideAppPicker];
        [self launchApp:bid inSlot:slot];
        if (slot == SCPSlotLeft) [SCPPrefs setLeftApp:bid]; else [SCPPrefs setRightApp:bid];
    }
}

- (void)showDropZones:(BOOL)show
{
    UIView *z1 = [self.pickerView viewWithTag:91], *z2 = [self.pickerView viewWithTag:92];
    if (!show) { [z1 removeFromSuperview]; [z2 removeFromSuperview]; return; }
    CGSize s = self.pickerView.bounds.size;
    BOOL v = [self vertical];
    CGRect r1 = v ? CGRectMake(0, 0, s.width, s.height / 2) : CGRectMake(0, 0, s.width / 2, s.height);
    CGRect r2 = v ? CGRectMake(0, s.height / 2, s.width, s.height / 2) : CGRectMake(s.width / 2, 0, s.width / 2, s.height);
    NSArray *specs = @[@[@91, [NSValue valueWithCGRect:r1], v ? @"Thả: ngăn TRÊN" : @"Thả: ngăn TRÁI"],
                       @[@92, [NSValue valueWithCGRect:r2], v ? @"Thả: ngăn DƯỚI" : @"Thả: ngăn PHẢI"]];
    for (NSArray *sp in specs) {
        UIView *z = [[UIView alloc] initWithFrame:[sp[1] CGRectValue]];
        z.tag = [sp[0] integerValue];
        z.backgroundColor = [UIColor colorWithRed:0.2 green:0.4 blue:0.9 alpha:0.18];
        z.layer.borderColor = [UIColor colorWithRed:0.3 green:0.5 blue:1 alpha:0.7].CGColor;
        z.layer.borderWidth = 2;
        z.userInteractionEnabled = NO;
        UILabel *l = [[UILabel alloc] initWithFrame:z.bounds];
        l.text = sp[2]; l.textColor = [UIColor whiteColor]; l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [z addSubview:l];
        [self.pickerView insertSubview:z belowSubview:self.dragImage];
    }
}

- (void)highlightDropZoneAt:(CGPoint)p
{
    CGSize s = self.pickerView.bounds.size;
    BOOL first = [self vertical] ? (p.y < s.height / 2) : (p.x < s.width / 2);
    [self.pickerView viewWithTag:91].backgroundColor = [UIColor colorWithRed:0.2 green:0.4 blue:0.9 alpha:(first ? 0.45 : 0.15)];
    [self.pickerView viewWithTag:92].backgroundColor = [UIColor colorWithRed:0.2 green:0.4 blue:0.9 alpha:(first ? 0.15 : 0.45)];
}

- (void)pickerCancelTapped
{
    if (self.panes.count == 0) {
        if (self.onMainScreen) return;   // che do thu: khong co gi de quay ve, giu bang chon
        [self dismiss];                  // tren xe: khong con app -> dong split
        return;
    }
    [self hideAppPicker];
}

- (void)hideAppPicker
{
    [self.dragImage removeFromSuperview]; self.dragImage = nil;
    BOOL hadPicker = (self.pickerView != nil);
    UIView *pv = self.pickerView;
    self.pickerView = nil;
    if (pv) [UIView animateWithDuration:0.18 animations:^{ pv.alpha = 0; pv.transform = CGAffineTransformMakeTranslation(0, 16); }
                            completion:^(BOOL f) { [pv removeFromSuperview]; }];
    BOOL wasPending = (self.pendingSlot != SCPSlotAuto);
    self.pendingSlot = SCPSlotAuto;
    // Huy khi dang cho chon app -> ngan con lai tro ve het man (hoac giu split neu da mo du 2); hoac chi hien lai nut chia doi
    if (wasPending) [self animateLayout:^{ [self relayoutPanes]; } completion:nil];
    else if (hadPicker) [self updatePaneActionStates];
}

// ---------------------------------------------------------------------
//  Chan doan
// ---------------------------------------------------------------------
- (void)logDiagnostics
{
    UIWindow *w = self.rootWindow;
    if (!w) return;
    SCPLog("DIAG window hidden=%d alpha=%.2f level=%.0f scene=%@ screen=%@",
           w.hidden, w.alpha, w.windowLevel, w.windowScene, w.screen);
    for (SCPAppPane *p in self.panes) {
        id appVC = p.appViewController;
        id appView = objcInvoke(appVC, @"appView");
        long long mode = objcInvokeT(appView, @"displayMode", long long);
        id scene  = objcInvoke(objcInvoke(appVC, @"sceneHandle"), @"sceneIfExists");
        id settings = objcInvoke(scene, @"settings");
        BOOL fg = settings ? objcInvokeT(settings, @"isForeground", BOOL) : NO;
        SCPLog("DIAG pane %@: container=%@ displayMode=%lld scene=%@ foreground=%d",
               p.bundleIdentifier, NSStringFromCGRect(p.containerView.frame), mode, scene ? @"yes" : @"nil", fg);
    }
}

// ---------------------------------------------------------------------
//  Mo app vao ngan
// ---------------------------------------------------------------------
- (void)launchPairLeft:(NSString *)left right:(NSString *)right
{
    if (left)  [self launchApp:left  inSlot:SCPSlotLeft];
    if (right) [self launchApp:right inSlot:SCPSlotRight];
}

- (void)applyFavorite:(NSInteger)index
{
    NSDictionary *fav = [SCPPrefs favorite:index];
    if (!fav) { SCPLog("cap yeu thich %ld chua dat", (long)index); return; }
    SCPLog("mo cap yeu thich %ld: %@", (long)index, fav);
    self.fullscreenSlot = SCPSlotAuto; self.pipSlot = SCPSlotAuto;
    [self launchPairLeft:fav[@"left"] right:fav[@"right"]];
}

- (void)launchApp:(NSString *)bundleID inSlot:(SCPSlot)slot
{
    if (slot == SCPSlotAuto) slot = self.leftPane ? SCPSlotRight : SCPSlotLeft;
    for (SCPAppPane *p in self.panes) {
        if ([p.bundleIdentifier isEqualToString:bundleID]) { SCPLog("%@ da dang mo", bundleID); return; }
    }
    [self closeSlot:slot];

    SCPAppPane *pane = [SCPAppPane new];
    pane.bundleIdentifier = bundleID;
    pane.orientation = (int)[SCPPrefs paneOrientation];

    pane.application = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"),
                                    @"applicationWithBundleIdentifier:", bundleID);
    expectClass(pane.application, "SBApplication");

    pane.containerView = [[UIView alloc] initWithFrame:[self frameForSlot:slot]];
    pane.containerView.backgroundColor = [UIColor blackColor];
    pane.containerView.clipsToBounds = YES;
    [self.rootWindow insertSubview:pane.containerView belowSubview:self.dividerView];

    @try {
        [self setupLiveAppViewForPane:pane];
    } @catch (NSException *e) {
        SCPLog("setupLiveAppView that bai: %@", e);
        [pane.containerView removeFromSuperview];
        return;
    }

    if (slot == SCPSlotLeft) self.leftPane = pane; else self.rightPane = pane;
    [self setupActionsForPane:pane];   // vien + dau "..." + thanh option rieng cua ngan
    if (slot == SCPSlotRight) {
        [self.rightHistory removeObject:bundleID];
        [self.rightHistory addObject:bundleID];
        UISwipeGestureRecognizer *sl = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(rightSwiped:)];
        sl.direction = UISwipeGestureRecognizerDirectionLeft; sl.numberOfTouchesRequired = 2;
        UISwipeGestureRecognizer *sr = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(rightSwiped:)];
        sr.direction = UISwipeGestureRecognizerDirectionRight; sr.numberOfTouchesRequired = 2;
        [pane.containerView addGestureRecognizer:sl];
        [pane.containerView addGestureRecognizer:sr];
    }
    [self relayoutPanes];
    [self applyPairRatioIfAny];
    if (self.pickerView) [self.rootWindow bringSubviewToFront:self.pickerView];
    // Ngan moi: hien len bang fade + phong nhe tu 94% (lo xo)
    pane.containerView.alpha = 0; pane.containerView.transform = CGAffineTransformMakeScale(0.94, 0.94);
    [UIView animateWithDuration:0.5 delay:0.05 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ pane.containerView.alpha = 1; pane.containerView.transform = CGAffineTransformIdentity; } completion:nil];
    SCPLog("da mo %@ vao ngan %d", bundleID, (int)slot);
    if (slot == SCPSlotRight) [self mirrorRightPaneIfEnabled];
}

// Vuot 2 ngon tren ngan phai: chuyen qua lai cac app da mo o ngan phai (chong app)
- (void)rightSwiped:(UISwipeGestureRecognizer *)g
{
    NSArray *stack = [self.rightHistory copy];
    if (stack.count < 2 || !self.rightPane) return;
    NSInteger idx = [stack indexOfObject:self.rightPane.bundleIdentifier];
    if (idx == NSNotFound) idx = stack.count - 1;
    NSInteger next = (g.direction == UISwipeGestureRecognizerDirectionLeft) ? (idx + 1) % stack.count : (idx - 1 + stack.count) % stack.count;
    NSString *bid = stack[next];
    SCPLog("vuot -> %@", bid);
    [self launchApp:bid inSlot:SCPSlotRight];
    // giu thu tu chong app, khong day len cuoi
    [self.rightHistory removeAllObjects];
    [self.rightHistory addObjectsFromArray:stack];
    [SCPPrefs setRightApp:bid];
}

// Port tu CRCarplayWindow -setupLiveAppView (selector iOS 16.x)
- (void)setupLiveAppViewForPane:(SCPAppPane *)pane
{
    NSString *appID = pane.bundleIdentifier;
    [lockAssertions() addObject:appID];

    id sceneManager = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    expectClass(sceneManager, "SBMainDisplaySceneManager");

    id layoutStateManager = objcInvoke(sceneManager, @"layoutStateManager");
    id displayIdentity    = objcInvoke(sceneManager, @"displayIdentity");
    expectClass(displayIdentity, "FBSDisplayIdentity");

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

    NSMutableSet *transitions = getIvar(appVC, @"_activeTransitions");
    __weak SCPSplitWindow *weakSelf = self;
    objcInvoke_1(transaction, @"setCompletionBlock:", ^(int result) {
        [transitions removeObject:transaction];
        id launchTx = getIvar(transaction, @"_processLaunchTransaction");
        id process  = objcInvoke(launchTx, @"process");
        if (!process) { SCPLog("khong co FBProcess sau launch (result=%d)", result); return; }
        void (^afterLaunch)(void) = ^{
            [weakSelf postOrientationToPane:pane];
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf layoutPane:pane]; });
        };
        objcInvoke_1(process, @"_executeBlockAfterLaunchCompletes:", afterLaunch);
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

    NSString *sceneID = objcInvoke_3(layoutStateManager, @"primarySceneIdentifierForBundleIdentifier:sceneSessionRole:displayIdentity:",
                                     appID, UIWindowSceneSessionRoleApplication, displayIdentity);
    if (sceneID) {
        pane.sceneMonitor = objcInvoke_1([objc_getClass("FBSceneMonitor") alloc], @"initWithSceneID:", sceneID);
        objcInvoke_1(pane.sceneMonitor, @"setDelegate:", self);
    }
}

// Resize scene cua app theo dung kich thuoc ngan (app tu layout lai, khong scale)
- (void)layoutPane:(SCPAppPane *)pane
{
    [self layoutPane:pane live:NO];
}

// Gui huong cua ngan + huong "thiet bi" (theo hinh dang ngan) sang app
- (void)postOrientationToPane:(SCPAppPane *)pane
{
    if (!pane.bundleIdentifier) return;
    NSDictionary *info = @{@"orientation": @(pane.orientation), @"device": @([self deviceOrientationForPane:pane])};
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        postNotificationName:SCP_NOTIF_ORIENTATION object:pane.bundleIdentifier userInfo:info];
}

// Huong "thiet bi" bao cho app: ngan rong hon cao -> ngang (3), nguoc lai -> doc (1)
- (int)deviceOrientationForPane:(SCPAppPane *)pane
{
    CGSize sz = pane.containerView.bounds.size;
    int o = (sz.width > sz.height) ? 3 : 1;
    if (pane.reportedDeviceOrientation == 0) pane.reportedDeviceOrientation = o;
    return o;
}

// live=YES: dang keo thanh phan cach -> chi doi khung container, resize scene khi tha tay
- (void)layoutPane:(SCPAppPane *)pane live:(BOOL)live
{
    if (!pane.appViewController || live) return;
    id deviceAppVC = getIvar(pane.appViewController, @"_deviceAppViewController");
    id sceneView   = getIvar(deviceAppVC, @"sceneView");
    UIView *hostingContentView = getIvar(sceneView, @"_sceneContentContainerView");
    if (!hostingContentView) { SCPLog("chua co _sceneContentContainerView"); return; }

    CGSize paneSize = pane.containerView.bounds.size;
    if (paneSize.width < 1) return;
    // Hinh dang ngan doi (rong <-> cao) -> bao lai cho app "thiet bi" dang ngang/doc. YouTube dua vao day de chon
    // fullscreen ngang (video lap day) hay fullscreen doc (video co dai den).
    int devO = [self deviceOrientationForPane:pane];
    if (devO != pane.reportedDeviceOrientation && pane.reportedDeviceOrientation != 0) {
        pane.reportedDeviceOrientation = devO;
        [self postOrientationToPane:pane];
    }
    [pane.appViewController view].frame = CGRectMake(0, 0, paneSize.width, paneSize.height);
    hostingContentView.transform = CGAffineTransformIdentity;

    id scene = objcInvoke(objcInvoke(pane.appViewController, @"sceneHandle"), @"sceneIfExists");
    if (scene) {
        // Huong giao dien dat thang vao scene settings: app xin/chi cho phep huong khac thi theo app, khong thi theo ngan.
        // Day la duong UIKit thuc su nghe theo (hook trong app khong du).
        long long orient = pane.requestedOrientation > 0 ? pane.requestedOrientation : pane.orientation;
        // Khung scene tinh theo toa do DOC cua man hinh: giao dien ngang thi UIKit tu hoan doi rong/cao,
        // nen phai gui (cao x rong) de cua so app ra dung (rong x cao) cua ngan -> khong bi scale sai.
        BOOL landscape = (orient == UIInterfaceOrientationLandscapeLeft || orient == UIInterfaceOrientationLandscapeRight);
        CGRect target = landscape ? CGRectMake(0, 0, paneSize.height, paneSize.width) : CGRectMake(0, 0, paneSize.width, paneSize.height);
        objcInvoke_1(scene, @"updateSettingsWithBlock:", ^(id settings) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, NSSelectorFromString(@"setFrame:"), target);
            if (orient > 0 && [settings respondsToSelector:NSSelectorFromString(@"setInterfaceOrientation:")])
                ((void (*)(id, SEL, long long))objc_msgSend)(settings, NSSelectorFromString(@"setInterfaceOrientation:"), orient);
        });
    }
}

// App bao vua doi yeu cau xoay (o: huong muon, 0 = ve huong ngan, 0xFF = chi lay lai). Tim ngan theo hash bundle id,
// roi "lay" scene: gui settings voi khung lech 1pt, ngay sau do gui lai khung dung -> UIKit trong app tinh lai huong
// theo app (dung nhu luc keo num chia). Chi dat interfaceOrientation khi app xin huong cu the.
- (void)appOrientationChangedWithHash:(uint64_t)bundleHash orientation:(int)orientation supportedMask:(NSUInteger)mask
{
    for (SCPAppPane *p in self.panes) {
        if (SCPBundleHash(p.bundleIdentifier) != bundleHash) continue;
        int want = 0;
        if (orientation != 0xFF) want = orientation;
        else if (mask && !(mask & UIInterfaceOrientationMaskPortrait)) {
            // App khong con cho phep doc (fullscreen video) -> xoay scene sang huong no cho phep
            if (mask & UIInterfaceOrientationMaskLandscapeLeft)       want = UIInterfaceOrientationLandscapeLeft;
            else if (mask & UIInterfaceOrientationMaskLandscapeRight) want = UIInterfaceOrientationLandscapeRight;
            else if (mask & UIInterfaceOrientationMaskPortraitUpsideDown) want = UIInterfaceOrientationPortraitUpsideDown;
        }
        p.requestedOrientation = want;
        SCPLog("%@ doi yeu cau xoay (ma %d, mask %lu) -> scene huong %d", p.bundleIdentifier, orientation, (unsigned long)mask, want);
        [self nudgePane:p];
        return;
    }
    SCPLog("apporient: khong tim thay ngan cho hash %llu (panes: %@)", (unsigned long long)bundleHash,
           [[self.panes valueForKey:@"bundleIdentifier"] componentsJoinedByString:@","]);
}

- (void)nudgePane:(SCPAppPane *)pane
{
    id scene = objcInvoke(objcInvoke(pane.appViewController, @"sceneHandle"), @"sceneIfExists");
    if (!scene) return;
    CGSize sz = pane.containerView.bounds.size;
    long long o = pane.requestedOrientation > 0 ? pane.requestedOrientation : pane.orientation;
    BOOL landscape = (o == UIInterfaceOrientationLandscapeLeft || o == UIInterfaceOrientationLandscapeRight);
    CGRect off = landscape ? CGRectMake(0, 0, sz.height, MAX(1, sz.width - 1)) : CGRectMake(0, 0, sz.width, MAX(1, sz.height - 1));
    objcInvoke_1(scene, @"updateSettingsWithBlock:", ^(id settings) {
        ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, NSSelectorFromString(@"setFrame:"), off);
    });
    __weak SCPSplitWindow *weakSelf = self;
    __weak SCPAppPane *weakPane = pane;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakPane) [weakSelf layoutPane:weakPane];
    });
}

// ---------------------------------------------------------------------
//  Mirror ngan phai tren iPhone (thu nghiem): host cung scene them 1 lan nua
// ---------------------------------------------------------------------
- (void)mirrorRightPaneIfEnabled
{
    if (self.onMainScreen || ![SCPPrefs mirrorRight] || !self.rightPane) return;
    [self teardownMirror];
    @try {
        id sceneHandle = objcInvoke(self.rightPane.appViewController, @"sceneHandle");
        id entity = objcInvoke_1([objc_getClass("SBDeviceApplicationSceneEntity") alloc], @"initWithApplicationSceneHandle:", sceneHandle);
        id vc = objcInvoke_2([objc_getClass("SBAppViewController") alloc], @"initWithIdentifier:andApplicationSceneEntity:",
                             self.rightPane.bundleIdentifier, entity);
        expectClass(vc, "SBAppViewController");
        objcInvoke_1(vc, @"setIgnoresOcclusions:", 0);
        setIvar(vc, @"_currentMode", @(2));
        objcInvoke(vc, @"_createSceneViewController");
        id appView = objcInvoke(vc, @"appView");
        objcInvoke_3(appView, @"setDisplayMode:animationFactory:completion:", 4, (id)nil, (void *)0);

        UIWindow *w = SCPMakePhoneWindow(NO);
        UIView *v = [vc view];
        v.frame = w.bounds;
        [w addSubview:v];
        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        [close setTitle:@"Đóng mirror" forState:UIControlStateNormal];
        close.frame = CGRectMake(0, w.bounds.size.height - 50, w.bounds.size.width, 44);
        close.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        [close addTarget:self action:@selector(teardownMirror) forControlEvents:UIControlEventTouchUpInside];
        [w addSubview:close];
        w.hidden = NO;
        self.mirrorWindow = w;
        self.mirrorVC = vc;
        SCPLog("mirror ngan phai tren iPhone: %@", self.rightPane.bundleIdentifier);
    } @catch (NSException *e) {
        SCPLog("mirror that bai: %@", e);
        [self teardownMirror];
    }
}

- (void)teardownMirror
{
    if (self.mirrorVC) {
        [[self.mirrorVC view] removeFromSuperview];
        objcInvoke_1(self.mirrorVC, @"_setCurrentMode:", 0);
        if ([self.mirrorVC respondsToSelector:@selector(invalidate)]) objcInvoke(self.mirrorVC, @"invalidate");
        self.mirrorVC = nil;
    }
    self.mirrorWindow.hidden = YES;
    [self.mirrorWindow removeFromSuperview];
    self.mirrorWindow = nil;
}

// ---------------------------------------------------------------------
//  Dong ngan / doi cho / dong tat ca
// ---------------------------------------------------------------------
- (void)teardownPane:(SCPAppPane *)pane
{
    if (!pane) return;
    if (pane == self.rightPane) [self teardownMirror];
    [pane.actionsHideTimer invalidate]; pane.actionsHideTimer = nil;
    [pane.sceneMonitor invalidate];
    NSString *appID = pane.bundleIdentifier;

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        postNotificationName:SCP_NOTIF_ORIENTATION object:appID userInfo:@{@"orientation": @(-1)}];

    objcInvoke_1(pane.appViewController, @"_setCurrentMode:", 0);
    [lockAssertions() removeObject:appID];
    // SBAppViewController la BSInvalidatable: dealloc ma chua invalidate -> assertion crash SpringBoard
    [[pane.appViewController view] removeFromSuperview];
    if ([pane.appViewController respondsToSelector:@selector(invalidate)]) {
        objcInvoke(pane.appViewController, @"invalidate");
    }

    id appScene = objcInvoke(objcInvoke(pane.appViewController, @"sceneHandle"), @"sceneIfExists");
    if (appScene) {
        id frontmost = objcInvoke([UIApplication sharedApplication], @"_accessibilityFrontMostApplication");
        BOOL onMainScreen = frontmost && [objcInvoke(frontmost, @"bundleIdentifier") isEqualToString:appID];
        if (!onMainScreen) {
            objcInvoke_1(appScene, @"updateSettingsWithBlock:", ^(id settings) {
                objcInvoke_1(settings, @"setBackgrounded:", 1);
                objcInvoke_1(settings, @"setForeground:", 0);
            });
        }
    }
    [pane.containerView removeFromSuperview];
}

// Tat han process cua app (khi nguoi dung bam X). Bo qua neu app do dang mo tren man iPhone.
static void SCPTerminateApp(NSString *bid)
{
    if (!bid) return;
    id frontmost = objcInvoke([UIApplication sharedApplication], @"_accessibilityFrontMostApplication");
    if (frontmost && [objcInvoke(frontmost, @"bundleIdentifier") isEqualToString:bid]) {
        SCPLog("%@ dang mo tren iPhone, khong kill", bid);
        return;
    }
    id svc = objcInvoke(objc_getClass("FBSSystemService"), @"sharedService");
    SEL sel = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
    if (svc && [svc respondsToSelector:sel]) {
        ((void (*)(id, SEL, id, long long, BOOL, id))objc_msgSend)(svc, sel, bid, 1, NO, @"SplitCarPlay: user closed pane");
        SCPLog("terminate %@ (FBSSystemService)", bid);
        return;
    }
    void (*fn)(NSString *, int, BOOL, NSString *) =
        (void (*)(NSString *, int, BOOL, NSString *))dlsym(RTLD_DEFAULT, "BKSTerminateApplicationForReasonAndReportWithDescription");
    if (fn) { fn(bid, 1, NO, @"SplitCarPlay"); SCPLog("terminate %@ (BKS)", bid); }
    else SCPLog("khong tim thay API terminate cho %@", bid);
}

- (void)closeSlot:(SCPSlot)slot
{
    [self closeSlot:slot terminate:NO];
}

- (void)closeSlot:(SCPSlot)slot terminate:(BOOL)terminate
{
    SCPAppPane *pane = (slot == SCPSlotLeft) ? self.leftPane : self.rightPane;
    if (!pane) return;
    NSString *bid = pane.bundleIdentifier;
    [self teardownPane:pane];
    if (slot == SCPSlotLeft) self.leftPane = nil; else self.rightPane = nil;
    if (terminate) {
        [self.rightHistory removeObject:bid];
        SCPTerminateApp(bid);
    }
    BOOL changed = NO;
    if (self.fullscreenSlot == slot) { self.fullscreenSlot = SCPSlotAuto; changed = YES; }
    if (self.pipSlot == slot)        { self.pipSlot = SCPSlotAuto; changed = YES; }
    if (changed) [self relayoutPanes];
}

- (void)swapPanes
{
    SCPAppPane *l = self.leftPane, *r = self.rightPane;
    self.leftPane = r; self.rightPane = l;
    if (self.fullscreenSlot == SCPSlotLeft) self.fullscreenSlot = SCPSlotRight;
    else if (self.fullscreenSlot == SCPSlotRight) self.fullscreenSlot = SCPSlotLeft;
    if (self.pipSlot == SCPSlotLeft) self.pipSlot = SCPSlotRight;
    else if (self.pipSlot == SCPSlotRight) self.pipSlot = SCPSlotLeft;
    [self animateLayout:^{ [self relayoutPanes]; } completion:nil];
}

- (void)dismiss
{
    SCPLog("dismiss split window");
    [self.dividerMenuTimer invalidate]; self.dividerMenuTimer = nil;
    [self.dividerMenu removeFromSuperview]; self.dividerMenu = nil;
    [self hideAppPicker];
    [self teardownMirror];
    [self closeSlot:SCPSlotLeft];
    [self closeSlot:SCPSlotRight];

    id app = [UIApplication sharedApplication];
    // Tren xe: neu iPhone dang khoa va den nen da tat thi tra man ve trang thai tat (carplay-cast).
    // Che do thu tren iPhone: tuyet doi khong dong vao den nen, neu khong man den va ket.
    if (!self.onMainScreen && objcInvokeT(app, @"isLocked", BOOL)) {
        void *fn = dlsym(RTLD_DEFAULT, "BKSHIDServicesGetBacklightFactor");
        if (fn && orig_BKSDisplayServicesSetScreenBlanked) {
            float backlight = ((float (*)(void))fn)();
            if (backlight < 0.2) orig_BKSDisplayServicesSetScreenBlanked(1);
        }
    }

    objc_setAssociatedObject(app, kSCPKey_splitWindow, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIWindow *w = self.rootWindow;
    w.userInteractionEnabled = NO;   // khong nuot cham trong luc mo dan
    void (^finish)(void) = ^{ if (w.hidden) return; w.hidden = YES; [w removeFromSuperview]; };
    [UIView animateWithDuration:0.3 animations:^{ w.alpha = 0; } completion:^(BOOL done) { finish(); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), finish);   // phong khi completion khong chay
    self.rootWindow = nil;

    // Che do thu: ep SpringBoard ve man hinh chinh, phong khi no coi app vua host la app dang mo (man den)
    if (self.onMainScreen) {
        SEL homeSel = NSSelectorFromString(@"_simulateHomeButtonPressWithCompletion:");
        if ([app respondsToSelector:homeSel]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SCPLog("demo: ve home");
                ((void (*)(id, SEL, id))objc_msgSend)(app, homeSel, nil);
            });
        }
    }

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        postNotificationName:SCP_NOTIF_SPLIT_CLOSED object:nil userInfo:nil];
}

@end

// =====================================================================
//  SCPLauncherButton: nut tron nho tren man CarPlay -> mo split + bang chon app
// =====================================================================
static UIWindow *sLauncherWindow = nil;

@implementation SCPLauncherButton

+ (void)showOnCarDisplay
{
    if (sLauncherWindow) return;
    UIWindow *w = SCPMakeCarWindow();
    if (!w) return;
    CGRect screen = w.frame;
    CGFloat size = 44;
    w.frame = CGRectMake(screen.size.width - size - 10, 10, size, size);
    w.windowLevel = UIWindowLevelStatusBar + 60;
    w.backgroundColor = [UIColor clearColor];

    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, size, size);
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    b.layer.cornerRadius = size / 2;
    b.layer.borderWidth = 1.5;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
    id cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    [b setImage:[UIImage systemImageNamed:@"rectangle.split.2x1" withConfiguration:cfg] forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    [b addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [w addSubview:b];

    w.hidden = NO;
    sLauncherWindow = w;
    SCPLog("launcher button hien tren man xe tai %@", NSStringFromCGRect(w.frame));
}

+ (void)hide
{
    sLauncherWindow.hidden = YES;
    [sLauncherWindow removeFromSuperview];
    sLauncherWindow = nil;
}

+ (void)tapped
{
    SCPLog("launcher tapped");
    SCPSplitWindow *w = [SCPSplitWindow currentOrCreate];
    if (!w) return;
    [w showAppPickerForSlot:SCPSlotLeft];
}

@end
