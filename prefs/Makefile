TARGET := iphone:clang:latest:14.0
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	TARGET := iphone:clang:latest:15.0
endif

ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = FakePassPrefs

FakePassPrefs_FILES = FPARootListController.m
FakePassPrefs_FRAMEWORKS = UIKit
FakePassPrefs_PRIVATE_FRAMEWORKS = FrontBoardServices Preferences SpringBoardServices
FakePassPrefs_INSTALL_PATH = /Library/PreferenceBundles
FakePassPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
