#import "SCPPrefs.h"
#import "common.h"

@implementation SCPPrefs

// Doi ten package com.anpham.splitcarplay -> com.anlai97.carduo: lan dau chay chep cau hinh cu sang domain moi
static void migrateOldDomain(NSUserDefaults *d)
{
    if ([d objectForKey:@"Migrated"]) return;
    CFArrayRef keys = CFPreferencesCopyKeyList(CFSTR("com.anpham.splitcarplay"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSDictionary *old = keys ? CFBridgingRelease(CFPreferencesCopyMultiple(keys, CFSTR("com.anpham.splitcarplay"),
                                                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) : nil;
    if (keys) CFRelease(keys);
    for (NSString *k in old) if (![d objectForKey:k]) [d setObject:old[k] forKey:k];
    [d setBool:YES forKey:@"Migrated"];
    [d synchronize];
    SCPLog("prefs: chep %lu khoa tu com.anpham.splitcarplay", (unsigned long)old.count);
}

static NSUserDefaults *defaults(void)
{
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:SCP_PREFS_DOMAIN]; migrateOldDomain(d); });
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
+ (NSInteger)splitDirection{ id v = value(@"SplitDirection");   return v ? [v integerValue] : 0; }
+ (BOOL)mirrorRight        { id v = value(@"MirrorRight");      return v ? [v boolValue] : NO; }
+ (BOOL)bootVideo          { id v = value(@"BootVideo");        return v ? [v boolValue] : YES; }
+ (CGFloat)bootDuration    { id v = value(@"BootDuration");     return v ? ([v doubleValue] <= 0 ? 0 : MIN(15, MAX(1, [v doubleValue]))) : 4; }
+ (BOOL)bootSound          { id v = value(@"BootSound");        return v ? [v boolValue] : YES; }
+ (NSString *)customBootVideo { return str(@"BootVideoPath"); }
+ (NSArray<NSString *> *)carPlayApps { id v = value(@"CarPlayApps"); return [v isKindOfClass:[NSArray class]] ? v : nil; }
+ (void)setCarPlayApps:(NSArray<NSString *> *)ids
{
    if ([[self carPlayApps] isEqualToArray:ids]) return;
    [defaults() setObject:ids forKey:@"CarPlayApps"];
    [defaults() synchronize];
}
+ (void)setCarBridgeApps:(NSArray<NSString *> *)ids
{
    id old = value(@"CarBridgeApps");
    if ([old isKindOfClass:[NSArray class]] && [old isEqualToArray:ids]) return;
    [defaults() setObject:ids forKey:@"CarBridgeApps"];
    [defaults() synchronize];
}

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

+ (void)setSplitRatio:(CGFloat)r     { [defaults() setDouble:r forKey:@"SplitRatio"]; [defaults() synchronize]; }
+ (void)setLeftApp:(NSString *)bid   { [defaults() setObject:bid forKey:@"LeftApp"];  [defaults() synchronize]; }
+ (void)setRightApp:(NSString *)bid  { [defaults() setObject:bid forKey:@"RightApp"]; [defaults() synchronize]; }

@end
