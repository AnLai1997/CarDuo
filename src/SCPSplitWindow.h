#import "common.h"

typedef NS_ENUM(int, SCPSlot) {
    SCPSlotAuto  = -1,
    SCPSlotLeft  = 0,
    SCPSlotRight = 1,
};

// Mot ngan chua mot app (port tu CRCarplayWindow cua carplay-cast, rut gon)
@interface SCPAppPane : NSObject
@property (nonatomic, strong) NSString *bundleIdentifier;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) id application;        // SBApplication
@property (nonatomic, strong) id appViewController;  // SBAppViewController
@property (nonatomic, strong) id sceneMonitor;       // FBSceneMonitor
@property (nonatomic) int orientation;               // UIInterfaceOrientation, mac dinh portrait
@end

// Cua so SpringBoard nam tren man hinh xe, chia 2 ngan
@interface SCPSplitWindow : NSObject
@property (nonatomic, strong) UIWindow *rootWindow;  // UIRootSceneWindow
@property (nonatomic, strong) UIView *dockView;
@property (nonatomic, strong) SCPAppPane *leftPane;
@property (nonatomic, strong) SCPAppPane *rightPane;

+ (instancetype)current;                 // cua so dang mo (nil neu chua)
+ (instancetype)currentOrCreate;         // tao neu chua co (can CarPlay dang ket noi)

- (void)launchApp:(NSString *)bundleID inSlot:(SCPSlot)slot;
- (void)closeSlot:(SCPSlot)slot;
- (void)swapPanes;
- (void)dismiss;
- (NSArray<SCPAppPane *> *)panes;
@end
