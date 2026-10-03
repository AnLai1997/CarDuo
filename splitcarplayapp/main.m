// SplitCarPlay companion app: nhan URL scheme cho Shortcuts / Siri
//   splitcarplay://open?left=<bundle>&right=<bundle>   mo split voi 2 app (tren xe)
//   splitcarplay://fav?n=1                               mo cap yeu thich 1..3
//   splitcarplay://close                                 dong split
// Ghi yeu cau vao prefs domain roi gui Darwin notification cho SpringBoard.
#import <UIKit/UIKit.h>
#import <notify.h>

#define SCP_DOMAIN CFSTR("com.anlai97.carduo")

static void setPref(NSString *key, NSString *value)
{
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, SCP_DOMAIN);
}

static BOOL handleURL(NSURL *url)
{
    if (![url.scheme isEqualToString:@"splitcarplay"]) return NO;
    NSString *action = url.host ?: @"open";
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *it in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
        if (it.value) q[it.name] = it.value;
    }
    if ([action isEqualToString:@"fav"] && q[@"n"]) {
        setPref(@"PendingAction", [NSString stringWithFormat:@"fav%@", q[@"n"]]);
    } else if ([action isEqualToString:@"close"]) {
        setPref(@"PendingAction", @"close");
    } else {
        setPref(@"PendingAction", @"open");
        setPref(@"PendingLeft", q[@"left"]);
        setPref(@"PendingRight", q[@"right"]);
    }
    CFPreferencesAppSynchronize(SCP_DOMAIN);
    notify_post("com.anlai97.carduo.open");
    return YES;
}

@interface SCPAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SCPAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.15 alpha:1];

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectInset(vc.view.bounds, 24, 0)];
    l.numberOfLines = 0;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:15];
    l.textAlignment = NSTextAlignmentCenter;
    l.text = @"SplitCarPlay\n\nApp này nhận lệnh từ Shortcuts / Siri.\n\nTạo Shortcut với hành động \"Open URL\":\n\n"
             @"splitcarplay://open?left=com.apple.Maps&right=com.google.ios.youtube\n\n"
             @"splitcarplay://fav?n=1   (cặp yêu thích 1)\n\nsplitcarplay://close\n\n"
             @"Cài đặt chi tiết: Cài đặt > SplitCarPlay";
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:l];

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"Mở Cài đặt SplitCarPlay" forState:UIControlStateNormal];
    b.frame = CGRectMake(0, vc.view.bounds.size.height - 90, vc.view.bounds.size.width, 44);
    b.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    [b addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:b];

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)openSettings
{
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"prefs:root=SplitCarPlay"] options:@{} completionHandler:nil];
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
    BOOL ok = handleURL(url);
    // Quay ve man truoc (Shortcuts) sau khi gui lenh
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] performSelector:@selector(suspend)];
    });
    return ok;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SCPAppDelegate class]));
    }
}
