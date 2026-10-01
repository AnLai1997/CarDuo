#import "SCPPrefs.h"

@implementation SCPPrefs

static NSUserDefaults *defaults(void)
{
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:SCP_PREFS_DOMAIN]; });
    return d;
}

static id value(NSString *key)
{
    // synchronize de lay gia tri moi nhat tu cfprefsd
    [defaults() synchronize];
    return [defaults() objectForKey:key];
}

+ (BOOL)enabled            { id v = value(@"Enabled");          return v ? [v boolValue] : YES; }
+ (NSString *)leftApp      { id v = value(@"LeftApp");          return [v isKindOfClass:[NSString class]] && [v length] ? v : nil; }
+ (NSString *)rightApp     { id v = value(@"RightApp");         return [v isKindOfClass:[NSString class]] && [v length] ? v : nil; }
+ (BOOL)autoLaunch         { id v = value(@"AutoLaunch");       return v ? [v boolValue] : NO; }
+ (NSInteger)dockSide      { id v = value(@"DockSide");         return v ? [v integerValue] : 0; }
+ (NSInteger)paneOrientation {
    id v = value(@"PaneOrientation");
    NSInteger o = v ? [v integerValue] : 1;
    return (o == 3 || o == 4) ? 3 : 1;
}
+ (CGFloat)splitRatio {
    id v = value(@"SplitRatio");
    CGFloat r = v ? [v doubleValue] : 0.5;
    return MIN(0.7, MAX(0.3, r));
}
+ (BOOL)testOnMainScreen   { id v = value(@"TestOnMainScreen"); return v ? [v boolValue] : NO; }
+ (BOOL)showDebug          { id v = value(@"ShowDebug");        return v ? [v boolValue] : YES; }
+ (void)setTestOnMainScreen:(BOOL)v { [defaults() setBool:v forKey:@"TestOnMainScreen"]; [defaults() synchronize]; }
+ (void)setSplitRatio:(CGFloat)r     { [defaults() setDouble:r forKey:@"SplitRatio"]; [defaults() synchronize]; }
+ (void)setLeftApp:(NSString *)bid   { [defaults() setObject:bid forKey:@"LeftApp"];  [defaults() synchronize]; }
+ (void)setRightApp:(NSString *)bid  { [defaults() setObject:bid forKey:@"RightApp"]; [defaults() synchronize]; }

@end
