TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# App nho nhan URL splitcarplay://open?left=..&right=.. (dung cho Shortcuts / Siri)
APPLICATION_NAME = SplitCarPlay
SplitCarPlay_FILES = main.m
SplitCarPlay_FRAMEWORKS = UIKit CoreFoundation
SplitCarPlay_CFLAGS = -fobjc-arc
SplitCarPlay_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
