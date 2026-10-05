#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "SCPLang.h"

@interface UIImage (SCPPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)format scale:(double)scale;
@end

static UIColor *SCPAccent(void) { return [UIColor colorWithRed:0.04 green:0.35 blue:0.97 alpha:1]; }

// ---------------------------------------------------------------------
//  SCPPreviewView: mo phong man CarPlay: dock doc ben trai (gio, 3 app gan day, nut Home)
//  + 2 ngan app ben phai dock, dung ti le / kieu chia / ti le man dang chon
// ---------------------------------------------------------------------
@interface SCPPreviewView : UIView
@property (nonatomic, strong) UIView *screenView, *wallpaper, *grip;
@property (nonatomic, strong) UIView *leftPane, *rightPane;
@property (nonatomic, strong) UIImageView *leftIcon, *rightIcon;
@property (nonatomic, strong) UILabel *leftLabel, *rightLabel, *infoLabel;
@property (nonatomic, strong) UILabel *leftTab, *rightTab;   // the trang "•••" o mep tren moi ngan
@property (nonatomic, strong) UIView *dock;
@property (nonatomic, strong) UILabel *dockTime, *dockSignal;
@property (nonatomic, strong) NSArray<UIImageView *> *dockIcons;
@property (nonatomic, strong) UIImageView *dockHome;
- (void)reload;
@end

@implementation SCPPreviewView

- (instancetype)initWithFrame:(CGRect)frame
{
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [UIColor clearColor];

    _screenView = [[UIView alloc] init];
    _screenView.backgroundColor = [UIColor blackColor];
    _screenView.layer.cornerRadius = 16;
    _screenView.layer.cornerCurve = kCACornerCurveContinuous;
    _screenView.layer.borderWidth = 3;
    _screenView.layer.borderColor = [UIColor colorWithWhite:0.16 alpha:1].CGColor;
    _screenView.clipsToBounds = YES;
    [self addSubview:_screenView];

    // Hinh nen kieu CarPlay (gradient xanh toi)
    _wallpaper = [[UIView alloc] init];
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors = @[(id)[UIColor colorWithRed:0.08 green:0.16 blue:0.38 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:0.01 green:0.03 blue:0.10 alpha:1].CGColor];
    g.startPoint = CGPointMake(0, 0); g.endPoint = CGPointMake(1, 1);
    [_wallpaper.layer addSublayer:g];
    [_screenView addSubview:_wallpaper];

    // Dock CarPlay
    _dock = [[UIView alloc] init];
    _dock.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.92];
    [_screenView addSubview:_dock];
    _dockTime = [self makeLabelIn:_dock];
    _dockSignal = [self makeLabelIn:_dock];
    _dockSignal.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    NSMutableArray *icons = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        UIImageView *iv = [[UIImageView alloc] init];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.layer.cornerCurve = kCACornerCurveContinuous;
        iv.clipsToBounds = YES;
        [_dock addSubview:iv];
        [icons addObject:iv];
    }
    _dockIcons = icons;
    _dockHome = [[UIImageView alloc] init];
    _dockHome.contentMode = UIViewContentModeCenter;
    _dockHome.tintColor = [UIColor whiteColor];
    [_dock addSubview:_dockHome];

    _leftPane  = [self makePane];
    _rightPane = [self makePane];
    _leftIcon  = [self makeIconIn:_leftPane];
    _rightIcon = [self makeIconIn:_rightPane];
    _leftLabel  = [self makeLabelIn:_leftPane];
    _rightLabel = [self makeLabelIn:_rightPane];
    _leftTab  = [self makeTabIn:_leftPane];
    _rightTab = [self makeTabIn:_rightPane];

    // Thanh keo: pill trang giong tren xe
    _grip = [[UIView alloc] init];
    _grip.backgroundColor = [UIColor whiteColor];
    _grip.layer.shadowColor = [UIColor blackColor].CGColor;
    _grip.layer.shadowOpacity = 0.4;
    _grip.layer.shadowRadius = 2;
    _grip.layer.shadowOffset = CGSizeZero;
    [_screenView addSubview:_grip];

    _infoLabel = [[UILabel alloc] init];
    _infoLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _infoLabel.textColor = SCPAccent();
    _infoLabel.backgroundColor = [SCPAccent() colorWithAlphaComponent:0.10];
    _infoLabel.textAlignment = NSTextAlignmentCenter;
    _infoLabel.adjustsFontSizeToFitWidth = YES;
    _infoLabel.minimumScaleFactor = 0.75;
    _infoLabel.clipsToBounds = YES;
    [self addSubview:_infoLabel];

    int tok = 0;
    __weak SCPPreviewView *weakSelf = self;
    notify_register_dispatch("com.anlai97.carduo.prefschanged", &tok, dispatch_get_main_queue(), ^(int t) {
        [weakSelf reload];
    });
    return self;
}

- (UIView *)makePane
{
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.18 alpha:1];
    v.clipsToBounds = YES;
    v.layer.borderWidth = 1;
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    v.layer.cornerRadius = 10;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    [_screenView addSubview:v];
    return v;
}

- (UILabel *)makeTabIn:(UIView *)pane
{
    UILabel *l = [[UILabel alloc] init];
    l.text = @"•••";
    l.textColor = [UIColor colorWithWhite:0.15 alpha:1];
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:1 alpha:0.92];
    l.clipsToBounds = YES;
    [pane addSubview:l];
    return l;
}

- (UIImageView *)makeIconIn:(UIView *)pane
{
    UIImageView *iv = [[UIImageView alloc] init];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerCurve = kCACornerCurveContinuous;
    iv.clipsToBounds = YES;
    [pane addSubview:iv];
    return iv;
}

- (UILabel *)makeLabelIn:(UIView *)parent
{
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.5;
    [parent addSubview:l];
    return l;
}

// ---- prefs ----
static NSString *prefString(NSString *key)
{
    id v = SCPPrefValue(key);
    return ([v isKindOfClass:[NSString class]] && [v length]) ? v : nil;
}

static NSString *appName(NSString *bid)
{
    if (!bid) return SCPL(@"Chưa chọn", @"None");
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

    NSString *left = prefString(@"LeftApp"), *right = prefString(@"RightApp");
    id o = SCPPrefValue(@"PaneOrientation");
    NSInteger orient = o ? [o integerValue] : 1;
    BOOL vertical = [SCPPrefValue(@"SplitDirection") integerValue] == 1;   // tren / duoi
    id rv = SCPPrefValue(@"SplitRatio");
    CGFloat ratio = rv ? [rv doubleValue] : 0.5;
    ratio = MIN(0.8, MAX(0.2, ratio));

    // Ti le man xe theo Settings (16:9 mac dinh), can giua
    NSString *aspect = prefString(@"ScreenAspect") ?: @"16:9";
    CGFloat aw = 16, ah = 9;
    if ([aspect isEqualToString:@"5:3"]) { aw = 5; ah = 3; }
    else if ([aspect isEqualToString:@"8:3"]) { aw = 8; ah = 3; }
    CGFloat W = self.bounds.size.width - 24, H = W * ah / aw;
    CGFloat maxH = self.bounds.size.height - 34;
    if (H > maxH) { H = maxH; W = H * aw / ah; }
    _screenView.frame = CGRectMake((self.bounds.size.width - W) / 2, 4, W, H);

    _wallpaper.frame = _screenView.bounds;
    for (CALayer *l in _wallpaper.layer.sublayers) l.frame = _wallpaper.bounds;

    // ---- Dock (~ 1/5 chieu cao man, nhu CarPlay that) ----
    CGFloat dw = round(H * 0.19);
    _dock.frame = CGRectMake(0, 0, dw, H);
    static NSDateFormatter *df; if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm"; }
    _dockTime.text = [df stringFromDate:[NSDate date]];
    _dockTime.font = [UIFont systemFontOfSize:MAX(7, dw * 0.24) weight:UIFontWeightSemibold];
    _dockTime.frame = CGRectMake(0, H * 0.04, dw, dw * 0.3);
    _dockSignal.text = @"5G";
    _dockSignal.font = [UIFont systemFontOfSize:MAX(5, dw * 0.16) weight:UIFontWeightSemibold];
    _dockSignal.frame = CGRectMake(0, CGRectGetMaxY(_dockTime.frame), dw, dw * 0.2);

    NSArray *dockApps = @[left ?: @"com.apple.Maps", right ?: @"com.apple.Music", @"com.apple.mobilephone"];
    CGFloat is = dw * 0.62, gap = dw * 0.16;
    CGFloat top = CGRectGetMaxY(_dockSignal.frame) + gap;
    for (NSUInteger i = 0; i < _dockIcons.count; i++) {
        UIImageView *iv = _dockIcons[i];
        iv.frame = CGRectMake((dw - is) / 2, top + i * (is + gap), is, is);
        iv.layer.cornerRadius = is * 0.225;
        iv.image = appIcon(dockApps[i]);
        iv.backgroundColor = iv.image ? [UIColor clearColor] : [UIColor colorWithWhite:1 alpha:0.15];
    }
    CGFloat hs = dw * 0.5;
    _dockHome.image = [UIImage systemImageNamed:@"square.grid.2x2.fill"
                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:MAX(8, hs * 0.6)]];
    _dockHome.frame = CGRectMake((dw - hs) / 2, H - hs - H * 0.05, hs, hs);

    // ---- 2 ngan ben phai dock ----
    CGFloat inset = MAX(2, H * 0.012), gap2 = MAX(2, H * 0.012);
    CGRect area = CGRectMake(dw + inset, inset, W - dw - inset * 2, H - inset * 2);
    CGRect a, b;
    if (vertical) {
        CGFloat h1 = floor((area.size.height - gap2) * ratio);
        a = CGRectMake(area.origin.x, area.origin.y, area.size.width, h1);
        b = CGRectMake(area.origin.x, CGRectGetMaxY(a) + gap2, area.size.width, area.size.height - h1 - gap2);
    } else {
        CGFloat w1 = floor((area.size.width - gap2) * ratio);
        a = CGRectMake(area.origin.x, area.origin.y, w1, area.size.height);
        b = CGRectMake(CGRectGetMaxX(a) + gap2, area.origin.y, area.size.width - w1 - gap2, area.size.height);
    }
    _leftPane.frame = a;
    _rightPane.frame = b;

    // pill keo o giua duong ranh
    if (vertical) {
        CGFloat gh = MAX(3, H * 0.03), gw = area.size.width * 0.12;
        _grip.frame = CGRectMake(CGRectGetMidX(area) - gw / 2, CGRectGetMaxY(a) + gap2 / 2 - gh / 2, gw, gh);
        _grip.layer.cornerRadius = gh / 2;
    } else {
        CGFloat gw = MAX(3, H * 0.03), gh = H * 0.18;
        _grip.frame = CGRectMake(CGRectGetMaxX(a) + gap2 / 2 - gw / 2, CGRectGetMidY(area) - gh / 2, gw, gh);
        _grip.layer.cornerRadius = gw / 2;
    }
    [_screenView bringSubviewToFront:_grip];

    [self layoutPane:_leftPane icon:_leftIcon label:_leftLabel bid:left];
    [self layoutPane:_rightPane icon:_rightIcon label:_rightLabel bid:right];

    // the "•••" o giua mep tren moi ngan
    CGFloat tw = MAX(18, W * 0.07), th = MAX(6, H * 0.045);
    for (UILabel *t in @[_leftTab, _rightTab]) {
        UIView *pane = t.superview;
        t.frame = CGRectMake((pane.bounds.size.width - tw) / 2, 0, tw, th);
        t.font = [UIFont systemFontOfSize:MAX(5, th * 0.65) weight:UIFontWeightBold];
        t.layer.cornerRadius = th * 0.45;
        t.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        [pane bringSubviewToFront:t];
    }

    _infoLabel.text = [NSString stringWithFormat:SCPL(@"%@ %.0f%% · App %@ · Chạm thẻ ••• để mở option", @"%@ %.0f%% · %@ apps · Tap the ••• tab for options"),
                       vertical ? SCPL(@"Trên", @"Top") : SCPL(@"Trái", @"Left"), ratio * 100,
                       orient == 3 ? SCPL(@"ngang", @"landscape") : SCPL(@"dọc", @"portrait")];
    CGFloat iw = MIN(self.bounds.size.width - 24, [_infoLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, 20)].width + 20);
    _infoLabel.frame = CGRectMake((self.bounds.size.width - iw) / 2, CGRectGetMaxY(_screenView.frame) + 8, iw, 20);
    _infoLabel.layer.cornerRadius = 10;
}

- (void)layoutPane:(UIView *)pane icon:(UIImageView *)icon label:(UILabel *)label bid:(NSString *)bid
{
    CGSize p = pane.bounds.size;
    CGFloat is = MIN(46, MIN(p.width, p.height) * 0.4);
    icon.frame = CGRectMake((p.width - is) / 2, (p.height - is) / 2 - 7, is, is);
    icon.layer.cornerRadius = is * 0.225;
    icon.image = appIcon(bid);
    icon.backgroundColor = icon.image ? [UIColor clearColor] : [UIColor colorWithWhite:1 alpha:0.2];
    label.frame = CGRectMake(2, CGRectGetMaxY(icon.frame) + 3, p.width - 4, 14);
    label.text = appName(bid);
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
