#import <Preferences/PSViewController.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "SCPLang.h"

@interface UIImage (SCPPickerPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)format scale:(double)scale;
@end

static NSString *SCPAppName(NSString *bid)
{
    Class LSProxy = objc_getClass("LSApplicationProxy");
    id proxy = LSProxy ? ((id (*)(id, SEL, id))objc_msgSend)(LSProxy, NSSelectorFromString(@"applicationProxyForIdentifier:"), bid) : nil;
    NSString *name = proxy ? ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"localizedName")) : nil;
    return name.length ? name : bid;
}

static UIImage *SCPAppIconImage(NSString *bid)
{
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    return [UIImage _applicationIconImageForBundleIdentifier:bid format:2 scale:[UIScreen mainScreen].scale];
}

// Chua cam xe lan nao (CarPlay chua ghi danh sach): tam doan app co CarPlay theo entitlement
static NSArray<NSString *> *SCPGuessCarPlayApps(void)
{
    NSSet *apple = [NSSet setWithArray:@[@"com.apple.Maps", @"com.apple.Music", @"com.apple.podcasts", @"com.apple.mobilephone",
                                         @"com.apple.MobileSMS", @"com.apple.iBooks", @"com.apple.news", @"com.apple.mobilecal"]];
    NSMutableArray *out = [NSMutableArray array];
    Class WS = objc_getClass("LSApplicationWorkspace");
    id ws = WS ? ((id (*)(id, SEL))objc_msgSend)(WS, NSSelectorFromString(@"defaultWorkspace")) : nil;
    NSArray *all = ws ? ((id (*)(id, SEL))objc_msgSend)(ws, NSSelectorFromString(@"allInstalledApplications")) : nil;
    for (id proxy in all) {
        NSString *bid = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"bundleIdentifier"));
        if (!bid.length) continue;
        if ([apple containsObject:bid]) { [out addObject:bid]; continue; }
        if (![proxy respondsToSelector:NSSelectorFromString(@"entitlements")]) continue;
        NSDictionary *ent = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"entitlements"));
        for (NSString *k in ent) {
            if ([k hasPrefix:@"com.apple.developer.carplay"] || [k isEqualToString:@"com.apple.developer.playable-content"]) {
                [out addObject:bid];
                break;
            }
        }
    }
    return out;
}

// ---------------------------------------------------------------------
//  SCPAppLinkCell: dong "Ngan trai: Vietmap >" (ten app dang chon o ben phai)
// ---------------------------------------------------------------------
@interface SCPAppLinkCell : PSTableCell
@end

@implementation SCPAppLinkCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    return [super initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseIdentifier specifier:specifier];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    NSString *bid = SCPPrefValue([specifier propertyForKey:@"key"]);
    BOOL has = [bid isKindOfClass:[NSString class]] && bid.length;
    self.detailTextLabel.text = has ? SCPAppName(bid) : SCPL(@"Chưa chọn", @"None");
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
}

@end

// ---------------------------------------------------------------------
//  SCPAppPickerController: chi liet ke app hien tren CarPlay (app CarPlay that + app CarBridge)
// ---------------------------------------------------------------------
@interface SCPAppPickerController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;   // @{id, name}
@property (nonatomic, readwrite) BOOL fromCar;                // danh sach do CarPlay ghi (co ca CarBridge)
@end

@implementation SCPAppPickerController

- (void)loadView
{
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 56;
    self.view = _table;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.specifier.name;
    self.view.tintColor = [UIColor colorWithRed:0.04 green:0.35 blue:0.97 alpha:1];

    NSArray *ids = SCPPrefValue(@"CarPlayApps");
    _fromCar = [ids isKindOfClass:[NSArray class]] && ids.count;
    if (!_fromCar) ids = SCPGuessCarPlayApps();
    NSMutableArray *apps = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *bid in ids) {
        if (![bid isKindOfClass:[NSString class]] || [seen containsObject:bid]) continue;
        [seen addObject:bid];
        [apps addObject:@{@"id": bid, @"name": SCPAppName(bid)}];
    }
    [apps sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)]]];
    _apps = apps;
}

- (NSString *)currentValue
{
    id v = SCPPrefValue([self.specifier propertyForKey:@"key"]);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : _apps.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section
{
    return section == 1 ? SCPL(@"APP TRÊN CARPLAY", @"APPS ON CARPLAY") : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section
{
    if (section != 1) return nil;
    return _fromCar
        ? SCPL(@"Chỉ hiện app có trên màn CarPlay (app CarPlay và app CarBridge). Danh sách cập nhật mỗi lần cắm xe.",
               @"Only apps shown on the CarPlay screen (CarPlay apps and CarBridge apps). The list refreshes each time you connect.")
        : SCPL(@"Chưa cắm xe lần nào: đang tạm liệt kê app có hỗ trợ CarPlay. Sau lần cắm xe đầu tiên sẽ có thêm app CarBridge.",
               @"Not connected to a car yet: showing apps with CarPlay support. CarBridge apps appear after the first connection.");
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"app"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    NSString *cur = [self currentValue];
    if (ip.section == 0) {
        c.textLabel.text = SCPL(@"Không chọn", @"None");
        c.detailTextLabel.text = nil;
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
        c.imageView.image = [[UIImage systemImageNamed:@"nosign" withConfiguration:cfg] imageWithTintColor:[UIColor tertiaryLabelColor]
                                                                                             renderingMode:UIImageRenderingModeAlwaysOriginal];
        c.accessoryType = cur ? UITableViewCellAccessoryNone : UITableViewCellAccessoryCheckmark;
        return c;
    }
    NSDictionary *a = _apps[ip.row];
    c.textLabel.text = a[@"name"];
    c.detailTextLabel.text = a[@"id"];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    UIImage *icon = SCPAppIconImage(a[@"id"]);
    if (icon) {
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(36, 36)];
        icon = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 36, 36) cornerRadius:9] addClip];
            [icon drawInRect:CGRectMake(0, 0, 36, 36)];
        }];
    }
    c.imageView.image = icon;
    c.accessoryType = [cur isEqualToString:a[@"id"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *key = [self.specifier propertyForKey:@"key"];
    if (ip.section == 0) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)SCP_DOMAIN);
        CFPreferencesAppSynchronize((__bridge CFStringRef)SCP_DOMAIN);
    } else {
        SCPSetPrefValue(key, _apps[ip.row][@"id"]);
    }
    notify_post("com.anlai97.carduo.prefschanged");
    [tv reloadData];
    id parent = [self respondsToSelector:NSSelectorFromString(@"parentController")] ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"parentController")) : nil;
    if ([parent respondsToSelector:@selector(reloadSpecifier:)]) [parent reloadSpecifier:self.specifier];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.navigationController popViewControllerAnimated:YES];
    });
}

@end
