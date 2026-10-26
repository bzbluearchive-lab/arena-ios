# inprobe - in-game offset probe as a dylib (read-only)
#
# Injected into the game via TrollFools. Output: UDP 127.0.0.1:45999 +
# <container>/Documents/inprobe.log.
#
# Theos forwards _CFLAGS to every source file, so C++ flags must go into
# _OBJCCFLAGS (applies to .mm only) - otherwise rebind.c fails to compile.

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = ARInProbe

ARInProbe_FILES = main.mm rebind.c
ARInProbe_OBJCCFLAGS = -fobjc-arc -std=c++17
ARInProbe_FRAMEWORKS = Foundation
ARInProbe_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/library.mk