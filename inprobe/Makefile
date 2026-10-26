# inprobe - in-game offset probe as a dylib
#
# Injected into the game via TrollFools. Reads only, no hooks, no writes.
# Output goes to UDP 127.0.0.1:45999 (received by ARProbe app) and to
# <game container>/Documents/inprobe.log

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = ARInProbe

ARInProbe_FILES = main.mm rebind.c
ARInProbe_CFLAGS = -fobjc-arc -std=c++17
ARInProbe_FRAMEWORKS = Foundation
ARInProbe_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/library.mk
