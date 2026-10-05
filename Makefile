# Dopamine (rootless) - iOS 15.0 -> 16.6.1, SDK 16.5
TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

# "CarPlay" la ten process cua com.apple.CarPlayApp (SpringBoard tu khoi dong lai no khi xe dang ket noi)
INSTALL_TARGET_PROCESSES = CarPlay SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SplitCarPlay
SplitCarPlay_FILES = $(wildcard src/hooks/*.xm) $(wildcard src/*.mm)
SplitCarPlay_CFLAGS = -fobjc-arc -Isrc
SplitCarPlay_FRAMEWORKS = UIKit QuartzCore AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += splitcarplayprefs splitcarplayapp
include $(THEOS_MAKE_PATH)/aggregate.mk

# entry.plist cho PreferenceLoader -> /var/jb/Library/PreferenceLoader/Preferences/
after-stage::
	mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	cp splitcarplayprefs/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/SplitCarPlayPrefs.plist"
	find "$(THEOS_STAGING_DIR)" -type f | sort
