#import "common.h"

// Bong bong toc do: hien toc do hien tai + gioi han toc do lay tu Vietmap Live khi app do dang chay
// nhung KHONG hien trong ngan nao (bi che boi fullscreen ngan khac, hoac da dong ngan nhung app van chay ngam).
// Du lieu do hook trong tien trinh Vietmap quet nhan so tren man hinh roi gui qua Darwin notify (SCP_DARWIN_SPEED).
@interface SCPSpeedBubble : NSObject
+ (instancetype)shared;
- (void)updateSpeed:(int)speed limit:(int)limit;   // speed/limit < 0 = khong co
- (void)refresh;                                    // tinh lai hien/an (goi khi bo cuc split doi)
- (void)hide;
- (void)runDemo;                                    // Cai dat > Xem thu: toc do gia 10 giay
- (void)setNativeVisibleBundles:(NSArray<NSString *> *)bundles;   // app dang hien trong ngan split CarPlay (process CarPlay bao)
@end
