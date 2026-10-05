#pragma once
#import <Foundation/Foundation.h>

#define SCP_DOMAIN @"com.anlai97.carduo"

// Ngon ngu cua trang Settings (chon o goc trai): "vi" (mac dinh) / "en"
static inline BOOL SCPLangIsEN(void)
{
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("Language"), (__bridge CFStringRef)SCP_DOMAIN);
    id s = v ? CFBridgingRelease(v) : nil;
    return [s isKindOfClass:[NSString class]] && [s isEqualToString:@"en"];
}

static inline NSString *SCPL(NSString *vi, NSString *en) { return SCPLangIsEN() ? en : vi; }

static inline id SCPPrefValue(NSString *key)
{
    if (![key isKindOfClass:[NSString class]]) return nil;
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)SCP_DOMAIN);
    return v ? CFBridgingRelease(v) : nil;
}

static inline void SCPSetPrefValue(NSString *key, id value)
{
    if (![key isKindOfClass:[NSString class]]) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)SCP_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)SCP_DOMAIN);
}
