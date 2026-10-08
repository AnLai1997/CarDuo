#import "common.h"

// Log: NSLog + luon ghi file /var/mobile/Documents/CarDuo.log (xem bang Filza)
static NSString *const kLogPath = @"/var/mobile/Documents/CarDuo.log";
static NSString *const kOldLogPath = @"/var/mobile/Documents/CarDuo.old.log";

// Goi luc SpringBoard khoi dong: file qua 2MB thi doi thanh CarDuo.old.log, bat dau file moi
void SCPLogTrim(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long size = [[fm attributesOfItemAtPath:kLogPath error:nil] fileSize];
    if (size < 2 * 1024 * 1024) return;
    [fm removeItemAtPath:kOldLogPath error:nil];
    [fm moveItemAtPath:kLogPath toPath:kOldLogPath error:nil];
}

// Ghi 1 dong vao file; tra ve NO neu khong duoc (sandbox)
static BOOL SCPAppendLine(NSString *path, NSString *line)
{
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path] && ![fm createFileAtPath:path contents:nil attributes:nil]) return NO;
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return NO;
        [fh seekToEndOfFile];
        [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
        return YES;
    } @catch (NSException *e) { return NO; }
}

void SCPLogAppendRelayed(NSString *line)
{
    SCPAppendLine(kLogPath, line);
}

void SCPLogWrite(NSString *msg)
{
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSLog(@LOGTAG " %@", msg);

    static NSDateFormatter *df; static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss"; });
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@", [df stringFromDate:[NSDate date]], proc, msg];

    // Ghi file chung. App nguoi dung bi sandbox -> khong ghi duoc: ghi vao Documents cua app do
    // va gui dong log sang SpringBoard de no ghi ho vao file chung (xem SpringBoard.xm).
    BOOL wrote = SCPAppendLine(kLogPath, line);
    if (!wrote) {
        SCPAppendLine([NSHomeDirectory() stringByAppendingPathComponent:@"Documents/CarDuo.log"], line);
        static BOOL isSpringBoard; static dispatch_once_t sbOnce;
        dispatch_once(&sbOnce, ^{ isSpringBoard = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]; });
        if (!isSpringBoard) {
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
                postNotificationName:SCP_NOTIF_LOG object:nil userInfo:@{@"line": line}];
        }
    }
}

void SCPMissingSelector(id obj, NSString *sel)
{
    if (!obj) return;   // goi tren nil la binh thuong (chua co doi tuong), khong can log
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%@ %@", NSStringFromClass([obj class]), sel];
    @synchronized (seen) {
        if ([seen containsObject:key]) return;
        [seen addObject:key];
    }
    SCPLog("THIEU METHOD: %@ khong co %@ -> bo qua", NSStringFromClass([obj class]), sel);
}
