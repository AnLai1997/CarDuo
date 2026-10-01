#import "SCPSplitWindow.h"
#import "SCPPrefs.h"

// =====================================================================
//  SCPSplitWindow - cua so tren man CarPlay, host 2 app cua iPhone
//  Co che: port tu carplay-cast (EthanArbuckle) - iOS 14, chinh cho 16.x + ARC
// =====================================================================

int (*orig_BKSDisplayServicesSetScreenBlanked)(int) = NULL;
const void *kSCPKey_splitWindow   = &kSCPKey_splitWindow;
const void *kSCPKey_lockAssertions = &kSCPKey_lockAssertions;

#define SCP_DIVIDER_WIDTH 14.0

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

// Danh sach app trong may: @{ @"id", @"name" }, app nguoi dung truoc, app Apple sau
static NSArray<NSDictionary *> *SCPInstalledApps(void)
{
    id controller = objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance");
    NSArray *apps = objcInvoke(controller, @"allInstalledApplications");
    NSMutableArray *user = [NSMutableArray array], *system = [NSMutableArray array];
    NSSet *skip = [NSSet setWithArray:@[@"com.apple.springboard", @"com.apple.CarPlayApp", @"com.apple.CarPlaySettings",
                                        @"com.apple.CarPlayTemplateUIHost", @"com.apple.webapp", @"com.apple.Preferences"]];
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
@property (nonatomic, strong) UIButton *homeButton;
@property (nonatomic, strong) UIButton *swapButton;
@property (nonatomic, strong) UIButton *appsButton;
@property (nonatomic, strong) UILabel *clockLabel;
@property (nonatomic, strong) NSTimer *clockTimer;
@property (nonatomic, strong) UIView *dividerView;
@property (nonatomic, strong) UIView *pickerView;
@property (nonatomic) SCPSlot pickerSlot;
@property (nonatomic, strong) UILabel *debugLabel;
@property (nonatomic, strong) id logObserver;
- (instancetype)initOnMainScreen:(BOOL)mainScreen;
- (void)setupDock;
- (void)setupDivider;
- (void)setupDebugOverlay;
- (void)refreshDebugOverlay;
- (void)logDiagnostics;
- (void)relayoutPanes;
- (void)layoutPane:(SCPAppPane *)pane;
- (void)layoutPane:(SCPAppPane *)pane live:(BOOL)live;
- (void)relayoutPanesLive:(BOOL)live;
- (CGRect)frameForSlot:(SCPSlot)slot;
- (CGRect)dividerFrame;
- (CGRect)pickerFrame;
- (CGFloat)paneAreaX;
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

    if (mainScreen) {
        // CHE DO THU: cua so tren man iPhone, xoay ngang de giong man xe
        CGRect sb = [UIScreen mainScreen].bounds;
        UIWindowScene *mainScene = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]] && ((UIWindowScene *)sc).screen == [UIScreen mainScreen]) {
                mainScene = (UIWindowScene *)sc; break;
            }
        }
        if (mainScene) self.rootWindow = [[UIWindow alloc] initWithWindowScene:mainScene];
        else           self.rootWindow = [[UIWindow alloc] initWithFrame:sb];
        self.rootWindow.frame = sb;
        self.rootWindow.windowLevel = UIWindowLevelStatusBar + 50;
        if (sb.size.width < sb.size.height) {
            self.rootWindow.transform = CGAffineTransformMakeRotation(M_PI_2);
            self.rootWindow.bounds = CGRectMake(0, 0, sb.size.height, sb.size.width);
        }
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
    [self setupDock];
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

// ---------------------------------------------------------------------
//  Dock: nut chon app, doi cho, dong
// ---------------------------------------------------------------------
- (UIButton *)dockButton:(NSString *)symbol tint:(UIColor *)tint action:(SEL)sel
{
    id cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    b.tintColor = tint;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self.dockView addSubview:b];
    return b;
}

- (void)setupDock
{
    CGRect f = self.rootWindow.bounds;
    CGFloat dockX = ([SCPPrefs dockSide] == 1) ? f.size.width - SCP_DOCK_WIDTH : 0;
    self.dockView = [[UIView alloc] initWithFrame:CGRectMake(dockX, 0, SCP_DOCK_WIDTH, f.size.height)];
    // Giong thanh ben CarPlay: nen toi mo, dong ho tren, Home (luoi cham) duoi
    self.dockView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    [self.rootWindow addSubview:self.dockView];

    self.clockLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 6, SCP_DOCK_WIDTH, 18)];
    self.clockLabel.textColor = [UIColor whiteColor];
    self.clockLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.clockLabel.textAlignment = NSTextAlignmentCenter;
    self.clockLabel.adjustsFontSizeToFitWidth = YES;
    [self.dockView addSubview:self.clockLabel];
    [self updateClock];
    self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(updateClock) userInfo:nil repeats:YES];

    CGFloat sz = 32, x = (SCP_DOCK_WIDTH - sz) / 2;
    self.appsButton = [self dockButton:@"square.grid.2x2" tint:[UIColor whiteColor] action:@selector(appsButtonTapped)];
    self.appsButton.frame = CGRectMake(x, 32, sz, sz);
    self.swapButton = [self dockButton:@"arrow.left.arrow.right" tint:[UIColor whiteColor] action:@selector(swapPanes)];
    self.swapButton.frame = CGRectMake(x, 32 + sz + 10, sz, sz);
    UIButton *layoutBtn = [self dockButton:@"rectangle.split.2x1" tint:[UIColor whiteColor] action:@selector(cycleLayoutPreset)];
    layoutBtn.frame = CGRectMake(x, 32 + (sz + 10) * 2, sz, sz);
    // Home kieu CarPlay = dong split, ve lai dashboard CarPlay
    self.homeButton = [self dockButton:@"circle.grid.3x3.fill" tint:[UIColor whiteColor] action:@selector(dismiss)];
    self.homeButton.frame = CGRectMake(x, f.size.height - sz - 8, sz, sz);
}

- (void)updateClock
{
    static NSDateFormatter *df; if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm"; }
    self.clockLabel.text = [df stringFromDate:[NSDate date]];
}

- (void)appsButtonTapped
{
    if (self.pickerView) [self hideAppPicker]; else [self showAppPickerForSlot:SCPSlotLeft];
}

// ---------------------------------------------------------------------
//  Bo cuc ngan + thanh phan cach keo duoc
// ---------------------------------------------------------------------
- (CGFloat)paneAreaX
{
    return ([SCPPrefs dockSide] == 1) ? 0 : SCP_DOCK_WIDTH;
}

- (CGRect)frameForSlot:(SCPSlot)slot
{
    CGRect f = self.rootWindow.bounds;
    if (self.fullscreenSlot != SCPSlotAuto) {
        // Fullscreen tam: ngan duoc chon chiem het, ngan kia an
        if (slot == self.fullscreenSlot) return CGRectMake([self paneAreaX], 0, f.size.width - SCP_DOCK_WIDTH, f.size.height);
        return CGRectMake([self paneAreaX], 0, 0, f.size.height);
    }
    CGFloat avail = f.size.width - SCP_DOCK_WIDTH - SCP_DIVIDER_WIDTH;
    CGFloat leftW = floor(avail * self.ratio);
    CGFloat rightW = avail - leftW;
    CGFloat x0 = [self paneAreaX];
    if (slot == SCPSlotLeft) return CGRectMake(x0, 0, leftW, f.size.height);
    return CGRectMake(x0 + leftW + SCP_DIVIDER_WIDTH, 0, rightW, f.size.height);
}

- (CGRect)dividerFrame
{
    CGRect l = [self frameForSlot:SCPSlotLeft];
    return CGRectMake(CGRectGetMaxX(l), 0, SCP_DIVIDER_WIDTH, self.rootWindow.bounds.size.height);
}

- (void)setupDivider
{
    self.dividerView = [[UIView alloc] initWithFrame:[self dividerFrame]];
    self.dividerView.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(4, self.dividerView.bounds.size.height / 2 - 24, SCP_DIVIDER_WIDTH - 8, 48)];
    pill.backgroundColor = [UIColor colorWithWhite:0.7 alpha:1];
    pill.layer.cornerRadius = (SCP_DIVIDER_WIDTH - 8) / 2;
    pill.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.dividerView addSubview:pill];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dividerPanned:)];
    [self.dividerView addGestureRecognizer:pan];
    [self.rootWindow addSubview:self.dividerView];
}

- (void)dividerPanned:(UIPanGestureRecognizer *)g
{
    CGPoint p = [g locationInView:self.rootWindow];
    CGFloat avail = self.rootWindow.bounds.size.width - SCP_DOCK_WIDTH - SCP_DIVIDER_WIDTH;
    CGFloat r = (p.x - [self paneAreaX] - SCP_DIVIDER_WIDTH / 2) / avail;
    r = MIN(0.75, MAX(0.25, r));

    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        // Hit ve moc 30 / 50 / 70 neu gan
        for (NSNumber *snap in @[@0.3, @0.5, @0.7]) {
            if (fabs(r - snap.doubleValue) < 0.04) { r = snap.doubleValue; break; }
        }
        self.ratio = r;
        [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            [self relayoutPanesLive:NO];
        } completion:nil];
        [SCPPrefs setSplitRatio:self.ratio];
        SCPLog("ti le ngan trai = %.2f (da luu)", self.ratio);
        return;
    }
    // Dang keo: chi doi khung + scale nhe, khong bat app dan lai, khong animation
    self.ratio = r;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self relayoutPanesLive:YES];
    [CATransaction commit];
}

- (void)relayoutPanes
{
    [self relayoutPanesLive:NO];
}

- (void)relayoutPanesLive:(BOOL)live
{
    BOOL fs = (self.fullscreenSlot != SCPSlotAuto);
    self.dividerView.hidden = fs;
    self.dividerView.frame = [self dividerFrame];
    for (SCPAppPane *p in self.panes) {
        SCPSlot slot = (p == self.leftPane) ? SCPSlotLeft : SCPSlotRight;
        BOOL hidden = fs && slot != self.fullscreenSlot;
        p.containerView.hidden = hidden;
        if (!hidden) { p.containerView.frame = [self frameForSlot:slot]; [self layoutPane:p live:live]; }
        if (!live) [self layoutExpandButtonForPane:p];
    }
    if (self.pickerView) self.pickerView.frame = [self pickerFrame];
}

// ---------------------------------------------------------------------
//  Bo cuc dat san + fullscreen tam
// ---------------------------------------------------------------------
- (void)applyPresetRatio:(CGFloat)ratio
{
    self.fullscreenSlot = SCPSlotAuto;
    self.ratio = MIN(0.75, MAX(0.25, ratio));
    [UIView animateWithDuration:0.25 animations:^{ [self relayoutPanes]; }];
    [SCPPrefs setSplitRatio:self.ratio];
    SCPLog("bo cuc dat san: trai %.0f%%", self.ratio * 100);
}

- (void)cycleLayoutPreset
{
    CGFloat r = self.ratio;
    CGFloat next = (self.fullscreenSlot != SCPSlotAuto) ? 0.5 : (fabs(r - 0.5) < 0.05 ? 0.7 : (r > 0.6 ? 0.3 : 0.5));
    [self applyPresetRatio:next];
}

- (void)toggleFullscreenForSlot:(SCPSlot)slot
{
    self.fullscreenSlot = (self.fullscreenSlot == slot) ? SCPSlotAuto : slot;
    SCPLog("fullscreen slot = %d", (int)self.fullscreenSlot);
    [UIView animateWithDuration:0.25 animations:^{ [self relayoutPanes]; }];
}

- (void)expandButtonTapped:(UIButton *)b
{
    [self toggleFullscreenForSlot:(SCPSlot)b.tag];
}

// Nut nho o goc tren-phai moi ngan: phong to / thu nho
- (void)layoutExpandButtonForPane:(SCPAppPane *)pane
{
    if (!pane.containerView) return;
    SCPSlot slot = (pane == self.leftPane) ? SCPSlotLeft : SCPSlotRight;
    if (!pane.expandButton) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        b.layer.cornerRadius = 13;
        b.tintColor = [UIColor whiteColor];
        [b addTarget:self action:@selector(expandButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        pane.expandButton = b;
    }
    pane.expandButton.tag = slot;
    BOOL isFull = (self.fullscreenSlot == slot);
    id cfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
    [pane.expandButton setImage:[UIImage systemImageNamed:(isFull ? @"arrow.down.right.and.arrow.up.left" : @"arrow.up.left.and.arrow.down.right")
                                           withConfiguration:cfg] forState:UIControlStateNormal];
    CGSize s = pane.containerView.bounds.size;
    pane.expandButton.frame = CGRectMake(s.width - 26 - 4, 4, 26, 26);
    [pane.containerView addSubview:pane.expandButton];
    [pane.containerView bringSubviewToFront:pane.expandButton];
}

// ---------------------------------------------------------------------
//  Bang chon app
// ---------------------------------------------------------------------
- (CGRect)pickerFrame
{
    CGRect f = self.rootWindow.bounds;
    return CGRectMake([self paneAreaX], 0, f.size.width - SCP_DOCK_WIDTH, f.size.height);
}

- (void)showAppPickerForSlot:(SCPSlot)slot
{
    [self hideAppPicker];
    self.pickerSlot = (slot == SCPSlotRight) ? SCPSlotRight : SCPSlotLeft;

    UIView *pv = [[UIView alloc] initWithFrame:[self pickerFrame]];
    pv.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.97];
    self.pickerView = pv;
    [self.rootWindow addSubview:pv];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, pv.bounds.size.width - 120, 30)];
    title.text = (self.pickerSlot == SCPSlotLeft) ? @"Chọn app cho ngăn TRÁI" : @"Chọn app cho ngăn PHẢI";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [pv addSubview:title];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"Huỷ" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:17];
    cancel.frame = CGRectMake(pv.bounds.size.width - 80, 8, 70, 30);
    [cancel addTarget:self action:@selector(hideAppPicker) forControlEvents:UIControlEventTouchUpInside];
    [pv addSubview:cancel];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 44, pv.bounds.size.width, pv.bounds.size.height - 44)];
    scroll.alwaysBounceVertical = YES;
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

        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((cellW - iconSize) / 2, 6, iconSize, iconSize)];
        iv.image = SCPAppIcon(app[@"id"]);
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.layer.cornerRadius = 11; iv.clipsToBounds = YES;
        iv.backgroundColor = iv.image ? [UIColor clearColor] : [UIColor colorWithWhite:0.3 alpha:1];
        iv.userInteractionEnabled = NO;
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
        [self showAppPickerForSlot:SCPSlotRight];   // chon tiep ngan phai
    } else {
        [SCPPrefs setRightApp:bid];
    }
}

- (void)hideAppPicker
{
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
    SCPLog("DIAG window hidden=%d alpha=%.2f level=%.0f scene=%@ screen=%@ superlayer=%@",
           w.hidden, w.alpha, w.windowLevel, w.windowScene, w.screen, w.layer.superlayer ? @"yes" : @"nil");
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
    CGRect f = self.rootWindow.bounds;
    CGFloat h = MIN(90, f.size.height * 0.3);
    self.debugLabel = [[UILabel alloc] initWithFrame:CGRectMake([self paneAreaX], f.size.height - h, f.size.width - SCP_DOCK_WIDTH, h)];
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
    [self.rootWindow bringSubviewToFront:self.debugLabel];
}

// ---------------------------------------------------------------------
//  Mo app vao ngan
// ---------------------------------------------------------------------
- (void)launchApp:(NSString *)bundleID inSlot:(SCPSlot)slot
{
    if (slot == SCPSlotAuto) {
        if (!self.leftPane) slot = SCPSlotLeft;
        else if (!self.rightPane) slot = SCPSlotRight;
        else slot = SCPSlotRight;
    }
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
    if (self.fullscreenSlot != SCPSlotAuto && self.fullscreenSlot != slot) { pane.containerView.frame = [self frameForSlot:slot]; pane.containerView.hidden = YES; }
    [self layoutPane:pane];
    [self layoutExpandButtonForPane:pane];
    if (self.debugLabel) [self.rootWindow bringSubviewToFront:self.debugLabel];
    if (self.pickerView) [self.rootWindow bringSubviewToFront:self.pickerView];
    SCPLog("da mo %@ vao ngan %d", bundleID, (int)slot);
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

// Scale noi dung app (kich thuoc iPhone) vao ngan
- (void)layoutPane:(SCPAppPane *)pane
{
    [self layoutPane:pane live:NO];
}

// live=YES: dang keo thanh phan cach -> chi scale bang transform (re), khong resize scene
- (void)layoutPane:(SCPAppPane *)pane live:(BOOL)live
{
    if (!pane.appViewController) return;
    id deviceAppVC = getIvar(pane.appViewController, @"_deviceAppViewController");
    id sceneView   = getIvar(deviceAppVC, @"sceneView");
    UIView *hostingContentView = getIvar(sceneView, @"_sceneContentContainerView");
    if (!hostingContentView) { SCPLog("chua co _sceneContentContainerView"); return; }

    CGSize paneSize = pane.containerView.bounds.size;
    if (paneSize.width < 1) return;   // ngan dang an (fullscreen ngan kia)
    CGSize phoneSize = boundsForOrientation([UIScreen mainScreen], pane.orientation).size;
    [pane.appViewController view].frame = CGRectMake(0, 0, paneSize.width, paneSize.height);

    NSInteger mode = [SCPPrefs scaleMode];
    if (mode == 2 && live) {
        // Trong luc keo: giu scene nguyen, chi can clip theo khung (app se dan lai khi tha tay)
        return;
    }
    if (mode == 2) {
        // THU NGHIEM: bao app scene co kich thuoc bang ngan -> app tu layout lai, khong meo
        hostingContentView.transform = CGAffineTransformIdentity;
        id scene = objcInvoke(objcInvoke(pane.appViewController, @"sceneHandle"), @"sceneIfExists");
        if (scene) {
            CGRect target = CGRectMake(0, 0, paneSize.width, paneSize.height);
            objcInvoke_1(scene, @"updateSettingsWithBlock:", ^(id settings) {
                ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, NSSelectorFromString(@"setFrame:"), target);
            });
            SCPLog("resize scene %@ -> %@", pane.bundleIdentifier, NSStringFromCGSize(paneSize));
        }
        return;
    }

    CGFloat sx = paneSize.width / phoneSize.width;
    CGFloat sy = paneSize.height / phoneSize.height;
    if (mode == 1) { CGFloat s = MIN(sx, sy); sx = sy = s; }   // giu ti le, phan thua de den

    // Scale tu goc tren-trai roi can giua phan thua
    hostingContentView.layer.anchorPoint = CGPointMake(0, 0);
    hostingContentView.transform = CGAffineTransformIdentity;
    hostingContentView.bounds = CGRectMake(0, 0, phoneSize.width, phoneSize.height);
    CGFloat ox = (paneSize.width  - phoneSize.width  * sx) / 2;
    CGFloat oy = (paneSize.height - phoneSize.height * sy) / 2;
    hostingContentView.layer.position = CGPointMake(ox, oy);
    hostingContentView.transform = CGAffineTransformMakeScale(sx, sy);
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
//  Dong ngan / doi cho / dong tat ca
// ---------------------------------------------------------------------
- (void)teardownPane:(SCPAppPane *)pane
{
    if (!pane) return;
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
    if (self.fullscreenSlot == slot) { self.fullscreenSlot = SCPSlotAuto; [self relayoutPanes]; }
}

- (void)swapPanes
{
    SCPAppPane *l = self.leftPane, *r = self.rightPane;
    self.leftPane = r; self.rightPane = l;
    if (self.fullscreenSlot == SCPSlotLeft) self.fullscreenSlot = SCPSlotRight;
    else if (self.fullscreenSlot == SCPSlotRight) self.fullscreenSlot = SCPSlotLeft;
    [UIView animateWithDuration:0.25 animations:^{ [self relayoutPanes]; }];
}

- (void)dismiss
{
    SCPLog("dismiss split window");
    [self.clockTimer invalidate]; self.clockTimer = nil;
    [self hideAppPicker];
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
    // Goc tren ben phai man xe (dock CarPlay thuong o ben trai)
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
