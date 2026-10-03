#import "SCPSpeedBubble.h"
#import "SCPSplitWindow.h"
#import "SCPCarSplit.h"

static NSSet<NSString *> *sNativeVisible;   // app dang hien trong ngan split CarPlay
#import "SCPPrefs.h"

#define SCP_SPEED_STALE 5.0   // giay khong co du lieu moi -> an bong bong
#define SCP_RING        56.0  // duong kinh moi vong
#define SCP_RING_GAP    10.0
#define SCP_PAD         8.0

// Cua so bong bong phu kin man (de keo tha tu do) nhung PHAI cho cham xuyen qua o moi cho khong co the/nut X,
// neu khong no nuot het cham cua cua so split ben duoi. Cua so xe la UIRootSceneWindow (class rieng cua SpringBoard)
// nen khong subclass tinh duoc -> tao subclass luc chay va doi class cua instance (object_setClass).
static UIView *SCPPassThroughHitTest(id self, SEL _cmd, CGPoint p, UIEvent *e)
{
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    UIView *v = ((UIView *(*)(struct objc_super *, SEL, CGPoint, UIEvent *))objc_msgSendSuper)(&sup, _cmd, p, e);
    return (v == self) ? nil : v;   // cham vao chinh cua so (khong trung subview) -> bo qua, xuong duoi
}

static void SCPMakeWindowPassThrough(UIWindow *w)
{
    Class base = object_getClass(w);
    NSString *name = [NSString stringWithFormat:@"SCPPassThrough_%@", NSStringFromClass(base)];
    Class cls = objc_getClass(name.UTF8String);
    if (!cls) {
        cls = objc_allocateClassPair(base, name.UTF8String, 0);
        Method m = class_getInstanceMethod(base, @selector(hitTest:withEvent:));
        class_addMethod(cls, @selector(hitTest:withEvent:), (IMP)SCPPassThroughHitTest, method_getTypeEncoding(m));
        objc_registerClassPair(cls);
    }
    object_setClass(w, cls);
}

@interface SCPSpeedBubble ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIView *limitRing, *speedRing;
@property (nonatomic, strong) UILabel *limitLabel, *speedLabel, *unitLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) int speed, limit;
@property (nonatomic) CFAbsoluteTime lastUpdate;
@property (nonatomic) CGPoint savedCenter;          // vi tri nguoi dung keo toi (giu giua cac lan hien)
@property (nonatomic) BOOL onPhone;
@property (nonatomic) CGFloat scale;                 // phong to/thu nho bang 2 ngon (0.6 .. 2.2)
@property (nonatomic, strong) UIButton *closeButton; // X do: giu bong bong de hien, bam de tat han Vietmap
@property (nonatomic, strong) NSTimer *closeTimer;
@end

@implementation SCPSpeedBubble

+ (instancetype)shared
{
    static SCPSpeedBubble *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SCPSpeedBubble new]; s.speed = -1; s.limit = -1; s.scale = 1; });
    return s;
}

// Transform goc cua the = ti le nguoi dung chon (moi animation deu nhan them vao day)
- (CGAffineTransform)baseTransform { return CGAffineTransformMakeScale(self.scale, self.scale); }
- (CGAffineTransform)baseScaled:(CGFloat)k { return CGAffineTransformMakeScale(self.scale * k, self.scale * k); }

- (void)setNativeVisibleBundles:(NSArray<NSString *> *)bundles
{
    sNativeVisible = [NSSet setWithArray:bundles ?: @[]];
    [self refresh];
}

- (void)updateSpeed:(int)speed limit:(int)limit
{
    self.speed = speed; self.limit = limit;
    self.lastUpdate = CFAbsoluteTimeGetCurrent();
    [self refresh];
}

// Ngan dang chua Vietmap (neu co)
- (SCPAppPane *)appPane
{
    for (SCPAppPane *p in [SCPSplitWindow current].panes) if ([p.bundleIdentifier isEqualToString:SCP_SPEED_APP]) return p;
    return nil;
}

// Vietmap dang hien trong 1 ngan nhin thay duoc? (ngan khong bi an boi fullscreen ngan khac, co kich thuoc)
- (BOOL)appVisibleInSplit
{
    if ([sNativeVisible containsObject:SCP_SPEED_APP]) return YES;   // dang hien trong ngan split CarPlay
    SCPAppPane *p = [self appPane];
    if (!p || p.containerView.hidden) return NO;
    CGSize s = p.containerView.bounds.size;
    return s.width > 1 && s.height > 1;
}

- (void)refresh
{
    BOOL fresh = (CFAbsoluteTimeGetCurrent() - self.lastUpdate) < SCP_SPEED_STALE && self.speed >= 0;
    BOOL show = fresh && [SCPPrefs speedBubble] && ![self appVisibleInSplit];
    if (!show) { [self hide]; return; }
    [self ensureWindow];
    if (!self.window) return;

    BOOL hasLimit = self.limit > 0;
    // So doi muot: chi dat text, khong animation (cap nhat lien tuc)
    self.speedLabel.text = [NSString stringWithFormat:@"%d", self.speed];
    self.limitLabel.text = hasLimit ? [NSString stringWithFormat:@"%d", self.limit] : @"";
    self.limitRing.hidden = !hasLimit;
    // Vuot gioi han -> vong toc do doi sang do, so do
    BOOL over = hasLimit && self.speed > self.limit;
    self.speedRing.layer.borderColor = (over ? [UIColor colorWithRed:0.86 green:0.1 blue:0.1 alpha:1] : [UIColor colorWithRed:0.2 green:0.55 blue:1.0 alpha:1]).CGColor;
    self.speedLabel.textColor = over ? [UIColor colorWithRed:0.8 green:0.05 blue:0.05 alpha:1] : [UIColor blackColor];
    [self layoutCardKeepingCenter];

    if (self.window.hidden) {
        self.window.hidden = NO;
        self.card.alpha = 0; self.card.transform = [self baseScaled:0.7];
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:0
                         animations:^{ self.card.alpha = 1; self.card.transform = [self baseTransform]; } completion:nil];
    }
    if (!self.timer) {
        __weak SCPSpeedBubble *weakSelf = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { [weakSelf refresh]; }];
    }
}

- (void)hide
{
    if (self.window && !self.window.hidden) {
        UIView *card = self.card; UIWindow *win = self.window;
        [self hideCloseButton];
        [UIView animateWithDuration:0.18 animations:^{ card.alpha = 0; card.transform = [self baseScaled:0.8]; }
                         completion:^(BOOL f) { if (card.alpha < 0.01) win.hidden = YES; }];
    }
    [self.timer invalidate]; self.timer = nil;
}

// Xep 2 vong trong the: [ (gioi han) (toc do) ]; khong co gioi han thi chi 1 vong. Giu tam the co dinh.
- (void)layoutCardKeepingCenter
{
    BOOL hasLimit = !self.limitRing.hidden;
    CGFloat w = SCP_PAD * 2 + SCP_RING + (hasLimit ? SCP_RING + SCP_RING_GAP : 0), h = SCP_PAD * 2 + SCP_RING;
    CGPoint c = self.card.center;
    self.card.bounds = CGRectMake(0, 0, w, h);
    self.card.layer.cornerRadius = h / 2;
    CGFloat x = SCP_PAD;
    if (hasLimit) { self.limitRing.frame = CGRectMake(x, SCP_PAD, SCP_RING, SCP_RING); x += SCP_RING + SCP_RING_GAP; }
    self.speedRing.frame = CGRectMake(x, SCP_PAD, SCP_RING, SCP_RING);
    self.card.center = c;
    [self clampCard];
}

- (void)positionCloseButton
{
    CGRect f = self.card.frame;   // da tinh ti le
    self.closeButton.center = CGPointMake(CGRectGetMaxX(f) - 4, CGRectGetMinY(f) + 4);
}

- (void)hideCloseButton
{
    [self.closeTimer invalidate]; self.closeTimer = nil;
    UIButton *x = self.closeButton;
    if (!x || x.hidden) return;
    [UIView animateWithDuration:0.15 animations:^{ x.alpha = 0; x.transform = CGAffineTransformMakeScale(0.5, 0.5); }
                     completion:^(BOOL f) { x.hidden = YES; x.transform = CGAffineTransformIdentity; }];
}

// Giu bong bong -> hien X 4 giay
- (void)longPressed:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self positionCloseButton];
    UIButton *x = self.closeButton;
    x.hidden = NO; x.alpha = 0; x.transform = CGAffineTransformMakeScale(0.3, 0.3);
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.6 options:0
                     animations:^{ x.alpha = 1; x.transform = CGAffineTransformIdentity; } completion:nil];
    [self.closeTimer invalidate];
    __weak SCPSpeedBubble *weakSelf = self;
    self.closeTimer = [NSTimer scheduledTimerWithTimeInterval:4 repeats:NO block:^(NSTimer *t) { [weakSelf hideCloseButton]; }];
}

// Bam X: tat han Vietmap (dong ngan neu dang co) -> bong bong tu an vi het du lieu
- (void)closeTapped
{
    [self hideCloseButton];
    SCPLog("speed bubble: X -> tat han %@", SCP_SPEED_APP);
    if (SCPGetCarPlayCADisplay()) {   // Vietmap co the dang nam trong ngan split CarPlay -> dong ngan do truoc
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
            postNotificationName:SCP_NOTIF_NATIVE object:nil userInfo:@{@"action": @"closeApp", @"identifier": SCP_SPEED_APP}];
    }
    SCPSplitWindow *w = [SCPSplitWindow current];
    SCPAppPane *p = [self appPane];
    if (w && p) {
        SCPSlot slot = (p == w.leftPane) ? SCPSlotLeft : SCPSlotRight;
        [w closeSlot:slot terminate:YES];
        if (w.panes.count == 0) { if (w.onMainScreen) [w showAppPickerForSlot:SCPSlotLeft]; else [w dismiss]; }
    } else {
        SCPTerminateApp(SCP_SPEED_APP);
    }
    self.speed = -1; self.limit = -1;
    [self hide];
}

// 2 ngon: phong to / thu nho the (0.6x .. 2.2x)
- (void)pinched:(UIPinchGestureRecognizer *)g
{
    static CGFloat startScale = 1;
    if (g.state == UIGestureRecognizerStateBegan) { startScale = self.scale; [self hideCloseButton]; }
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        self.scale = MIN(2.2, MAX(0.6, startScale * g.scale));
        self.card.transform = [self baseTransform];
        [self clampCard];
    }
    if (g.state == UIGestureRecognizerStateEnded) self.savedCenter = self.card.center;
}

- (UIView *)ringWithColor:(UIColor *)color
{
    UIView *ring = [[UIView alloc] initWithFrame:CGRectMake(0, 0, SCP_RING, SCP_RING)];
    ring.backgroundColor = [UIColor whiteColor];
    ring.layer.cornerRadius = SCP_RING / 2;
    ring.layer.borderWidth = 5;
    ring.layer.borderColor = color.CGColor;
    ring.layer.shadowColor = [UIColor blackColor].CGColor;
    ring.layer.shadowOpacity = 0.35; ring.layer.shadowRadius = 3; ring.layer.shadowOffset = CGSizeMake(0, 1);
    return ring;
}

// Cua so rieng: tren man xe neu dang ket noi, neu khong (che do thu) thi tren man iPhone
- (void)ensureWindow
{
    BOOL car = SCPGetCarPlayCADisplay() != nil;
    if (self.window && self.onPhone == !car) return;
    if (self.window) { self.window.hidden = YES; [self.window removeFromSuperview]; self.window = nil; }
    UIWindow *w = car ? SCPMakeCarWindow() : SCPMakePhoneWindow(YES);
    if (!w) return;
    self.onPhone = !car;
    SCPMakeWindowPassThrough(w);
    w.windowLevel = UIWindowLevelStatusBar + 70;   // tren cua so split (1050) va nut launcher (1060)
    w.backgroundColor = [UIColor clearColor];

    // The nen toi mo, ben trong 2 vong giong Vietmap: vong do = gioi han, vong xanh = toc do + km/h
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    card.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.6];
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;

    UIView *limitRing = [self ringWithColor:[UIColor colorWithRed:0.86 green:0.1 blue:0.1 alpha:1]];
    UILabel *limit = [[UILabel alloc] initWithFrame:limitRing.bounds];
    limit.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    limit.textColor = [UIColor blackColor];
    limit.textAlignment = NSTextAlignmentCenter;
    limit.adjustsFontSizeToFitWidth = YES;
    limit.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [limitRing addSubview:limit];

    UIView *speedRing = [self ringWithColor:[UIColor colorWithRed:0.2 green:0.55 blue:1.0 alpha:1]];
    UILabel *speed = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, SCP_RING, 28)];
    speed.font = [UIFont monospacedDigitSystemFontOfSize:24 weight:UIFontWeightBold];
    speed.textColor = [UIColor blackColor];
    speed.textAlignment = NSTextAlignmentCenter;
    speed.adjustsFontSizeToFitWidth = YES;
    [speedRing addSubview:speed];
    UILabel *unit = [[UILabel alloc] initWithFrame:CGRectMake(0, 34, SCP_RING, 12)];
    unit.text = @"km/h";
    unit.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
    unit.textColor = [UIColor colorWithWhite:0.25 alpha:1];
    unit.textAlignment = NSTextAlignmentCenter;
    [speedRing addSubview:unit];

    [card addSubview:limitRing];
    [card addSubview:speedRing];
    [card addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)]];
    [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinched:)];
    [card addGestureRecognizer:pinch];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
    lp.minimumPressDuration = 0.5;
    [card addGestureRecognizer:lp];
    card.transform = [self baseTransform];

    // Nut X do (an san), nam goc tren phai cua the, tren cung cua so de khong bi the che
    UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
    x.bounds = CGRectMake(0, 0, 30, 30);
    x.backgroundColor = [UIColor systemRedColor];
    x.layer.cornerRadius = 15;
    x.layer.borderWidth = 2; x.layer.borderColor = [UIColor whiteColor].CGColor;
    x.tintColor = [UIColor whiteColor];
    [x setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    [x addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    x.hidden = YES;
    [w addSubview:x];
    self.closeButton = x;
    [w addSubview:card];

    self.window = w; self.card = card; self.limitRing = limitRing; self.speedRing = speedRing;
    self.limitLabel = limit; self.speedLabel = speed; self.unitLabel = unit;
    // Vi tri mac dinh: goc tren trai (tranh nut launcher o goc tren phai)
    if (CGPointEqualToPoint(self.savedCenter, CGPointZero)) self.savedCenter = CGPointMake(16 + 70, 12 + 36);
    card.center = self.savedCenter;
    w.hidden = YES;
    SCPLog("speed bubble: cua so %@ tao xong", car ? @"xe" : @"iPhone");
}

- (void)clampCard
{
    CGRect b = self.window.bounds; CGSize s = self.card.frame.size; CGPoint c = self.card.center;   // frame da tinh ti le
    c.x = MIN(CGRectGetMaxX(b) - s.width / 2, MAX(s.width / 2, c.x));
    c.y = MIN(CGRectGetMaxY(b) - s.height / 2, MAX(s.height / 2, c.y));
    self.card.center = c;
}

- (void)panned:(UIPanGestureRecognizer *)g
{
    if (g.state == UIGestureRecognizerStateBegan) [self hideCloseButton];
    CGPoint t = [g translationInView:self.window];
    self.card.center = CGPointMake(self.card.center.x + t.x, self.card.center.y + t.y);
    [self clampCard];
    [g setTranslation:CGPointZero inView:self.window];
    if (g.state == UIGestureRecognizerStateEnded) self.savedCenter = self.card.center;
}

// Cham bong bong -> mo lai Vietmap: dang bi che boi toan man ngan khac thi bo toan man; chua co ngan thi mo vao ngan trong
- (void)tapped:(UITapGestureRecognizer *)g
{
    if (self.closeButton && !self.closeButton.hidden) { [self hideCloseButton]; return; }   // dang hien X: cham ngoai X -> chi an X
    [UIView animateWithDuration:0.1 animations:^{ self.card.transform = [self baseScaled:0.92]; }
                     completion:^(BOOL f) { [UIView animateWithDuration:0.15 animations:^{ self.card.transform = [self baseTransform]; }]; }];
    BOOL car = SCPGetCarPlayCADisplay() != nil;
    SCPAppPane *p = [self appPane];
    if (car && !p) {
        // Tren xe: mo Vietmap bang giao dien CarPlay trong split CarPlay
        SCPLog("speed bubble: cham -> mo Vietmap trong split CarPlay");
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
            postNotificationName:SCP_NOTIF_NATIVE object:nil userInfo:@{@"action": @"open", @"identifier": SCP_SPEED_APP}];
        return;
    }
    SCPSplitWindow *w = [SCPSplitWindow currentOrCreateOnMainScreen:!car];
    if (!w) return;
    if (p) {
        SCPLog("speed bubble: cham -> hien lai Vietmap");
        if (w.fullscreenSlot != SCPSlotAuto) [w toggleFullscreenForSlot:w.fullscreenSlot];   // bo toan man ngan kia
        SCPSlot mySlot = (p == w.leftPane) ? SCPSlotLeft : SCPSlotRight;
        if (w.pipSlot != SCPSlotAuto && w.pipSlot != mySlot) [w togglePiPForSlot:w.pipSlot];   // ngan kia dang PiP de len -> tra ve
    } else {
        SCPLog("speed bubble: cham -> mo Vietmap vao ngan trong");
        [w launchApp:SCP_SPEED_APP inSlot:SCPSlotAuto];
    }
    [self refresh];
}

@end
