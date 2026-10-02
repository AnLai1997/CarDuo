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
// App process -> SpringBoard (Darwin notify, qua duoc sandbox cua app): app vua doi yeu cau xoay (YouTube fullscreen).
// Payload trong notify state: (hash bundle id << 24) | (mask huong app dang cho phep << 8) | ma
// (ma: huong app xin, 0 = ve huong ngan, 0xFF = app vua doi mask -> SpringBoard tu suy ra huong tu mask).
#define SCP_DARWIN_APP_ORIENT "com.anpham.splitcarplay.apporient"
static inline uint64_t SCPBundleHash(NSString *bid)
{
    uint32_t h = 2166136261u;
    for (const char *c = bid.UTF8String; c && *c; c++) { h ^= (uint8_t)*c; h *= 16777619u; }
    return h;
}
// App process -> SpringBoard: chuyen tiep 1 dong log (app bi sandbox, khong ghi duoc file log chung)
#define SCP_NOTIF_LOG           @"com.anpham.splitcarplay.log"
// Vietmap Live -> SpringBoard: toc do hien tai + gioi han (Darwin notify; state = flags<<16 | speed<<8 | limit)
#define SCP_DARWIN_SPEED        "com.anpham.splitcarplay.speed"
#define SCP_SPEED_APP           @"vn.vietmap.live"
// SpringBoard -> CarPlay process: dong/mo split (de CarPlay dong app native dang chay)
#define SCP_NOTIF_SPLIT_CLOSED  @"com.anpham.splitcarplay.closed"

// Moi ngan co the (grabber) trang tron 44x6 o giua mep tren (vung cham no rong 18pt moi phia); cham hoac keo xuong
// de hien hang nut tron trang (kieu HyperOS) bat ra lan luot ngay duoi. Nut tron 52pt, icon den don sac.
#define SCP_PANE_BAR_HEIGHT    64.0
#define SCP_PANE_HANDLE_WIDTH  44.0
#define SCP_PANE_HANDLE_HEIGHT 6.0
#define SCP_PANE_BORDER        2.5
#define SCP_PANE_INSET         3.0    // ngan lui vao so voi mep man -> thay ro bo goc tren nen toi

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
void SCPLogAppendRelayed(NSString *line);   // SpringBoard ghi ho dong log tu app
NSArray<NSString *> *SCPRecentLogLines(void);
extern NSString *const SCPLogLineNotification;
extern const void *kSCPKey_splitWindow;
extern const void *kSCPKey_lockAssertions;
id SCPGetCarPlayCADisplay(void);
#ifdef __cplusplus
}
#endif
