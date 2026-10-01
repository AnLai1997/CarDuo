#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#define SCP_PREFS_DOMAIN @"com.anpham.splitcarplay"

// Doc cau hinh tu domain com.anpham.splitcarplay (Settings ghi qua cfprefsd).
// Doc moi lan can nen thay doi trong Settings co hieu luc ngay, khong can respring.
@interface SCPPrefs : NSObject
+ (BOOL)enabled;
+ (NSString *)leftApp;
+ (NSString *)rightApp;
+ (BOOL)autoLaunch;
+ (NSInteger)dockSide;          // 0 = trai, 1 = phai
+ (NSInteger)paneOrientation;   // 1 = portrait, 3 = landscape
+ (CGFloat)splitRatio;          // ti le be rong ngan trai (0.2 - 0.8)
+ (BOOL)testOnMainScreen;
+ (BOOL)showDebug;             // hien log tren cua so split
+ (NSInteger)scaleMode;        // 0 keo gian, 1 giu ti le (vien den), 2 resize scene (thu nghiem)
+ (NSInteger)splitDirection;   // 0 trai/phai, 1 tren/duoi
+ (BOOL)widgetPane;            // ngan phai = widget Now Playing
+ (BOOL)mirrorRight;           // hien ngan phai tren iPhone (thu nghiem)
+ (BOOL)autoSplitOnIcon;       // bam icon tren dashboard CarPlay -> mo vao ngan phai, giu ngan trai

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
