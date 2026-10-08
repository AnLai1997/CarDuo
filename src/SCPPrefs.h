#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#define SCP_PREFS_DOMAIN @"com.anlai97.carduo"

// Doc cau hinh tu domain com.anlai97.carduo (Settings ghi qua cfprefsd).
// Doc moi lan can nen thay doi trong Settings co hieu luc ngay, khong can respring.
@interface SCPPrefs : NSObject
+ (BOOL)enabled;
+ (NSString *)leftApp;
+ (NSString *)rightApp;
+ (NSString *)lastLeftApp;        // cap app dung lan cuoi tren xe (tu mo lai khi cam xe)
+ (NSString *)lastRightApp;
+ (BOOL)autoLaunch;
+ (NSInteger)paneOrientation;   // 1 = portrait, 3 = landscape
+ (CGFloat)splitRatio;          // ti le be rong ngan trai (0.2 - 0.8)
+ (NSInteger)splitDirection;   // 0 trai/phai, 1 tren/duoi
+ (BOOL)bootVideo;             // phat video khoi dong khi CarPlay mo (mac dinh bat)
+ (CGFloat)bootDuration;        // so giay phat video khoi dong (0 = het video)
+ (BOOL)bootSound;             // video khoi dong co tieng (mac dinh bat)
+ (NSString *)customBootVideo;  // duong dan video khoi dong tu chon (nil = video mac dinh)
+ (NSArray<NSString *> *)carPlayApps;   // app CarPlay hien duoc (CarPlay process ghi lai)
+ (void)setCarPlayApps:(NSArray<NSString *> *)ids;
+ (void)setCarBridgeApps:(NSArray<NSString *> *)ids;   // app CarBridge dang bat (CarPlay process ghi lai)

// Cap app yeu thich 1..3: @{ @"name", @"left", @"right" } (nil neu chua dat)
+ (NSDictionary *)favorite:(NSInteger)index;

// Ti le rieng cho tung cap app
+ (CGFloat)ratioForPairLeft:(NSString *)left right:(NSString *)right;   // 0 neu chua co
+ (void)setRatio:(CGFloat)ratio forPairLeft:(NSString *)left right:(NSString *)right;

// Yeu cau tu app URL scheme (carduo://open?left=..&right=..)
+ (NSDictionary *)takePendingRequest;   // doc va xoa

+ (void)setSplitRatio:(CGFloat)r;
+ (void)setLeftApp:(NSString *)bid;
+ (void)setRightApp:(NSString *)bid;
+ (void)setLastPairLeft:(NSString *)left right:(NSString *)right;
@end
