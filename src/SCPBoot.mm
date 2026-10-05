#import "common.h"
#import "SCPPrefs.h"
#import "SCPBoot.h"
#import <AVFoundation/AVFoundation.h>

// ---------------------------------------------------------------------
//  Video khoi dong CarPlay: khi DashBoard vua hien (cam xe) phat boot.mp4 vai giay
//  tren cua so rieng phu kin man xe, roi mo dan ra man chinh. Video doc -> nen la chinh
//  video do phong to + lam mo, video that o giua.
// ---------------------------------------------------------------------
static UIWindow *sBootWindow;
static AVPlayer *sBootPlayer;
static BOOL sBootShown;   // da phat cho lan ket noi nay
static id sBootEndObserver;

NSString *SCPBootVideoPath(void)
{
    for (NSString *p in @[@"/var/jb/Library/Application Support/CarDuo/boot.mp4",
                          @"/Library/Application Support/CarDuo/boot.mp4"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

static void SCPBootFinish(void)
{
    UIWindow *w = sBootWindow;
    if (!w) return;
    AVPlayer *player = sBootPlayer;
    sBootWindow = nil;
    if (sBootEndObserver) [[NSNotificationCenter defaultCenter] removeObserver:sBootEndObserver];
    sBootEndObserver = nil;
    [UIView animateWithDuration:0.45 animations:^{
        w.alpha = 0;
        w.transform = CGAffineTransformMakeScale(1.04, 1.04);
    } completion:^(BOOL done) {
        [player pause];
        if (sBootPlayer == player) sBootPlayer = nil;
        w.hidden = YES;
    }];
    SCPLog("Boot: xong video khoi dong");
}

static AVPlayerLayer *SCPBootLayer(AVPlayer *player, NSString *gravity, CGRect frame)
{
    AVPlayerLayer *l = [AVPlayerLayer playerLayerWithPlayer:player];
    l.videoGravity = gravity;
    l.frame = frame;
    return l;
}

void SCPBootShowIfNeeded(UIViewController *root)
{
    if (sBootShown || ![SCPPrefs enabled] || ![SCPPrefs bootVideo]) return;
    UIWindowScene *scene = root.view.window.windowScene;
    NSString *path = SCPBootVideoPath();
    if (!scene || !path) {
        if (!path) SCPLog("Boot: khong thay boot.mp4");
        return;
    }
    sBootShown = YES;

    CGRect b = scene.coordinateSpace.bounds;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = b;
    w.windowLevel = UIWindowLevelAlert + 10;
    w.backgroundColor = [UIColor blackColor];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor blackColor];
    w.rootViewController = vc;

    sBootPlayer = [AVPlayer playerWithURL:[NSURL fileURLWithPath:path]];
    sBootPlayer.muted = YES;   // khong chiem am thanh cua xe
    // nen: video phong kin man + mo
    [vc.view.layer addSublayer:SCPBootLayer(sBootPlayer, AVLayerVideoGravityResizeAspectFill, b)];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blur.frame = b;
    [vc.view addSubview:blur];
    // video that o giua
    [vc.view.layer addSublayer:SCPBootLayer(sBootPlayer, AVLayerVideoGravityResizeAspect, b)];

    w.hidden = NO;
    sBootWindow = w;
    [sBootPlayer play];

    CGFloat dur = [SCPPrefs bootDuration];
    SCPLog("Boot: phat video khoi dong %.0fs", dur);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dur * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ SCPBootFinish(); });
    // video ngan hon thoi luong -> xong som
    sBootEndObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:sBootPlayer.currentItem queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { SCPBootFinish(); }];
}

void SCPBootReset(void)
{
    sBootShown = NO;
    if (sBootWindow) { sBootWindow.hidden = YES; sBootWindow = nil; }
    [sBootPlayer pause];
    sBootPlayer = nil;
}
