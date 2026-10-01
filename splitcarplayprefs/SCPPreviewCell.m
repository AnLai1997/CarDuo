#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

#define SCP_DOMAIN @"com.anpham.splitcarplay"

@interface UIImage (SCPPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)format scale:(double)scale;
@end

// ---------------------------------------------------------------------
//  SCPPreviewView: mo phong man CarPlay voi dock, 2 ngan, icon app
// ---------------------------------------------------------------------
@interface SCPPreviewView : UIView
@property (nonatomic, strong) UIView *screenView;
@property (nonatomic, strong) UIView *leftPane, *rightPane;
@property (nonatomic, strong) UIImageView *leftIcon, *rightIcon;
@property (nonatomic, strong) UILabel *leftLabel, *rightLabel, *infoLabel;
@property (nonatomic, strong) UIView *leftPhone, *rightPhone;
@property (nonatomic, strong) UILabel *leftTime, *rightTime;
@property (nonatomic, strong) UILabel *leftDots, *rightDots;   // dau "..." tren dau moi ngan
@property (nonatomic, strong) UIView *wallpaper, *divider;
- (void)reload;
@end

@implementation SCPPreviewView

- (instancetype)initWithFrame:(CGRect)frame
{
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [UIColor clearColor];

    _screenView = [[UIView alloc] init];
    _screenView.backgroundColor = [UIColor blackColor];
    _screenView.layer.cornerRadius = 10;
    _screenView.layer.borderWidth = 3;
    _screenView.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:1].CGColor;
    _screenView.clipsToBounds = YES;
    [self addSubview:_screenView];

    // Hinh nen kieu CarPlay (gradient toi)
    _wallpaper = [[UIView alloc] init];
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors = @[(id)[UIColor colorWithRed:0.10 green:0.12 blue:0.22 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:0.02 green:0.03 blue:0.08 alpha:1].CGColor];
    g.startPoint = CGPointMake(0, 0); g.endPoint = CGPointMake(1, 1);
    [_wallpaper.layer addSublayer:g];
    [_screenView addSubview:_wallpaper];

    _leftPane  = [self makePaneWithColor:[UIColor colorWithWhite:0.06 alpha:1]];
    _rightPane = [self makePaneWithColor:[UIColor colorWithWhite:0.06 alpha:1]];
    _leftTime  = [self makeStatusIn:_leftPane];
    _rightTime = [self makeStatusIn:_rightPane];
    _divider = [[UIView alloc] init];
    _divider.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    [_screenView addSubview:_divider];

    _leftPhone  = [self makePhoneIn:_leftPane];
    _rightPhone = [self makePhoneIn:_rightPane];
    _leftIcon   = [self makeIconIn:_leftPane];
    _rightIcon  = [self makeIconIn:_rightPane];
    _leftLabel  = [self makeLabelIn:_leftPane];
    _rightLabel = [self makeLabelIn:_rightPane];
    _leftDots   = [self makeDotsIn:_leftPane];
    _rightDots  = [self makeDotsIn:_rightPane];

    _infoLabel = [[UILabel alloc] init];
    _infoLabel.font = [UIFont systemFontOfSize:12];
    _infoLabel.textColor = [UIColor secondaryLabelColor];
    _infoLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_infoLabel];

    int tok = 0;
    __weak SCPPreviewView *weakSelf = self;
    notify_register_dispatch("com.anpham.splitcarplay.prefschanged", &tok, dispatch_get_main_queue(), ^(int t) {
        [weakSelf reload];
    });
    return self;
}

- (UIView *)makePaneWithColor:(UIColor *)c
{
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = c;
    v.clipsToBounds = YES;
    // Vien quanh app nhu tren xe
    v.layer.borderWidth = 1;
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    v.layer.cornerRadius = 4;
    [_screenView addSubview:v];
    return v;
}

// Dau "..." o giua mep tren ngan: keo xuong de hien option cua ngan
- (UILabel *)makeDotsIn:(UIView *)pane
{
    UILabel *l = [[UILabel alloc] init];
    l.text = @"•••";
    l.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    l.clipsToBounds = YES;
    [pane addSubview:l];
    return l;
}

// Thanh trang thai gia cua app (gio + pin) de giong app that
- (UILabel *)makeStatusIn:(UIView *)pane
{
    UILabel *l = [[UILabel alloc] init];
    l.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    l.textAlignment = NSTextAlignmentCenter;
    l.adjustsFontSizeToFitWidth = YES;
    [pane addSubview:l];
    return l;
}

- (UIView *)makePhoneIn:(UIView *)pane
{
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    v.layer.cornerRadius = 3;
    [pane addSubview:v];
    return v;
}

- (UIImageView *)makeIconIn:(UIView *)pane
{
    UIImageView *iv = [[UIImageView alloc] init];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 7;
    iv.clipsToBounds = YES;
    [pane addSubview:iv];
    return iv;
}

- (UILabel *)makeLabelIn:(UIView *)pane
{
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.6;
    [pane addSubview:l];
    return l;
}

// ---- prefs ----
static id prefValue(NSString *key)
{
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)SCP_DOMAIN);
    return v ? CFBridgingRelease(v) : nil;
}

static NSString *appName(NSString *bid)
{
    if (!bid) return @"(chưa chọn)";
    Class LSProxy = objc_getClass("LSApplicationProxy");
    if (LSProxy) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(LSProxy, NSSelectorFromString(@"applicationProxyForIdentifier:"), bid);
        NSString *name = proxy ? ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"localizedName")) : nil;
        if (name.length) return name;
    }
    return bid;
}

static UIImage *appIcon(NSString *bid)
{
    if (!bid) return nil;
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        return [UIImage _applicationIconImageForBundleIdentifier:bid format:2 scale:[UIScreen mainScreen].scale];
    }
    return nil;
}

- (void)reload
{
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    NSString *left = prefValue(@"LeftApp"), *right = prefValue(@"RightApp");
    NSInteger orient = prefValue(@"PaneOrientation") ? [prefValue(@"PaneOrientation") integerValue] : 1;
    CGFloat ratio = prefValue(@"SplitRatio") ? [prefValue(@"SplitRatio") doubleValue] : 0.5;
    ratio = MIN(0.7, MAX(0.3, ratio));

    // Ti le man xe theo Settings (16:9 mac dinh), can giua
    NSString *aspect = prefValue(@"ScreenAspect") ?: @"16:9";
    CGFloat aw = 16, ah = 9;
    if ([aspect isEqualToString:@"5:3"]) { aw = 5; ah = 3; }
    else if ([aspect isEqualToString:@"8:3"]) { aw = 8; ah = 3; }
    CGFloat W = self.bounds.size.width - 24, H = W * ah / aw;
    CGFloat maxH = self.bounds.size.height - 30;
    if (H > maxH) { H = maxH; W = H * aw / ah; }
    CGFloat x = (self.bounds.size.width - W) / 2;
    _screenView.frame = CGRectMake(x, 4, W, H);

    _wallpaper.frame = _screenView.bounds;
    for (CALayer *l in _wallpaper.layer.sublayers) l.frame = _wallpaper.bounds;

    CGFloat divW  = MAX(2, W * 0.012);
    CGFloat avail = W - divW;           // ngan dung het man
    CGFloat leftW = floor(avail * ratio), rightW = avail - leftW;
    _leftPane.frame  = CGRectMake(0, 0, leftW, H);
    _divider.frame   = CGRectMake(leftW, 0, divW, H);
    _rightPane.frame = CGRectMake(leftW + divW, 0, rightW, H);

    static NSDateFormatter *df; if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm"; }
    NSString *now = [df stringFromDate:[NSDate date]];
    _leftTime.text = now; _rightTime.text = now;

    [self layoutPane:_leftPane phone:_leftPhone icon:_leftIcon label:_leftLabel bid:left orientation:orient];
    [self layoutPane:_rightPane phone:_rightPhone icon:_rightIcon label:_rightLabel bid:right orientation:orient];

    // dau "..." o giua mep tren moi ngan (~64x16 tren man 800x480)
    CGFloat dw = W * 0.08, dh = H * 0.035;
    for (UILabel *d in @[_leftDots, _rightDots]) {
        UIView *pane = d.superview;
        d.frame = CGRectMake((pane.bounds.size.width - dw) / 2, 0, dw, dh);
        d.font = [UIFont systemFontOfSize:MAX(5, dh * 0.7) weight:UIFontWeightBold];
        d.layer.cornerRadius = dh * 0.35;
        d.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        [pane bringSubviewToFront:d];
    }

    _infoLabel.frame = CGRectMake(0, CGRectGetMaxY(_screenView.frame) + 4, self.bounds.size.width, 18);
    _infoLabel.text = [NSString stringWithFormat:@"Trái %.0f%% · App %@ · Kéo dấu ... của ngăn xuống để hiện option",
                       ratio * 100, orient == 3 ? @"ngang" : @"dọc"];
}

- (void)layoutPane:(UIView *)pane phone:(UIView *)phone icon:(UIImageView *)icon label:(UILabel *)label
               bid:(NSString *)bid orientation:(NSInteger)orient
{
    CGSize p = pane.bounds.size;
    // App duoc resize dung kich thuoc ngan -> khung "man hinh iPhone" chiem het ngan
    CGRect phoneRect = CGRectMake(0, 0, p.width, p.height);
    phone.frame = phoneRect;
    phone.alpha = 1;
    // thanh trang thai gia o dau "man hinh iPhone"
    UILabel *status = (pane == _leftPane) ? _leftTime : _rightTime;
    status.font = [UIFont systemFontOfSize:MAX(6, phoneRect.size.width * 0.07) weight:UIFontWeightSemibold];
    status.frame = CGRectMake(phoneRect.origin.x, phoneRect.origin.y + 2, phoneRect.size.width, phoneRect.size.width * 0.1);
    [pane bringSubviewToFront:status];

    CGFloat is = MIN(44, MIN(phoneRect.size.width, phoneRect.size.height) * 0.42);
    icon.frame = CGRectMake(CGRectGetMidX(phoneRect) - is / 2, CGRectGetMidY(phoneRect) - is / 2 - 6, is, is);
    icon.image = appIcon(bid);
    icon.backgroundColor = icon.image ? [UIColor clearColor] : [UIColor colorWithWhite:1 alpha:0.2];
    label.frame = CGRectMake(phoneRect.origin.x + 2, CGRectGetMaxY(icon.frame) + 3, phoneRect.size.width - 4, 14);
    label.text = appName(bid);
    [pane bringSubviewToFront:icon]; [pane bringSubviewToFront:label];
    (void)phoneRect;
}

@end

// ---------------------------------------------------------------------
//  SCPPreviewCell: cell chua SCPPreviewView (height dat trong Root.plist)
// ---------------------------------------------------------------------
@interface SCPPreviewCell : PSTableCell
@property (nonatomic, strong) SCPPreviewView *preview;
@end

@implementation SCPPreviewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _preview = [[SCPPreviewView alloc] initWithFrame:self.contentView.bounds];
    _preview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentView addSubview:_preview];
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    _preview.frame = self.contentView.bounds;
    [_preview reload];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    [_preview reload];
}

@end
