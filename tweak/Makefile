TARGET := iphone:clang:latest:15.0

INSTALL_TARGET_PROCESSES = Minecraft

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LuminaProxyTweak
LuminaProxyTweak_FILES = Tweak.xm
LuminaProxyTweak_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

