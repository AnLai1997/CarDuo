TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# App nho nhan URL carduo://open?left=..&right=.. (dung cho Shortcuts / Siri)
APPLICATION_NAME = CarDuo
CarDuo_FILES = main.m
CarDuo_FRAMEWORKS = UIKit CoreFoundation
CarDuo_CFLAGS = -fobjc-arc
CarDuo_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
