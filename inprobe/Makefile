# inprobe - in-game offset probe as a dylib (read-only)
#
# Injected into the game via TrollFools. Output goes to UDP 127.0.0.1:45999
# and to <container>/Documents/inprobe.log.
#
# NOTE: main.mm is ObjC++ (-std=c++17); rebind.c is plain C and needs its own
# flags, otherwise theos forwards -std=c++17 to the C compiler and it fails.

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = ARInProbe

ARInProbe_FILES = main.mm rebind.c
ARInProbe_CFLAGS = -fobjc-arc -std=c++17
ARInProbe_CCFLAGS = -std=gnu11
ARInProbe_FRAMEWORKS = Foundation
ARInProbe_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/library.mk