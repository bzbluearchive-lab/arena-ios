# daemon：常驻助手进程
#
# 职责：注入 SpringBoard（后续再加读内存）。它是"活过 app 退出"的那个进程。
# 产出：.theos/obj/arm64/ARDaemon

ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = ARDaemon

ARDaemon_FILES = main.mm
ARDaemon_CFLAGS = -fobjc-arc -I../src -I../src/Inject -I../src/Core -I../src/Game
ARDaemon_FRAMEWORKS = Foundation
ARDaemon_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
