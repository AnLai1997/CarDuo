#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#import <dlfcn.h>

// Mau chu dao HarmonyOS
#define SCP_ACCENT [UIColor colorWithRed:0.04 green:0.35 blue:0.97 alpha:1]

static UIColor *rgb(int hex)
{
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:1];
}

// Icon o vuong bo goc: gradient nhe + SF Symbol trang (kieu Settings HarmonyOS)
static UIImage *rowIcon(NSString *symbol, UIColor *color)
{
    CGFloat s = 29;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:8.5] addClip];
        CGFloat h, sat, b, a;
        [color getHue:&h saturation:&sat brightness:&b alpha:&a];
        UIColor *top = [UIColor colorWithHue:h saturation:MAX(0, sat - 0.18) brightness:MIN(1, b + 0.10) alpha:1];
        NSArray *cols = @[(id)top.CGColor, (id)color.CGColor];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, NULL);
        CGContextDrawLinearGradient(ctx.CGContext, g, CGPointZero, CGPointMake(s, s), 0);
        CGGradientRelease(g);
        CGColorSpaceRelease(cs);
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
        UIImage *sym = [[UIImage systemImageNamed:symbol withConfiguration:cfg] imageWithTintColor:[UIColor whiteColor]
                                                                                     renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGSize z = sym.size;
        [sym drawInRect:CGRectMake((s - z.width) / 2, (s - z.height) / 2, z.width, z.height)];
    }];
}

// Tim UISlider / UISegmentedControl trong cell (vi tri khac nhau theo iOS)
static UIView *findControl(UIView *v)
{
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UISlider class]] || [s isKindOfClass:[UISegmentedControl class]] || [s isKindOfClass:[UISwitch class]]) return s;
        UIView *f = findControl(s);
        if (f) return f;
    }
    return nil;
}

// key (hoac action cua nut) -> [SF Symbol, mau]
static NSDictionary *iconMap(void)
{
    static NSDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIColor *blue = rgb(0x0A59F7), *green = rgb(0x41BA41), *orange = rgb(0xF97316), *red = rgb(0xE84026),
                *teal = rgb(0x00B3C7), *indigo = rgb(0x5B5BF0), *purple = rgb(0xA855F7), *amber = rgb(0xF5A623),
                *gray = rgb(0x8E8E93), *pink = rgb(0xEC4899);
        m = @{
            @"Enabled":          @[@"power", blue],
            @"AllowPhoneApps":   @[@"iphone", orange],
            @"LeftApp":          @[@"rectangle.lefthalf.filled", teal],
            @"RightApp":         @[@"rectangle.righthalf.filled", indigo],
            @"AutoLaunch":       @[@"car.fill", green],
            @"Fav1Name":         @[@"1.circle.fill", amber],
            @"Fav2Name":         @[@"2.circle.fill", amber],
            @"Fav3Name":         @[@"3.circle.fill", amber],
            @"Fav1Left":         @[@"rectangle.lefthalf.filled", amber],
            @"Fav2Left":         @[@"rectangle.lefthalf.filled", amber],
            @"Fav3Left":         @[@"rectangle.lefthalf.filled", amber],
            @"Fav1Right":        @[@"rectangle.righthalf.filled", amber],
            @"Fav2Right":        @[@"rectangle.righthalf.filled", amber],
            @"Fav3Right":        @[@"rectangle.righthalf.filled", amber],
            @"SplitDirection":   @[@"rectangle.split.2x1.fill", purple],
            @"PaneOrientation":  @[@"rotate.right.fill", teal],
            @"ScreenAspect":     @[@"aspectratio.fill", gray],
            @"MirrorRight":      @[@"rectangle.on.rectangle", pink],
            @"TestOnMainScreen": @[@"arrow.clockwise", gray],
            @"runTest":          @[@"play.fill", green],
            @"closeSplit":       @[@"xmark", red],
            @"clearLog":         @[@"trash.fill", gray],
        };
    });
    return m;
}

@interface SCPRootListController : PSListController
@end

@implementation SCPRootListController

// AltList cung cap ATLApplicationListSelectionController (chon app). Nap dong de khong can link luc build.
+ (void)initialize
{
    if (self != [SCPRootListController class]) return;
    if (!dlopen("/var/jb/Library/Frameworks/AltList.framework/AltList", RTLD_NOW)) {
        dlopen("/Library/Frameworks/AltList.framework/AltList", RTLD_NOW);
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.tintColor = SCP_ACCENT;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.tintColor = SCP_ACCENT;
}

// Cell co key "height" trong Root.plist (khung xem truoc, header)
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
    id h = [sp propertyForKey:@"height"];
    if (h) return [h floatValue];
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}

// To mau control theo mau chu dao (switch, slider, segment, nut)
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    UIView *ctl = cell.accessoryView ?: findControl(cell.contentView);
    if ([ctl isKindOfClass:[UISwitch class]]) {
        ((UISwitch *)ctl).onTintColor = SCP_ACCENT;
    } else if ([ctl isKindOfClass:[UISlider class]]) {
        ((UISlider *)ctl).minimumTrackTintColor = SCP_ACCENT;
    } else if ([ctl isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *seg = (UISegmentedControl *)ctl;
        seg.selectedSegmentTintColor = SCP_ACCENT;
        [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor],
                                      NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]}
                           forState:UIControlStateSelected];
    }
    PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
    NSString *btn = [sp propertyForKey:@"scpKey"];
    if (btn) {
        BOOL danger = [btn isEqualToString:@"closeSplit"] || [btn isEqualToString:@"clearLog"];
        cell.textLabel.textColor = danger ? rgb(0xE84026) : SCP_ACCENT;
    }
    return cell;
}

- (NSArray *)specifiers
{
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        for (PSSpecifier *sp in _specifiers) {
            NSString *k = [sp propertyForKey:@"key"];
            if (!k) k = [sp propertyForKey:@"scpKey"];
            NSArray *ic = k ? iconMap()[k] : nil;
            if (ic) [sp setProperty:rowIcon(ic[0], ic[1]) forKey:@"iconImage"];
        }
    }
    return _specifiers;
}

// Gui Darwin notification sang SpringBoard
- (void)runTest
{
    notify_post("com.anlai97.carduo.test");
}

- (void)closeSplit
{
    notify_post("com.anlai97.carduo.close");
}

- (void)clearLog
{
    notify_post("com.anlai97.carduo.clearlog");
}

@end
