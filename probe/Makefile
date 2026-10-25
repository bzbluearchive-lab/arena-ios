# probe app —— 跨进程偏移探针
#
# 产出：ARProbe.ipa（TrollStore 装），带 task_for_pid 所需 entitlement。
# 作用：在设备上直接读游戏进程内存，用 FName 类名校验候选偏移。
#      不需要游戏 IPA、不需要注入游戏、不需要每次改包重装。

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ARProbe

ARProbe_FILES = main.mm
ARProbe_CFLAGS = -fobjc-arc -std=c++17
ARProbe_FRAMEWORKS = UIKit Foundation
ARProbe_INSTALL_PATH = /Applications
ARProbe_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
