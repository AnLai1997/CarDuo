#import "../common.h"
#import "../SCPPrefs.h"

// Inject vao process CarPlay (com.apple.CarPlayApp)
// - Long-press icon tren dashboard -> mo app do vao mot ngan (SpringBoard host).
// iOS 16: code cua app CarPlay nam trong DashBoard.framework, prefix DB (DBDashboard, DBIconView, DBEvent).
%group CARPLAY

static void SCPCloseNativeApp(void)
{
    id dashboard = objcInvoke([UIApplication sharedApplication], @"_currentDashboard");
    NSDictionary *fg = objcInvoke(dashboard, @"identifierToForegroundAppScenesMap");
    if (fg.count > 0) {
        id homeEvent = objcInvoke_2(objc_getClass("DBEvent"), @"eventWithType:context:", (unsigned long long)1, @"SplitCarPlay close app");
        if (homeEvent) objcInvoke_1(dashboard, @"handleEvent:", homeEvent);
    }
}

static void SCPRequestLaunch(NSString *bundleID, int slot)
{
    if (!bundleID) return;
    SCPLog("yeu cau split: %@ slot=%d", bundleID, slot);
    SCPCloseNativeApp();   // cua so split cua SpringBoard se phu len dashboard
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        postNotificationName:SCP_NOTIF_LAUNCH object:nil userInfo:@{@"identifier": bundleID, @"slot": @(slot)}];
}

%hook DBIconView

%new
- (void)scp_handleLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (![SCPPrefs enabled]) return;
    id icon = objcInvoke(self, @"icon");
    NSString *bid = objcInvoke(icon, @"applicationBundleID");
    SCPRequestLaunch(bid, -1);
}

- (id)initWithConfigurationOptions:(unsigned long long)opts listLayoutProvider:(id)provider
{
    id v = %orig;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:v action:NSSelectorFromString(@"scp_handleLongPress:")];
    lp.minimumPressDuration = 1.0;
    [v addGestureRecognizer:lp];
    return v;
}

%end

%end // CARPLAY

%ctor
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.CarPlayApp"]) return;
    SCPLog("loaded into CarPlay");
    %init(CARPLAY);
}
