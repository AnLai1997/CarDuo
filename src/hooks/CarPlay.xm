#import "../common.h"
#import "../SCPPrefs.h"
#import "../SCPCarSplit.h"

// Inject vao process CarPlay (com.apple.CarPlayApp, code trong DashBoard.framework, prefix DB).
// Split hien GIAO DIEN CARPLAY cua app: DashBoard tu mo scene CarPlay cua app (giong cham icon),
// tweak dua view controller cua scene do vao 1 ngan va bao kich thuoc ngan cho scene (xem SCPCarSplit.mm).
// ---- Nhan giu icon -> hien nut CarDuo canh icon; cham nut moi dua app vao split ----
@interface UIImage (SCPCarHookPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)format scale:(double)scale;
@end

// Lop phu trong suot phu ca cua so CarPlay: cham ra ngoai nut thi an
@interface SCPCarDuoPopup : UIView
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) UIControl *button;
+ (void)showForBundle:(NSString *)bid fromView:(UIView *)iconView;
+ (void)dismiss;
@end

@implementation SCPCarDuoPopup

static SCPCarDuoPopup *sPopup;

+ (void)dismiss
{
    SCPCarDuoPopup *p = sPopup;
    sPopup = nil;
    if (!p) return;
    [UIView animateWithDuration:0.15 animations:^{ p.button.alpha = 0; p.button.transform = CGAffineTransformMakeScale(0.8, 0.8); }
                     completion:^(BOOL f) { [p removeFromSuperview]; }];
}

+ (void)showForBundle:(NSString *)bid fromView:(UIView *)iconView
{
    [self dismiss];
    UIWindow *win = iconView.window;
    if (!win || !bid.length) return;

    SCPCarDuoPopup *p = [[SCPCarDuoPopup alloc] initWithFrame:win.bounds];
    p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    p.backgroundColor = [UIColor clearColor];
    p.bundleID = bid;

    // Nut dang vien thuoc: icon CarDuo + chu "CarDuo"
    UIControl *b = [[UIControl alloc] initWithFrame:CGRectZero];
    b.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96];
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    b.layer.borderWidth = 1;
    b.layer.shadowColor = [UIColor blackColor].CGColor;
    b.layer.shadowOpacity = 0.45; b.layer.shadowRadius = 8; b.layer.shadowOffset = CGSizeMake(0, 2);
    UIImage *icon = nil;
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        icon = [UIImage _applicationIconImageForBundleIdentifier:@"com.anlai97.carduo.app" format:2 scale:2.0];
    }
    CGFloat is = 30, h = 44, pad = 7;
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(pad, (h - is) / 2, is, is)];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    if (icon) {
        iv.image = icon;
        iv.layer.cornerRadius = is * 0.225;
        iv.clipsToBounds = YES;
    } else {
        id cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
        iv.image = [UIImage systemImageNamed:@"rectangle.split.2x1.fill" withConfiguration:cfg];
        iv.tintColor = [UIColor whiteColor];
    }
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectZero];
    lb.text = @"CarDuo";
    lb.textColor = [UIColor whiteColor];
    lb.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [lb sizeToFit];
    lb.frame = CGRectMake(pad + is + 8, (h - lb.bounds.size.height) / 2, lb.bounds.size.width, lb.bounds.size.height);
    iv.userInteractionEnabled = NO; lb.userInteractionEnabled = NO;
    [b addSubview:iv];
    [b addSubview:lb];
    CGSize s = CGSizeMake(CGRectGetMaxX(lb.frame) + 16, h);
    b.layer.cornerRadius = h / 2;
    [b addTarget:p action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    p.button = b;
    [p addSubview:b];

    // Dat tren icon; khong du cho thi dat duoi; luon nam trong cua so
    CGRect ir = [iconView convertRect:iconView.bounds toView:p];
    CGRect safe = UIEdgeInsetsInsetRect(p.bounds, win.safeAreaInsets);
    CGFloat x = CGRectGetMidX(ir) - s.width / 2;
    CGFloat y = CGRectGetMinY(ir) - s.height - 6;
    if (y < CGRectGetMinY(safe) + 4) y = CGRectGetMaxY(ir) + 6;
    x = MAX(CGRectGetMinX(safe) + 4, MIN(x, CGRectGetMaxX(safe) - s.width - 4));
    y = MAX(CGRectGetMinY(safe) + 4, MIN(y, CGRectGetMaxY(safe) - s.height - 4));
    b.frame = CGRectMake(x, y, s.width, s.height);

    [win addSubview:p];
    sPopup = p;
    b.alpha = 0; b.transform = CGAffineTransformMakeScale(0.6, 0.6);
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.65 initialSpringVelocity:0.6
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ b.alpha = 1; b.transform = CGAffineTransformIdentity; } completion:nil];

    __weak SCPCarDuoPopup *weakP = p;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakP && sPopup == weakP) [SCPCarDuoPopup dismiss];
    });
}

// Cham ra ngoai nut (vao lop phu) -> an. Cham trung nut thi UIControl nhan, lop phu khong nhan.
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    CGPoint pt = [touches.anyObject locationInView:self];
    if (CGRectContainsPoint(self.button.frame, pt)) return;
    [SCPCarDuoPopup dismiss];
}

- (void)tapped
{
    NSString *bid = self.bundleID;
    [SCPCarDuoPopup dismiss];
    SCPLog("CarDuo popup: cham -> split CarPlay voi %@", bid);
    [[SCPCarSplit shared] openApp:bid slot:-1];
}

@end

%group CARPLAY

// ---- Long-press icon tren man chinh CarPlay -> hien nut CarDuo (cham nut moi mo app vao ngan) ----
%hook DBIconView

%new
- (void)scp_handleLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (![SCPPrefs enabled]) return;
    id icon = objcInvoke(self, @"icon");
    NSString *bid = objcInvoke(icon, @"applicationBundleID");
    SCPLog("long-press icon %@ -> hien nut CarDuo", bid);
    [SCPCarDuoPopup showForBundle:bid fromView:(UIView *)self];
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
    [SCPCarDuoPopup dismiss];
    if (sp.active) [sp closeGoingHome:NO];
    %orig;
}

- (void)invalidate
{
    [SCPCarDuoPopup dismiss];
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
