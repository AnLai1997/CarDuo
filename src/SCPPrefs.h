#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#define SCP_PREFS_DOMAIN @"com.anlai97.carduo"

// Doc cau hinh tu domain com.anlai97.carduo (Settings ghi qua cfprefsd).
// Doc moi lan can nen thay doi trong Settings co hieu luc ngay, khong can respring.
@interface SCPPrefs : NSObject
+ (BOOL)enabled;
+ (NSString *)leftApp;
+ (NSString *)rightApp;
+ (BOOL)autoLaunch;
+ (NSInteger)paneOrientation;   // 1 = portrait, 3 = landscape
+ (CGFloat)splitRatio;          // ti le be rong ngan trai (0.2 - 0.8)
+ (BOOL)testOnMainScreen;
+ (NSInteger)splitDirection;   // 0 trai/phai, 1 tren/duoi
+ (BOOL)mirrorRight;           // hien ngan phai tren iPhone (thu nghiem)
+ (NSInteger)speedBubbleStyle;  // 0 Vietmap, 1 Toi gian, 2 Bien bao, 3 Dong ho, 4 HUD, 5 Mau toc do
+ (BOOL)speedBubble;           // bong bong toc do tu Vietmap Live khi app khong hien
+ (BOOL)allowPhoneApps;        // app khong co CarPlay: cho chieu giao dien iPhone (mac dinh tat)

// Cap app yeu thich 1..3: @{ @"name", @"left", @"right" } (nil neu chua dat)
+ (NSDictionary *)favorite:(NSInteger)index;

// Ti le rieng cho tung cap app
+ (CGFloat)ratioForPairLeft:(NSString *)left right:(NSString *)right;   // 0 neu chua co
+ (void)setRatio:(CGFloat)ratio forPairLeft:(NSString *)left right:(NSString *)right;

// Yeu cau tu app URL scheme (splitcarplay://open?left=..&right=..)
+ (NSDictionary *)takePendingRequest;   // doc va xoa

+ (void)setTestOnMainScreen:(BOOL)v;
+ (void)setSplitRatio:(CGFloat)r;
+ (void)setLeftApp:(NSString *)bid;
+ (void)setRightApp:(NSString *)bid;
@end
