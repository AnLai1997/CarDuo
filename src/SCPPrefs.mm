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
    [defaults() synchronize];
    return [defaults() objectForKey:key];
}

static NSString *str(NSString *key)
{
    id v = value(key);
    return ([v isKindOfClass:[NSString class]] && [v length]) ? v : nil;
}

+ (BOOL)enabled            { id v = value(@"Enabled");          return v ? [v boolValue] : YES; }
+ (NSString *)leftApp      { return str(@"LeftApp"); }
+ (NSString *)rightApp     { return str(@"RightApp"); }
+ (BOOL)autoLaunch         { id v = value(@"AutoLaunch");       return v ? [v boolValue] : NO; }
+ (NSInteger)paneOrientation {
    id v = value(@"PaneOrientation");
    NSInteger o = v ? [v integerValue] : 1;
    return (o == 3 || o == 4) ? 3 : 1;
}
+ (CGFloat)splitRatio {
    id v = value(@"SplitRatio");
    CGFloat r = v ? [v doubleValue] : 0.5;
    return MIN(0.8, MAX(0.2, r));
}
+ (BOOL)testOnMainScreen   { id v = value(@"TestOnMainScreen"); return v ? [v boolValue] : NO; }
+ (NSInteger)splitDirection{ id v = value(@"SplitDirection");   return v ? [v integerValue] : 0; }
+ (BOOL)mirrorRight        { id v = value(@"MirrorRight");      return v ? [v boolValue] : NO; }
+ (NSInteger)speedBubbleStyle { id v = value(@"SpeedBubbleStyle"); NSInteger i = v ? [v integerValue] : 0; return (i >= 0 && i <= 5) ? i : 0; }
+ (BOOL)speedBubble        { id v = value(@"SpeedBubble");      return v ? [v boolValue] : YES; }
+ (BOOL)allowPhoneApps     { id v = value(@"AllowPhoneApps");   return v ? [v boolValue] : NO; }

+ (NSDictionary *)favorite:(NSInteger)index
{
    NSString *left = str([NSString stringWithFormat:@"Fav%ldLeft", (long)index]);
    NSString *right = str([NSString stringWithFormat:@"Fav%ldRight", (long)index]);
    if (!left && !right) return nil;
    NSString *name = str([NSString stringWithFormat:@"Fav%ldName", (long)index]) ?: [NSString stringWithFormat:@"Cặp %ld", (long)index];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:name forKey:@"name"];
    if (left) d[@"left"] = left;
    if (right) d[@"right"] = right;
    return d;
}

static NSString *pairKey(NSString *left, NSString *right)
{
    return [NSString stringWithFormat:@"%@|%@", left ?: @"-", right ?: @"-"];
}

+ (CGFloat)ratioForPairLeft:(NSString *)left right:(NSString *)right
{
    NSDictionary *d = value(@"PairRatios");
    if (![d isKindOfClass:[NSDictionary class]]) return 0;
    id v = d[pairKey(left, right)];
    return v ? [v doubleValue] : 0;
}

+ (void)setRatio:(CGFloat)ratio forPairLeft:(NSString *)left right:(NSString *)right
{
    NSDictionary *old = value(@"PairRatios");
    NSMutableDictionary *d = [old isKindOfClass:[NSDictionary class]] ? [old mutableCopy] : [NSMutableDictionary dictionary];
    d[pairKey(left, right)] = @(ratio);
    [defaults() setObject:d forKey:@"PairRatios"];
    [defaults() synchronize];
}

+ (NSDictionary *)takePendingRequest
{
    NSString *action = str(@"PendingAction");
    if (!action) return nil;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:action forKey:@"action"];
    NSString *l = str(@"PendingLeft"), *r = str(@"PendingRight");
    if (l) d[@"left"] = l;
    if (r) d[@"right"] = r;
    [defaults() removeObjectForKey:@"PendingAction"];
    [defaults() removeObjectForKey:@"PendingLeft"];
    [defaults() removeObjectForKey:@"PendingRight"];
    [defaults() synchronize];
    return d;
}

+ (void)setTestOnMainScreen:(BOOL)v { [defaults() setBool:v forKey:@"TestOnMainScreen"]; [defaults() synchronize]; }
+ (void)setSplitRatio:(CGFloat)r     { [defaults() setDouble:r forKey:@"SplitRatio"]; [defaults() synchronize]; }
+ (void)setLeftApp:(NSString *)bid   { [defaults() setObject:bid forKey:@"LeftApp"];  [defaults() synchronize]; }
+ (void)setRightApp:(NSString *)bid  { [defaults() setObject:bid forKey:@"RightApp"]; [defaults() synchronize]; }

@end
