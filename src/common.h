// Helper goi runtime dong - phong cach carplay-cast (EthanArbuckle/carplay-cast)
#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define LOGTAG "[CarDuo]"
#define SCPLog(fmt, ...) SCPLogWrite([NSString stringWithFormat:@fmt, ##__VA_ARGS__])

// Process khong ghi duoc file log chung -> SpringBoard ghi ho 1 dong log
#define SCP_NOTIF_LOG           @"com.anlai97.carduo.log"

// Goi method rieng cua Apple qua runtime. Moi macro deu kiem tra object co method do khong: khong co
// (doi iOS, object nil / sai lop) thi ghi log 1 lan va tra nil / 0 thay vi crash vi "unrecognized selector".
//   objcInvoke*  : method TRA VE OBJECT (id).
//   objcCall*    : method KHONG tra ve object (void / BOOL ...) ma bo qua ket qua. Khong duoc dung objcInvoke
//                  cho loai nay: ARC se release "ket qua" rac trong thanh ghi -> crash ngau nhien.
//   objcInvokeT  : method tra ve kieu so / struct (BOOL, CGRect ...), tra 0 neu khong co method.
#define SCPSel(b) NSSelectorFromString(b)
#define objcInvokeT(a, b, t) ({ id _o = (a); SEL _s = SCPSel(b); t _r = (t){0};     if ([_o respondsToSelector:_s]) _r = ((t (*)(id, SEL))objc_msgSend)(_o, _s); else SCPMissingSelector(_o, b); _r; })
#define objcInvoke(a, b) ({ id _o = (a); SEL _s = SCPSel(b); id _r = nil;     if ([_o respondsToSelector:_s]) _r = ((id (*)(id, SEL))objc_msgSend)(_o, _s); else SCPMissingSelector(_o, b); _r; })
#define objcInvoke_1(a, b, c) ({ id _o = (a); SEL _s = SCPSel(b); id _r = nil;     if ([_o respondsToSelector:_s]) _r = ((id (*)(id, SEL, __typeof__(c)))objc_msgSend)(_o, _s, c); else SCPMissingSelector(_o, b); _r; })
#define objcInvoke_2(a, b, c, d) ({ id _o = (a); SEL _s = SCPSel(b); id _r = nil;     if ([_o respondsToSelector:_s]) _r = ((id (*)(id, SEL, __typeof__(c), __typeof__(d)))objc_msgSend)(_o, _s, c, d); else SCPMissingSelector(_o, b); _r; })
#define objcCall(a, b) ({ id _o = (a); SEL _s = SCPSel(b);     if ([_o respondsToSelector:_s]) ((void (*)(id, SEL))objc_msgSend)(_o, _s); else SCPMissingSelector(_o, b); })
#define objcCall_1(a, b, c) ({ id _o = (a); SEL _s = SCPSel(b);     if ([_o respondsToSelector:_s]) ((void (*)(id, SEL, __typeof__(c)))objc_msgSend)(_o, _s, c); else SCPMissingSelector(_o, b); })
#define objcCall_2(a, b, c, d) ({ id _o = (a); SEL _s = SCPSel(b);     if ([_o respondsToSelector:_s]) ((void (*)(id, SEL, __typeof__(c), __typeof__(d)))objc_msgSend)(_o, _s, c, d); else SCPMissingSelector(_o, b); })

#ifdef __cplusplus
extern "C" {
#endif
void SCPLogWrite(NSString *msg);
void SCPMissingSelector(id obj, NSString *sel);   // object (khac nil) thieu method -> log 1 lan moi lop/method
void SCPLogTrim(void);                      // SpringBoard khoi dong: log > 2MB -> CarDuo.old.log
void SCPLogAppendRelayed(NSString *line);   // SpringBoard ghi ho dong log tu app
#ifdef __cplusplus
}
#endif
