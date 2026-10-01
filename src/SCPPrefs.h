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
+ (CGFloat)splitRatio;          // ti le be rong ngan trai (0.3 - 0.7)
+ (BOOL)testOnMainScreen;
@end
