#pragma once
#import <Foundation/Foundation.h>

#define SCP_DOMAIN @"com.anlai97.carduo"

// Chuoi giao dien theo ngon ngu chon o nut qua cau (key "Language": "vi" / "en"),
// doc tu <lang>.lproj/Localizable.strings. Cai dat trong SCPRootListController.m.
FOUNDATION_EXTERN NSString *SCPLanguage(void);
FOUNDATION_EXTERN NSString *L(NSString *key);

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
