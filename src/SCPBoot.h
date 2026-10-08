#pragma once
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif
NSString *SCPBootVideoPath(void);                     // nil neu chua cai video
void SCPBootShowIfNeeded(UIViewController *root);     // DashBoard vua hien -> phat video khoi dong (1 lan / ket noi)
void SCPBootReset(void);                              // ngat xe -> lan ket noi sau phat lai
BOOL SCPBootIsShowing(void);                          // video khoi dong dang hien tren man xe
#ifdef __cplusplus
}
#endif
