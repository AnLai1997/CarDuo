// Helper goi runtime dong - phong cach carplay-cast (EthanArbuckle/carplay-cast)
#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define LOGTAG "[SplitCP]"
#define SCPLog(fmt, ...) SCPLogWrite([NSString stringWithFormat:@fmt, ##__VA_ARGS__])

// Notification CarPlay process -> SpringBoard: yeu cau mo app vao mot ngan
#define SCP_NOTIF_LAUNCH        @"com.anpham.splitcarplay.launch"
// SpringBoard -> app process: ep huong xoay
#define SCP_NOTIF_ORIENTATION   @"com.anpham.splitcarplay.orientation"
// SpringBoard -> CarPlay process: dong/mo split (de CarPlay dong app native dang chay)
#define SCP_NOTIF_SPLIT_CLOSED  @"com.anpham.splitcarplay.closed"

// Moi ngan co tab "..." o giua mep tren; cham hoac keo xuong de hien thanh nut rieng cua ngan do.
// Kich thuoc to cho man xe: nut 64x60 co nhan chu, tab 96x22.
#define SCP_PANE_BAR_HEIGHT    76.0
#define SCP_PANE_HANDLE_WIDTH  96.0
#define SCP_PANE_HANDLE_HEIGHT 22.0
#define SCP_PANE_BORDER        2.0

#define getIvar(object, ivar)        [object valueForKey:ivar]
#define setIvar(object, ivar, value) [object setValue:value forKey:ivar]

#define objcInvokeT(a, b, t)            ((t (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvoke(a, b)                objcInvokeT(a, b, id)
#define objcInvoke_1(a, b, c)           ((id (*)(id, SEL, __typeof__(c)))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_2(a, b, c, d)        ((id (*)(id, SEL, __typeof__(c), __typeof__(d)))objc_msgSend)(a, NSSelectorFromString(b), c, d)
#define objcInvoke_3(a, b, c, d, e)     ((id (*)(id, SEL, __typeof__(c), __typeof__(d), __typeof__(e)))objc_msgSend)(a, NSSelectorFromString(b), c, d, e)

// Kiem tra object tra ve dung class mong doi, log ro rang neu sai (thay cho assert crash)
#define expectClass(obj, clsName) \
    ({ id _o = (obj); \
       if (!_o || ![_o isKindOfClass:objc_getClass(clsName)]) { \
           SCPLog("UNEXPECTED %s: got %@ (%s:%d)", clsName, _o, __FILE__, __LINE__); \
           [NSException raise:@"SplitCarPlay" format:@"expected %s got %@", clsName, _o]; \
       } _o; })


#ifdef __cplusplus
extern "C" {
#endif
extern int (*orig_BKSDisplayServicesSetScreenBlanked)(int);
void SCPLogWrite(NSString *msg);
void SCPLogClear(void);
NSArray<NSString *> *SCPRecentLogLines(void);
extern NSString *const SCPLogLineNotification;
extern const void *kSCPKey_splitWindow;
extern const void *kSCPKey_lockAssertions;
id SCPGetCarPlayCADisplay(void);
#ifdef __cplusplus
}
#endif
