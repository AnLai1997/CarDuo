#import "SCPCarSplit.h"
#import "SCPPrefs.h"

// =====================================================================
//  SCPCarSplit - split CarPlay "that": moi ngan la scene CarPlay cua app (giao dien CarPlay/template),
//  chay trong process CarPlay (DashBoard.framework, iOS 16.5).
//
//  Luong mo 1 app vao ngan:
//    1. Ghi nho bundle -> ngan (pending), gui [DBDashboard handleEvent:[DBEvent eventWithType:4 context:launchInfo]]
//       = dung duong DashBoard mo app khi cham icon.
//    2. DashBoard tao DBApplicationSceneViewController (app template: proxy qua CarPlayTemplateUIHost),
//       foreground scene. Kich thuoc scene lay tu -[DBDashboard sceneFrameForAppInfo:proxyAppInfo:]
//       -> hook tra ve kich thuoc ngan.
//    3. DashBoard goi -[DBDashboardRootViewController presentBaseViewController:...] -> hook dua VC vao ngan.
//  Scene cua ngan duoc giu foreground: hook chan backgroundScene/deactivateScene cho VC dang nam trong ngan.
// =====================================================================

#define SCPC_GAP          4.0     // khe giua 2 ngan
#define SCPC_INSET        2.0     // ngan lui vao so voi vung app
#define SCPC_RADIUS       8.0
#define SCPC_BTN          38.0
#define SCPC_BTN_GAP      8.0
#define SCPC_HANDLE_W     30.0
#define SCPC_HANDLE_H     4.0
#define SCPC_KNOB_W       10.0
#define SCPC_KNOB_H       36.0
#define SCPC_DIVIDER_HIT  26.0
#define SCPC_PENDING_TTL  12.0    // giay: qua thoi gian ma DashBoard chua trinh bay app thi bo pending
#define SCPC_HOME_SETTLE  0.5     // giay: cho DashBoard ve Home truoc khi mo app vao ngan
#define SCPC_LAUNCH_GAP   1.2     // giay: khoang cach toi thieu giua 2 lan mo app

@interface UIImage (SCPCarPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)format scale:(double)scale;
@end

NSString *SCPRealBundleForInfos(id info, id proxyInfo)
{
    NSString *a = info ? objcInvoke(info, @"bundleIdentifier") : nil;
    NSString *b = proxyInfo ? objcInvoke(proxyInfo, @"bundleIdentifier") : nil;
    if (a.length && ![a isEqualToString:SCP_TEMPLATE_HOST]) return a;
    if (b.length && ![b isEqualToString:SCP_TEMPLATE_HOST]) return b;
    return a ?: b;
}

static id SCPCDashboard(void)
{
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:NSSelectorFromString(@"_currentDashboard")]) return nil;
    return objcInvoke(app, @"_currentDashboard");
}

static UIViewController *SCPCRootVC(void)
{
    id d = SCPCDashboard();
    return d ? objcInvoke(d, @"rootViewController") : nil;
}

static id SCPCLibrary(void)
{
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:NSSelectorFromString(@"sharedApplicationLibrary")]) return nil;
    return objcInvoke(app, @"sharedApplicationLibrary");
}

static id SCPCAppInfo(NSString *bid)
{
    id lib = SCPCLibrary();
    return (lib && bid) ? objcInvoke_1(lib, @"applicationInfoForBundleIdentifier:", bid) : nil;
}

static BOOL SCPCBool(id obj, NSString *sel)
{
    return obj && [obj respondsToSelector:NSSelectorFromString(sel)] && objcInvokeT(obj, sel, BOOL);
}

// App co giao dien CarPlay (DashBoard hien duoc) va khong phai app he thong cua chinh CarPlay
static BOOL SCPCInfoIsCarPlayApp(id info)
{
    if (!info) return NO;
    NSString *bid = objcInvoke(info, @"bundleIdentifier");
    if (!bid.length || [bid isEqualToString:SCP_TEMPLATE_HOST] || [bid isEqualToString:@"com.apple.CarPlayApp"]
        || [bid isEqualToString:@"com.apple.CarPlaySettings"]) return NO;
    if (![info respondsToSelector:NSSelectorFromString(@"carPlayDeclaration")]) return NO;
    if (!objcInvoke(info, @"carPlayDeclaration")) return NO;
    if (SCPCBool(info, @"isHidden") || SCPCBool(info, @"presentsFullScreen")) return NO;
    return YES;
}

static void SCPCSendEvent(unsigned long long type, id context)
{
    id d = SCPCDashboard();
    if (!d) return;
    id ev = objcInvoke_2(objc_getClass("DBEvent"), @"eventWithType:context:", type, context);
    if (ev) objcInvoke_1(d, @"handleEvent:", ev);
}

// Danh sach app CarPlay: @{ id, name }
static NSArray<NSDictionary *> *SCPCCarPlayApps(void)
{
    NSMutableArray *out = [NSMutableArray array];
    id lib = SCPCLibrary();
    NSArray *all = lib ? objcInvoke(lib, @"allInstalledApplications") : nil;
    for (id info in all) {
        if (!SCPCInfoIsCarPlayApp(info)) continue;
        NSString *name = objcInvoke(info, @"displayName");
        NSString *bid = objcInvoke(info, @"bundleIdentifier");
        [out addObject:@{@"id": bid, @"name": name.length ? name : bid}];
    }
    [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)]]];
    return out;
}

static UIImage *SCPCAppIcon(NSString *bid)
{
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        return [UIImage _applicationIconImageForBundleIdentifier:bid format:2 scale:2.0];
    }
    return nil;
}

// ---------------------------------------------------------------------
//  Kieu nut HyperOS (giong cua so split cu): tron 52pt nen trang, icon den
// ---------------------------------------------------------------------
static UIColor *SCPCInk(void) { return [UIColor colorWithWhite:0.13 alpha:1]; }

static UIButton *SCPCRoundButton(NSString *symbol, id target, SEL action)
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.bounds = CGRectMake(0, 0, SCPC_BTN, SCPC_BTN);
    b.layer.cornerRadius = SCPC_BTN / 2;
    b.layer.shadowColor = [UIColor blackColor].CGColor;
    b.layer.shadowOpacity = 0.3; b.layer.shadowRadius = 4; b.layer.shadowOffset = CGSizeMake(0, 1);
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.96];
    b.tintColor = SCPCInk();
    id cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void SCPCSetOn(UIButton *b, BOOL on)
{
    UIColor *accent = [UIColor colorWithRed:0.10 green:0.47 blue:1.0 alpha:1];
    b.tintColor = on ? accent : SCPCInk();
    b.backgroundColor = on ? [UIColor colorWithRed:0.86 green:0.92 blue:1.0 alpha:1] : [UIColor colorWithWhite:1 alpha:0.96];
}

static void SCPCPopIn(NSArray<UIView *> *views)
{
    NSInteger i = 0;
    for (UIView *v in views) {
        if (v.hidden) continue;
        v.alpha = 0; v.transform = CGAffineTransformMakeScale(0.3, 0.3);
        [UIView animateWithDuration:0.5 delay:i * 0.04 usingSpringWithDamping:0.6 initialSpringVelocity:0.6
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ v.alpha = 1; v.transform = CGAffineTransformIdentity; } completion:nil];
        i++;
    }
}

// ---------------------------------------------------------------------
//  View
// ---------------------------------------------------------------------
@interface SCPCarSplitView : UIView
@property (nonatomic, copy) void (^touched)(CGPoint p);
@end
@implementation SCPCarSplitView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e
{
    UIView *v = [super hitTest:p withEvent:e];
    if (v && self.touched && e.type == UIEventTypeTouches) self.touched(p);
    return v;
}
@end

// Duong ranh mong nhung vung cham rong
@interface SCPCarDividerView : UIView
@end
@implementation SCPCarDividerView
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e
{
    if (CGRectContainsPoint(CGRectInset(self.bounds, -SCPC_DIVIDER_HIT, -SCPC_DIVIDER_HIT), p)) return YES;
    for (UIView *sub in self.subviews) if (!sub.hidden && CGRectContainsPoint(CGRectInset(sub.frame, -10, -10), p)) return YES;
    return NO;
}
@end

@interface SCPCarTabView : UIView
@end
@implementation SCPCarTabView
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { return CGRectContainsPoint(CGRectInset(self.bounds, -18, -14), p); }
@end

@interface SCPCarPane : NSObject
@property (nonatomic) int slot;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) UIViewController *vc;   // DBApplicationSceneViewController
@property (nonatomic, strong) UIView *view;           // khung ngan (bo goc)
@property (nonatomic, strong) UIView *host;           // chua view cua app
@property (nonatomic, strong) UIView *handle;         // the trang giua mep tren
@property (nonatomic, strong) UIView *bar;            // hang nut cua ngan
@property (nonatomic, strong) UIButton *fullscreenButton;
@property (nonatomic, strong) NSTimer *barTimer;
@property (nonatomic, strong) UIView *picker;         // bang chon app cho ngan nay
@property (nonatomic) CGSize sceneSize;               // kich thuoc da bao cho scene lan cuoi
@end
@implementation SCPCarPane
@end

static BOOL SCPCIsBridgedApp(NSString *bid);

@interface SCPCarSplit ()
@property (nonatomic, readwrite) BOOL active;
@property (nonatomic, strong) SCPCarSplitView *container;
@property (nonatomic, strong) NSArray<SCPCarPane *> *slots;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray *> *pending;   // bundle -> @[slot, NSDate]
@property (nonatomic) CGFloat ratio;
@property (nonatomic) int fullscreenSlot;
@property (nonatomic) int focusedSlot;
@property (nonatomic) NSInteger allowBackground;
@property (nonatomic, strong) SCPCarDividerView *divider;
@property (nonatomic, strong) UIView *knob;
@property (nonatomic, strong) UIView *menu;
@property (nonatomic, strong) NSTimer *menuTimer;
@property (nonatomic) BOOL loggedArea;
@property (nonatomic) CFAbsoluteTime nextLaunchAt;   // lan mo app ke tiep som nhat (DashBoard can xong lan truoc)
@property (nonatomic, copy) NSString *bridgedBundle;  // app CarBridge dang duoc chieu vao ngan
@property (nonatomic, readwrite) BOOL bridgeStarting; // CarBridge dang khoi dong chieu (bo qua Home / dismiss cua no)
@property (nonatomic) CGRect lastBridgeFrame;
// Tab tren app CarPlay dang mo toan man (chua split): cham / vuot xuong -> hang icon app CarPlay
@property (nonatomic, strong) UIView *appTab;
@property (nonatomic, strong) UIView *tray;
@property (nonatomic, strong) UIView *trayShield;
@property (nonatomic, copy) NSString *tabBundle;
@property (nonatomic, strong) NSTimer *trayTimer;
@end

@implementation SCPCarSplit

+ (instancetype)shared
{
    static SCPCarSplit *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SCPCarSplit new]; });
    return s;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _pending = [NSMutableDictionary dictionary];
        _fullscreenSlot = -1;
        _ratio = 0.5;
    }
    return self;
}

- (BOOL)isCarPlayApp:(NSString *)bundleID { return SCPCInfoIsCarPlayApp(SCPCAppInfo(bundleID)); }

- (NSString *)displayNameFor:(NSString *)bid
{
    id info = SCPCAppInfo(bid);
    NSString *n = info ? objcInvoke(info, @"displayName") : nil;
    return n.length ? n : bid;
}

- (BOOL)vertical { return [SCPPrefs splitDirection] == 1; }

- (SCPCarPane *)paneForBundle:(NSString *)bid
{
    if (!bid) return nil;
    for (SCPCarPane *p in self.slots) if (p.vc && [p.bundleID isEqualToString:bid]) return p;
    return nil;
}

- (void)purgePending
{
    NSDate *now = [NSDate date];
    for (NSString *bid in self.pending.allKeys) {
        if ([now timeIntervalSinceDate:self.pending[bid][1]] > SCPC_PENDING_TTL) {
            SCPLog("CarSplit: het han cho %@ (DashBoard khong trinh bay app)", bid);
            [self.pending removeObjectForKey:bid];
        }
    }
}

- (int)pendingSlotForBundle:(NSString *)bid
{
    NSArray *v = bid ? self.pending[bid] : nil;
    if (!v || [[NSDate date] timeIntervalSinceDate:v[1]] > SCPC_PENDING_TTL) return -1;
    return [v[0] intValue];
}

- (BOOL)slotOccupied:(int)s
{
    SCPCarPane *p = self.slots[s];
    if (p.vc || p.picker) return YES;
    for (NSString *bid in self.pending) if ([self pendingSlotForBundle:bid] == s) return YES;
    return NO;
}

// Ngan cho app moi khi khong chi dinh: ngan trong truoc, het cho thi ngan dang duoc cham gan nhat
- (int)autoSlot
{
    for (int s = 0; s < 2; s++) if (![self slotOccupied:s]) return s;
    return self.focusedSlot;
}

// ---------------------------------------------------------------------
//  Hinh hoc
// ---------------------------------------------------------------------
- (CGRect)frameForSlot:(int)s
{
    CGRect b = self.container.bounds;
    CGRect a = CGRectInset(b, SCPC_INSET, SCPC_INSET);
    CGRect none = CGRectMake(a.origin.x, a.origin.y, 0, 0);
    if (self.fullscreenSlot >= 0) return (s == self.fullscreenSlot) ? b : none;
    BOOL o0 = [self slotOccupied:0], o1 = [self slotOccupied:1];
    if (!o0 && !o1) return (s == 0) ? a : none;
    if (o0 != o1) return ((s == 0) == o0) ? a : none;   // chi 1 ngan -> chiem het vung
    BOOL v = [self vertical];
    CGFloat len = (v ? a.size.height : a.size.width) - SCPC_GAP;
    CGFloat first = floor(len * self.ratio), second = len - first;
    if (v) {
        if (s == 0) return CGRectMake(a.origin.x, a.origin.y, a.size.width, first);
        return CGRectMake(a.origin.x, a.origin.y + first + SCPC_GAP, a.size.width, second);
    }
    if (s == 0) return CGRectMake(a.origin.x, a.origin.y, first, a.size.height);
    return CGRectMake(a.origin.x + first + SCPC_GAP, a.origin.y, second, a.size.height);
}

- (BOOL)bothVisible
{
    return self.fullscreenSlot < 0 && [self slotOccupied:0] && [self slotOccupied:1];
}

- (CGRect)dividerFrame
{
    CGRect l = [self frameForSlot:0];
    CGRect a = CGRectInset(self.container.bounds, SCPC_INSET, SCPC_INSET);
    if ([self vertical]) return CGRectMake(a.origin.x, CGRectGetMaxY(l), a.size.width, SCPC_GAP);
    return CGRectMake(CGRectGetMaxX(l), a.origin.y, SCPC_GAP, a.size.height);
}

// Vung danh cho app tren man xe (toa do cua view cha cua container): contentView cua DashBoard
// tru phan dock/status bar (o canh tai xe). Tim thay view dock thi cat dung phan dock; khong thi dung statusBarInsets.
- (CGRect)appAreaInParent:(UIView *)parent
{
    UIViewController *root = SCPCRootVC();
    UIView *content = objcInvoke(root, @"contentView") ?: root.view;
    CGRect area = [parent convertRect:content.bounds fromView:content];

    UIView *dock = nil;
    @try { id dockVC = objcInvoke(root, @"appDockViewController"); dock = dockVC ? objcInvoke(dockVC, @"view") : nil; } @catch (NSException *e) {}
    CGRect dockRect = CGRectNull;
    if (dock.window && !dock.hidden && parent.window) {
        UIScreen *screen = parent.window.screen ?: dock.window.screen;
        if (screen) {
            CGRect inScreen = [dock convertRect:dock.bounds toCoordinateSpace:screen.coordinateSpace];
            dockRect = [parent convertRect:inScreen fromCoordinateSpace:screen.coordinateSpace];
        }
    }
    CGRect inter = CGRectIsNull(dockRect) ? CGRectNull : CGRectIntersection(area, dockRect);
    UIEdgeInsets ins = UIEdgeInsetsZero;
    id d = SCPCDashboard();
    if ([d respondsToSelector:NSSelectorFromString(@"statusBarInsets")]) {
        ins = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(d, NSSelectorFromString(@"statusBarInsets"));
    }
    // View dock chi bao khung cum icon (vd {{0,64.5},{45,111}}), khong phai ca thanh dock cao het man.
    // Xac dinh huong dock theo hinh dang cua chinh no va mep no bam vao, roi cat het chieu doc/ngang
    // o mep do. Gop voi statusBarInsets (lay max tung canh) de khong cat trung 2 lan.
    UIEdgeInsets cut = ins;
    if (!CGRectIsNull(inter) && inter.size.width > 1 && inter.size.height > 1) {
        if (inter.size.height >= inter.size.width) {          // dock doc o mep trai/phai
            CGFloat leftGap = inter.origin.x - area.origin.x, rightGap = CGRectGetMaxX(area) - CGRectGetMaxX(inter);
            if (leftGap <= rightGap) cut.left = MAX(cut.left, CGRectGetMaxX(inter) - area.origin.x);
            else cut.right = MAX(cut.right, CGRectGetMaxX(area) - inter.origin.x);
        } else {                                              // dock ngang o mep tren/duoi
            CGFloat topGap = inter.origin.y - area.origin.y, botGap = CGRectGetMaxY(area) - CGRectGetMaxY(inter);
            if (topGap <= botGap) cut.top = MAX(cut.top, CGRectGetMaxY(inter) - area.origin.y);
            else cut.bottom = MAX(cut.bottom, CGRectGetMaxY(area) - inter.origin.y);
        }
    }
    CGRect result = UIEdgeInsetsInsetRect(area, cut);
    if (result.size.width < area.size.width * 0.5 || result.size.height < area.size.height * 0.5) {
        result = UIEdgeInsetsInsetRect(area, ins);            // cat qua tay -> chi dung statusBarInsets
    }
    if (!self.loggedArea) {
        self.loggedArea = YES;
        SCPLog("CarSplit: content=%@ dock=%@ statusBarInsets={%.0f,%.0f,%.0f,%.0f} -> vung app=%@",
               NSStringFromCGRect(area), NSStringFromCGRect(dockRect), ins.top, ins.left, ins.bottom, ins.right, NSStringFromCGRect(result));
    }
    return result;
}

// ---------------------------------------------------------------------
//  Tao / dat container vao cay view cua DashBoard
// ---------------------------------------------------------------------
- (BOOL)ensureContainer
{
    if (self.container.superview) return YES;
    UIViewController *root = SCPCRootVC();
    if (!root) { SCPLog("CarSplit: chua co DBDashboardRootViewController (xe chua ket noi?)"); return NO; }
    UIView *base = objcInvoke(root, @"baseContainerView");
    UIView *parent = base.superview ?: root.view;

    SCPCarSplitView *c = [[SCPCarSplitView alloc] initWithFrame:parent.bounds];
    c.backgroundColor = [UIColor blackColor];
    c.clipsToBounds = YES;
    __weak SCPCarSplit *weakSelf = self;
    c.touched = ^(CGPoint p) {
        SCPCarSplit *me = weakSelf;
        for (SCPCarPane *pane in me.slots) if (pane.view.alpha > 0 && CGRectContainsPoint(pane.view.frame, p)) me.focusedSlot = pane.slot;
    };
    self.container = c;

    NSMutableArray *slots = [NSMutableArray array];
    for (int s = 0; s < 2; s++) {
        SCPCarPane *p = [SCPCarPane new];
        p.slot = s;
        p.view = [[UIView alloc] initWithFrame:CGRectZero];
        p.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
        p.view.layer.cornerRadius = SCPC_RADIUS;
        p.view.clipsToBounds = YES;
        p.host = [[UIView alloc] initWithFrame:CGRectZero];
        p.host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [p.view addSubview:p.host];
        [c addSubview:p.view];
        [self setupBarForPane:p];
        [slots addObject:p];
    }
    self.slots = slots;
    [self setupDivider];

    [parent addSubview:c];
    [self raise];
    self.loggedArea = NO;
    c.frame = [self appAreaInParent:parent];
    SCPLog("CarSplit: container trong %@ frame=%@", NSStringFromClass([parent class]), NSStringFromCGRect(c.frame));
    return YES;
}

// Container nam tren app/home cua DashBoard nhung duoi Siri (stackedContainerView)
- (void)raise
{
    UIView *parent = self.container.superview;
    if (!parent) return;
    [parent bringSubviewToFront:self.container];
    UIView *stacked = objcInvoke(SCPCRootVC(), @"stackedContainerView");
    if (stacked.superview == parent) [parent insertSubview:self.container belowSubview:stacked];
}

- (void)rootDidLayout
{
    if (!self.active) { [self refreshAppTab]; return; }
    if (!self.active || !self.container.superview) return;
    CGRect f = [self appAreaInParent:self.container.superview];
    if (!CGRectEqualToRect(f, self.container.frame)) {
        SCPLog("CarSplit: vung app doi %@ -> %@", NSStringFromCGRect(self.container.frame), NSStringFromCGRect(f));
        self.container.frame = f;
        [self relayoutAnimated:NO];
    }
}

- (BOOL)activate
{
    if (![SCPPrefs enabled]) return NO;
    [self removeAppTab];
    if (self.active && self.container.superview) { [self raise]; return YES; }
    UIViewController *root = SCPCRootVC();
    UIViewController *cur = objcInvoke(root, @"currentBaseViewController");
    // App dang mo toan man: KHONG nhet VC cua no vao ngan tai cho (DashBoard van tuong app dang toan man
    // -> scene khong doi kich thuoc, nut Home ve man chinh bi ket). Ve Home truoc roi mo lai app do vao
    // ngan trai qua duong mo app binh thuong.
    NSString *reopen = (cur && [self isAdoptableViewController:cur])
        ? SCPRealBundleForInfos(objcInvoke(cur, @"applicationInfo"), objcInvoke(cur, @"proxyApplicationInfo")) : nil;
    if (cur) {
        SCPLog("CarSplit: dang mo %@ toan man -> ve man chinh truoc%@", cur, reopen ? [NSString stringWithFormat:@", mo lai %@ vao ngan trai", reopen] : @"");
        SCPCSendEvent(1, @"CarDuo: mo split");
        self.nextLaunchAt = CFAbsoluteTimeGetCurrent() + SCPC_HOME_SETTLE;   // cho DashBoard ve Home xong
    }
    if (![self ensureContainer]) return NO;
    self.active = YES;
    self.fullscreenSlot = -1;
    self.focusedSlot = 0;
    self.ratio = 0.5;   // moi lan chia luon bat dau 50/50 (keo vach chia van doi duoc)
    [self.pending removeAllObjects];
    SCPLog("CarSplit: bat split CarPlay");

    [self relayoutAnimated:NO];
    self.container.alpha = 0;
    self.container.transform = CGAffineTransformMakeScale(0.97, 0.97);
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.3 options:0
                     animations:^{ self.container.alpha = 1; self.container.transform = CGAffineTransformIdentity; } completion:nil];
    if (reopen) [self openApp:reopen slot:0];
    return YES;
}

// ---------------------------------------------------------------------
//  Mo app
// ---------------------------------------------------------------------
- (void)openApp:(NSString *)bid slot:(int)slot
{
    if (!bid.length) return;
    if (![self isCarPlayApp:bid]) {
        if ([SCPPrefs allowPhoneApps]) {
            SCPLog("CarSplit: %@ khong co giao dien CarPlay -> chieu giao dien iPhone (SpringBoard)", bid);
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
                postNotificationName:SCP_NOTIF_LAUNCH object:nil userInfo:@{@"identifier": bid, @"slot": @(slot)}];
        } else {
            SCPLog("CarSplit: %@ khong co giao dien CarPlay -> bo qua", bid);
            [self toast:@"App này không hỗ trợ CarPlay"];
        }
        return;
    }
    BOOL wasActive = self.active;
    BOOL autoSlotRequested = (slot < 0 || slot > 1);
    if (![self activate]) return;
    [self purgePending];

    SCPCarPane *existing = [self paneForBundle:bid];
    if (slot < 0 || slot > 1) slot = existing ? existing.slot : [self autoSlot];
    SCPCarPane *target = self.slots[slot];
    [self removePickerFromPane:target];

    if (existing) {
        if (existing.slot != slot) [self swapPanes];
        if (self.fullscreenSlot >= 0 && self.fullscreenSlot != slot) self.fullscreenSlot = -1;
        if (!wasActive && autoSlotRequested && ![self slotOccupied:1 - slot]) [self showPickerForSlot:1 - slot];
        [self relayoutAnimated:YES];
        return;
    }

    // Dang cho chinh app nay vao dung ngan nay (vd activate vua mo lai app toan man) -> khong mo lan nua
    if ([self pendingSlotForBundle:bid] == slot) { [self relayoutAnimated:YES]; return; }

    self.pending[bid] = @[@(slot), [NSDate date]];
    if (self.fullscreenSlot >= 0 && self.fullscreenSlot != slot) self.fullscreenSlot = -1;
    // Vua mo split tu 1 app (bong bong): nua con lai hien bang chon app CarPlay.
    // Dat bang chon TRUOC khi DashBoard tao scene de scene nhan ngay kich thuoc nua man.
    if (!wasActive && autoSlotRequested && ![self slotOccupied:1 - slot]) [self showPickerForSlot:1 - slot];
    [self relayoutAnimated:YES];

    id info = SCPCAppInfo(bid);
    id launchInfo = objcInvoke_1(objc_getClass("DBApplicationLaunchInfo"), @"launchInfoForApplication:", info);
    // Gian cach cac lan mo: DashBoard phai xong phien doi workspace cua lan truoc (va lan ve Home)
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double delay = MAX(0, self.nextLaunchAt - now);
    self.nextLaunchAt = now + delay + SCPC_LAUNCH_GAP;
    SCPLog("CarSplit: mo %@ vao ngan %d sau %.1fs (launchInfo=%@)", bid, slot, delay, launchInfo);
    if (!launchInfo) {
        [self.pending removeObjectForKey:bid];
        [self relayoutAnimated:YES];
        [self toast:[NSString stringWithFormat:@"Không mở được %@ trong ngăn", [self displayNameFor:bid]]];
        return;
    }
    __weak SCPCarSplit *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SCPCarSplit *me = weakSelf;
        if (!me.active || [me pendingSlotForBundle:bid] < 0) return;
        SCPCSendEvent(4, launchInfo);
        // App da la app chinh cua workspace (khong nam trong ngan) -> DashBoard khong trinh bay lai -> tu lay VC
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf recoverPending:bid attempt:1];
        });
    });
}

// App mo cham (TikTok, YouTube qua tweak CarPlay khac mat ~4s): thu lai o giay 2, 4, 6 roi moi bao loi
- (void)recoverPending:(NSString *)bid attempt:(int)attempt
{
    if (!self.active || [self pendingSlotForBundle:bid] < 0) return;
    id owner = objcInvoke(SCPCDashboard(), @"workspaceOwner");
    NSDictionary *map = nil;
    @try { map = [owner valueForKey:@"_entityIdentifierToViewControllerMap"]; } @catch (NSException *e) {}
    NSArray *vcs = [map isKindOfClass:[NSDictionary class]] ? map.allValues : @[];
    for (id vc in vcs) {
        if (![self wantsViewController:vc]) continue;
        NSString *b = SCPRealBundleForInfos(objcInvoke(vc, @"applicationInfo"), objcInvoke(vc, @"proxyApplicationInfo"));
        if (![b isEqualToString:bid]) continue;
        SCPLog("CarSplit: DashBoard khong trinh bay %@ -> lay VC co san", bid);
        [self adoptViewController:vc];
        return;
    }
    if (attempt < 3) {
        SCPLog("CarSplit: %@ chua toi sau %ds, doi them", bid, attempt * 2);
        __weak SCPCarSplit *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf recoverPending:bid attempt:attempt + 1];
        });
        return;
    }
    // Ghi lai cac VC DashBoard dang giu de biet vi sao app (vd YouTube qua tweak CarPlay khac) khong vao ngan
    NSMutableArray *seen = [NSMutableArray array];
    for (id vc in vcs) {
        id info = [vc respondsToSelector:NSSelectorFromString(@"applicationInfo")] ? objcInvoke(vc, @"applicationInfo") : nil;
        NSString *b = info ? SCPRealBundleForInfos(info, [vc respondsToSelector:NSSelectorFromString(@"proxyApplicationInfo")] ? objcInvoke(vc, @"proxyApplicationInfo") : nil) : nil;
        [seen addObject:[NSString stringWithFormat:@"%@(%@ fullScreen=%d)", NSStringFromClass([vc class]), b ?: @"?", SCPCBool(info, @"presentsFullScreen")]];
    }
    SCPLog("CarSplit: khong tim thay VC cua %@ sau khi mo; DashBoard dang giu: %@", bid, [seen componentsJoinedByString:@", "]);
    [self toast:[NSString stringWithFormat:@"%@ chưa chia màn hình được", [self displayNameFor:bid]]];
    [self.pending removeObjectForKey:bid];
    [self relayoutAnimated:YES];
}

- (void)openPairLeft:(NSString *)left right:(NSString *)right
{
    SCPLog("CarSplit: mo cap left=%@ right=%@", left, right);
    if (!left && !right) { [self showPickerForSlot:0]; return; }
    if (![self activate]) return;
    if (left) [self openApp:left slot:0];
    if (right) {
        // Doi DashBoard xong phien doi workspace cua app trai roi moi mo app phai
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((left ? 1.2 : 0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.active) [self openApp:right slot:1];
        });
    } else {
        [self showPickerForSlot:1];
    }
}

// ---------------------------------------------------------------------
//  Nhan VC tu DashBoard
// ---------------------------------------------------------------------
- (BOOL)wantsViewController:(UIViewController *)vc
{
    return self.active && [self isAdoptableViewController:vc];
}

- (BOOL)isAdoptableViewController:(UIViewController *)vc
{
    Class cls = objc_getClass("DBApplicationSceneViewController");
    if (!cls || ![vc isKindOfClass:cls]) return NO;
    id info = objcInvoke(vc, @"applicationInfo");
    if (SCPCBool(info, @"presentsFullScreen")) return NO;
    return SCPRealBundleForInfos(info, objcInvoke(vc, @"proxyApplicationInfo")) != nil;
}

- (void)adoptViewController:(UIViewController *)vc
{
    NSString *bid = SCPRealBundleForInfos(objcInvoke(vc, @"applicationInfo"), objcInvoke(vc, @"proxyApplicationInfo"));
    int slot = [self pendingSlotForBundle:bid];
    SCPCarPane *existing = nil;
    for (SCPCarPane *p in self.slots) if ([p.bundleID isEqualToString:bid]) existing = p;
    if (slot < 0) slot = existing ? existing.slot : [self autoSlot];
    if (bid) [self.pending removeObjectForKey:bid];
    [self adopt:vc slot:slot];
}

- (void)adopt:(UIViewController *)vc slot:(int)slot
{
    SCPCarPane *p = self.slots[slot];
    NSString *bid = SCPRealBundleForInfos(objcInvoke(vc, @"applicationInfo"), objcInvoke(vc, @"proxyApplicationInfo"));
    [self removePickerFromPane:p];
    if (p.vc == vc) { [self relayoutAnimated:YES]; return; }

    // Cung app dang nam o ngan kia (VC cu) -> go VC cu, khong background vi van la scene do
    SCPCarPane *other = self.slots[1 - slot];
    if (other.vc && [other.bundleID isEqualToString:bid]) {
        [self detachVC:other.vc background:NO];
        other.vc = nil; other.bundleID = nil; other.sceneSize = CGSizeZero;
    }
    if (p.vc) [self detachVC:p.vc background:![p.bundleID isEqualToString:bid]];

    UIViewController *root = SCPCRootVC();
    BOOL moved = NO;
    if (vc.parentViewController != root) {
        if (vc.parentViewController) { [vc willMoveToParentViewController:nil]; [vc removeFromParentViewController]; }
        [root addChildViewController:vc];
        moved = YES;
    }
    [vc.view removeFromSuperview];
    vc.view.hidden = NO;
    vc.view.alpha = 1;
    vc.view.transform = CGAffineTransformIdentity;
    vc.view.frame = p.host.bounds;
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [p.host addSubview:vc.view];
    if (moved) [vc didMoveToParentViewController:root];
    vc.additionalSafeAreaInsets = UIEdgeInsetsZero;

    p.vc = vc; p.bundleID = bid; p.sceneSize = CGSizeZero;
    if (self.fullscreenSlot >= 0 && self.fullscreenSlot != slot) self.fullscreenSlot = -1;
    self.focusedSlot = slot;
    SCPLog("CarSplit: dua %@ (%@) vao ngan %d", bid, NSStringFromClass([vc class]), slot);
    // Chan doan CarBridge: cay view cua app trong ngan, 1 lan moi app
    static NSMutableSet *dumpedPane; if (!dumpedPane) dumpedPane = [NSMutableSet set];
    if (bid && ![bid hasPrefix:@"com.apple."] && ![dumpedPane containsObject:bid]) {
        [dumpedPane addObject:bid];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ SCPCDumpVC(vc, @"trong ngan"); });
    }
    [self raise];
    [self relayoutAnimated:YES];
    // App iPhone qua CarBridge: scene DashBoard rong -> nho CarBridge chieu app vao dung ngan nay
    if (SCPCIsBridgedApp(bid)) {
        __weak SCPCarSplit *weakSelf = self;
        __weak SCPCarPane *weakPane = p;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SCPCarPane *pp = weakPane;
            if (weakSelf.active && [pp.bundleID isEqualToString:bid]) [weakSelf startBridgeForPane:pp];
        });
    }
}

- (void)detachVC:(UIViewController *)vc background:(BOOL)background
{
    if (!vc) return;
    if (background) {
        self.allowBackground++;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(vc, NSSelectorFromString(@"backgroundSceneWithCompletion:"), ^{});
        } @catch (NSException *e) { SCPLog("CarSplit: background loi %@", e); }
        self.allowBackground--;
    }
    [vc willMoveToParentViewController:nil];
    [vc.view removeFromSuperview];
    [vc removeFromParentViewController];
}

- (BOOL)protectsViewController:(id)vc
{
    if (!self.active || self.allowBackground > 0) return NO;
    for (SCPCarPane *p in self.slots) if (p.vc == vc) return YES;
    return NO;
}

- (void)sceneDestroyedForViewController:(id)vc
{
    for (SCPCarPane *p in self.slots) {
        if (p.vc != vc) continue;
        SCPLog("CarSplit: scene cua %@ bi huy (app thoat/crash) -> dong ngan %d", p.bundleID, p.slot);
        int slot = p.slot;
        dispatch_async(dispatch_get_main_queue(), ^{ [self closeSlot:slot background:NO]; });
    }
}

- (BOOL)paneSize:(CGSize *)outSize forBundle:(NSString *)bid
{
    if (!self.active || !bid || !self.container) return NO;
    SCPCarPane *p = [self paneForBundle:bid];
    int slot = p ? p.slot : [self pendingSlotForBundle:bid];
    if (slot < 0) return NO;
    CGSize s = [self frameForSlot:slot].size;
    if (s.width < 2 || s.height < 2) return NO;
    if (outSize) *outSize = s;
    return YES;
}

// ---------------------------------------------------------------------
//  Bo cuc
// ---------------------------------------------------------------------
- (void)relayoutAnimated:(BOOL)animated
{
    [self relayoutAnimated:animated pushScenes:YES];
}

- (void)relayoutAnimated:(BOOL)animated pushScenes:(BOOL)push
{
    if (!self.container) return;
    BOOL both = [self bothVisible];
    void (^changes)(void) = ^{
        for (SCPCarPane *p in self.slots) {
            CGRect f = [self frameForSlot:p.slot];
            BOOL visible = f.size.width > 1 && f.size.height > 1;
            p.view.frame = f;
            p.view.alpha = visible ? 1 : 0;
            p.view.layer.cornerRadius = (self.fullscreenSlot == p.slot) ? 0 : SCPC_RADIUS;
            p.host.frame = p.view.bounds;
            p.picker.frame = p.view.bounds;
            [self layoutBarForPane:p];
        }
        self.divider.frame = [self dividerFrame];
        self.divider.alpha = both ? 1 : 0;
        [self layoutKnob];
    };
    if (animated) {
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:changes completion:nil];
    } else {
        changes();
    }
    for (SCPCarPane *p in self.slots) p.view.userInteractionEnabled = (p.view.alpha > 0);
    self.divider.userInteractionEnabled = both;
    if (push) [self pushSceneSizes];
    [self pushBridgeFrameSoon];   // CBWindow cua CarBridge theo khung ngan moi
}

// FBScene cua 1 DBApplicationSceneViewController (thu vai ten thuoc tinh), nil neu khong lay duoc
static id SCPCSceneOf(UIViewController *vc)
{
    for (NSString *k in @[@"scene", @"_scene"]) {
        @try { id s = [vc valueForKey:k]; if (s) return s; } @catch (NSException *e) {}
    }
    @try {
        id h = [vc valueForKey:@"sceneHandle"];
        id s = h ? [h valueForKey:@"scene"] : nil;
        if (s) return s;
    } @catch (NSException *e) {}
    return nil;
}

// Kich thuoc scene dang dung (settings.frame); CGSizeZero neu khong doc duoc
static CGSize SCPCSceneSize(UIViewController *vc)
{
    id scene = SCPCSceneOf(vc);
    id st = nil;
    @try { st = [scene respondsToSelector:NSSelectorFromString(@"settings")] ? objcInvoke(scene, @"settings") : nil; } @catch (NSException *e) {}
    if (![st respondsToSelector:NSSelectorFromString(@"frame")]) return CGSizeZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(st, NSSelectorFromString(@"frame")).size;
}

// Bao kich thuoc moi cho scene cua tung ngan: DashBoard tao DBSceneUpdate, lay frame qua hook sceneFrameForAppInfo
- (void)pushSceneSizes
{
    for (SCPCarPane *p in self.slots) {
        if (!p.vc) continue;
        CGSize s = [self frameForSlot:p.slot].size;
        if (s.width < 2 || s.height < 2 || CGSizeEqualToSize(s, p.sceneSize)) continue;
        p.sceneSize = s;
        SCPLog("CarSplit: scene %@ -> %@", p.bundleID, NSStringFromCGSize(s));
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(p.vc, NSSelectorFromString(@"foregroundSceneWithSettings:completion:"), nil, ^{});
        } @catch (NSException *e) { SCPLog("CarSplit: foregroundScene loi %@", e); }
        UIViewController *vc = p.vc;
        __weak SCPCarSplit *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *h = nil;
            @try { h = objcInvoke(vc, @"sceneHostView"); } @catch (NSException *e) {}
            if (h && h.superview == vc.view && !CGRectEqualToRect(h.frame, vc.view.bounds)) {
                SCPLog("CarSplit: sceneHostView %@ -> %@", NSStringFromCGRect(h.frame), NSStringFromCGRect(vc.view.bounds));
                h.frame = vc.view.bounds;
            }
        });
        // Kiem tra scene da doi kich thuoc that chua; chua thi dua scene ve nen roi len lai 1 lan
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf verifySceneOfPane:p expected:s retry:YES];
        });
    }
}

- (void)verifySceneOfPane:(SCPCarPane *)p expected:(CGSize)s retry:(BOOL)retry
{
    if (!self.active || !p.vc || !CGSizeEqualToSize(p.sceneSize, s)) return;   // da doi tiep / da dong
    CGSize cur = SCPCSceneSize(p.vc);
    if (CGSizeEqualToSize(cur, CGSizeZero)) { SCPLog("CarSplit: khong doc duoc kich thuoc scene %@", p.bundleID); return; }
    BOOL ok = (fabs(cur.width - s.width) < 2 && fabs(cur.height - s.height) < 2)
           || (fabs(cur.width - s.height) < 2 && fabs(cur.height - s.width) < 2);   // co the bi dao chieu
    SCPLog("CarSplit: scene %@ that = %@ (can %@)%@", p.bundleID, NSStringFromCGSize(cur), NSStringFromCGSize(s),
           ok ? @"" : (retry ? @" -> ve nen roi len lai" : @" -> van sai"));
    if (ok || !retry) return;
    UIViewController *vc = p.vc;
    self.allowBackground++;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(vc, NSSelectorFromString(@"backgroundSceneWithCompletion:"), ^{});
    } @catch (NSException *e) { SCPLog("CarSplit: background loi %@", e); }
    self.allowBackground--;
    __weak SCPCarSplit *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SCPCarSplit *me = weakSelf;
        if (!me.active || p.vc != vc) return;
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(vc, NSSelectorFromString(@"foregroundSceneWithSettings:completion:"), nil, ^{});
        } @catch (NSException *e) { SCPLog("CarSplit: foregroundScene loi %@", e); }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf verifySceneOfPane:p expected:s retry:NO];
        });
    });
}

- (void)swapPanes
{
    SCPCarPane *a = self.slots[0], *b = self.slots[1];
    self.slots = @[b, a];
    b.slot = 0; a.slot = 1;
    if (self.fullscreenSlot >= 0) self.fullscreenSlot = 1 - self.fullscreenSlot;
    self.ratio = 1 - self.ratio;
    for (NSString *bid in self.pending.allKeys) {
        NSArray *v = self.pending[bid];
        self.pending[bid] = @[@(1 - [v[0] intValue]), v[1]];
    }
    for (SCPCarPane *p in self.slots) for (UIView *btn in p.picker.subviews) if ([btn isKindOfClass:[UIButton class]]) btn.tag = p.slot;
    SCPLog("CarSplit: doi cho 2 ngan");
    [self relayoutAnimated:YES];
}

- (void)toggleFullscreenForSlot:(int)slot
{
    self.fullscreenSlot = (self.fullscreenSlot == slot) ? -1 : slot;
    [self relayoutAnimated:YES];
}

// ---------------------------------------------------------------------
//  Dong
// ---------------------------------------------------------------------
- (void)closeSlot:(int)slot background:(BOOL)background
{
    if (!self.active) return;
    SCPCarPane *p = self.slots[slot];
    NSString *bid = p.bundleID;
    if (bid && [bid isEqualToString:self.bridgedBundle]) [self stopBridge];
    [self removePickerFromPane:p];
    if (p.vc) [self detachVC:p.vc background:background];
    p.vc = nil; p.bundleID = nil; p.sceneSize = CGSizeZero;
    if (self.fullscreenSlot == slot) self.fullscreenSlot = -1;
    SCPCarPane *other = self.slots[1 - slot];
    if (!other.vc && !other.picker) { [self closeGoingHome:YES]; return; }
    SCPLog("CarSplit: dong ngan %d (%@)", slot, bid);
    [self relayoutAnimated:YES];

    // Workspace cua DashBoard van coi app vua dong la app chinh -> chuyen sang app con lai cho khop
    NSString *activeBase = objcInvoke(objcInvoke(SCPCDashboard(), @"workspaceOwner"), @"activeBaseApplicationBundleID");
    if (bid && other.bundleID && [activeBase isEqualToString:bid]) {
        NSString *ob = other.bundleID;
        self.pending[ob] = @[@(other.slot), [NSDate date]];
        id launchInfo = objcInvoke_1(objc_getClass("DBApplicationLaunchInfo"), @"launchInfoForApplication:", SCPCAppInfo(ob));
        if (launchInfo) SCPCSendEvent(4, launchInfo);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.pending removeObjectForKey:ob];
        });
    }
}

- (void)closeApp:(NSString *)bundleID
{
    SCPCarPane *p = [self paneForBundle:bundleID];
    if (self.active && p) [self closeSlot:p.slot background:YES];
}

- (void)closeGoingHome:(BOOL)goHome
{
    if (!self.active) return;
    SCPLog("CarSplit: tat split (goHome=%d)", goHome);
    [self stopBridge];
    for (SCPCarPane *p in self.slots) {
        [p.barTimer invalidate]; p.barTimer = nil;
        if (p.vc) [self detachVC:p.vc background:YES];
        p.vc = nil; p.bundleID = nil;
        [p.picker removeFromSuperview]; p.picker = nil;
    }
    self.active = NO;
    [self.pending removeAllObjects];
    [self hideMenu];
    UIView *c = self.container;
    self.container = nil; self.slots = nil; self.divider = nil; self.knob = nil;
    [UIView animateWithDuration:0.2 animations:^{ c.alpha = 0; } completion:^(BOOL f) { [c removeFromSuperview]; }];
    if (goHome) SCPCSendEvent(1, @"CarDuo: dong split");
    [self refreshAppTabSoon];   // DashBoard co the dang mo 1 app toan man -> hien tab
}

// DashBoard bi huy (ngat xe): bo trang thai, khong goi gi vao scene nua
- (void)dashboardInvalidated
{
    [self removeAppTab];
    if (!self.active) return;
    SCPLog("CarSplit: DashBoard invalidate -> bo split");
    self.bridgedBundle = nil; self.bridgeStarting = NO;   // CarBridge tu xu ly ngat xe
    self.active = NO;
    [self.pending removeAllObjects];
    for (SCPCarPane *p in self.slots) [p.barTimer invalidate];
    [self.menuTimer invalidate]; self.menuTimer = nil;
    [self.container removeFromSuperview];
    self.container = nil; self.slots = nil; self.divider = nil; self.knob = nil; self.menu = nil;
}

// ---------------------------------------------------------------------
//  Option cua tung ngan: the trang giua mep tren -> hang nut (doi app / toan man / dong)
// ---------------------------------------------------------------------
- (void)setupBarForPane:(SCPCarPane *)p
{
    UIView *h = [[SCPCarTabView alloc] initWithFrame:CGRectMake(0, 0, SCPC_HANDLE_W, SCPC_HANDLE_H)];
    h.backgroundColor = [UIColor colorWithWhite:1 alpha:0.7];
    h.layer.cornerRadius = SCPC_HANDLE_H / 2;
    h.layer.shadowColor = [UIColor blackColor].CGColor;
    h.layer.shadowOpacity = 0.4; h.layer.shadowRadius = 2; h.layer.shadowOffset = CGSizeMake(0, 1);
    [h addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTapped:)]];
    [h addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanned:)]];
    p.handle = h;
    [p.view addSubview:h];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.hidden = YES;
    UIButton *choose = SCPCRoundButton(@"square.grid.2x2", self, @selector(paneChoose:));
    p.fullscreenButton = SCPCRoundButton(@"square.fill", self, @selector(paneFullscreen:));
    UIButton *close = SCPCRoundButton(@"xmark.square", self, @selector(paneClose:));
    for (UIButton *b in @[choose, p.fullscreenButton, close]) [bar addSubview:b];
    p.bar = bar;
    [p.view addSubview:bar];
}

- (SCPCarPane *)paneForView:(UIView *)v
{
    for (SCPCarPane *p in self.slots) if ([v isDescendantOfView:p.view]) return p;
    return nil;
}

- (void)layoutBarForPane:(SCPCarPane *)p
{
    CGSize s = p.view.bounds.size;
    p.handle.center = CGPointMake(s.width / 2, 4 + SCPC_HANDLE_H / 2);
    p.handle.hidden = (p.vc == nil);   // dang chon app thi khong can
    NSArray *btns = p.bar.subviews;
    CGFloat w = btns.count * SCPC_BTN + (btns.count - 1) * SCPC_BTN_GAP;
    p.bar.frame = CGRectMake((s.width - w) / 2, SCPC_HANDLE_H + 10, w, SCPC_BTN);
    CGFloat x = 0;
    for (UIView *b in btns) { b.center = CGPointMake(x + SCPC_BTN / 2, SCPC_BTN / 2); x += SCPC_BTN + SCPC_BTN_GAP; }
    SCPCSetOn(p.fullscreenButton, self.fullscreenSlot == p.slot);
    [p.view bringSubviewToFront:p.handle];
    [p.view bringSubviewToFront:p.bar];
}

- (void)setBarVisible:(BOOL)visible forPane:(SCPCarPane *)p
{
    [p.barTimer invalidate]; p.barTimer = nil;
    if (visible) {
        [self hideMenu];
        for (SCPCarPane *o in self.slots) if (o != p) [self setBarVisible:NO forPane:o];
        [self layoutBarForPane:p];
        BOOL wasHidden = p.bar.hidden;
        p.bar.hidden = NO;
        if (wasHidden) SCPCPopIn(p.bar.subviews);
        __weak SCPCarSplit *weakSelf = self;
        __weak SCPCarPane *weakPane = p;
        p.barTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *t) {
            if (weakPane) [weakSelf setBarVisible:NO forPane:weakPane];
        }];
    } else if (!p.bar.hidden) {
        UIView *bar = p.bar;
        [UIView animateWithDuration:0.16 animations:^{ bar.alpha = 0; } completion:^(BOOL f) { bar.hidden = YES; bar.alpha = 1; }];
    }
    if (p.bundleID && [p.bundleID isEqualToString:self.bridgedBundle]) [self pushBridgeFrameSoon];   // nhuong cho thanh nut
}

- (void)handleTapped:(UITapGestureRecognizer *)g
{
    SCPCarPane *p = [self paneForView:g.view];
    if (p) [self setBarVisible:p.bar.hidden forPane:p];
}

- (void)handlePanned:(UIPanGestureRecognizer *)g
{
    SCPCarPane *p = [self paneForView:g.view];
    if (!p || g.state != UIGestureRecognizerStateEnded) return;
    CGFloat ty = [g translationInView:p.view].y;
    if (ty > 10) [self setBarVisible:YES forPane:p];
    else if (ty < -10) [self setBarVisible:NO forPane:p];
}

- (void)paneChoose:(UIButton *)b
{
    SCPCarPane *p = [self paneForView:b];
    if (!p) return;
    [self setBarVisible:NO forPane:p];
    [self showPickerForSlot:p.slot];
}

- (void)paneFullscreen:(UIButton *)b
{
    SCPCarPane *p = [self paneForView:b];
    if (!p) return;
    [self setBarVisible:NO forPane:p];
    [self toggleFullscreenForSlot:p.slot];
}

- (void)paneClose:(UIButton *)b
{
    SCPCarPane *p = [self paneForView:b];
    if (!p) return;
    [self setBarVisible:NO forPane:p];
    [self closeSlot:p.slot background:YES];
}

// ---------------------------------------------------------------------
//  Duong ranh + num keo: keo doi ti le, cham mo menu (doi cho / ti le / ve CarPlay)
// ---------------------------------------------------------------------
- (void)setupDivider
{
    SCPCarDividerView *d = [[SCPCarDividerView alloc] initWithFrame:CGRectZero];
    d.backgroundColor = [UIColor clearColor];
    UIView *knob = [[UIView alloc] init];
    knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.92];
    knob.layer.shadowColor = [UIColor blackColor].CGColor;
    knob.layer.shadowOpacity = 0.55; knob.layer.shadowRadius = 3; knob.layer.shadowOffset = CGSizeZero;
    knob.userInteractionEnabled = NO;
    for (NSInteger i = 0; i < 3; i++) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 3, 3)];
        dot.backgroundColor = SCPCInk();
        dot.layer.cornerRadius = 1.5;
        dot.tag = 300 + i;
        [knob addSubview:dot];
    }
    [d addSubview:knob];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dividerPanned:)];
    pan.maximumNumberOfTouches = 1;
    [d addGestureRecognizer:pan];
    [d addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dividerTapped:)]];
    self.divider = d;
    self.knob = knob;
    [self.container addSubview:d];
}

- (void)layoutKnob
{
    CGSize s = self.divider.bounds.size;
    BOOL v = [self vertical];
    CGFloat kw = v ? SCPC_KNOB_H : SCPC_KNOB_W, kh = v ? SCPC_KNOB_W : SCPC_KNOB_H;
    self.knob.bounds = CGRectMake(0, 0, kw, kh);
    self.knob.center = CGPointMake(s.width / 2, s.height / 2);
    self.knob.layer.cornerRadius = SCPC_KNOB_W / 2;
    for (NSInteger i = 0; i < 3; i++) {
        UIView *dot = [self.knob viewWithTag:300 + i];
        CGFloat off = (i - 1) * 6;
        dot.center = v ? CGPointMake(kw / 2 + off, kh / 2) : CGPointMake(kw / 2, kh / 2 + off);
    }
    [self.container bringSubviewToFront:self.divider];
    if (self.menu) [self.container bringSubviewToFront:self.menu];
}

- (void)dividerPanned:(UIPanGestureRecognizer *)g
{
    static CGFloat startRatio = 0.5;
    CGRect a = CGRectInset(self.container.bounds, SCPC_INSET, SCPC_INSET);
    BOOL v = [self vertical];
    CGFloat len = (v ? a.size.height : a.size.width) - SCPC_GAP;
    if (g.state == UIGestureRecognizerStateBegan) {
        startRatio = self.ratio;
        [self hideMenu];
        [UIView animateWithDuration:0.15 animations:^{ self.knob.transform = CGAffineTransformMakeScale(1.15, 1.15); }];
    }
    CGPoint t = [g translationInView:self.container];
    CGFloat r = MIN(0.8, MAX(0.2, startRatio + (v ? t.y : t.x) / len));
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [UIView animateWithDuration:0.15 animations:^{ self.knob.transform = CGAffineTransformIdentity; }];
        for (NSNumber *snap in @[@0.3, @0.5, @0.7]) if (fabs(r - snap.doubleValue) < 0.04) { r = snap.doubleValue; break; }
        self.ratio = r;
        [self relayoutAnimated:YES];   // tha tay moi bao kich thuoc moi cho scene
        [self saveRatio];
        return;
    }
    self.ratio = r;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self relayoutAnimated:NO pushScenes:NO];
    [CATransaction commit];
}

- (void)saveRatio
{
    [SCPPrefs setSplitRatio:self.ratio];
    NSString *l = self.slots[0].bundleID, *r = self.slots[1].bundleID;
    if (l && r) [SCPPrefs setRatio:self.ratio forPairLeft:l right:r];
    SCPLog("CarSplit: ti le ngan trai = %.2f", self.ratio);
}

- (void)dividerTapped:(UITapGestureRecognizer *)g
{
    CGPoint p = [g locationInView:self.divider];
    if (!CGRectContainsPoint(CGRectInset(self.knob.frame, -14, -14), p)) return;
    if (self.menu) [self hideMenu]; else [self showMenu];
}

- (NSString *)nextRatioSymbol
{
    CGFloat r = self.ratio;
    CGFloat next = fabs(r - 0.5) < 0.05 ? 0.7 : (r > 0.6 ? 0.3 : 0.5);
    BOOL v = [self vertical];
    if (fabs(next - 0.5) < 0.01) return v ? @"rectangle.split.1x2" : @"rectangle.split.2x1";
    if (next > 0.5) return v ? @"rectangle.tophalf.filled" : @"rectangle.lefthalf.filled";
    return v ? @"rectangle.bottomhalf.filled" : @"rectangle.righthalf.filled";
}

- (void)showMenu
{
    [self hideMenu];
    for (SCPCarPane *p in self.slots) [self setBarVisible:NO forPane:p];
    UIView *m = [[UIView alloc] init];
    NSArray *btns = @[SCPCRoundButton(@"arrow.left.arrow.right", self, @selector(menuSwap)),
                      SCPCRoundButton([self nextRatioSymbol], self, @selector(menuRatio)),
                      SCPCRoundButton(@"xmark", self, @selector(menuClose))];
    BOOL v = [self vertical];
    CGFloat len = btns.count * SCPC_BTN + (btns.count - 1) * SCPC_BTN_GAP;
    m.bounds = v ? CGRectMake(0, 0, len, SCPC_BTN) : CGRectMake(0, 0, SCPC_BTN, len);
    CGFloat o = 0;
    for (UIButton *b in btns) {
        b.center = v ? CGPointMake(o + SCPC_BTN / 2, SCPC_BTN / 2) : CGPointMake(SCPC_BTN / 2, o + SCPC_BTN / 2);
        o += SCPC_BTN + SCPC_BTN_GAP;
        [m addSubview:b];
    }
    // Hang nut nam doc theo duong ranh, ngay tren num keo (chia trai/phai) hoac ben trai num (chia tren/duoi)
    CGRect d = self.divider.frame;
    if (!v) m.center = CGPointMake(CGRectGetMidX(d), MAX(len / 2 + 8, CGRectGetMidY(d) - SCPC_KNOB_H / 2 - 8 - len / 2));
    else    m.center = CGPointMake(MAX(len / 2 + 8, CGRectGetMidX(d) - SCPC_KNOB_H / 2 - 8 - len / 2), CGRectGetMidY(d));
    self.menu = m;
    [self.container addSubview:m];
    SCPCPopIn(btns);
    __weak SCPCarSplit *weakSelf = self;
    self.menuTimer = [NSTimer scheduledTimerWithTimeInterval:3.5 repeats:NO block:^(NSTimer *t) { [weakSelf hideMenu]; }];
}

- (void)hideMenu
{
    [self.menuTimer invalidate]; self.menuTimer = nil;
    UIView *m = self.menu;
    self.menu = nil;
    if (!m) return;
    [UIView animateWithDuration:0.15 animations:^{ m.alpha = 0; } completion:^(BOOL f) { [m removeFromSuperview]; }];
}

- (void)menuSwap { [self hideMenu]; [self swapPanes]; }

- (void)menuRatio
{
    [self hideMenu];
    CGFloat r = self.ratio;
    self.ratio = fabs(r - 0.5) < 0.05 ? 0.7 : (r > 0.6 ? 0.3 : 0.5);
    self.fullscreenSlot = -1;
    [self relayoutAnimated:YES];
    [self saveRatio];
}

- (void)menuClose { [self hideMenu]; [self closeGoingHome:YES]; }

// ---------------------------------------------------------------------
//  Bang chon app CarPlay (nam trong 1 ngan)
// ---------------------------------------------------------------------
- (void)removePickerFromPane:(SCPCarPane *)p
{
    if (!p.picker) return;
    UIView *pv = p.picker;
    p.picker = nil;
    [UIView animateWithDuration:0.15 animations:^{ pv.alpha = 0; } completion:^(BOOL f) { [pv removeFromSuperview]; }];
}

- (void)showPickerForSlot:(int)slot
{
    if (![self activate]) return;
    if (slot < 0 || slot > 1) slot = [self autoSlot];
    SCPCarPane *p = self.slots[slot];
    [self removePickerFromPane:p];
    [self hideMenu];
    if (self.fullscreenSlot >= 0 && self.fullscreenSlot != slot) self.fullscreenSlot = -1;

    UIView *pv = [[UIView alloc] init];
    p.picker = pv;                     // dat truoc de bo cuc tinh ca ngan nay
    CGSize size = [self frameForSlot:slot].size;
    pv.frame = CGRectMake(0, 0, size.width, size.height);
    pv.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.98];
    pv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, size.width - 60, 24)];
    title.text = @"Chọn app CarPlay";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    title.adjustsFontSizeToFitWidth = YES;
    [pv addSubview:title];

    UIButton *cancel = SCPCRoundButton(@"xmark", self, @selector(pickerCancel:));
    cancel.tag = slot;
    cancel.bounds = CGRectMake(0, 0, 30, 30);
    cancel.layer.cornerRadius = 15;
    cancel.center = CGPointMake(size.width - 22, 20);
    cancel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [pv addSubview:cancel];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 40, size.width, size.height - 40)];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.alwaysBounceVertical = YES;
    [pv addSubview:scroll];

    NSArray *apps = SCPCCarPlayApps();
    NSMutableSet *inUse = [NSMutableSet set];
    for (SCPCarPane *o in self.slots) if (o.bundleID) [inUse addObject:o.bundleID];
    CGFloat cellW = 76, cellH = 80, icon = 44;
    NSInteger cols = MAX(1, (NSInteger)(size.width / cellW));
    CGFloat padX = (size.width - cols * cellW) / 2;
    NSInteger i = 0;
    NSMutableArray *cells = [NSMutableArray array];
    for (NSDictionary *app in apps) {
        NSInteger row = i / cols, col = i % cols;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(padX + col * cellW, 4 + row * cellH, cellW, cellH);
        b.accessibilityIdentifier = app[@"id"];
        b.tag = slot;
        [b addTarget:self action:@selector(pickerAppTapped:) forControlEvents:UIControlEventTouchUpInside];
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((cellW - icon) / 2, 4, icon, icon)];
        iv.image = SCPCAppIcon(app[@"id"]);
        iv.layer.cornerRadius = 10; iv.clipsToBounds = YES;
        iv.backgroundColor = iv.image ? [UIColor clearColor] : [UIColor colorWithWhite:0.3 alpha:1];
        iv.userInteractionEnabled = NO;
        iv.alpha = [inUse containsObject:app[@"id"]] ? 0.45 : 1;
        [b addSubview:iv];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(2, icon + 6, cellW - 4, 26)];
        l.text = app[@"name"];
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:10];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 2;
        l.userInteractionEnabled = NO;
        [b addSubview:l];
        [scroll addSubview:b];
        if (i < cols * 2) [cells addObject:b];
        i++;
    }
    scroll.contentSize = CGSizeMake(size.width, 12 + ((i + cols - 1) / cols) * cellH);
    if (i == 0) title.text = @"Không tìm thấy app CarPlay";

    [p.view addSubview:pv];
    [p.view bringSubviewToFront:p.handle];
    [self relayoutAnimated:YES];
    pv.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{ pv.alpha = 1; }];
    SCPCPopIn(cells);
    SCPLog("CarSplit: bang chon %ld app CarPlay cho ngan %d", (long)i, slot);
}

- (void)pickerAppTapped:(UIButton *)b
{
    NSString *bid = b.accessibilityIdentifier;
    int slot = (int)b.tag;
    SCPLog("CarSplit: chon %@ cho ngan %d", bid, slot);
    [self openApp:bid slot:slot];
}

- (void)pickerCancel:(UIButton *)b
{
    int slot = (int)b.tag;
    if (slot < 0 || slot > 1 || !self.slots) return;
    SCPCarPane *p = self.slots[slot];
    [self removePickerFromPane:p];
    SCPCarPane *other = self.slots[1 - slot];
    if (!p.vc && !other.vc && !other.picker && self.pending.count == 0) { [self closeGoingHome:YES]; return; }
    [self relayoutAnimated:YES];
}

// ---------------------------------------------------------------------
// ---------------------------------------------------------------------
//  Tab tren app toan man: khi 1 app CarPlay dang mo toan man (chua split) -> tab nho o giua mep tren.
//  Cham / vuot xuong tab -> hang icon cac app CarPlay khac; cham icon -> chia man:
//  app dang mo sang ngan trai, app vua chon vao ngan phai.
// ---------------------------------------------------------------------
#define SCPC_TAB_W      64.0
#define SCPC_TAB_H      20.0
#define SCPC_TRAY_ICON  46.0
#define SCPC_TRAY_CELL  66.0
#define SCPC_TRAY_IDLE  8.0     // giay khong cham -> thu hang icon

- (UIView *)tabParent
{
    UIViewController *root = SCPCRootVC();
    UIView *base = objcInvoke(root, @"baseContainerView");
    return base.superview ?: root.view;
}

// App CarPlay dang mo toan man (co the dua vao ngan), nil neu dang o man chinh / app khong ho tro
- (NSString *)fullscreenAppBundle
{
    UIViewController *cur = objcInvoke(SCPCRootVC(), @"currentBaseViewController");
    if (!cur || ![self isAdoptableViewController:cur]) return nil;
    return SCPRealBundleForInfos(objcInvoke(cur, @"applicationInfo"), objcInvoke(cur, @"proxyApplicationInfo"));
}

// Dat view tren app/home nhung duoi Siri (stackedContainerView)
- (BOOL)viewIsRaised:(UIView *)v
{
    UIView *parent = v.superview;
    if (!parent) return NO;
    UIView *stacked = objcInvoke(SCPCRootVC(), @"stackedContainerView");
    NSArray *subs = parent.subviews;
    if (stacked.superview != parent) return subs.lastObject == v;
    NSUInteger i = [subs indexOfObjectIdenticalTo:v], si = [subs indexOfObjectIdenticalTo:stacked];
    return i != NSNotFound && i + 1 == si;
}

- (void)raiseView:(UIView *)v
{
    UIView *parent = v.superview;
    if (!parent || [self viewIsRaised:v]) return;   // da dung cho -> khong dong vao (tranh layout lai)
    UIView *stacked = objcInvoke(SCPCRootVC(), @"stackedContainerView");
    if (stacked.superview == parent) [parent insertSubview:v belowSubview:stacked];
    else [parent bringSubviewToFront:v];
}

- (void)refreshAppTabSoon
{
    __weak SCPCarSplit *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf refreshAppTab];
    });
}

- (void)refreshAppTab
{
    NSString *bid = (!self.active && [SCPPrefs enabled]) ? [self fullscreenAppBundle] : nil;
    UIView *parent = bid ? [self tabParent] : nil;
    if (!bid || !parent) { [self removeAppTab]; return; }

    if (![bid isEqualToString:self.tabBundle]) {
        [self collapseAppTray];
        self.tabBundle = bid;
        SCPLog("CarSplit: tab icon tren %@", bid);
    }
    if (!self.appTab) [self buildAppTab];
    if (self.appTab.superview != parent) [parent addSubview:self.appTab];
    CGRect area = [self appAreaInParent:parent];
    self.appTab.center = CGPointMake(CGRectGetMidX(area), CGRectGetMinY(area) + SCPC_TAB_H / 2 + 3);
    self.appTab.hidden = (self.tray != nil);
    if (self.tray) {
        if (![self viewIsRaised:self.tray]) { [self raiseView:self.trayShield]; [self raiseView:self.tray]; }
    } else {
        [self raiseView:self.appTab];
    }
}

- (void)buildAppTab
{
    SCPCarTabView *t = [[SCPCarTabView alloc] initWithFrame:CGRectMake(0, 0, SCPC_TAB_W, SCPC_TAB_H)];
    t.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.78];
    t.layer.cornerRadius = SCPC_TAB_H / 2;
    t.layer.borderWidth = 1;
    t.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    t.layer.shadowColor = [UIColor blackColor].CGColor;
    t.layer.shadowOpacity = 0.35; t.layer.shadowRadius = 4; t.layer.shadowOffset = CGSizeMake(0, 1);
    id cfg = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold];
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"square.grid.2x2.fill" withConfiguration:cfg]];
    UIImageView *ch = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down" withConfiguration:cfg]];
    iv.tintColor = [UIColor whiteColor]; ch.tintColor = [UIColor whiteColor];
    iv.center = CGPointMake(SCPC_TAB_W / 2 - 9, SCPC_TAB_H / 2);
    ch.center = CGPointMake(SCPC_TAB_W / 2 + 9, SCPC_TAB_H / 2);
    [t addSubview:iv]; [t addSubview:ch];
    [t addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(appTabTapped)]];
    UISwipeGestureRecognizer *sw = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(appTabTapped)];
    sw.direction = UISwipeGestureRecognizerDirectionDown;
    [t addGestureRecognizer:sw];
    self.appTab = t;
}

- (void)removeAppTab
{
    [self collapseAppTray];
    [self.appTab removeFromSuperview];
    self.appTab = nil;
    self.tabBundle = nil;
}

- (void)appTabTapped
{
    if (self.tray) [self collapseAppTray]; else [self expandAppTray];
}

- (void)expandAppTray
{
    UIView *parent = self.appTab.superview;
    NSString *cur = self.tabBundle;
    if (!parent || !cur) return;

    NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
    for (NSDictionary *a in SCPCCarPlayApps()) if (![a[@"id"] isEqualToString:cur]) [apps addObject:a];
    if (!apps.count) { [self toast:@"Không có app CarPlay khác"]; return; }

    CGRect area = [self appAreaInParent:parent];
    // Lop phu: cham ra ngoai hang icon -> thu lai
    UIView *shield = [[UIView alloc] initWithFrame:parent.bounds];
    shield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    shield.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
    [shield addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(collapseAppTray)]];
    [parent addSubview:shield];
    self.trayShield = shield;

    CGFloat padX = 10, h = SCPC_TRAY_ICON + 34;
    CGFloat w = MIN(area.size.width - 16, padX * 2 + apps.count * SCPC_TRAY_CELL);
    UIView *tray = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMidX(area) - w / 2, CGRectGetMinY(area) + 6, w, h)];
    tray.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.96];
    tray.layer.cornerRadius = 18;
    tray.layer.borderWidth = 1;
    tray.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    tray.layer.shadowColor = [UIColor blackColor].CGColor;
    tray.layer.shadowOpacity = 0.5; tray.layer.shadowRadius = 10; tray.layer.shadowOffset = CGSizeMake(0, 3);

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:tray.bounds];
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    scroll.layer.cornerRadius = 18; scroll.clipsToBounds = YES;
    scroll.delegate = (id<UIScrollViewDelegate>)self;
    [tray addSubview:scroll];

    NSMutableArray *cells = [NSMutableArray array];
    NSInteger i = 0;
    for (NSDictionary *app in apps) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(padX + i * SCPC_TRAY_CELL, 0, SCPC_TRAY_CELL, h);
        b.accessibilityIdentifier = app[@"id"];
        [b addTarget:self action:@selector(trayAppTapped:) forControlEvents:UIControlEventTouchUpInside];
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((SCPC_TRAY_CELL - SCPC_TRAY_ICON) / 2, 8, SCPC_TRAY_ICON, SCPC_TRAY_ICON)];
        iv.image = SCPCAppIcon(app[@"id"]);
        iv.layer.cornerRadius = SCPC_TRAY_ICON * 0.225; iv.clipsToBounds = YES;
        iv.backgroundColor = iv.image ? [UIColor clearColor] : [UIColor colorWithWhite:0.3 alpha:1];
        iv.userInteractionEnabled = NO;
        [b addSubview:iv];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(2, 8 + SCPC_TRAY_ICON + 3, SCPC_TRAY_CELL - 4, 14)];
        l.text = app[@"name"];
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        l.textAlignment = NSTextAlignmentCenter;
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        l.userInteractionEnabled = NO;
        [b addSubview:l];
        [scroll addSubview:b];
        [cells addObject:b];
        i++;
    }
    scroll.contentSize = CGSizeMake(padX * 2 + i * SCPC_TRAY_CELL, h);

    [parent addSubview:tray];
    self.tray = tray;
    self.appTab.hidden = YES;
    [self raiseView:shield];
    [self raiseView:tray];

    shield.alpha = 0;
    tray.alpha = 0; tray.transform = CGAffineTransformMakeTranslation(0, -h);
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.4 options:0
                     animations:^{ shield.alpha = 1; tray.alpha = 1; tray.transform = CGAffineTransformIdentity; } completion:nil];
    SCPCPopIn(cells.count > 8 ? [cells subarrayWithRange:NSMakeRange(0, 8)] : cells);
    [self restartTrayTimer];
    SCPLog("CarSplit: hang icon %ld app CarPlay tren %@", (long)i, cur);
}

- (void)restartTrayTimer
{
    [self.trayTimer invalidate];
    __weak SCPCarSplit *weakSelf = self;
    self.trayTimer = [NSTimer scheduledTimerWithTimeInterval:SCPC_TRAY_IDLE repeats:NO block:^(NSTimer *t) { [weakSelf collapseAppTray]; }];
}

// Dang vuot hang icon -> chua tu thu
- (void)scrollViewDidScroll:(UIScrollView *)sv { if (sv.superview == self.tray) [self restartTrayTimer]; }

- (void)collapseAppTray
{
    [self.trayTimer invalidate]; self.trayTimer = nil;
    UIView *tray = self.tray, *shield = self.trayShield;
    self.tray = nil; self.trayShield = nil;
    self.appTab.hidden = NO;
    if (!tray && !shield) return;
    [UIView animateWithDuration:0.2 animations:^{
        tray.alpha = 0; tray.transform = CGAffineTransformMakeTranslation(0, -20); shield.alpha = 0;
    } completion:^(BOOL f) { [tray removeFromSuperview]; [shield removeFromSuperview]; }];
}

- (void)trayAppTapped:(UIButton *)b
{
    NSString *bid = b.accessibilityIdentifier, *cur = self.tabBundle;
    SCPLog("CarSplit: hang icon: %@ (trai) + %@ (phai)", cur, bid);
    [self removeAppTab];
    // Ve Home roi mo ca 2 app vao ngan (activate tu mo lai app dang toan man vao ngan trai)
    [self openPairLeft:cur right:bid];
}

// ---------------------------------------------------------------------
//  CarBridge (YouTube, TikTok... app iPhone tren CarPlay): DashBoard chi tao scene rong (ngan trang),
//  CarBridge tu ve app bang cua so rieng CBWindow (SpringBoard) khi duoc kich hoat tu cham icon.
//  App CarBridge vao ngan -> goi CBBridgeManagerDashboard startBridging:, khung chieu = khung ngan
//  (hook getAppFrame + bao SpringBoard dat lai CBWindow moi khi ngan doi).
// ---------------------------------------------------------------------
#define SCPC_BRIDGE_TOP   16.0    // chua mep tren ngan (thanh "...") khong bi CBWindow che

static id SCPCBridgeManager(void)
{
    Class c = objc_getClass("CBBridgeManagerDashboard");
    return (c && [c respondsToSelector:@selector(sharedInstance)]) ? objcInvoke(c, @"sharedInstance") : nil;
}

static BOOL SCPCIsBridgedApp(NSString *bid)
{
    Class c = objc_getClass("CBBridgeManagerDashboard");
    SEL s = NSSelectorFromString(@"isBridgedApp:");
    if (!c || !bid || ![c respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(c, s, bid);
}

- (SCPCarPane *)bridgedPane
{
    if (!self.bridgedBundle) return nil;
    for (SCPCarPane *p in self.slots) if ([p.bundleID isEqualToString:self.bridgedBundle]) return p;
    return nil;
}

// Khung CBWindow (toa do man xe) cho app CarBridge dang o trong ngan; CGRectZero neu ngan dang an
- (CGRect)bridgeFrame
{
    SCPCarPane *p = [self bridgedPane];
    if (!self.active || !p || p.view.alpha < 0.5 || p.view.bounds.size.width < 20 || !p.view.window) return CGRectZero;
    // Thanh nut cua ngan dang hien -> day khung chieu xuong duoi thanh nut de bam duoc
    CGFloat top = p.bar.hidden ? SCPC_BRIDGE_TOP : SCPC_HANDLE_H + 10 + SCPC_BTN + 6;
    CGRect b = p.view.bounds;
    CGRect r = CGRectMake(0, top, b.size.width, MAX(0, b.size.height - top));
    return [p.view convertRect:r toView:nil];
}

- (void)startBridgeForPane:(SCPCarPane *)p
{
    id mgr = SCPCBridgeManager();
    if (!mgr || !p.bundleID) return;
    if (self.bridgedBundle && ![self.bridgedBundle isEqualToString:p.bundleID]) {
        SCPLog("CarBridge: chi chieu duoc 1 app, thay %@ bang %@", self.bridgedBundle, p.bundleID);
    }
    self.bridgedBundle = p.bundleID;
    self.lastBridgeFrame = CGRectNull;
    self.bridgeStarting = YES;
    SCPLog("CarBridge: chieu %@ vao ngan %d, khung %@", p.bundleID, p.slot, NSStringFromCGRect([self bridgeFrame]));
    NSString *bid = p.bundleID;
    __weak SCPCarSplit *weakSelf = self;
    @try {
        void (^done)(void) = ^{
            SCPLog("CarBridge: da chieu %@", bid);
            [weakSelf pushBridgeFrame];
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, NSSelectorFromString(@"startBridging:withCompletion:"), bid, done);
    } @catch (NSException *e) { SCPLog("CarBridge: startBridging loi %@", e); }
    // Cho CarBridge tao xong CBWindow roi dat khung (vai lan cho chac), het giai doan khoi dong sau 4s
    for (NSNumber *d in @[@1.0, @2.5, @4.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SCPCarSplit *me = weakSelf;
            if (d.doubleValue >= 4.0) me.bridgeStarting = NO;
            [me pushBridgeFrame];
        });
    }
}

- (void)stopBridge
{
    if (!self.bridgedBundle) return;
    SCPLog("CarBridge: dung chieu %@", self.bridgedBundle);
    self.bridgedBundle = nil;
    self.bridgeStarting = NO;
    @try { objcInvoke(SCPCBridgeManager(), @"stopBridging"); } @catch (NSException *e) { SCPLog("CarBridge: stopBridging loi %@", e); }
}

// Bao SpringBoard dat CBWindow dung khung ngan (CBWindow nam trong SpringBoard)
- (void)pushBridgeFrame
{
    if (!self.bridgedBundle) return;
    if (!self.active || ![self bridgedPane]) { [self stopBridge]; return; }
    CGRect r = [self bridgeFrame];
    if (CGRectEqualToRect(r, self.lastBridgeFrame)) return;
    self.lastBridgeFrame = r;
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        postNotificationName:SCP_NOTIF_CBFRAME object:nil
                    userInfo:@{@"identifier": self.bridgedBundle, @"x": @(r.origin.x), @"y": @(r.origin.y),
                               @"w": @(r.size.width), @"h": @(r.size.height)}];
}

- (void)pushBridgeFrameSoon
{
    if (!self.bridgedBundle) return;
    __weak SCPCarSplit *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf pushBridgeFrame];
    });
}

- (void)toast:(NSString *)msg
{
    UIView *host = SCPCRootVC().view;
    if (!host) return;
    UILabel *l = [[UILabel alloc] init];
    l.text = msg;
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.95];
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    l.textAlignment = NSTextAlignmentCenter;
    [l sizeToFit];
    l.bounds = CGRectMake(0, 0, l.bounds.size.width + 36, 40);
    l.layer.cornerRadius = 20; l.clipsToBounds = YES;
    l.center = CGPointMake(CGRectGetMidX(host.bounds), host.bounds.size.height - 50);
    [host addSubview:l];
    l.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:2.2 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL f2) { [l removeFromSuperview]; }];
    }];
}

@end

// ---------------------------------------------------------------------
//  Chan doan CarBridge (YouTube / TikTok trang trong ngan): ghi lop cua CarBridge va cay view cua app
//  khi mo toan man (chay dung) va khi nam trong ngan (trang) de so sanh.
// ---------------------------------------------------------------------
static void SCPCDumpViewInto(UIView *v, int depth, NSMutableArray<NSString *> *out)
{
    if (!v || depth > 9 || out.count >= 90) return;
    CGAffineTransform t = v.transform;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    [out addObject:[NSString stringWithFormat:@"%@%@ %@%@%@%@ layer=%@%@", pad, NSStringFromClass([v class]),
                    NSStringFromCGRect(v.frame),
                    CGAffineTransformIsIdentity(t) ? @"" : [NSString stringWithFormat:@" t=(%.2f,%.2f,%.2f,%.2f)", t.a, t.b, t.c, t.d],
                    v.hidden ? @" HIDDEN" : @"", v.alpha < 1 ? [NSString stringWithFormat:@" a=%.2f", v.alpha] : @"",
                    NSStringFromClass([v.layer class]),
                    v.layer.sublayers.count && !v.subviews.count ? [NSString stringWithFormat:@" sublayers=%lu", (unsigned long)v.layer.sublayers.count] : @""]];
    for (UIView *c in v.subviews) SCPCDumpViewInto(c, depth + 1, out);
}

void SCPCDumpVC(UIViewController *vc, NSString *why)
{
    if (!vc) return;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    SCPCDumpViewInto(vc.view, 0, lines);
    NSString *bid = SCPRealBundleForInfos(objcInvoke(vc, @"applicationInfo"), objcInvoke(vc, @"proxyApplicationInfo"));
    NSMutableArray *childs = [NSMutableArray array];
    for (UIViewController *c in vc.childViewControllers) [childs addObject:NSStringFromClass([c class])];
    SCPLog("DIAG %@ %@ (%@, con: %@):\n%@", why, bid, NSStringFromClass([vc class]),
           childs.count ? [childs componentsJoinedByString:@","] : @"-", [lines componentsJoinedByString:@"\n"]);
}

