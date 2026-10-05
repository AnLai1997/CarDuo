#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <notify.h>

#define SCP_DOMAIN @"com.anlai97.carduo"

// ---------------------------------------------------------------------
//  SCPHeaderCell: the gradient card at the top of the settings page
//  (logo + name + status chip), HarmonyOS style
// ---------------------------------------------------------------------
@interface SCPHeaderCell : PSTableCell
@property (nonatomic, strong) UIView *card, *clip;
@property (nonatomic, strong) CAGradientLayer *gradient;
@property (nonatomic, strong) UIImageView *logo;
@property (nonatomic, strong) UILabel *titleLabel2, *subtitleLabel, *statusLabel;
@property (nonatomic, strong) UIView *statusDot, *statusChip;
@end

@implementation SCPHeaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor clearColor];
    self.backgroundView = [UIView new];
    self.backgroundView.backgroundColor = [UIColor clearColor];

    _card = [[UIView alloc] init];
    _card.layer.cornerRadius = 24;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.shadowColor = [UIColor colorWithRed:0.04 green:0.27 blue:0.88 alpha:1].CGColor;
    _card.layer.shadowOpacity = 0.30;
    _card.layer.shadowRadius = 14;
    _card.layer.shadowOffset = CGSizeMake(0, 6);
    [self.contentView addSubview:_card];

    // card keeps the shadow, clip rounds the content
    _clip = [[UIView alloc] init];
    _clip.layer.cornerRadius = 24;
    _clip.layer.cornerCurve = kCACornerCurveContinuous;
    _clip.clipsToBounds = YES;
    [_card addSubview:_clip];

    _gradient = [CAGradientLayer layer];
    _gradient.colors = @[(id)[UIColor colorWithRed:0.36 green:0.71 blue:1.00 alpha:1].CGColor,
                         (id)[UIColor colorWithRed:0.12 green:0.42 blue:1.00 alpha:1].CGColor,
                         (id)[UIColor colorWithRed:0.04 green:0.27 blue:0.88 alpha:1].CGColor];
    _gradient.locations = @[@0, @0.55, @1];
    _gradient.startPoint = CGPointMake(0, 0);
    _gradient.endPoint = CGPointMake(1, 1);
    [_clip.layer addSublayer:_gradient];

    // Decorative soft circles (glass highlight)
    for (int i = 0; i < 2; i++) {
        UIView *c = [[UIView alloc] init];
        c.tag = 100 + i;
        c.backgroundColor = [UIColor colorWithWhite:1 alpha:i == 0 ? 0.12 : 0.08];
        [_clip addSubview:c];
    }

    NSBundle *b = [NSBundle bundleForClass:[self class]];
    _logo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"logo" inBundle:b compatibleWithTraitCollection:nil]];
    _logo.layer.shadowColor = [UIColor blackColor].CGColor;
    _logo.layer.shadowOpacity = 0.18;
    _logo.layer.shadowRadius = 8;
    _logo.layer.shadowOffset = CGSizeMake(0, 4);
    [_clip addSubview:_logo];

    _titleLabel2 = [[UILabel alloc] init];
    _titleLabel2.text = @"CarDuo";
    _titleLabel2.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    _titleLabel2.textColor = [UIColor whiteColor];
    [_clip addSubview:_titleLabel2];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.text = @"Hai app CarPlay trên một màn xe";
    _subtitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _subtitleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    _subtitleLabel.adjustsFontSizeToFitWidth = YES;
    _subtitleLabel.minimumScaleFactor = 0.8;
    [_clip addSubview:_subtitleLabel];

    _statusChip = [[UIView alloc] init];
    _statusChip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    _statusChip.layer.cornerRadius = 11;
    [_clip addSubview:_statusChip];

    _statusDot = [[UIView alloc] init];
    _statusDot.layer.cornerRadius = 3.5;
    [_statusChip addSubview:_statusDot];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _statusLabel.textColor = [UIColor whiteColor];
    [_statusChip addSubview:_statusLabel];

    int tok = 0;
    __weak SCPHeaderCell *weakSelf = self;
    notify_register_dispatch("com.anlai97.carduo.prefschanged", &tok, dispatch_get_main_queue(), ^(int t) {
        [weakSelf setNeedsLayout];
    });
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect r = CGRectInset(self.contentView.bounds, 0, 8);
    _card.frame = r;
    _clip.frame = _card.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _gradient.frame = _clip.bounds;
    [CATransaction commit];
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:24].CGPath;

    CGFloat W = r.size.width, H = r.size.height;
    UIView *c0 = [_clip viewWithTag:100], *c1 = [_clip viewWithTag:101];
    c0.frame = CGRectMake(W - 120, -50, 170, 170);
    c1.frame = CGRectMake(W - 60, H - 70, 110, 110);
    c0.layer.cornerRadius = 85; c1.layer.cornerRadius = 55;

    CGFloat ls = 64;
    _logo.frame = CGRectMake(20, (H - ls) / 2, ls, ls);
    CGFloat tx = CGRectGetMaxX(_logo.frame) + 16, tw = W - tx - 16;
    _titleLabel2.frame = CGRectMake(tx, H / 2 - 38, tw, 32);
    _subtitleLabel.frame = CGRectMake(tx, CGRectGetMaxY(_titleLabel2.frame), tw, 18);

    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("Enabled"), (__bridge CFStringRef)SCP_DOMAIN);
    id en = v ? CFBridgingRelease(v) : nil;
    BOOL on = en ? [en boolValue] : YES;
    _statusLabel.text = on ? @"Đang bật · v0.3" : @"Đang tắt · v0.3";
    _statusDot.backgroundColor = on ? [UIColor colorWithRed:0.45 green:0.95 blue:0.55 alpha:1]
                                    : [UIColor colorWithRed:1.00 green:0.55 blue:0.45 alpha:1];
    CGSize ts = [_statusLabel sizeThatFits:CGSizeMake(200, 22)];
    _statusChip.frame = CGRectMake(tx, CGRectGetMaxY(_subtitleLabel.frame) + 8, ts.width + 30, 22);
    _statusDot.frame = CGRectMake(10, 7.5, 7, 7);
    _statusLabel.frame = CGRectMake(22, 0, ts.width, 22);
}

@end
