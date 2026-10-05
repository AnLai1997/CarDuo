#import <Preferences/PSViewController.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "SCPLang.h"

@interface PSViewController (SCPPicker)
- (PSSpecifier *)specifier;
@end

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

// App bat trong CarBridge: CarBridge luu cau hinh trong 1 file plist co "carbridge" trong ten.
// Khong biet chinh xac dinh dang -> lay moi chuoi la bundle id cua app da cai (khoa co gia tri bat, hoac phan tu mang).
static void SCPCollectBundleIDs(id obj, NSSet *installed, NSMutableOrderedSet *out, int depth)
{
    if (depth > 6 || !obj) return;
    if ([obj isKindOfClass:[NSString class]]) {
        if ([installed containsObject:obj]) [out addObject:obj];
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id o in obj) SCPCollectBundleIDs(o, installed, out, depth + 1);
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        [obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            BOOL off = [v isKindOfClass:[NSNumber class]] && ![v boolValue];
            if (!off) SCPCollectBundleIDs(k, installed, out, depth + 1);
            SCPCollectBundleIDs(v, installed, out, depth + 1);
        }];
    }
}

static NSArray<NSString *> *SCPCarBridgeApps(void)
{
    NSMutableSet *installed = [NSMutableSet set];
    Class WS = objc_getClass("LSApplicationWorkspace");
    id ws = WS ? ((id (*)(id, SEL))objc_msgSend)(WS, NSSelectorFromString(@"defaultWorkspace")) : nil;
    NSArray *all = ws ? ((id (*)(id, SEL))objc_msgSend)(ws, NSSelectorFromString(@"allInstalledApplications")) : nil;
    for (id proxy in all) {
        NSString *bid = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"bundleIdentifier"));
        if (bid.length) [installed addObject:bid];
    }
    NSMutableOrderedSet *out = [NSMutableOrderedSet orderedSet];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[@"/var/mobile/Library/Preferences", @"/var/jb/var/mobile/Library/Preferences"]) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![f.lowercaseString containsString:@"carbridge"] || ![f hasSuffix:@".plist"]) continue;
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
            if (!d) {
                // cfprefsd co the chua ghi file -> doc qua CFPreferences theo ten domain
                NSString *dom = [f stringByDeletingPathExtension];
                CFArrayRef keys = CFPreferencesCopyKeyList((__bridge CFStringRef)dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
                if (keys) {
                    d = CFBridgingRelease(CFPreferencesCopyMultiple(keys, (__bridge CFStringRef)dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
                    CFRelease(keys);
                }
            }
            SCPCollectBundleIDs(d, installed, out, 0);
        }
    }
    return out.array;
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
@property (nonatomic, strong) NSArray<NSDictionary *> *carPlayApps, *bridgeApps;   // @{id, name}
@property (nonatomic, readwrite) BOOL fromCar;   // da co danh sach do CarPlay ghi lai (da cam xe)
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

static NSArray<NSDictionary *> *SCPAppRows(NSArray *ids, NSMutableSet *seen)
{
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *bid in ids) {
        if (![bid isKindOfClass:[NSString class]] || [seen containsObject:bid]) continue;
        [seen addObject:bid];
        [rows addObject:@{@"id": bid, @"name": SCPAppName(bid)}];
    }
    [rows sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)]]];
    return rows;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.specifier.name;
    self.view.tintColor = [UIColor colorWithRed:0.04 green:0.35 blue:0.97 alpha:1];

    // CarBridge: danh sach CarPlay ghi lai (chinh xac) + doc thang cau hinh CarBridge (chua cam xe van co)
    NSArray *carIDs = SCPPrefValue(@"CarPlayApps"), *carBridge = SCPPrefValue(@"CarBridgeApps");
    _fromCar = [carIDs isKindOfClass:[NSArray class]] && carIDs.count;
    NSMutableArray *bridge = [NSMutableArray array];
    if ([carBridge isKindOfClass:[NSArray class]]) [bridge addObjectsFromArray:carBridge];
    [bridge addObjectsFromArray:SCPCarBridgeApps()];
    NSMutableSet *seen = [NSMutableSet set];
    _bridgeApps = SCPAppRows(bridge, seen);

    NSMutableArray *native = [NSMutableArray array];
    if (_fromCar) [native addObjectsFromArray:carIDs];
    [native addObjectsFromArray:SCPGuessCarPlayApps()];
    _carPlayApps = SCPAppRows(native, seen);
}

- (NSString *)currentValue
{
    id v = SCPPrefValue([self.specifier propertyForKey:@"key"]);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

- (NSArray<NSDictionary *> *)rowsInSection:(NSInteger)s { return s == 1 ? _carPlayApps : _bridgeApps; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : [self rowsInSection:section].count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section
{
    if (section == 1) return SCPL(@"APP CARPLAY", @"CARPLAY APPS");
    if (section == 2) return SCPL(@"APP CARBRIDGE", @"CARBRIDGE APPS");
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section
{
    if (section == 1 && !_fromCar)
        return SCPL(@"Chưa cắm xe lần nào: đang liệt kê app có hỗ trợ CarPlay. Danh sách chính xác cập nhật mỗi lần cắm xe.",
                    @"Not connected to a car yet: showing apps with CarPlay support. The exact list refreshes each time you connect.");
    if (section == 2)
        return _bridgeApps.count
            ? SCPL(@"App iPhone được bật trong CarBridge.", @"iPhone apps enabled in CarBridge.")
            : SCPL(@"Không thấy app CarBridge nào. Bật app trong CarBridge rồi cắm xe một lần để cập nhật.",
                   @"No CarBridge apps found. Enable apps in CarBridge, then connect to the car once to refresh.");
    return nil;
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
    NSDictionary *a = [self rowsInSection:ip.section][ip.row];
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
    if (![key isKindOfClass:[NSString class]]) return;
    if (ip.section == 0) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)SCP_DOMAIN);
        CFPreferencesAppSynchronize((__bridge CFStringRef)SCP_DOMAIN);
    } else {
        SCPSetPrefValue(key, [self rowsInSection:ip.section][ip.row][@"id"]);
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
