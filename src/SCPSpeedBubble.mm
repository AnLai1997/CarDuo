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
@property (nonatomic) BOOL onPhone;
@property (nonatomic) CGFloat scale;                 // phong to/thu nho bang 2 ngon (0.6 .. 2.2)
@property (nonatomic, strong) UIButton *closeButton; // X do: giu bong bong de hien, bam de tat han Vietmap
@property (nonatomic, strong) NSTimer *closeTimer;
@property (nonatomic) NSInteger builtStyle;          // kieu dang ve trong the (-1 = chua ve)
@property (nonatomic, strong) CAShapeLayer *gaugeTrack, *gaugeArc;   // kieu Dong ho
@property (nonatomic, strong) UIView *stateBar;      // kieu HUD: vach mau ben trai
@property (nonatomic, strong) UIView *flashView;     // nen / quang do nhay khi vuot gioi han (moi kieu)
@property (nonatomic, strong) NSTimer *demoTimer;    // "Xem thu bong bong" trong Cai dat
@property (nonatomic) CGFloat appliedRotation;       // goc xoay dang ap cho cua so tren iPhone
@property (nonatomic) CGPoint phoneFraction, carFraction;   // vi tri the theo ti le man (-1 = mac dinh), rieng iPhone / xe
@end

@implementation SCPSpeedBubble

+ (instancetype)shared
{
    static SCPSpeedBubble *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [SCPSpeedBubble new]; s.speed = -1; s.limit = -1; s.scale = 1; s.builtStyle = -1;
        s.phoneFraction = CGPointMake(-1, -1); s.carFraction = CGPointMake(-1, -1);
        [s startOrientationTracking];
    });
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
    if (self.onPhone) [self applyPhoneOrientationForce:NO];

    NSInteger style = [SCPPrefs speedBubbleStyle];
    if (style != self.builtStyle) [self buildStyle:style];
    // So doi muot: chi dat text, khong animation (cap nhat lien tuc)
    [self renderStyle];

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

// =====================================================================
//  Cac kieu bong bong (Cai dat > Bong bong toc do > Kieu hien thi)
//    0 Vietmap      : 2 vong trang (do = gioi han, xanh = toc do) trong the toi
//    1 Toi gian     : so toc do lon + km/h, bien gioi han nho ben phai
//    2 Bien bao     : bien gioi han lon, toc do trong o tron nho o goc
//    3 Dong ho      : cung 270 do chay theo toc do, so o giua, bien nho ben duoi
//    4 Thanh HUD    : thanh ngang mong, vach mau trang thai ben trai
//    5 Mau toc do   : hinh tron to mau xanh la / cam / do theo muc vuot gioi han
// =====================================================================
static UIColor *SCPBlue(void)   { return [UIColor colorWithRed:0.2 green:0.55 blue:1.0 alpha:1]; }
static UIColor *SCPRed(void)    { return [UIColor colorWithRed:0.86 green:0.1 blue:0.1 alpha:1]; }
static UIColor *SCPOrange(void) { return [UIColor colorWithRed:1.0 green:0.58 blue:0.0 alpha:1]; }
static UIColor *SCPGreen(void)  { return [UIColor colorWithRed:0.18 green:0.72 blue:0.33 alpha:1]; }

// 0 = binh thuong, 1 = sap cham gioi han (>= 90%), 2 = vuot
- (int)speedState
{
    if (self.limit <= 0) return 0;
    if (self.speed > self.limit) return 2;
    if (self.speed >= self.limit * 0.9) return 1;
    return 0;
}

- (UIColor *)stateColor
{
    switch ([self speedState]) {
        case 2: return SCPRed();
        case 1: return SCPOrange();
        default: return self.limit > 0 ? SCPGreen() : SCPBlue();
    }
}

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)w color:(UIColor *)c mono:(BOOL)mono
{
    UILabel *l = [[UILabel alloc] init];
    l.font = mono ? [UIFont monospacedDigitSystemFontOfSize:size weight:w] : [UIFont systemFontOfSize:size weight:w];
    l.textColor = c;
    l.textAlignment = NSTextAlignmentCenter;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.5;
    return l;
}

// Bien gioi han: tron trang, vien do, so den
- (UIView *)limitSignWithDiameter:(CGFloat)d border:(CGFloat)bw fontSize:(CGFloat)fs
{
    UIView *ring = [self ringWithColor:SCPRed()];
    ring.bounds = CGRectMake(0, 0, d, d);
    ring.layer.cornerRadius = d / 2;
    ring.layer.borderWidth = bw;
    UILabel *l = [self labelWithSize:fs weight:UIFontWeightBold color:[UIColor blackColor] mono:NO];
    l.frame = CGRectInset(ring.bounds, bw, bw);
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [ring addSubview:l];
    self.limitLabel = l;
    return ring;
}

- (void)buildStyle:(NSInteger)style
{
    UIView *card = self.card;
    for (UIView *v in [card.subviews copy]) [v removeFromSuperview];
    [self.gaugeTrack removeFromSuperlayer]; [self.gaugeArc removeFromSuperlayer];
    self.gaugeTrack = nil; self.gaugeArc = nil; self.stateBar = nil; self.flashView = nil;
    self.limitRing = nil; self.speedRing = nil; self.limitLabel = nil; self.speedLabel = nil; self.unitLabel = nil;
    card.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.6];
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
    card.layer.shadowOpacity = 0;

    switch (style) {
    case 1: {   // Toi gian
        card.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.78];
        self.speedLabel = [self labelWithSize:34 weight:UIFontWeightHeavy color:[UIColor whiteColor] mono:YES];
        self.unitLabel = [self labelWithSize:11 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.7 alpha:1] mono:NO];
        self.limitRing = [self limitSignWithDiameter:34 border:4 fontSize:15];
        [card addSubview:self.speedLabel]; [card addSubview:self.unitLabel]; [card addSubview:self.limitRing];
        break;
    }
    case 2: {   // Bien bao
        card.backgroundColor = [UIColor clearColor];
        card.layer.borderWidth = 0;
        self.limitRing = [self limitSignWithDiameter:72 border:8 fontSize:30];
        UIView *bubble = [[UIView alloc] init];
        bubble.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        bubble.layer.borderWidth = 2; bubble.layer.borderColor = [UIColor whiteColor].CGColor;
        bubble.layer.shadowColor = [UIColor blackColor].CGColor;
        bubble.layer.shadowOpacity = 0.4; bubble.layer.shadowRadius = 3; bubble.layer.shadowOffset = CGSizeMake(0, 1);
        self.speedRing = bubble;
        self.speedLabel = [self labelWithSize:20 weight:UIFontWeightBold color:[UIColor whiteColor] mono:YES];
        [bubble addSubview:self.speedLabel];
        [card addSubview:self.limitRing]; [card addSubview:bubble];
        break;
    }
    case 3: {   // Dong ho
        card.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.8];
        CAShapeLayer *track = [CAShapeLayer layer], *arc = [CAShapeLayer layer];
        for (CAShapeLayer *l in @[track, arc]) {
            l.fillColor = [UIColor clearColor].CGColor;
            l.lineWidth = 7; l.lineCap = kCALineCapRound;
            [card.layer addSublayer:l];
        }
        track.strokeColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
        self.gaugeTrack = track; self.gaugeArc = arc;
        self.speedLabel = [self labelWithSize:30 weight:UIFontWeightHeavy color:[UIColor whiteColor] mono:YES];
        self.unitLabel = [self labelWithSize:10 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.7 alpha:1] mono:NO];
        self.limitRing = [self limitSignWithDiameter:38 border:4.5 fontSize:17];
        [card addSubview:self.speedLabel]; [card addSubview:self.unitLabel]; [card addSubview:self.limitRing];
        break;
    }
    case 4: {   // Thanh HUD
        card.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.72];
        self.stateBar = [[UIView alloc] init];
        self.speedLabel = [self labelWithSize:26 weight:UIFontWeightBold color:[UIColor whiteColor] mono:YES];
        self.speedLabel.textAlignment = NSTextAlignmentRight;
        self.unitLabel = [self labelWithSize:12 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.7 alpha:1] mono:NO];
        self.unitLabel.textAlignment = NSTextAlignmentLeft;
        self.limitRing = [self limitSignWithDiameter:32 border:4 fontSize:14];
        for (UIView *v in @[self.stateBar, self.speedLabel, self.unitLabel, self.limitRing]) [card addSubview:v];
        break;
    }
    case 5: {   // Mau theo toc do
        card.backgroundColor = [UIColor clearColor];
        card.layer.borderWidth = 0;
        UIView *disc = [[UIView alloc] init];
        disc.layer.borderWidth = 3; disc.layer.borderColor = [UIColor whiteColor].CGColor;
        disc.layer.shadowColor = [UIColor blackColor].CGColor;
        disc.layer.shadowOpacity = 0.45; disc.layer.shadowRadius = 4; disc.layer.shadowOffset = CGSizeMake(0, 2);
        self.speedRing = disc;
        self.speedLabel = [self labelWithSize:30 weight:UIFontWeightHeavy color:[UIColor whiteColor] mono:YES];
        self.unitLabel = [self labelWithSize:10 weight:UIFontWeightBold color:[UIColor colorWithWhite:1 alpha:0.85] mono:NO];
        [disc addSubview:self.speedLabel]; [disc addSubview:self.unitLabel];
        self.limitRing = [self limitSignWithDiameter:30 border:4 fontSize:13];
        [card addSubview:disc]; [card addSubview:self.limitRing];
        break;
    }
    default: {  // 0 Vietmap: 2 vong
        UIView *limitRing = [self limitSignWithDiameter:SCP_RING border:5 fontSize:24];
        UIView *speedRing = [self ringWithColor:SCPBlue()];
        self.speedLabel = [self labelWithSize:24 weight:UIFontWeightBold color:[UIColor blackColor] mono:YES];
        self.speedLabel.frame = CGRectMake(0, 8, SCP_RING, 28);
        self.unitLabel = [self labelWithSize:9 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.25 alpha:1] mono:NO];
        self.unitLabel.frame = CGRectMake(0, 34, SCP_RING, 12);
        [speedRing addSubview:self.speedLabel]; [speedRing addSubview:self.unitLabel];
        self.limitRing = limitRing; self.speedRing = speedRing;
        [card addSubview:limitRing]; [card addSubview:speedRing];
        style = 0;
        break;
    }
    }
    UIView *flash = [[UIView alloc] init];
    flash.backgroundColor = SCPRed();
    flash.alpha = 0;
    flash.userInteractionEnabled = NO;
    [card insertSubview:flash atIndex:0];   // sau noi dung (ke ca cung cua kieu Dong ho)
    self.flashView = flash;
    self.unitLabel.text = @"km/h";
    self.builtStyle = style;
    SCPLog("speed bubble: kieu %ld", (long)style);
}

// Vuot gioi han (moi kieu): nen / quang do nhay, bien gioi han dap theo nhip
- (void)setOverLimitWarning:(BOOL)on
{
    UIView *f = self.flashView;
    BOOL running = [f.layer animationForKey:@"scpFlash"] != nil;
    if (on == running) return;
    if (on) {
        CABasicAnimation *blink = [CABasicAnimation animationWithKeyPath:@"opacity"];
        blink.fromValue = @0.0; blink.toValue = @0.75;
        blink.duration = 0.35; blink.autoreverses = YES; blink.repeatCount = HUGE_VALF;
        blink.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        f.alpha = 1; f.layer.opacity = 0;
        [f.layer addAnimation:blink forKey:@"scpFlash"];
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        pulse.fromValue = @1.0; pulse.toValue = @1.18;
        pulse.duration = 0.35; pulse.autoreverses = YES; pulse.repeatCount = HUGE_VALF;
        [self.limitRing.layer addAnimation:pulse forKey:@"scpPulse"];
        SCPLog("speed bubble: vuot gioi han -> nhay canh bao");
    } else {
        [f.layer removeAnimationForKey:@"scpFlash"];
        f.alpha = 0;
        [self.limitRing.layer removeAnimationForKey:@"scpPulse"];
    }
}

// Dat so + mau + bo cuc theo kieu, giu tam the co dinh
- (void)renderStyle
{
    BOOL hasLimit = self.limit > 0;
    int state = [self speedState];
    UIColor *sc = [self stateColor];
    self.speedLabel.text = [NSString stringWithFormat:@"%d", self.speed];
    self.limitLabel.text = hasLimit ? [NSString stringWithFormat:@"%d", self.limit] : @"";
    self.limitRing.hidden = !hasLimit;

    CGPoint c = self.card.center;
    CGSize size;
    switch (self.builtStyle) {
    case 1: {   // Toi gian
        CGFloat numW = 66, h = 64;
        size = CGSizeMake(10 + numW + (hasLimit ? 8 + 34 : 0) + 10, h);
        self.speedLabel.frame = CGRectMake(10, 6, numW, 38);
        self.unitLabel.frame = CGRectMake(10, 44, numW, 14);
        self.limitRing.center = CGPointMake(10 + numW + 8 + 17, h / 2);
        self.speedLabel.textColor = state == 2 ? SCPRed() : (state == 1 ? SCPOrange() : [UIColor whiteColor]);
        self.card.layer.cornerRadius = 14;
        break;
    }
    case 2: {   // Bien bao
        CGFloat sign = 72, bub = 44;
        if (hasLimit) {
            size = CGSizeMake(sign + bub / 2, sign + bub / 2);
            self.limitRing.center = CGPointMake(sign / 2, sign / 2);
            self.speedRing.frame = CGRectMake(size.width - bub, size.height - bub, bub, bub);
        } else {
            bub = 60;
            size = CGSizeMake(bub, bub);
            self.speedRing.frame = CGRectMake(0, 0, bub, bub);
        }
        self.speedRing.layer.cornerRadius = bub / 2;
        self.speedLabel.frame = CGRectInset(self.speedRing.bounds, 4, 4);
        self.speedRing.backgroundColor = state == 2 ? SCPRed() : [UIColor colorWithWhite:0.08 alpha:0.92];
        self.card.layer.cornerRadius = 0;
        break;
    }
    case 3: {   // Dong ho
        CGFloat d = 112;
        size = CGSizeMake(d, d);
        CGPoint mid = CGPointMake(d / 2, d / 2);
        UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:mid radius:d / 2 - 10
                                                        startAngle:M_PI * 0.75 endAngle:M_PI * 2.25 clockwise:YES];
        self.gaugeTrack.path = path.CGPath; self.gaugeArc.path = path.CGPath;
        self.gaugeTrack.frame = CGRectMake(0, 0, d, d); self.gaugeArc.frame = CGRectMake(0, 0, d, d);
        CGFloat maxV = hasLimit ? MAX(self.limit * 1.3, 40) : 160;
        [CATransaction begin]; [CATransaction setAnimationDuration:0.4];
        self.gaugeArc.strokeEnd = MIN(1.0, MAX(0.0, self.speed / maxV));
        self.gaugeArc.strokeColor = sc.CGColor;
        [CATransaction commit];
        self.speedLabel.frame = CGRectMake(14, d / 2 - 30, d - 28, 34);
        self.unitLabel.frame = CGRectMake(14, d / 2 + 2, d - 28, 12);
        self.limitRing.center = CGPointMake(d / 2, d - 22);
        self.card.layer.cornerRadius = d / 2;
        break;
    }
    case 4: {   // Thanh HUD
        CGFloat h = 46;
        size = CGSizeMake(8 + 6 + 8 + 50 + 4 + 34 + (hasLimit ? 10 + 32 : 0) + 10, h);
        self.stateBar.frame = CGRectMake(8, 9, 6, h - 18);
        self.stateBar.layer.cornerRadius = 3;
        self.stateBar.backgroundColor = sc;
        self.speedLabel.frame = CGRectMake(22, 6, 50, h - 12);
        self.unitLabel.frame = CGRectMake(76, 14, 34, h - 22);
        self.limitRing.center = CGPointMake(76 + 34 + 10 + 16, h / 2);
        self.speedLabel.textColor = state == 2 ? SCPRed() : [UIColor whiteColor];
        self.card.layer.cornerRadius = h / 2;
        break;
    }
    case 5: {   // Mau theo toc do
        CGFloat d = 78;
        size = hasLimit ? CGSizeMake(d + 12, d + 6) : CGSizeMake(d, d);
        self.speedRing.frame = CGRectMake(0, size.height - d, d, d);
        self.speedRing.layer.cornerRadius = d / 2;
        self.speedRing.backgroundColor = sc;
        self.speedLabel.frame = CGRectMake(8, d / 2 - 22, d - 16, 34);
        self.unitLabel.frame = CGRectMake(8, d / 2 + 10, d - 16, 12);
        self.limitRing.center = CGPointMake(size.width - 15, 15);
        self.card.layer.cornerRadius = 0;
        break;
    }
    default: {  // Vietmap
        size = CGSizeMake(SCP_PAD * 2 + SCP_RING + (hasLimit ? SCP_RING + SCP_RING_GAP : 0), SCP_PAD * 2 + SCP_RING);
        CGFloat x = SCP_PAD;
        if (hasLimit) { self.limitRing.frame = CGRectMake(x, SCP_PAD, SCP_RING, SCP_RING); x += SCP_RING + SCP_RING_GAP; }
        self.speedRing.frame = CGRectMake(x, SCP_PAD, SCP_RING, SCP_RING);
        // Vuot gioi han -> vong toc do doi sang do, so do
        self.speedRing.layer.borderColor = (state == 2 ? SCPRed() : SCPBlue()).CGColor;
        self.speedLabel.textColor = state == 2 ? [UIColor colorWithRed:0.8 green:0.05 blue:0.05 alpha:1] : [UIColor blackColor];
        self.card.layer.cornerRadius = size.height / 2;
        break;
    }
    }
    self.card.bounds = CGRectMake(0, 0, size.width, size.height);
    self.card.center = c;
    // Vung nhay: the toi -> ca the; kieu khong co nen (Bien bao, Mau toc do) -> quang tron quanh hinh chinh
    UIView *halo = (self.builtStyle == 2) ? self.limitRing : (self.builtStyle == 5 ? self.speedRing : nil);
    if (halo) {
        CGRect r = CGRectInset(halo.frame, -7, -7);
        self.flashView.frame = r;
        self.flashView.layer.cornerRadius = r.size.width / 2;
    } else {
        self.flashView.frame = CGRectMake(0, 0, size.width, size.height);
        self.flashView.layer.cornerRadius = self.card.layer.cornerRadius;
    }
    [self setOverLimitWarning:(state == 2)];
    [self clampCard];
}

// "Xem thu bong bong" trong Cai dat: toc do gia 10 giay (tang qua gioi han 60 de thay doi mau)
- (void)runDemo
{
    [self.demoTimer invalidate];
    __block int tick = 0;
    SCPLog("speed bubble: xem thu 10 giay");
    __weak SCPSpeedBubble *weakSelf = self;
    self.demoTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        tick++;
        if (tick > 20) { [t invalidate]; weakSelf.demoTimer = nil; return; }
        int speed = 40 + tick * 2;   // 42 -> 80 km/h
        [weakSelf updateSpeed:speed limit:60];
    }];
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
    if (g.state == UIGestureRecognizerStateEnded) [self saveCardPosition];
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
    UIWindow *w = car ? SCPMakeCarWindow() : SCPMakePhoneWindow(NO);   // iPhone: xoay theo huong may (applyPhoneOrientation)
    if (!w) return;
    self.onPhone = !car;
    SCPMakeWindowPassThrough(w);
    w.windowLevel = UIWindowLevelStatusBar + 70;   // tren cua so split (1050) va nut launcher (1060)
    w.backgroundColor = [UIColor clearColor];

    // The chua noi dung theo kieu da chon (xem buildStyle:)
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
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

    self.window = w; self.card = card;
    self.builtStyle = -1;   // ve lai noi dung trong the moi
    if (!car) [self applyPhoneOrientationForce:YES];
    [self restoreCardPosition];
    w.hidden = YES;
    SCPLog("speed bubble: cua so %@ tao xong", car ? @"xe" : @"iPhone");
}

// ---------------------------------------------------------------------
//  Huong & vi tri
//  iPhone: cua so xoay theo huong cam may (doc / ngang trai / ngang phai); cua so split thu dang mo (ngang) thi theo no.
//  CarPlay: cua so nam tren man xe (huong cua man xe), vi tri mac dinh ben phai dock CarPlay.
// ---------------------------------------------------------------------
- (void)startOrientationTracking
{
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    __weak SCPSpeedBubble *weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification object:nil
                                                       queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        SCPSpeedBubble *me = weakSelf;
        if (me.window && me.onPhone) [me applyPhoneOrientationForce:NO];
    }];
}

// Goc xoay noi dung tren iPhone (giu goc cu khi may nam ngua / up / khong ro)
- (CGFloat)phoneRotation
{
    SCPSplitWindow *sw = [SCPSplitWindow current];
    if (sw && sw.onMainScreen) return M_PI_2;   // giong cua so split thu (SCPMakePhoneWindow ngang)
    switch ([UIDevice currentDevice].orientation) {
        case UIDeviceOrientationPortrait:      return 0;
        case UIDeviceOrientationLandscapeLeft: return M_PI_2;
        case UIDeviceOrientationLandscapeRight: return -M_PI_2;
        default: return self.appliedRotation;
    }
}

- (void)applyPhoneOrientationForce:(BOOL)force
{
    if (!self.window || !self.onPhone) return;
    CGFloat r = [self phoneRotation];
    if (!force && fabs(r - self.appliedRotation) < 0.01) return;
    BOOL wasVisible = !self.window.hidden && self.card.bounds.size.width > 10;
    if (wasVisible && !force) [self saveCardPosition];
    CGRect sb = [UIScreen mainScreen].bounds;
    BOOL land = fabs(r) > 0.1;
    self.window.transform = CGAffineTransformMakeRotation(r);
    self.window.bounds = land ? CGRectMake(0, 0, sb.size.height, sb.size.width) : CGRectMake(0, 0, sb.size.width, sb.size.height);
    self.window.center = CGPointMake(CGRectGetMidX(sb), CGRectGetMidY(sb));
    self.appliedRotation = r;
    [self restoreCardPosition];
    SCPLog("speed bubble: iPhone xoay %.0f do", r * 180 / M_PI);
}

// Vi tri mac dinh: iPhone = goc tren trai (duoi thanh trang thai); xe = ngay ben phai dock CarPlay
- (CGPoint)defaultCardCenter
{
    CGRect b = self.window.bounds;
    if (self.onPhone) return CGPointMake(16 + 70, b.size.height > b.size.width ? 70 : 12 + 40);
    return CGPointMake(MIN(b.size.width - 80, 90 + 80), 12 + 40);
}

- (void)saveCardPosition
{
    CGRect b = self.window.bounds;
    if (b.size.width < 1 || b.size.height < 1) return;
    CGPoint f = CGPointMake(self.card.center.x / b.size.width, self.card.center.y / b.size.height);
    if (self.onPhone) self.phoneFraction = f; else self.carFraction = f;
}

- (void)restoreCardPosition
{
    CGRect b = self.window.bounds;
    CGPoint f = self.onPhone ? self.phoneFraction : self.carFraction;
    self.card.center = (f.x < 0) ? [self defaultCardCenter] : CGPointMake(f.x * b.size.width, f.y * b.size.height);
    [self clampCard];
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
    if (g.state == UIGestureRecognizerStateEnded) [self saveCardPosition];
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
