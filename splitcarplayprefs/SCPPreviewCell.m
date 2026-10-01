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
@property (nonatomic, strong) UIView *dockView;
@property (nonatomic, strong) UIView *leftPane, *rightPane;
@property (nonatomic, strong) UIImageView *leftIcon, *rightIcon;
@property (nonatomic, strong) UILabel *leftLabel, *rightLabel, *infoLabel;
@property (nonatomic, strong) UIView *leftPhone, *rightPhone;
@property (nonatomic, strong) UILabel *clockLabel, *leftTime, *rightTime;
@property (nonatomic, strong) UIImageView *homeIcon, *gridIcon, *swapIcon;
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

    // Thanh ben kieu CarPlay: dong ho tren, nut Home duoi
    _dockView = [[UIView alloc] init];
    _dockView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    [_screenView addSubview:_dockView];
    _clockLabel = [[UILabel alloc] init];
    _clockLabel.textColor = [UIColor whiteColor];
    _clockLabel.textAlignment = NSTextAlignmentCenter;
    _clockLabel.adjustsFontSizeToFitWidth = YES;
    [_dockView addSubview:_clockLabel];
    _gridIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"square.grid.2x2"]];
    _gridIcon.tintColor = [UIColor whiteColor]; _gridIcon.contentMode = UIViewContentModeScaleAspectFit;
    [_dockView addSubview:_gridIcon];
    _swapIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.left.arrow.right"]];
    _swapIcon.tintColor = [UIColor whiteColor]; _swapIcon.contentMode = UIViewContentModeScaleAspectFit;
    [_dockView addSubview:_swapIcon];
    _homeIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"circle.grid.3x3.fill"]];
    _homeIcon.tintColor = [UIColor whiteColor]; _homeIcon.contentMode = UIViewContentModeScaleAspectFit;
    [_dockView addSubview:_homeIcon];

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
    [_screenView addSubview:v];
    return v;
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
    NSInteger dockSide = [prefValue(@"DockSide") integerValue];
    NSInteger orient = prefValue(@"PaneOrientation") ? [prefValue(@"PaneOrientation") integerValue] : 1;
    CGFloat ratio = prefValue(@"SplitRatio") ? [prefValue(@"SplitRatio") doubleValue] : 0.5;
    ratio = MIN(0.7, MAX(0.3, ratio));

    // Ti le man xe theo Settings (16:9 mac dinh), can giua
    NSString *aspect = prefValue(@"ScreenAspect") ?: @"16:9";
    CGFloat aw = 16, ah = 9;
    if ([aspect isEqualToString:@"5:3"]) { aw = 5; ah = 3; }
    else if ([aspect isEqualToString:@"8:3"]) { aw = 8; ah = 3; }
    NSInteger scaleMode = prefValue(@"ScaleMode") ? [prefValue(@"ScaleMode") integerValue] : 1;
    CGFloat W = self.bounds.size.width - 24, H = W * ah / aw;
    CGFloat maxH = self.bounds.size.height - 30;
    if (H > maxH) { H = maxH; W = H * aw / ah; }
    CGFloat x = (self.bounds.size.width - W) / 2;
    _screenView.frame = CGRectMake(x, 4, W, H);

    _wallpaper.frame = _screenView.bounds;
    for (CALayer *l in _wallpaper.layer.sublayers) l.frame = _wallpaper.bounds;

    CGFloat dockW = W * 0.075;          // thanh ben CarPlay ~ 60/800
    CGFloat divW  = MAX(2, W * 0.012);
    CGFloat avail = W - dockW - divW;
    CGFloat leftW = floor(avail * ratio), rightW = avail - leftW;
    CGFloat x0 = (dockSide == 1) ? 0 : dockW;
    _dockView.frame  = CGRectMake(dockSide == 1 ? W - dockW : 0, 0, dockW, H);
    _leftPane.frame  = CGRectMake(x0, 0, leftW, H);
    _divider.frame   = CGRectMake(x0 + leftW, 0, divW, H);
    _rightPane.frame = CGRectMake(x0 + leftW + divW, 0, rightW, H);

    // noi dung thanh ben
    static NSDateFormatter *df; if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm"; }
    NSString *now = [df stringFromDate:[NSDate date]];
    _clockLabel.font = [UIFont systemFontOfSize:dockW * 0.42 weight:UIFontWeightSemibold];
    _clockLabel.text = now;
    _clockLabel.frame = CGRectMake(0, 4, dockW, dockW * 0.6);
    CGFloat ic = dockW * 0.5;
    _gridIcon.frame = CGRectMake((dockW - ic) / 2, dockW * 0.75, ic, ic);
    _swapIcon.frame = CGRectMake((dockW - ic) / 2, dockW * 0.75 + ic + 6, ic, ic);
    _homeIcon.frame = CGRectMake((dockW - ic) / 2, H - ic - 6, ic, ic);
    _leftTime.text = now; _rightTime.text = now;

    [self layoutPane:_leftPane phone:_leftPhone icon:_leftIcon label:_leftLabel bid:left orientation:orient scaleMode:scaleMode];
    [self layoutPane:_rightPane phone:_rightPhone icon:_rightIcon label:_rightLabel bid:right orientation:orient scaleMode:scaleMode];

    _infoLabel.frame = CGRectMake(0, CGRectGetMaxY(_screenView.frame) + 4, self.bounds.size.width, 18);
    NSString *modeName = scaleMode == 0 ? @"kéo giãn" : (scaleMode == 2 ? @"resize" : @"giữ tỉ lệ");
    _infoLabel.text = [NSString stringWithFormat:@"Dock %@ · Trái %.0f%% · App %@ · %@",
                       dockSide == 1 ? @"phải" : @"trái", ratio * 100, orient == 3 ? @"ngang" : @"dọc", modeName];
}

- (void)layoutPane:(UIView *)pane phone:(UIView *)phone icon:(UIImageView *)icon label:(UILabel *)label
               bid:(NSString *)bid orientation:(NSInteger)orient scaleMode:(NSInteger)scaleMode
{
    CGSize p = pane.bounds.size;
    // Khung "man hinh iPhone" trong ngan: keo gian / resize = full ngan; giu ti le = 9:16 (doc) hoac 16:9 (ngang) can giua
    CGFloat inset = 0;
    CGFloat pw = p.width, ph = p.height;
    CGRect phoneRect = CGRectMake(inset, inset, pw, ph);
    if (scaleMode == 1) {
        if (orient == 3) { CGFloat h = MIN(ph, pw * 9.0 / 16.0); CGFloat w = h * 16.0 / 9.0; phoneRect = CGRectMake((p.width - w)/2, inset + (ph - h)/2, w, h); }
        else             { CGFloat w = MIN(pw, ph * 9.0 / 16.0); CGFloat h = w * 16.0 / 9.0; phoneRect = CGRectMake((p.width - w)/2, inset + (ph - h)/2, w, h); }
    }
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
