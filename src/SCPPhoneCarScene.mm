#import "SCPPhoneCarScene.h"
#import "SCPPrefs.h"

#define SCPP_TEMPLATE_HOST  @"com.apple.CarPlayTemplateUIHost"
#define SCPP_CONTENT_TIMEOUT 8.0     // giay cho scene co noi dung truoc khi bao that bai

@interface SCPPhoneCarScene ()
@property (nonatomic, readwrite) NSString *bundleID;
@property (nonatomic, readwrite) UIView *view;
@property (nonatomic) SCPCarAppKind kind;
@property (nonatomic, strong) UIView *holder;          // kich thuoc logic (point xe), scale xuong man iPhone
@property (nonatomic, copy) NSString *sceneID;
@property (nonatomic, strong) id transaction;
@property (nonatomic, strong) id presenter;
@property (nonatomic, strong) UIView *presentationView;
@property (nonatomic) CGSize logicalSize;
@property (nonatomic) BOOL invalidated, failed, presented;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation SCPPhoneCarScene

// ---------------------------------------------------------------------
//  Phan loai app theo Info.plist (giong cach CarPlay chon kieu scene)
// ---------------------------------------------------------------------
+ (SCPCarAppKind)carPlayKindForBundleID:(NSString *)bid
{
    if (!bid.length) return SCPCarAppKindNone;
    id proxy = objcInvoke_1(objc_getClass("LSApplicationProxy"), @"applicationProxyForIdentifier:", bid);
    NSURL *url = proxy ? objcInvoke(proxy, @"bundleURL") : nil;
    NSDictionary *info = url ? [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"Info.plist"]] : nil;
    if ([info[@"SBStarkCapable"] boolValue]) return SCPCarAppKindNative;
    NSDictionary *configs = info[@"UIApplicationSceneManifest"][@"UISceneConfigurations"];
    if ([configs isKindOfClass:[NSDictionary class]]) {
        if (configs[@"UIWindowSceneSessionRoleCarPlay"]) return SCPCarAppKindNative;
        if (configs[@"CPTemplateApplicationSceneSessionRoleApplication"]) return SCPCarAppKindTemplate;
    }
    // App template doi cu (CPApplicationDelegate, chua co scene manifest): nhan biet qua entitlement CarPlay
    NSDictionary *ents = nil;
    @try {
        if ([proxy respondsToSelector:NSSelectorFromString(@"entitlements")]) ents = objcInvoke(proxy, @"entitlements");
    } @catch (NSException *e) {}
    if ([ents isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in ents) {
            if ([k hasPrefix:@"com.apple.developer.carplay"] || [k isEqualToString:@"com.apple.developer.playable-content"]) return SCPCarAppKindTemplate;
        }
    }
    return SCPCarAppKindNone;
}

- (instancetype)initWithBundleID:(NSString *)bundleID kind:(SCPCarAppKind)kind
{
    if ((self = [super init])) {
        _bundleID = [bundleID copy];
        _kind = kind;
        _view = [[UIView alloc] initWithFrame:CGRectZero];
        _view.backgroundColor = [UIColor blackColor];
        _view.clipsToBounds = YES;
        _holder = [[UIView alloc] initWithFrame:CGRectZero];
        _holder.backgroundColor = [UIColor blackColor];
        [_view addSubview:_holder];
        _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        _statusLabel.font = [UIFont systemFontOfSize:13];
        _statusLabel.textAlignment = NSTextAlignmentCenter;
        _statusLabel.numberOfLines = 2;
        _statusLabel.text = @"Đang mở giao diện CarPlay…";
        [_view addSubview:_statusLabel];
    }
    return self;
}

static id SCPPMainDisplayConfiguration(void)
{
    Class dm = objc_getClass("FBDisplayManager");
    return dm ? objcInvoke(dm, @"mainConfiguration") : nil;
}

static void SCPPSet(id obj, NSString *sel, id value)
{
    if ([obj respondsToSelector:NSSelectorFromString(sel)]) objcInvoke_1(obj, sel, value);
}

// Workspace cua scene: lay dung workspace ma SpringBoard dung cho scene cua app (log de doi chieu)
static NSString *SCPPWorkspaceIdentifier(NSString *bid)
{
    @try {
        id app = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", bid);
        id sm = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
        if (!app || !sm) return nil;
        id ident = objcInvoke_3(sm, @"sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:",
                                app, 0, UIWindowSceneSessionRoleApplication);
        return [ident respondsToSelector:NSSelectorFromString(@"workspaceIdentifier")] ? objcInvoke(ident, @"workspaceIdentifier") : nil;
    } @catch (NSException *e) { return nil; }
}

- (id)buildSettingsForSpecification:(id)spec size:(CGSize)size
{
    Class settingsCls = objcInvoke(spec, @"settingsClass");
    id settings = [[settingsCls new] mutableCopy];
    SCPPSet(settings, @"setDisplayConfiguration:", SCPPMainDisplayConfiguration());
    ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, NSSelectorFromString(@"setFrame:"), CGRectMake(0, 0, size.width, size.height));
    if ([settings respondsToSelector:NSSelectorFromString(@"setLevel:")])
        ((void (*)(id, SEL, double))objc_msgSend)(settings, NSSelectorFromString(@"setLevel:"), 1.0);
    if ([settings respondsToSelector:NSSelectorFromString(@"setInterfaceOrientation:")])
        ((void (*)(id, SEL, long long))objc_msgSend)(settings, NSSelectorFromString(@"setInterfaceOrientation:"), 1);
    if ([settings respondsToSelector:NSSelectorFromString(@"setSafeAreaInsetsPortrait:")])
        ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(settings, NSSelectorFromString(@"setSafeAreaInsetsPortrait:"), UIEdgeInsetsZero);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, NSSelectorFromString(@"setForeground:"), YES);
    if ([settings respondsToSelector:NSSelectorFromString(@"setUserInterfaceStyle:")])
        ((void (*)(id, SEL, long long))objc_msgSend)(settings, NSSelectorFromString(@"setUserInterfaceStyle:"), 2);   // dark nhu CarPlay
    if (self.kind == SCPCarAppKindTemplate) {
        SCPPSet(settings, @"setProxiedApplicationBundleIdentifier:", self.bundleID);
        if ([settings respondsToSelector:NSSelectorFromString(@"setProxiedApplicationLinkedOnOrAfterYukon:")])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, NSSelectorFromString(@"setProxiedApplicationLinkedOnOrAfterYukon:"), YES);
    }
    return settings;
}

- (void)startWithLogicalSize:(CGSize)logicalSize scale:(CGFloat)scale
{
    self.logicalSize = logicalSize;
    [self layoutInBounds:CGSizeMake(logicalSize.width * scale, logicalSize.height * scale) scale:scale live:NO];
    // Danh dau "dang tao": neu SpringBoard chet giua chung, lan khoi dong sau se tu tat tinh nang nay
    [SCPPrefs setCarSceneInProgress:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((SCPP_CONTENT_TIMEOUT + 4) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [SCPPrefs setCarSceneInProgress:NO];
    });
    @try {
        [self createScene];
    } @catch (NSException *e) {
        [self failWithReason:[NSString stringWithFormat:@"tao scene loi: %@", e.reason]];
    }
}

- (void)createScene
{
    dlopen("/System/Library/PrivateFrameworks/CarPlayUIServices.framework/CarPlayUIServices", RTLD_NOW);
    BOOL tmpl = (self.kind == SCPCarAppKindTemplate);
    Class specCls = objc_getClass(tmpl ? "CRSUIProxyApplicationSceneSpecification" : "CRSUIApplicationSceneSpecification");
    if (!specCls) { [self failWithReason:@"khong co CRSUI*SceneSpecification"]; return; }
    id spec = [specCls respondsToSelector:NSSelectorFromString(@"specification")] ? objcInvoke(specCls, @"specification") : [specCls new];

    id settings = [self buildSettingsForSpecification:spec size:self.logicalSize];
    id params = objcInvoke_1(objc_getClass("FBSSceneParameters"), @"parametersForSpecification:", spec);
    objcInvoke_1(params, @"setSettings:", settings);
    Class tcCls = objcInvoke(spec, @"transitionContextClass");
    id tc = tcCls ? [tcCls new] : [objc_getClass("FBSSceneTransitionContext") new];

    NSString *processBid = tmpl ? SCPP_TEMPLATE_HOST : self.bundleID;
    id processIdentity = objcInvoke_1(objc_getClass("RBSProcessIdentity"), @"identityForEmbeddedApplicationIdentifier:", processBid);
    id (^contextProvider)(void) = ^id {
        id ctx = [objc_getClass("FBMutableProcessExecutionContext") new];
        if ([ctx respondsToSelector:NSSelectorFromString(@"setLaunchIntent:")])
            ((void (*)(id, SEL, long long))objc_msgSend)(ctx, NSSelectorFromString(@"setLaunchIntent:"), 4);   // foreground
        return ctx;
    };
    id tx = objcInvoke_2([objc_getClass("FBApplicationUpdateScenesTransaction") alloc], @"initWithProcessIdentity:executionContextProvider:",
                         processIdentity, contextProvider);
    if (!tx) { [self failWithReason:@"khong tao duoc FBApplicationUpdateScenesTransaction"]; return; }

    self.sceneID = [NSString stringWithFormat:@"com.anpham.carduo.carscene:%@", self.bundleID];
    NSString *ws = SCPPWorkspaceIdentifier(self.bundleID);
    id identity = ws ? objcInvoke_2(objc_getClass("FBSSceneIdentity"), @"identityForIdentifier:workspaceIdentifier:", self.sceneID, ws)
                     : objcInvoke_1(objc_getClass("FBSSceneIdentity"), @"identityForIdentifier:", self.sceneID);
    SCPLog("CarScene: tao scene CarPlay tren iPhone cho %@ (kind=%d, process=%@, spec=%@, workspace=%@, size=%@)",
           self.bundleID, self.kind, processBid, NSStringFromClass([spec class]), ws, NSStringFromCGSize(self.logicalSize));

    objcInvoke_3(tx, @"updateSceneWithIdentity:parameters:transitionContext:", identity, params, tc);
    __weak SCPPhoneCarScene *weakSelf = self;
    ((void (*)(id, SEL, id))objc_msgSend)(tx, NSSelectorFromString(@"setCompletionBlock:"), ^(BOOL ok) {
        SCPLog("CarScene: transaction %@ xong ok=%d", weakSelf.bundleID, ok);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf tryPresentAttempt:0]; });
    });
    self.transaction = tx;
    objcInvoke(tx, @"begin");
    [self tryPresentAttempt:0];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SCPP_CONTENT_TIMEOUT * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf checkContent];
    });
}

- (id)scene
{
    if (!self.sceneID) return nil;
    id mgr = objcInvoke(objc_getClass("FBSceneManager"), @"sharedInstance");
    return mgr ? objcInvoke_1(mgr, @"sceneWithIdentifier:", self.sceneID) : nil;
}

// Scene co the chua ton tai ngay sau begin (cho process launch) -> thu lai vai lan
- (void)tryPresentAttempt:(int)attempt
{
    if (self.invalidated || self.failed || self.presented) return;
    id scene = [self scene];
    if (!scene) {
        if (attempt < 40) {
            __weak SCPPhoneCarScene *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf tryPresentAttempt:attempt + 1];
            });
        }
        return;
    }
    @try {
        id pm = objcInvoke(scene, @"uiPresentationManager");
        id presenter = objcInvoke_2(pm, @"createPresenterWithIdentifier:priority:", @"CarDuo", (long long)0);
        if (!presenter) { [self failWithReason:@"khong tao duoc scene presenter"]; return; }
        objcInvoke(presenter, @"activate");
        UIView *pv = objcInvoke(presenter, @"presentationView");
        self.presenter = presenter;
        self.presentationView = pv;
        self.presented = YES;
        pv.frame = self.holder.bounds;
        pv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.holder addSubview:pv];
        SCPLog("CarScene: dang hien scene %@ (%@)", self.bundleID, scene);
    } @catch (NSException *e) {
        [self failWithReason:[NSString stringWithFormat:@"present loi: %@", e.reason]];
    }
}

// Het thoi gian ma scene chua co noi dung (contentState 2 = ready) -> bao that bai
- (void)checkContent
{
    if (self.invalidated || self.failed) return;
    id scene = [self scene];
    long long state = scene && [scene respondsToSelector:NSSelectorFromString(@"contentState")] ? objcInvokeT(scene, @"contentState", long long) : -1;
    id process = scene ? objcInvoke(scene, @"clientProcess") : nil;
    SCPLog("CarScene: kiem tra %@: scene=%@ contentState=%lld process=%@", self.bundleID, scene ? @"co" : @"khong", state, process);
    if (!scene || state != 2) {
        [self failWithReason:scene ? [NSString stringWithFormat:@"scene chua co noi dung (contentState=%lld)", state] : @"khong co scene"];
        return;
    }
    self.statusLabel.hidden = YES;
}

- (void)failWithReason:(NSString *)reason
{
    if (self.failed || self.invalidated) return;
    self.failed = YES;
    SCPLog("CarScene: KHONG hien duoc giao dien CarPlay cua %@: %@", self.bundleID, reason);
    if (self.onFail) self.onFail(reason);
}

- (void)layoutInBounds:(CGSize)paneSize scale:(CGFloat)scale live:(BOOL)live
{
    if (scale <= 0) scale = 1;
    self.view.frame = CGRectMake(0, 0, paneSize.width, paneSize.height);
    CGSize logical = CGSizeMake(round(paneSize.width / scale), round(paneSize.height / scale));
    self.holder.transform = CGAffineTransformIdentity;
    self.holder.frame = CGRectMake(0, 0, logical.width, logical.height);
    self.holder.transform = CGAffineTransformMakeScale(scale, scale);
    self.holder.center = CGPointMake(paneSize.width / 2, paneSize.height / 2);
    self.statusLabel.frame = CGRectMake(8, paneSize.height / 2 - 20, paneSize.width - 16, 40);
    if (live || CGSizeEqualToSize(logical, self.logicalSize) || logical.width < 2) return;
    self.logicalSize = logical;
    id scene = [self scene];
    if (!scene) return;
    objcInvoke_1(scene, @"updateSettingsWithBlock:", ^(id settings) {
        ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, NSSelectorFromString(@"setFrame:"), CGRectMake(0, 0, logical.width, logical.height));
    });
}

- (void)invalidate
{
    if (self.invalidated) return;
    self.invalidated = YES;
    @try {
        if ([self.presenter respondsToSelector:NSSelectorFromString(@"invalidate")]) objcInvoke(self.presenter, @"invalidate");
        [self.presentationView removeFromSuperview];
        id scene = [self scene];
        if (scene) {
            id mgr = objcInvoke(objc_getClass("FBSceneManager"), @"sharedInstance");
            objcInvoke_2(mgr, @"destroyScene:withTransitionContext:", self.sceneID, (id)nil);
        }
    } @catch (NSException *e) {
        SCPLog("CarScene: huy scene loi %@", e);
    }
    self.presenter = nil; self.presentationView = nil; self.transaction = nil;
    [self.view removeFromSuperview];
    SCPLog("CarScene: da huy scene %@", self.bundleID);
}

@end
