# Dopamine (rootless) - iOS 15.0 -> 16.6.1, SDK 16.5
TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

# "CarPlay" la ten process cua com.apple.CarPlayApp (SpringBoard tu khoi dong lai no khi xe dang ket noi)
INSTALL_TARGET_PROCESSES = CarPlay SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SplitCarPlay
SplitCarPlay_FILES = Tweak.x
SplitCarPlay_CFLAGS = -fobjc-arc
SplitCarPlay_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
