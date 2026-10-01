#import "SCPSplitWindow.h"
#import "SCPPrefs.h"

// =====================================================================
//  SCPSplitWindow - cua so tren man CarPlay, host 2 app cua iPhone
//  Co che: port tu carplay-cast (EthanArbuckle) - iOS 14, chinh cho 16.x + ARC
// =====================================================================

int (*orig_BKSDisplayServicesSetScreenBlanked)(int) = NULL;
const void *kSCPKey_splitWindow   = &kSCPKey_splitWindow;
const void *kSCPKey_lockAssertions = &kSCPKey_lockAssertions;

#define SCP_DIVIDER_WIDTH 6.0      // khe mong giua 2 ngan (ngan da co vien), vung cham de keo rong hon
#define SCP_DIVIDER_HIT   14.0     // mo rong vung cham moi ben
#define SCP_PIP_SCALE     0.36

// Khe phan cach mong nhung van de keo: nhan cham trong pham vi rong hon kich thuoc that
@interface SCPDividerView : UIView
@end
@implementation SCPDividerView
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e
{
    return CGRectContainsPoint(CGRectInset(self.bounds, -SCP_DIVIDER_HIT, -SCP_DIVIDER_HIT), p);
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
@property (nonatomic, strong) UIView *pickerView;
@property (nonatomic, strong) UIImageView *dragImage;
@property (nonatomic, strong) NSString *dragBundleID;
@property (nonatomic) SCPSlot pickerSlot;
@property (nonatomic) CGPoint pipOrigin;              // goc PiP trong vung ngan (ti le 0..1)
@property (nonatomic, strong) NSMutableArray<NSString *> *rightHistory;   // chong app ngan phai (vuot 2 ngon)
@property (nonatomic, strong) UIWindow *mirrorWindow;  // mirror ngan phai tren iPhone (thu nghiem)
@property (nonatomic, strong) id mirrorVC;
@property (nonatomic, strong) UILabel *debugLabel;
@property (nonatomic, strong) id logObserver;
- (instancetype)initOnMainScreen:(BOOL)mainScreen;
- (void)setupActionsForPane:(SCPAppPane *)pane;
- (void)layoutActionsForPane:(SCPAppPane *)pane;
- (void)setActionsVisible:(BOOL)visible forPane:(SCPAppPane *)pane animated:(BOOL)animated;
- (void)scheduleActionsHideForPane:(SCPAppPane *)pane;
- (void)hideAllPaneActions;
- (SCPAppPane *)paneForView:(UIView *)v;
- (SCPSlot)slotForPane:(SCPAppPane *)pane;
- (void)bringChromeToFront;
- (void)setupDivider;
- (void)setupDebugOverlay;
- (void)refreshDebugOverlay;
- (void)logDiagnostics;
- (void)relayoutPanes;
- (void)relayoutPanesLive:(BOOL)live;
- (void)layoutPane:(SCPAppPane *)pane;
- (void)layoutPane:(SCPAppPane *)pane live:(BOOL)live;
- (void)layoutPipHandleForPane:(SCPAppPane *)pane;
- (CGRect)frameForSlot:(SCPSlot)slot;
- (CGRect)dividerFrame;
- (CGRect)pickerFrame;
- (CGRect)paneArea;
- (BOOL)vertical;
- (void)saveRatio;
- (void)applyPairRatioIfAny;
- (void)updatePaneActionStates;
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
    self.pipOrigin = CGPointMake(1, 1);   // goc duoi-phai
    self.rightHistory = [NSMutableArray array];

    if (mainScreen) {
        self.rootWindow = SCPMakePhoneWindow(YES);
        // An toan: tu dong dong sau 120s de khong bi ket
        __weak SCPSplitWindow *weakSelfTest = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SCPSplitWindow *s = weakSelfTest;
            if (s && s.onMainScreen && [SCPSplitWindow current] == s) { SCPLog("test window auto-close"); [s dismiss]; }
        });
        SCPLog("TEST window tren man chinh, bounds=%@", NSStringFromCGRect(self.rootWindow.bounds));
    } else {
        self.rootWindow = SCPMakeCarWindow();
        if (!self.rootWindow) return nil;
        SCPLog("root window tren man xe frame=%@ screen=%@", NSStringFromCGRect(self.rootWindow.frame), self.rootWindow.screen);
    }

    self.rootWindow.backgroundColor = [UIColor colorWithRed:0.02 green:0.03 blue:0.08 alpha:1];
    [self setupDivider];
    [self setupDebugOverlay];

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

// Nut tron 32pt nen trang mo, symbol 14pt semibold - dong bo cho moi nut tren bar
#define SCP_ACTION_BTN 32.0
static id SCPActionSymbolConfig(void)
{
    static id cfg;
    if (!cfg) cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold scale:UIImageSymbolScaleMedium];
    return cfg;
}

- (UIButton *)actionButton:(NSString *)symbol action:(SEL)sel inBar:(UIScrollView *)bar
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:SCPActionSymbolConfig()] forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    b.layer.cornerRadius = SCP_ACTION_BTN / 2;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [b addTarget:self action:@selector(actionButtonTouched:) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:b];
    return b;
}

- (void)setupActionsForPane:(SCPAppPane *)pane
{
    // Vien quanh app
    pane.containerView.layer.borderWidth = SCP_PANE_BORDER;
    pane.containerView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    pane.containerView.layer.cornerRadius = 10;

    // Dau "..." o giua mep tren (SF Symbol ellipsis tren nen toi mo, bo goc duoi)
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, SCP_PANE_HANDLE_WIDTH, SCP_PANE_HANDLE_HEIGHT)];
    h.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    h.layer.cornerRadius = SCP_PANE_HANDLE_HEIGHT / 2;
    h.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    id dotsCfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
    UIImageView *dots = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:dotsCfg]];
    dots.tintColor = [UIColor colorWithWhite:1 alpha:0.9];
    dots.contentMode = UIViewContentModeCenter;
    dots.frame = h.bounds;
    dots.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dots.userInteractionEnabled = NO;
    [h addSubview:dots];
    [h addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(paneActionsPanned:)]];
    [h addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(paneHandleTapped:)]];
    pane.actionHandle = h;
    [pane.containerView addSubview:h];

    // Thanh nut (cuon ngang neu ngan hep)
    UIScrollView *bar = [[UIScrollView alloc] initWithFrame:CGRectMake(0, -SCP_PANE_BAR_HEIGHT, pane.containerView.bounds.size.width, SCP_PANE_BAR_HEIGHT)];
    bar.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.9];
    bar.layer.cornerRadius = 10;
    bar.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    bar.showsHorizontalScrollIndicator = NO;
    bar.alwaysBounceHorizontal = NO;
    [bar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(paneActionsPanned:)]];
    pane.actionBar = bar;
    pane.actionsVisible = NO;
    [pane.containerView addSubview:bar];

    CGFloat sz = SCP_ACTION_BTN, y = (SCP_PANE_BAR_HEIGHT - sz) / 2, x = 8, step = sz + 6;
    UIButton *b;
    b = [self actionButton:@"square.grid.2x2.fill" action:@selector(paneChooseApp:) inBar:bar];      b.frame = CGRectMake(x, y, sz, sz); x += step;
    b = [self actionButton:@"xmark" action:@selector(paneCloseApp:) inBar:bar];                      b.frame = CGRectMake(x, y, sz, sz); x += step;
    pane.fullscreenButton = [self actionButton:@"arrow.up.left.and.arrow.down.right" action:@selector(paneToggleFullscreen:) inBar:bar];
    pane.fullscreenButton.frame = CGRectMake(x, y, sz, sz); x += step;
    pane.pipButton = [self actionButton:@"pip" action:@selector(paneTogglePiP:) inBar:bar];
    pane.pipButton.frame = CGRectMake(x, y, sz, sz); x += step;
    b = [self actionButton:@"arrow.left.arrow.right" action:@selector(paneSwap:) inBar:bar];         b.frame = CGRectMake(x, y, sz, sz); x += step;
    b = [self actionButton:@"rectangle.lefthalf.inset.filled" action:@selector(paneCycleLayout:) inBar:bar]; b.frame = CGRectMake(x, y, sz, sz); x += step;

    // Vach ngan nho giua nhom nut ngan va nhom cap yeu thich
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(x + 2, (SCP_PANE_BAR_HEIGHT - 18) / 2, 1, 18)];
    sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    [bar addSubview:sep];
    x += 11;

    // Cap yeu thich 1..3: cung kich thuoc, cung nen, chi khac la so thay cho icon
    NSMutableArray *favs = [NSMutableArray array];
    for (NSInteger i = 1; i <= 3; i++) {
        UIButton *f = [UIButton buttonWithType:UIButtonTypeCustom];
        [f setTitle:[NSString stringWithFormat:@"%ld", (long)i] forState:UIControlStateNormal];
        f.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        [f setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
        f.layer.cornerRadius = sz / 2;
        f.frame = CGRectMake(x, y, sz, sz); x += step;
        f.tag = i;
        [f addTarget:self action:@selector(paneFavTapped:) forControlEvents:UIControlEventTouchUpInside];
        [f addTarget:self action:@selector(actionButtonTouched:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:f];
        [favs addObject:f];
    }
    pane.favButtons = favs;
    x += 4;

    // Home = dong split, ve lai dashboard CarPlay
    b = [self actionButton:@"house.fill" action:@selector(dismiss) inBar:bar];
    b.frame = CGRectMake(x, y, sz, sz); b.tag = 1001; x += step + 2;
    bar.contentSize = CGSizeMake(x, SCP_PANE_BAR_HEIGHT);

    [self layoutActionsForPane:pane];
}

// Dat lai khung handle/bar theo kich thuoc ngan (goi moi lan relayout)
- (void)layoutActionsForPane:(SCPAppPane *)pane
{
    if (!pane.actionBar) return;
    CGSize s = pane.containerView.bounds.size;
    BOOL isPip = (self.pipSlot == [self slotForPane:pane]);
    // Dang PiP: mep tren danh cho thanh keo PiP, an option
    pane.actionHandle.hidden = isPip;
    pane.actionBar.hidden = isPip;
    if (isPip && pane.actionsVisible) { pane.actionsVisible = NO; [pane.actionsHideTimer invalidate]; pane.actionsHideTimer = nil; }

    pane.actionHandle.frame = CGRectMake((s.width - SCP_PANE_HANDLE_WIDTH) / 2, 0, SCP_PANE_HANDLE_WIDTH, SCP_PANE_HANDLE_HEIGHT);
    pane.actionHandle.alpha = pane.actionsVisible ? 0 : 1;
    CGRect bf = CGRectMake(0, pane.actionsVisible ? 0 : -SCP_PANE_BAR_HEIGHT, s.width, SCP_PANE_BAR_HEIGHT);
    pane.actionBar.frame = bf;
    // Khi ngan du rong, day nut Home sat mep phai
    UIButton *home = (UIButton *)[pane.actionBar viewWithTag:1001];
    CGFloat natural = pane.actionBar.contentSize.width;
    if (home && s.width > natural) {
        CGRect hf = home.frame; hf.origin.x = s.width - hf.size.width - 8; home.frame = hf;
    } else if (home) {
        CGRect hf = home.frame; hf.origin.x = natural - hf.size.width - 8; home.frame = hf;
    }
    [pane.containerView bringSubviewToFront:pane.actionHandle];
    [pane.containerView bringSubviewToFront:pane.actionBar];
}

- (void)paneActionsPanned:(UIPanGestureRecognizer *)g
{
    SCPAppPane *pane = [self paneForView:g.view];
    if (!pane) return;
    CGFloat ty = [g translationInView:pane.containerView].y;
    CGFloat startY = pane.actionsVisible ? 0 : -SCP_PANE_BAR_HEIGHT;
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        [pane.actionsHideTimer invalidate]; pane.actionsHideTimer = nil;
        CGRect fr = pane.actionBar.frame;
        fr.origin.y = MIN(0, MAX(-SCP_PANE_BAR_HEIGHT, startY + ty));
        pane.actionBar.frame = fr;
        pane.actionHandle.alpha = 1 - (fr.origin.y + SCP_PANE_BAR_HEIGHT) / SCP_PANE_BAR_HEIGHT;
        return;
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat vy = [g velocityInView:pane.containerView].y;
        BOOL show = (vy > 150) || (vy > -150 && CGRectGetMinY(pane.actionBar.frame) > -SCP_PANE_BAR_HEIGHT / 2);
        [self setActionsVisible:show forPane:pane animated:YES];
    }
}

- (void)paneHandleTapped:(UITapGestureRecognizer *)g
{
    SCPAppPane *pane = [self paneForView:g.view];
    if (pane) [self setActionsVisible:!pane.actionsVisible forPane:pane animated:YES];
}

- (void)setActionsVisible:(BOOL)visible forPane:(SCPAppPane *)pane animated:(BOOL)animated
{
    if (!pane.actionBar) return;
    pane.actionsVisible = visible;
    [pane.actionsHideTimer invalidate]; pane.actionsHideTimer = nil;
    [self updatePaneActionStates];
    CGRect fr = pane.actionBar.frame;
    fr.origin.y = visible ? 0 : -SCP_PANE_BAR_HEIGHT;
    void (^apply)(void) = ^{
        pane.actionBar.frame = fr;
        pane.actionHandle.alpha = visible ? 0 : 1;
    };
    if (animated) [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:apply completion:nil];
    else apply();
    if (visible) [self scheduleActionsHideForPane:pane];
}

- (void)scheduleActionsHideForPane:(SCPAppPane *)pane
{
    [pane.actionsHideTimer invalidate];
    if (!pane.actionsVisible) return;
    __weak SCPSplitWindow *weakSelf = self;
    __weak SCPAppPane *weakPane = pane;
    pane.actionsHideTimer = [NSTimer scheduledTimerWithTimeInterval:6 repeats:NO block:^(NSTimer *t) {
        if (weakPane) [weakSelf setActionsVisible:NO forPane:weakPane animated:YES];
    }];
}

- (void)hideAllPaneActions
{
    for (SCPAppPane *p in self.panes) if (p.actionsVisible) [self setActionsVisible:NO forPane:p animated:YES];
}

// Bam nut nao tren bar cung reset bo dem tu an
- (void)actionButtonTouched:(UIButton *)b
{
    SCPAppPane *pane = [self paneForView:b];
    if (pane) [self scheduleActionsHideForPane:pane];
}

// Icon fullscreen / PiP doi theo trang thai, nut cap yeu thich an neu chua dat
- (void)updatePaneActionStates
{
    UIColor *on = [UIColor systemYellowColor], *off = [UIColor whiteColor];
    UIColor *onBg = [[UIColor systemYellowColor] colorWithAlphaComponent:0.22], *offBg = [UIColor colorWithWhite:1 alpha:0.14];
    for (SCPAppPane *p in self.panes) {
        if (!p.actionBar) continue;
        SCPSlot slot = [self slotForPane:p];
        BOOL isFull = (self.fullscreenSlot == slot), isPip = (self.pipSlot == slot);
        [p.fullscreenButton setImage:[UIImage systemImageNamed:(isFull ? @"arrow.down.right.and.arrow.up.left" : @"arrow.up.left.and.arrow.down.right")
                                               withConfiguration:SCPActionSymbolConfig()] forState:UIControlStateNormal];
        p.fullscreenButton.tintColor = isFull ? on : off;
        p.fullscreenButton.backgroundColor = isFull ? onBg : offBg;
        [p.pipButton setImage:[UIImage systemImageNamed:(isPip ? @"pip.exit" : @"pip") withConfiguration:SCPActionSymbolConfig()] forState:UIControlStateNormal];
        p.pipButton.tintColor = isPip ? on : off;
        p.pipButton.backgroundColor = isPip ? onBg : offBg;
        for (UIButton *f in p.favButtons) f.hidden = ([SCPPrefs favorite:f.tag] == nil);
    }
}

// ---- hanh dong tu bar cua ngan ----
- (void)paneChooseApp:(UIButton *)b
{
    SCPAppPane *pane = [self paneForView:b];
    if (!pane) return;
    [self showAppPickerForSlot:[self slotForPane:pane]];
}

- (void)paneCloseApp:(UIButton *)b
{
    SCPAppPane *pane = [self paneForView:b];
    if (!pane) return;
    SCPSlot slot = [self slotForPane:pane];
    [self closeSlot:slot];
    if (self.panes.count == 0) [self showAppPickerForSlot:slot];   // ngan trong het -> chon app moi
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

- (void)paneSwap:(UIButton *)b
{
    [self swapPanes];
}

- (void)paneCycleLayout:(UIButton *)b
{
    [self cycleLayoutPreset];
}

- (void)paneFavTapped:(UIButton *)b
{
    [self applyFavorite:b.tag];
}

// Log overlay luon nam tren cung
- (void)bringChromeToFront
{
    if (self.debugLabel) [self.rootWindow bringSubviewToFront:self.debugLabel];
}

// ---------------------------------------------------------------------
//  Bo cuc: trai/phai hoac tren/duoi, fullscreen, PiP
// ---------------------------------------------------------------------
// Ngan dung het cua so (option cua ngan nam trong chinh ngan do)
- (CGRect)paneArea
{
    return self.rootWindow.bounds;
}

- (CGRect)frameForSlot:(SCPSlot)slot
{
    CGRect a = [self paneArea];
    if (self.fullscreenSlot != SCPSlotAuto) {
        return (slot == self.fullscreenSlot) ? a : CGRectMake(a.origin.x, a.origin.y, 0, 0);
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
    self.dividerView = [[SCPDividerView alloc] initWithFrame:[self dividerFrame]];
    self.dividerView.backgroundColor = [UIColor clearColor];   // chi la khe, ngan da co vien
    self.dividerPill = [[UIView alloc] init];
    self.dividerPill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.5];
    [self.dividerView addSubview:self.dividerPill];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dividerPanned:)];
    [self.dividerView addGestureRecognizer:pan];
    [self.rootWindow addSubview:self.dividerView];
    [self layoutDividerPill];
}

- (void)layoutDividerPill
{
    // Gach nho 3pt o giua khe, dai 36pt
    CGSize s = self.dividerView.bounds.size;
    if ([self vertical]) { self.dividerPill.frame = CGRectMake(s.width / 2 - 18, (s.height - 3) / 2, 36, 3); }
    else                 { self.dividerPill.frame = CGRectMake((s.width - 3) / 2, s.height / 2 - 18, 3, 36); }
    self.dividerPill.layer.cornerRadius = 1.5;
}

- (void)dividerPanned:(UIPanGestureRecognizer *)g
{
    CGPoint p = [g locationInView:self.rootWindow];
    CGRect a = [self paneArea];
    BOOL v = [self vertical];
    CGFloat len = (v ? a.size.height : a.size.width) - SCP_DIVIDER_WIDTH;
    CGFloat pos = v ? (p.y - a.origin.y) : (p.x - a.origin.x);
    CGFloat r = (pos - SCP_DIVIDER_WIDTH / 2) / len;
    r = MIN(0.8, MAX(0.2, r));

    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        for (NSNumber *snap in @[@0.3, @0.5, @0.7]) {
            if (fabs(r - snap.doubleValue) < 0.04) { r = snap.doubleValue; break; }
        }
        self.ratio = r;
        [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            [self relayoutPanesLive:NO];
        } completion:nil];
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
        [UIView animateWithDuration:0.25 animations:^{ [self relayoutPanesLive:NO]; }];
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
    self.dividerView.hidden = special;
    self.dividerView.frame = [self dividerFrame];
    [self layoutDividerPill];
    for (SCPAppPane *p in self.panes) {
        SCPSlot slot = (p == self.leftPane) ? SCPSlotLeft : SCPSlotRight;
        BOOL hidden = (self.fullscreenSlot != SCPSlotAuto && slot != self.fullscreenSlot);
        p.containerView.hidden = hidden;
        if (!hidden) { p.containerView.frame = [self frameForSlot:slot]; [self layoutPane:p live:live]; }
        if (slot == self.pipSlot) [self.rootWindow bringSubviewToFront:p.containerView];
        if (!live) { [self layoutActionsForPane:p]; [self layoutPipHandleForPane:p]; }
    }
    if (self.pickerView) self.pickerView.frame = [self pickerFrame];
    [self bringChromeToFront];
    [self updatePaneActionStates];
}

// ---- bo cuc dat san ----
- (void)applyPresetRatio:(CGFloat)ratio
{
    self.fullscreenSlot = SCPSlotAuto;
    self.pipSlot = SCPSlotAuto;
    self.ratio = MIN(0.8, MAX(0.2, ratio));
    [UIView animateWithDuration:0.25 animations:^{ [self relayoutPanes]; }];
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
    [UIView animateWithDuration:0.25 animations:^{ [self relayoutPanes]; }];
}

// ---- Picture in Picture ----
- (void)togglePiPForSlot:(SCPSlot)slot
{
    SCPAppPane *pane = (slot == SCPSlotLeft) ? self.leftPane : self.rightPane;
    if (!pane && self.pipSlot == SCPSlotAuto) { SCPLog("khong co app o ngan %d de PiP", (int)slot); return; }
    self.fullscreenSlot = SCPSlotAuto;
    self.pipSlot = (self.pipSlot == slot) ? SCPSlotAuto : slot;
    SCPLog("pip slot = %d", (int)self.pipSlot);
    [UIView animateWithDuration:0.25 animations:^{ [self relayoutPanes]; }];
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
    return [self paneArea];
}

- (void)showAppPickerForSlot:(SCPSlot)slot
{
    [self hideAppPicker];
    self.pickerSlot = (slot == SCPSlotRight) ? SCPSlotRight : SCPSlotLeft;

    UIView *pv = [[UIView alloc] initWithFrame:[self pickerFrame]];
    pv.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.97];
    self.pickerView = pv;
    [self.rootWindow addSubview:pv];
    [self hideAllPaneActions];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, pv.bounds.size.width - 120, 30)];
    title.text = (self.pickerSlot == SCPSlotLeft) ? @"Chọn app cho ngăn TRÁI  (giữ icon và kéo để thả vào ngăn)" : @"Chọn app cho ngăn PHẢI";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.adjustsFontSizeToFitWidth = YES;
    [pv addSubview:title];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"Huỷ" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:17];
    cancel.frame = CGRectMake(pv.bounds.size.width - 80, 14, 70, 30);
    [cancel addTarget:self action:@selector(hideAppPicker) forControlEvents:UIControlEventTouchUpInside];
    [pv addSubview:cancel];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 50, pv.bounds.size.width, pv.bounds.size.height - 50)];
    scroll.alwaysBounceVertical = YES;
    scroll.tag = 77;
    [pv addSubview:scroll];

    NSArray *apps = SCPInstalledApps();
    CGFloat cellW = 96, cellH = 92, iconSize = 52;
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
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pickerDrag:)];
        lp.minimumPressDuration = 0.35;
        [b addGestureRecognizer:lp];

        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((cellW - iconSize) / 2, 6, iconSize, iconSize)];
        iv.image = SCPAppIcon(app[@"id"]);
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.layer.cornerRadius = 11; iv.clipsToBounds = YES;
        iv.backgroundColor = iv.image ? [UIColor clearColor] : [UIColor colorWithWhite:0.3 alpha:1];
        iv.userInteractionEnabled = NO;
        iv.tag = 78;
        [b addSubview:iv];

        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(2, iconSize + 10, cellW - 4, 28)];
        l.text = app[@"name"];
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:11];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 2;
        l.userInteractionEnabled = NO;
        [b addSubview:l];

        [scroll addSubview:b];
        i++;
    }
    NSInteger rows = (i + cols - 1) / cols;
    scroll.contentSize = CGSizeMake(scroll.bounds.size.width, 16 + rows * cellH);
    SCPLog("picker: %ld app, slot=%d", (long)i, (int)self.pickerSlot);
}

- (void)pickerAppTapped:(UIButton *)b
{
    NSString *bid = b.accessibilityIdentifier;
    SCPSlot slot = self.pickerSlot;
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

- (void)hideAppPicker
{
    [self.dragImage removeFromSuperview]; self.dragImage = nil;
    [self.pickerView removeFromSuperview];
    self.pickerView = nil;
}

// ---------------------------------------------------------------------
//  Chan doan / overlay log
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

- (void)setupDebugOverlay
{
    if (![SCPPrefs showDebug]) return;
    CGRect a = [self paneArea];
    CGFloat h = MIN(90, a.size.height * 0.3);
    self.debugLabel = [[UILabel alloc] initWithFrame:CGRectMake(a.origin.x, CGRectGetMaxY(a) - h, a.size.width, h)];
    self.debugLabel.numberOfLines = 0;
    self.debugLabel.font = [UIFont monospacedSystemFontOfSize:8 weight:UIFontWeightRegular];
    self.debugLabel.textColor = [UIColor greenColor];
    self.debugLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    self.debugLabel.userInteractionEnabled = NO;
    self.debugLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.rootWindow addSubview:self.debugLabel];
    [self refreshDebugOverlay];
    __weak SCPSplitWindow *weakSelf = self;
    self.logObserver = [[NSNotificationCenter defaultCenter] addObserverForName:SCPLogLineNotification object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [weakSelf refreshDebugOverlay]; }];
}

- (void)refreshDebugOverlay
{
    if (!self.debugLabel) return;
    NSArray *lines = SCPRecentLogLines();
    NSUInteger n = MIN((NSUInteger)10, lines.count);
    self.debugLabel.text = [[lines subarrayWithRange:NSMakeRange(lines.count - n, n)] componentsJoinedByString:@"\n"];
    [self bringChromeToFront];
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
    if (self.pickerView) { [self.rootWindow bringSubviewToFront:self.pickerView]; [self bringChromeToFront]; }
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
    int orientation = pane.orientation;
    objcInvoke_1(transaction, @"setCompletionBlock:", ^(int result) {
        [transitions removeObject:transaction];
        id launchTx = getIvar(transaction, @"_processLaunchTransaction");
        id process  = objcInvoke(launchTx, @"process");
        if (!process) { SCPLog("khong co FBProcess sau launch (result=%d)", result); return; }
        objcInvoke_1(process, @"_executeBlockAfterLaunchCompletes:", ^{
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
    [pane.appViewController view].frame = CGRectMake(0, 0, paneSize.width, paneSize.height);
    hostingContentView.transform = CGAffineTransformIdentity;

    id scene = objcInvoke(objcInvoke(pane.appViewController, @"sceneHandle"), @"sceneIfExists");
    if (scene) {
        CGRect target = CGRectMake(0, 0, paneSize.width, paneSize.height);
        objcInvoke_1(scene, @"updateSettingsWithBlock:", ^(id settings) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, NSSelectorFromString(@"setFrame:"), target);
        });
    }
}

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

- (void)closeSlot:(SCPSlot)slot
{
    SCPAppPane *pane = (slot == SCPSlotLeft) ? self.leftPane : self.rightPane;
    if (!pane) return;
    [self teardownPane:pane];
    if (slot == SCPSlotLeft) self.leftPane = nil; else self.rightPane = nil;
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
    [UIView animateWithDuration:0.25 animations:^{ [self relayoutPanes]; }];
}

- (void)dismiss
{
    SCPLog("dismiss split window");
    [self hideAppPicker];
    [self teardownMirror];
    [self closeSlot:SCPSlotLeft];
    [self closeSlot:SCPSlotRight];

    id app = [UIApplication sharedApplication];
    if (objcInvokeT(app, @"isLocked", BOOL)) {
        void *fn = dlsym(RTLD_DEFAULT, "BKSHIDServicesGetBacklightFactor");
        if (fn && orig_BKSDisplayServicesSetScreenBlanked) {
            float backlight = ((float (*)(void))fn)();
            if (backlight < 0.2) orig_BKSDisplayServicesSetScreenBlanked(1);
        }
    }

    objc_setAssociatedObject(app, kSCPKey_splitWindow, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.logObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.logObserver];
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
