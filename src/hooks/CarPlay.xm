#import "../common.h"

// Inject vao process CarPlay (com.apple.CarPlayApp)
// Long-press icon tren dashboard -> gui yeu cau mo app vao mot ngan sang SpringBoard.
// iOS 16: code cua app CarPlay nam trong DashBoard.framework, prefix DB (DBDashboard, DBIconView, DBEvent).
%group CARPLAY

static void SCPRequestLaunch(NSString *bundleID)
{
    if (!bundleID) return;
    SCPLog("long-press %@ -> yeu cau split", bundleID);

    // Dong app CarPlay native dang chay (cua so split cua SpringBoard se phu len dashboard)
    id dashboard = objcInvoke([UIApplication sharedApplication], @"_currentDashboard");
    NSDictionary *fg = objcInvoke(dashboard, @"identifierToForegroundAppScenesMap");
    if (fg.count > 0) {
        id homeEvent = objcInvoke_2(objc_getClass("DBEvent"), @"eventWithType:context:", (unsigned long long)1, @"SplitCarPlay close app");
        if (homeEvent) objcInvoke_1(dashboard, @"handleEvent:", homeEvent);
    }

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        postNotificationName:SCP_NOTIF_LAUNCH object:nil userInfo:@{@"identifier": bundleID}];
}

%hook DBIconView

%new
- (void)scp_handleLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    id icon = objcInvoke(self, @"icon");
    NSString *bid = objcInvoke(icon, @"applicationBundleID");
    SCPRequestLaunch(bid);
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
