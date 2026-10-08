#import "common.h"

// Log: NSLog + ghi file (xem bang Filza) + notification de cua so split hien overlay
NSString *const SCPLogLineNotification = @"SCPLogLineNotification";
static NSString *const kLogPath = @"/var/mobile/Documents/CarDuo.log";

static NSMutableArray<NSString *> *ringBuffer(void)
{
    static NSMutableArray *a; static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [NSMutableArray array]; });
    return a;
}

NSArray<NSString *> *SCPRecentLogLines(void)
{
    @synchronized (ringBuffer()) { return [ringBuffer() copy]; }
}

void SCPLogClear(void)
{
    @synchronized (ringBuffer()) { [ringBuffer() removeAllObjects]; }
    [[NSFileManager defaultManager] removeItemAtPath:kLogPath error:nil];
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

    @synchronized (ringBuffer()) {
        [ringBuffer() addObject:line];
        while (ringBuffer().count > 40) [ringBuffer() removeObjectAtIndex:0];
    }

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

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SCPLogLineNotification object:nil userInfo:@{@"line": line}];
    });
}
