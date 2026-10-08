#import "../common.h"
#import "../SCPPrefs.h"
#import "../SCPCarSplit.h"
#import <notify.h>
#import <signal.h>

// Inject vao SpringBoard. Split nam het trong process CarPlay (SCPCarSplit); SpringBoard chi:
//  - nhan yeu cau tu app URL scheme (Shortcuts / Siri) va chuyen sang CarPlay
//  - dat khung cua so CarBridge (CBWindow, nam trong SpringBoard) dung vao ngan split
//  - ghi ho log cho process khong ghi duoc file chung

#define SCP_DARWIN_OPEN     "com.anlai97.carduo.open"      // tu app URL scheme (Shortcuts / Siri)

// Dat CBWindow cua CarBridge (SpringBoard) = khung ngan split CarPlay. w = 0 -> an cua so (ngan dang an).
// Moi yeu cau dat khung tang so thu tu; lan thu lai cua yeu cau cu thi bo (khong de khung cu de len khung moi)
static NSUInteger sCBFrameSeq;

static void SCPApplyCarBridgeFrame(CGRect r, NSString *bid, int attempt, NSUInteger seq)
{
    if (seq != sCBFrameSeq) return;
    Class mc = objc_getClass("CBBridgeManager");
    id mgr = (mc && [mc respondsToSelector:@selector(sharedInstance)]) ? objcInvoke(mc, @"sharedInstance") : nil;
    id win = nil;
    @try { win = (mgr && [mgr respondsToSelector:NSSelectorFromString(@"window")]) ? objcInvoke(mgr, @"window") : nil; } @catch (NSException *e) {}
    if (!win) {
        if (attempt < 6) {   // ~2.4s roi bao CarPlay chieu lai
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SCPApplyCarBridgeFrame(r, bid, attempt + 1, seq);
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

// Nut [x] tren ngan CarPlay: tat han app (nhu vuot tat trong app switcher). FBSSystemService, khong co thi kill pid.
static void SCPTerminateApp(NSString *bid)
{
    if (![bid isKindOfClass:[NSString class]] || !bid.length) return;
    id svc = nil;
    Class sc = objc_getClass("FBSSystemService");
    if (sc && [sc respondsToSelector:@selector(sharedService)]) svc = objcInvoke(sc, @"sharedService");
    SEL sel = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
    if ([svc respondsToSelector:sel]) {
        @try {
            ((void (*)(id, SEL, id, long long, BOOL, id))objc_msgSend)(svc, sel, bid, 1, NO, @"CarDuo close");
            SCPLog("tat han %@ (FBSSystemService)", bid);
            return;
        } @catch (NSException *e) { SCPLog("tat han %@ loi %@", bid, e); }
    }
    id ctl = objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance");
    id app = ctl ? objcInvoke_1(ctl, @"applicationWithBundleIdentifier:", bid) : nil;
    id state = app ? objcInvoke(app, @"processState") : nil;
    int pid = state ? objcInvokeT(state, @"pid", int) : 0;
    if (pid > 0) { kill(pid, SIGKILL); SCPLog("tat han %@ (kill pid %d)", bid, pid); }
    else SCPLog("tat han %@: khong thay process", bid);
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
        SCPApplyCarBridgeFrame(r, u[@"identifier"], 0, ++sCBFrameSeq);
    }];

    // Nut [x] tren ngan CarPlay -> tat han app
    [dnc addObserverForName:SCP_NOTIF_KILL object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *note) { SCPTerminateApp(note.userInfo[@"identifier"]); }];

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
