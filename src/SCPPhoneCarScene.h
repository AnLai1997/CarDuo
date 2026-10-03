#import "common.h"

// =====================================================================
//  SCPPhoneCarScene - che do thu tren iPhone: SpringBoard tu tao scene CARPLAY cua app ngay tren man iPhone
//  (giong DashBoard tao tren xe: DBSceneUpdate -> FBApplicationUpdateScenesTransaction), roi hien trong ngan.
//    - App ve giao dien CarPlay rieng (Apple Maps, Music, Phone): CRSUIApplicationSceneSpecification, process = app.
//    - App template (Vietmap, Google Maps, Spotify, Podcasts...): CRSUIProxyApplicationSceneSpecification,
//      process = com.apple.CarPlayTemplateUIHost, settings.proxiedApplicationBundleIdentifier = app.
//  Thu nghiem: khong co phien CarPlay that, app co the tu choi ve -> sau vai giay ma scene chua co noi dung
//  thi goi onFail (ngan quay ve chieu giao dien iPhone).
// =====================================================================

typedef NS_ENUM(int, SCPCarAppKind) {
    SCPCarAppKindNone     = 0,   // khong co CarPlay
    SCPCarAppKindNative   = 1,   // tu ve giao dien CarPlay (SBStarkCapable / UIWindowSceneSessionRoleCarPlay)
    SCPCarAppKindTemplate = 2,   // app template (CPTemplateApplicationSceneSessionRoleApplication / entitlement carplay)
};

@interface SCPPhoneCarScene : NSObject
+ (SCPCarAppKind)carPlayKindForBundleID:(NSString *)bundleID;

- (instancetype)initWithBundleID:(NSString *)bundleID kind:(SCPCarAppKind)kind;
@property (nonatomic, readonly) NSString *bundleID;
@property (nonatomic, readonly) UIView *view;              // dat vao ngan; noi dung scene nam ben trong (da scale)
@property (nonatomic, copy) void (^onFail)(NSString *reason);

// logicalSize: kich thuoc scene theo point cua XE; scale: point xe -> point iPhone (view hien = logicalSize * scale)
- (void)startWithLogicalSize:(CGSize)logicalSize scale:(CGFloat)scale;
- (void)layoutInBounds:(CGSize)paneSize scale:(CGFloat)scale live:(BOOL)live;
- (void)invalidate;
@end
