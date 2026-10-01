TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SplitCarPlayPrefs
SplitCarPlayPrefs_FILES = SCPRootListController.m SCPPreviewCell.m
SplitCarPlayPrefs_INSTALL_PATH = /Library/PreferenceBundles
SplitCarPlayPrefs_FRAMEWORKS = UIKit CoreFoundation QuartzCore
SplitCarPlayPrefs_PRIVATE_FRAMEWORKS = Preferences
SplitCarPlayPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
