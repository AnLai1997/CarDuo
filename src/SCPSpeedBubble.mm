#import "SCPSpeedBubble.h"
#import "SCPSplitWindow.h"
#import "SCPPrefs.h"

#define SCP_SPEED_STALE 6.0   // giay khong co du lieu moi -> an bong bong

@interface SCPSpeedBubble ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *speedLabel, *unitLabel, *limitLabel;
@property (nonatomic, strong) UIView *limitCircle;
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

// Vietmap dang hien trong 1 ngan nhin thay duoc? (co ngan, ngan khong bi an boi fullscreen ngan khac, co kich thuoc)
- (BOOL)appVisibleInSplit
{
    SCPSplitWindow *w = [SCPSplitWindow current];
    if (!w) return NO;
    for (SCPAppPane *p in w.panes) {
        if (![p.bundleIdentifier isEqualToString:SCP_SPEED_APP]) continue;
        if (p.containerView.hidden) return NO;
        CGSize s = p.containerView.bounds.size;
        return s.width > 1 && s.height > 1;
    }
    return NO;
}

- (void)refresh
{
    BOOL fresh = (CFAbsoluteTimeGetCurrent() - self.lastUpdate) < SCP_SPEED_STALE && self.speed >= 0;
    BOOL show = fresh && [SCPPrefs speedBubble] && ![self appVisibleInSplit];
    if (!show) { [self hide]; return; }
    [self ensureWindow];
    if (!self.window) return;
    self.speedLabel.text = [NSString stringWithFormat:@"%d", self.speed];
    BOOL hasLimit = self.limit > 0;
    self.limitCircle.hidden = !hasLimit;
    self.limitLabel.text = hasLimit ? [NSString stringWithFormat:@"%d", self.limit] : @"";
    // Vuot gioi han -> so toc do do
    self.speedLabel.textColor = (hasLimit && self.speed > self.limit) ? [UIColor systemRedColor] : [UIColor whiteColor];
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
                         completion:^(BOOL f) { if (card.alpha == 0) win.hidden = YES; }];
    }
    [self.timer invalidate]; self.timer = nil;
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
    CGRect screen = w.bounds;
    w.windowLevel = UIWindowLevelStatusBar + 70;   // tren cua so split (1050) va nut launcher (1060)
    w.backgroundColor = [UIColor clearColor];

    // The: [ 68 km/h ] ( 80 )
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 132, 56)];
    card.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.82];
    card.layer.cornerRadius = 28;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.5; card.layer.shadowRadius = 6; card.layer.shadowOffset = CGSizeMake(0, 2);

    UILabel *speed = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, 64, 36)];
    speed.font = [UIFont monospacedDigitSystemFontOfSize:30 weight:UIFontWeightBold];
    speed.textColor = [UIColor whiteColor];
    speed.textAlignment = NSTextAlignmentCenter;
    speed.adjustsFontSizeToFitWidth = YES;
    [card addSubview:speed];
    UILabel *unit = [[UILabel alloc] initWithFrame:CGRectMake(12, 37, 64, 14)];
    unit.text = @"km/h";
    unit.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    unit.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    unit.textAlignment = NSTextAlignmentCenter;
    [card addSubview:unit];

    // Bien gioi han: tron trang, vien do, so den
    UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(84, 6, 44, 44)];
    circle.backgroundColor = [UIColor whiteColor];
    circle.layer.cornerRadius = 22;
    circle.layer.borderWidth = 4;
    circle.layer.borderColor = [UIColor colorWithRed:0.86 green:0.1 blue:0.1 alpha:1].CGColor;
    UILabel *limit = [[UILabel alloc] initWithFrame:circle.bounds];
    limit.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    limit.textColor = [UIColor blackColor];
    limit.textAlignment = NSTextAlignmentCenter;
    limit.adjustsFontSizeToFitWidth = YES;
    [circle addSubview:limit];
    [card addSubview:circle];

    [card addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)]];
    [w addSubview:card];

    // Vi tri mac dinh: goc tren trai (tranh nut launcher o goc tren phai)
    if (CGPointEqualToPoint(self.savedCenter, CGPointZero)) self.savedCenter = CGPointMake(16 + 66, 12 + 28);
    card.center = self.savedCenter;
    (void)screen;

    self.window = w; self.card = card; self.speedLabel = speed; self.unitLabel = unit;
    self.limitLabel = limit; self.limitCircle = circle;
    w.hidden = YES;
    SCPLog("speed bubble: cua so %@ tao xong", car ? @"xe" : @"iPhone");
}

- (void)panned:(UIPanGestureRecognizer *)g
{
    CGPoint t = [g translationInView:self.window];
    CGPoint c = CGPointMake(self.card.center.x + t.x, self.card.center.y + t.y);
    CGRect b = self.window.bounds; CGSize s = self.card.bounds.size;
    c.x = MIN(CGRectGetMaxX(b) - s.width / 2, MAX(s.width / 2, c.x));
    c.y = MIN(CGRectGetMaxY(b) - s.height / 2, MAX(s.height / 2, c.y));
    self.card.center = c;
    [g setTranslation:CGPointZero inView:self.window];
    if (g.state == UIGestureRecognizerStateEnded) self.savedCenter = c;
}

@end
