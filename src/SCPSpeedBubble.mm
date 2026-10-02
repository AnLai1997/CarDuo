#import "SCPSpeedBubble.h"
#import "SCPSplitWindow.h"
#import "SCPPrefs.h"

#define SCP_SPEED_STALE 5.0   // giay khong co du lieu moi -> an bong bong
#define SCP_RING        56.0  // duong kinh moi vong
#define SCP_RING_GAP    10.0
#define SCP_PAD         8.0

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
@end

@implementation SCPSpeedBubble

+ (instancetype)shared
{
    static SCPSpeedBubble *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SCPSpeedBubble new]; s.speed = -1; s.limit = -1; });
    return s;
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
        self.card.alpha = 0; self.card.transform = CGAffineTransformMakeScale(0.7, 0.7);
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:0
                         animations:^{ self.card.alpha = 1; self.card.transform = CGAffineTransformIdentity; } completion:nil];
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
        [UIView animateWithDuration:0.18 animations:^{ card.alpha = 0; card.transform = CGAffineTransformMakeScale(0.8, 0.8); }
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
    CGRect b = self.window.bounds; CGSize s = self.card.bounds.size; CGPoint c = self.card.center;
    c.x = MIN(CGRectGetMaxX(b) - s.width / 2, MAX(s.width / 2, c.x));
    c.y = MIN(CGRectGetMaxY(b) - s.height / 2, MAX(s.height / 2, c.y));
    self.card.center = c;
}

- (void)panned:(UIPanGestureRecognizer *)g
{
    CGPoint t = [g translationInView:self.window];
    self.card.center = CGPointMake(self.card.center.x + t.x, self.card.center.y + t.y);
    [self clampCard];
    [g setTranslation:CGPointZero inView:self.window];
    if (g.state == UIGestureRecognizerStateEnded) self.savedCenter = self.card.center;
}

// Cham bong bong -> mo lai Vietmap: dang bi che boi toan man ngan khac thi bo toan man; chua co ngan thi mo vao ngan trong
- (void)tapped:(UITapGestureRecognizer *)g
{
    [UIView animateWithDuration:0.1 animations:^{ self.card.transform = CGAffineTransformMakeScale(0.92, 0.92); }
                     completion:^(BOOL f) { [UIView animateWithDuration:0.15 animations:^{ self.card.transform = CGAffineTransformIdentity; }]; }];
    BOOL car = SCPGetCarPlayCADisplay() != nil;
    SCPSplitWindow *w = [SCPSplitWindow currentOrCreateOnMainScreen:!car];
    if (!w) return;
    SCPAppPane *p = [self appPane];
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
