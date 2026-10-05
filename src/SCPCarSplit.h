#import "common.h"

// =====================================================================
//  SCPCarSplit - chia doi man CarPlay NGAY TRONG process CarPlay (DashBoard).
//  Moi ngan la giao dien CarPlay that cua app (scene CarPlay / template), khong phai giao dien iPhone:
//  DashBoard tu mo app theo duong binh thuong (DBEvent type 4) va tao DBApplicationSceneViewController
//  (ke ca proxy CarPlayTemplateUIHost cho app template). Tweak chi "nhan nuoi" view controller do vao
//  1 ngan thay vi de DashBoard hien toan man, va bao kich thuoc ngan cho scene qua
//  -[DBDashboard sceneFrameForAppInfo:proxyAppInfo:].
// =====================================================================

#define SCP_TEMPLATE_HOST @"com.apple.CarPlayTemplateUIHost"

// SpringBoard / Settings -> CarPlay process: mo split CarPlay
// userInfo: action = open | pair | picker | close | fav ; identifier, slot, left, right, index
#define SCP_NOTIF_NATIVE        @"com.anlai97.carduo.native"
// CarPlay process -> SpringBoard: dat khung CBWindow cua CarBridge = khung ngan (identifier, x, y, w, h; w=0 -> an)
#define SCP_NOTIF_CBFRAME       @"com.anlai97.carduo.cbframe"

@interface SCPCarSplit : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL active;
@property (nonatomic, readonly) BOOL bridgeStarting;   // CarBridge dang khoi dong chieu app vao ngan
- (CGRect)bridgeFrame;                                   // khung chieu CarBridge (toa do man xe), Zero neu khong co

- (void)openApp:(NSString *)bundleID slot:(int)slot;          // slot -1 = tu chon (ngan trong / ngan dang chon)
- (void)openPairLeft:(NSString *)left right:(NSString *)right;
- (void)showPickerForSlot:(int)slot;                           // -1 = ngan trong
- (void)closeGoingHome:(BOOL)goHome;                           // goHome: gui Home cho DashBoard de workspace ve man chinh
- (void)closeApp:(NSString *)bundleID;                         // dong ngan dang chua app nay (neu co)
- (BOOL)isCarPlayApp:(NSString *)bundleID;

// Dung trong hook
- (BOOL)paneSize:(CGSize *)outSize forBundle:(NSString *)bundleID;
- (BOOL)wantsViewController:(UIViewController *)vc;
- (void)adoptViewController:(UIViewController *)vc;
- (BOOL)protectsViewController:(id)vc;
- (void)sceneDestroyedForViewController:(id)vc;
- (void)rootDidLayout;                  // DBDashboardRootViewController viewDidLayoutSubviews
- (void)dashboardInvalidated;           // ngat xe
- (void)refreshAppTabSoon;              // DashBoard vua mo / dong app toan man -> hien / an tab icon
- (void)removeAppTab;
@end

#ifdef __cplusplus
extern "C" {
#endif
NSString *SCPRealBundleForInfos(id info, id proxyInfo);   // bo qua CarPlayTemplateUIHost, tra ve bundle that cua app
void SCPCDumpVC(UIViewController *vc, NSString *why);     // chan doan: ghi cay view cua app (CarBridge)
#ifdef __cplusplus
}
#endif
