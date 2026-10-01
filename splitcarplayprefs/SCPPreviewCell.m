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

    _dockView = [[UIView alloc] init];
    _dockView.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
    [_screenView addSubview:_dockView];

    _leftPane  = [self makePaneWithColor:[UIColor colorWithRed:0.12 green:0.25 blue:0.45 alpha:1]];
    _rightPane = [self makePaneWithColor:[UIColor colorWithRed:0.15 green:0.4 blue:0.25 alpha:1]];

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

- (UIView *)makePhoneIn:(UIView *)pane
{
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
    v.layer.borderWidth = 1;
    v.layer.cornerRadius = 4;
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

    CGFloat dockW = W * 40.0 / 800.0 * 1.6;
    CGFloat avail = W - dockW;
    CGFloat leftW = floor(avail * ratio), rightW = avail - leftW;
    CGFloat x0 = (dockSide == 1) ? 0 : dockW;
    _dockView.frame  = CGRectMake(dockSide == 1 ? W - dockW : 0, 0, dockW, H);
    _leftPane.frame  = CGRectMake(x0, 0, leftW, H);
    _rightPane.frame = CGRectMake(x0 + leftW, 0, rightW, H);

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
    CGFloat inset = 6;
    CGFloat pw = p.width - inset * 2, ph = p.height - inset * 2 - 14;
    CGRect phoneRect = CGRectMake(inset, inset, pw, ph);
    if (scaleMode == 1) {
        if (orient == 3) { CGFloat h = MIN(ph, pw * 9.0 / 16.0); CGFloat w = h * 16.0 / 9.0; phoneRect = CGRectMake((p.width - w)/2, inset + (ph - h)/2, w, h); }
        else             { CGFloat w = MIN(pw, ph * 9.0 / 16.0); CGFloat h = w * 16.0 / 9.0; phoneRect = CGRectMake((p.width - w)/2, inset + (ph - h)/2, w, h); }
    }
    phone.frame = phoneRect;
    phone.alpha = 1;

    CGFloat is = MIN(44, MIN(pw, ph) * 0.45);
    icon.frame = CGRectMake((p.width - is) / 2, inset + (ph - is) / 2 - 6, is, is);
    icon.image = appIcon(bid);
    icon.backgroundColor = icon.image ? [UIColor clearColor] : [UIColor colorWithWhite:1 alpha:0.2];
    label.frame = CGRectMake(2, p.height - 16, p.width - 4, 14);
    label.text = appName(bid);
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
