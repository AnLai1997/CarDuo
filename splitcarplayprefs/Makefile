TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SplitCarPlayPrefs
SplitCarPlayPrefs_FILES = SCPRootListController.m
SplitCarPlayPrefs_INSTALL_PATH = /Library/PreferenceBundles
SplitCarPlayPrefs_FRAMEWORKS = UIKit
SplitCarPlayPrefs_PRIVATE_FRAMEWORKS = Preferences
SplitCarPlayPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

# entry.plist cho PreferenceLoader (rootless: duoi /var/jb)
internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceLoader/Preferences/SplitCarPlayPrefs.plist$(ECHO_END)
