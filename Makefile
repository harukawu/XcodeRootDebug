THEOS_DEVICE_IP = localhost -o StrictHostKeyChecking=no
THEOS_DEVICE_PORT = 2222

ARCHS = arm64 arm64e

ifeq ($(THEOS_PACKAGE_SCHEME), rootless)
TARGET = iphone:clang:14.5:18.7.2 # theos includes the iOS 14.5 SDK by default, it's ok
else
TARGET = iphone:clang:14.5:9.0
endif

INSTALL_TARGET_PROCESSES = lockdownd remoted dtdebugproxyd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XcodeRootDebug

XcodeRootDebug_FILES = Tweak.x
XcodeRootDebug_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = XcodeRootDebugPrefs

XcodeRootDebugPrefs_FILES = XRDRootListController.m
XcodeRootDebugPrefs_FRAMEWORKS = UIKit
XcodeRootDebugPrefs_PRIVATE_FRAMEWORKS = Preferences
XcodeRootDebugPrefs_INSTALL_PATH = /Library/PreferenceBundles
XcodeRootDebugPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk