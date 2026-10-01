#import "common.h"

// Log: NSLog + ghi file (xem bang Filza) + notification de cua so split hien overlay
NSString *const SCPLogLineNotification = @"SCPLogLineNotification";
static NSString *const kLogPath = @"/var/mobile/Documents/SplitCarPlay.log";

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

    // Ghi file (CarPlay process co the bi sandbox -> bo qua loi)
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:kLogPath]) [fm createFileAtPath:kLogPath contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SCPLogLineNotification object:nil userInfo:@{@"line": line}];
    });
}
