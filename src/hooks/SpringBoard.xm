#import "../common.h"
#import "../SCPPrefs.h"
#import "../SCPCarSplit.h"
#import <notify.h>

// Inject vao SpringBoard. Split nam het trong process CarPlay (SCPCarSplit); SpringBoard chi:
//  - nhan yeu cau tu app URL scheme (Shortcuts / Siri) va chuyen sang CarPlay
//  - dat khung cua so CarBridge (CBWindow, nam trong SpringBoard) dung vao ngan split
//  - ghi ho log cho process khong ghi duoc file chung

#define SCP_DARWIN_OPEN     "com.anlai97.carduo.open"      // tu app URL scheme (Shortcuts / Siri)

// Dat CBWindow cua CarBridge (SpringBoard) = khung ngan split CarPlay. w = 0 -> an cua so (ngan dang an).
static void SCPApplyCarBridgeFrame(CGRect r, NSString *bid, int attempt)
{
    Class mc = objc_getClass("CBBridgeManager");
    id mgr = (mc && [mc respondsToSelector:@selector(sharedInstance)]) ? objcInvoke(mc, @"sharedInstance") : nil;
    id win = nil;
    @try { win = (mgr && [mgr respondsToSelector:NSSelectorFromString(@"window")]) ? objcInvoke(mgr, @"window") : nil; } @catch (NSException *e) {}
    if (!win) {
        if (attempt < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SCPApplyCarBridgeFrame(r, bid, attempt + 1);
            });
        } else {
            SCPLog("CarBridge: khong thay CBWindow de dat khung %@ (%@) -> bao CarPlay chieu lai", NSStringFromCGRect(r), bid);
            if (bid && r.size.width >= 2)
                [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
                    postNotificationName:SCP_NOTIF_CBLOST object:nil userInfo:@{@"identifier": bid}];
        }
        return;
    }
    UIWindow *root = nil;
    @try { root = [win respondsToSelector:NSSelectorFromString(@"rootWindow")] ? objcInvoke(win, @"rootWindow") : nil; } @catch (NSException *e) {}
    if (r.size.width < 2 || r.size.height < 2) {
        root.hidden = YES;
        SCPLog("CarBridge: ngan dang an -> an CBWindow");
        return;
    }
    @try {
        ((void (*)(id, SEL, CGRect))objc_msgSend)(win, NSSelectorFromString(@"setAppFrame:"), r);
        @try { [mgr setValue:[NSValue valueWithCGRect:r] forKey:@"appFrame"]; } @catch (NSException *e) {}
        objcCall(win, @"resizeWindows");
    } @catch (NSException *e) { SCPLog("CarBridge: dat khung loi %@", e); return; }
    root.hidden = NO;
    SCPLog("CarBridge: CBWindow %@ -> %@ (rootWindow %@)", bid, NSStringFromCGRect(r), root ? NSStringFromCGRect(root.frame) : @"nil");
}

// Gui yeu cau sang process CarPlay. Xe chua ket noi thi khong co process CarPlay nghe -> yeu cau tu bo.
static void SCPPostNative(NSDictionary *info)
{
    SCPLog("-> split CarPlay: %@", info);
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:SCP_NOTIF_NATIVE object:nil userInfo:info];
}

// Yeu cau tu app URL scheme: carduo://open|fav|close
static void SCPHandlePendingRequest(void)
{
    NSDictionary *req = [SCPPrefs takePendingRequest];
    if (!req) return;
    NSString *action = req[@"action"];
    SCPLog("yeu cau tu URL: %@", req);
    if ([action isEqualToString:@"close"]) {
        SCPPostNative(@{@"action": @"close"});
        return;
    }
    if ([action hasPrefix:@"fav"]) {
        SCPPostNative(@{@"action": @"fav", @"index": @([[action substringFromIndex:3] integerValue])});
        return;
    }
    NSString *l = req[@"left"], *r = req[@"right"];
    if (l) [SCPPrefs setLeftApp:l];
    if (r) [SCPPrefs setRightApp:r];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:@"pair" forKey:@"action"];
    if (l ?: [SCPPrefs leftApp]) d[@"left"] = l ?: [SCPPrefs leftApp];
    if (r ?: [SCPPrefs rightApp]) d[@"right"] = r ?: [SCPPrefs rightApp];
    SCPPostNative(d);
}

%group SPRINGBOARD

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)app
{
    %orig;
    SCPLogTrim();
    SCPLog("SpringBoard ready, dang ky notification");

    // Process CarPlay: dat cua so CarBridge (CBWindow) dung khung ngan split. CBWindow chi co khi CarBridge
    // dang chieu -> thu lai vai lan neu chua co.
    NSNotificationCenter *dnc = [objc_getClass("NSDistributedNotificationCenter") defaultCenter];
    [dnc addObserverForName:SCP_NOTIF_CBFRAME object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *note) {
        NSDictionary *u = note.userInfo;
        CGRect r = CGRectMake([u[@"x"] doubleValue], [u[@"y"] doubleValue], [u[@"w"] doubleValue], [u[@"h"] doubleValue]);
        SCPApplyCarBridgeFrame(r, u[@"identifier"], 0);
    }];

    // Dong log tu process khong ghi duoc file chung -> ghi ho
    [dnc addObserverForName:SCP_NOTIF_LOG object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *note) {
        NSString *line = note.userInfo[@"line"];
        if ([line isKindOfClass:[NSString class]]) SCPLogAppendRelayed(line);
    }];

    // App URL scheme -> Darwin notification
    static int tokOpen = 0;
    notify_register_dispatch(SCP_DARWIN_OPEN, &tokOpen, dispatch_get_main_queue(), ^(int t) { SCPHandlePendingRequest(); });
}

%end

%end // SPRINGBOARD

%ctor
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
    SCPLog("loaded into SpringBoard");
    %init(SPRINGBOARD);
}
