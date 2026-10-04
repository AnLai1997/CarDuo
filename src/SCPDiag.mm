#import "common.h"
#import <mach-o/dyld.h>
#import <dlfcn.h>

// =====================================================================
//  Chan doan tweak khac (CarBridge): tweak do hook ham nao cua he thong, va chi tiet cac lop cua no
//  (phuong thuc lop / doi tuong + kieu, bien). Chi ghi log, khong thay doi gi.
// =====================================================================

// Anh (image) cua he thong can quet de tim ham bi hook
static BOOL SCPDiagIsTargetImage(NSString *path)
{
    for (NSString *s in @[@"DashBoard", @"SpringBoard", @"FrontBoard", @"CarPlay", @"CarKit", @"UIKitCore"]) {
        if ([path rangeOfString:s options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static void SCPDiagScanMethods(Class cls, BOOL meta, NSString *hooker, NSMutableArray<NSString *> *out)
{
    unsigned int mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    for (unsigned int m = 0; m < mc; m++) {
        IMP imp = method_getImplementation(ms[m]);
        Dl_info info;
        if (!dladdr((const void *)imp, &info) || !info.dli_fname) continue;
        if ([@(info.dli_fname) rangeOfString:hooker options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [out addObject:[NSString stringWithFormat:@"%c[%s %@] %s <- %@", meta ? '+' : '-', class_getName(cls),
                        NSStringFromSelector(method_getName(ms[m])), method_getTypeEncoding(ms[m]) ?: "",
                        @(info.dli_fname).lastPathComponent]];
    }
    if (ms) free(ms);
}

// Ham he thong (DashBoard / SpringBoard / FrontBoard / CarPlay / UIKit) ma IMP nam trong dylib `hooker`
void SCPDiagHooks(NSString *hooker)
{
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path || !SCPDiagIsTargetImage(@(path))) continue;
        unsigned int count = 0;
        const char **names = objc_copyClassNamesForImage(path, &count);
        for (unsigned int k = 0; k < count; k++) {
            Class cls = objc_getClass(names[k]);
            if (!cls) continue;
            SCPDiagScanMethods(cls, NO, hooker, out);
            SCPDiagScanMethods(object_getClass(cls), YES, hooker, out);
        }
        if (names) free(names);
    }
    SCPLog("DIAG ham bi %@ hook (%lu, %.0fms):\n%@", hooker, (unsigned long)out.count,
           (CFAbsoluteTimeGetCurrent() - t0) * 1000, [out componentsJoinedByString:@"\n"]);
}

// Chi tiet lop: phuong thuc lop (+) va doi tuong (-) kem kieu, bien (ivar) kem kieu, lop cha
void SCPDiagClasses(NSArray<NSString *> *names)
{
    for (NSString *name in names) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) { SCPLog("DIAG lop %@: khong co trong tien trinh nay", name); continue; }
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        [lines addObject:[NSString stringWithFormat:@"cha: %s", class_getName(class_getSuperclass(cls))]];
        for (int meta = 1; meta >= 0; meta--) {
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(meta ? object_getClass(cls) : cls, &mc);
            for (unsigned int m = 0; m < mc; m++) {
                [lines addObject:[NSString stringWithFormat:@"%c%@ %s", meta ? '+' : '-',
                                  NSStringFromSelector(method_getName(ms[m])), method_getTypeEncoding(ms[m]) ?: ""]];
            }
            if (ms) free(ms);
        }
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList(cls, &ic);
        for (unsigned int v = 0; v < ic; v++) {
            [lines addObject:[NSString stringWithFormat:@"ivar %s %s", ivar_getName(ivs[v]), ivar_getTypeEncoding(ivs[v]) ?: ""]];
        }
        if (ivs) free(ivs);
        unsigned int pc = 0;
        objc_property_t *props = class_copyPropertyList(cls, &pc);
        for (unsigned int p = 0; p < pc; p++) {
            [lines addObject:[NSString stringWithFormat:@"prop %s %s", property_getName(props[p]), property_getAttributes(props[p]) ?: ""]];
        }
        if (props) free(props);
        SCPLog("DIAG lop %@:\n%@", name, [lines componentsJoinedByString:@"\n"]);
    }
}
