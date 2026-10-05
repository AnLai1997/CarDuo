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
static BOOL sBootAudio;   // da lay audio session -> phai tra lai

NSString *SCPBootVideoPath(void)
{
    // Video tu chon trong Settings (chep vao /var/jb/var/mobile/Library/CarDuo)
    NSString *custom = [SCPPrefs customBootVideo];
    if (custom && [[NSFileManager defaultManager] fileExistsAtPath:custom]) return custom;
    if (custom) SCPLog("Boot: khong doc duoc video tu chon %@ -> dung video mac dinh", custom);
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
    // nho dan tieng cung luc mo dan hinh
    for (int i = 1; i <= 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ player.volume = MAX(0, 1 - i * 0.2); });
    }
    [UIView animateWithDuration:0.45 animations:^{
        w.alpha = 0;
        w.transform = CGAffineTransformMakeScale(1.04, 1.04);
    } completion:^(BOOL done) {
        [player pause];
        if (sBootAudio) [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        sBootAudio = NO;
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
    // Co tieng: lay audio session (nhac dang phat tren xe duoc giam nho), xong thi tra lai
    BOOL sound = [SCPPrefs bootSound];
    sBootPlayer.muted = !sound;
    if (sound) {
        NSError *err = nil;
        AVAudioSession *as = [AVAudioSession sharedInstance];
        [as setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback
                options:AVAudioSessionCategoryOptionDuckOthers error:&err];
        [as setActive:YES error:&err];
        sBootAudio = !err;
        if (err) SCPLog("Boot: audio session loi %@", err);
    }
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
    if (dur <= 0) dur = 30;   // "Het video": dung khi video ket thuc, toi da 30s
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
