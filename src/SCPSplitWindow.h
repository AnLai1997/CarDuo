#import "common.h"

typedef NS_ENUM(int, SCPSlot) {
    SCPSlotAuto  = -1,
    SCPSlotLeft  = 0,    // trai (hoac tren khi chia tren/duoi)
    SCPSlotRight = 1,    // phai (hoac duoi)
};

// Mot ngan chua mot app (port tu CRCarplayWindow cua carplay-cast, rut gon)
@interface SCPAppPane : NSObject
@property (nonatomic, strong) NSString *bundleIdentifier;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) id application;        // SBApplication
@property (nonatomic, strong) id appViewController;  // SBAppViewController
@property (nonatomic, strong) id sceneMonitor;       // FBSceneMonitor
@property (nonatomic) int orientation;               // UIInterfaceOrientation, mac dinh portrait
@property (nonatomic, strong) UIView *pipHandle;      // thanh keo khi dang PiP
// Option rieng cua ngan: dau "..." o giua mep tren, keo xuong de hien thanh nut (tu an sau vai giay)
@property (nonatomic, strong) UIView *actionHandle;
@property (nonatomic, strong) UIScrollView *actionBar;
@property (nonatomic) BOOL actionsVisible;
@property (nonatomic, strong) NSTimer *actionsHideTimer;
@property (nonatomic, strong) UIButton *fullscreenButton, *pipButton;   // doi icon theo trang thai
@property (nonatomic, strong) NSArray<UIButton *> *favButtons;
@property (nonatomic, strong) UIButton *splitButton;   // nut "chia doi" noi, chi hien khi ngan nay dang mot minh het man
@end

// Cua so SpringBoard nam tren man hinh xe, chia 2 ngan
@interface SCPSplitWindow : NSObject
@property (nonatomic, strong) UIWindow *rootWindow;  // UIRootSceneWindow
@property (nonatomic, strong) SCPAppPane *leftPane;
@property (nonatomic, strong) SCPAppPane *rightPane;
@property (nonatomic) BOOL onMainScreen;
@property (nonatomic) CGFloat ratio;                 // ti le ngan trai (keo thanh phan cach de doi)
@property (nonatomic) SCPSlot fullscreenSlot;         // SCPSlotAuto = khong fullscreen
@property (nonatomic) SCPSlot pipSlot;                // ngan dang thu nho thanh PiP, SCPSlotAuto = khong

+ (instancetype)current;                 // cua so dang mo (nil neu chua)
+ (instancetype)currentOrCreate;         // tao neu chua co (can CarPlay dang ket noi)
+ (instancetype)currentOrCreateOnMainScreen:(BOOL)mainScreen;   // mainScreen=YES: test ngay tren man iPhone

- (void)launchApp:(NSString *)bundleID inSlot:(SCPSlot)slot;
- (void)launchPairLeft:(NSString *)left right:(NSString *)right;   // mo 2 app + ap ti le rieng cua cap
- (void)applyFavorite:(NSInteger)index;                             // cap yeu thich 1..3
- (void)closeSlot:(SCPSlot)slot;                                   // go app khoi ngan (app van chay nen)
- (void)closeSlot:(SCPSlot)slot terminate:(BOOL)terminate;         // terminate=YES: tat han app
- (void)swapPanes;
- (void)dismiss;
- (void)applyPresetRatio:(CGFloat)ratio;     // bo cuc dat san: 0.5, 0.7, 0.3
- (void)cycleLayoutPreset;                   // 50/50 -> 70/30 -> 30/70 -> 50/50
- (void)toggleFullscreenForSlot:(SCPSlot)slot;   // fullscreen tam mot ngan, bam lai de ve split
- (void)togglePiPForSlot:(SCPSlot)slot;          // thu ngan thanh o noi nho, bam lai de ve split
- (void)beginSplitFromSinglePane;                // 1 ngan dang het man -> dua ve nua trai, nua phai hien bang chon app
- (NSArray<SCPAppPane *> *)panes;

// Bang chon app (luoi icon moi app trong may). slot = Left -> chon xong tu hoi tiep cho Right.
// Giu icon roi keo tha vao nua trai/phai cua bang de chon ngan truc tiep.
- (void)showAppPickerForSlot:(SCPSlot)slot;
- (void)hideAppPicker;
@end

// Nut "chia man hinh" noi tren man CarPlay (cua so nho rieng, luon hien khi xe ket noi)
@interface SCPLauncherButton : NSObject
+ (void)showOnCarDisplay;
+ (void)hide;
@end
