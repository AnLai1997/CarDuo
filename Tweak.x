#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// =====================================================================
//  SplitCarPlay - ban dev ca nhan (Dopamine rootless, iOS 15.0 - 16.6.1)
//
//  GIAI DOAN 1 = RECON (mac dinh): CHI LOG, khong doi giao dien.
//    - Chay trong process "CarPlay" (com.apple.CarPlayApp) la noi host UI CarPlay.
//    - Dump cay view that cua moi UIWindow -> biet CHINH XAC class nao giu app.
//    - Log moi view co ten chua "Host"/"Scene" khi no duoc gan vao window.
//
//  GIAI DOAN 2 = RESIZE: sau khi recon xong, dien ten class host that vao
//    HOST_VIEW_CLASS va bat ENABLE_RESIZE = 1 de ep app xuong nua man hinh trai.
//
//  Xem log:  ssh vao may -> `oslog | grep SplitCP`
//            hoac tu Windows: `idevicesyslog | findstr SplitCP`
// =====================================================================

#define ENABLE_RESIZE    0
#define HOST_VIEW_CLASS  "FBSceneHostWrapperView"   // <-- thay bang ten that sau recon
#define LOGTAG           "[SplitCP]"
#define RECON_DELAY_SEC  8.0

static BOOL isCarPlayProcess(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.CarPlayApp"];
}

// ---------------------------------------------------------------------
//  RECON helpers
// ---------------------------------------------------------------------
static NSString *viewChain(UIView *v) {
    NSMutableArray *chain = [NSMutableArray array];
    UIView *cur = v;
    int depth = 0;
    while (cur && depth++ < 12) {
        [chain addObject:NSStringFromClass([cur class])];
        cur = cur.superview;
    }
    return [chain componentsJoinedByString:@" < "];
}

static void dumpWindows(NSString *reason) {
    NSLog(@LOGTAG " ===== DUMP (%@) screens=%lu =====", reason,
          (unsigned long)[UIScreen screens].count);

    for (UIScreen *s in [UIScreen screens]) {
        NSLog(@LOGTAG " screen %@ bounds=%@ scale=%.1f",
              s, NSStringFromCGRect(s.bounds), s.scale);
    }

    NSArray *windows = [UIApplication sharedApplication].windows;
    NSLog(@LOGTAG " windows=%lu", (unsigned long)windows.count);
    for (UIWindow *w in windows) {
        NSLog(@LOGTAG " --- window %@ frame=%@ level=%.0f hidden=%d scene=%@",
              NSStringFromClass([w class]), NSStringFromCGRect(w.frame),
              w.windowLevel, w.hidden, w.windowScene);
        // recursiveDescription la method private, co san tren moi UIView
        NSString *desc = [w performSelector:@selector(recursiveDescription)];
        // log tung dong de khong bi oslog cat
        for (NSString *line in [desc componentsSeparatedByString:@"\n"]) {
            if (line.length) NSLog(@LOGTAG " | %@", line);
        }
    }

    // Thu liet ke FBScene neu process nay la scene host
    Class fbsm = objc_getClass("FBSceneManager");
    if (fbsm && [fbsm respondsToSelector:@selector(sharedInstance)]) {
        id mgr = [fbsm performSelector:@selector(sharedInstance)];
        @try {
            id scenes = [mgr valueForKey:@"scenes"];
            NSLog(@LOGTAG " FBSceneManager scenes: %@", scenes);
        } @catch (NSException *e) {
            NSLog(@LOGTAG " FBSceneManager co nhung khong doc duoc 'scenes': %@", e.reason);
        }
    } else {
        NSLog(@LOGTAG " khong co FBSceneManager trong process nay");
    }
    NSLog(@LOGTAG " ===== END DUMP =====");
}

// ---------------------------------------------------------------------
//  RECON hooks (chay trong CarPlay process)
// ---------------------------------------------------------------------
%group Recon

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    NSString *cls = NSStringFromClass([self class]);
    if ([cls containsString:@"Host"] || [cls containsString:@"Scene"] ||
        [cls containsString:@"CAR"]  || [cls containsString:@"CPUI"]) {
        NSLog(@LOGTAG " attached %@ frame=%@ chain: %@",
              cls, NSStringFromCGRect(self.frame), viewChain(self));
    }
}
%end

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    NSLog(@LOGTAG " makeKeyAndVisible %@ frame=%@", NSStringFromClass([self class]),
          NSStringFromCGRect(self.frame));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ dumpWindows(@"after makeKeyAndVisible"); });
}
%end

%end // Recon

// ---------------------------------------------------------------------
//  RESIZE hooks - "HostView" duoc map sang class that trong %ctor
// ---------------------------------------------------------------------
%group Resize

%hook HostView
- (void)setFrame:(CGRect)frame {
    UIView *parent = self.superview;
    CGRect bounds = parent ? parent.bounds : frame;
    if (!CGRectIsEmpty(bounds)) {
        frame.origin.x   = 0;
        frame.size.width = bounds.size.width / 2.0;
    }
    NSLog(@LOGTAG " resize -> %@", NSStringFromCGRect(frame));
    %orig(frame);
}
%end

%end // Resize

// ---------------------------------------------------------------------
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSLog(@LOGTAG " loaded into %@ (%@)", proc, [[NSBundle mainBundle] bundleIdentifier]);

    if (!isCarPlayProcess()) return;   // trong SpringBoard chi log "loaded" de xac nhan inject

    %init(Recon);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RECON_DELAY_SEC * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ dumpWindows(@"timer"); });

#if ENABLE_RESIZE
    Class host = objc_getClass(HOST_VIEW_CLASS);
    if (host) {
        %init(Resize, HostView = host);
        NSLog(@LOGTAG " RESIZE enabled on %s", HOST_VIEW_CLASS);
    } else {
        NSLog(@LOGTAG " RESIZE: khong tim thay class %s", HOST_VIEW_CLASS);
    }
#endif
}
