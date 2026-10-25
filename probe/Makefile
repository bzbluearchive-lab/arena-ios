# probe app —— 跨进程偏移探针
#
# 产出：ARProbe.ipa（TrollStore 装），带 task_for_pid 所需 entitlement。
# 作用：在设备上直接读游戏进程内存，用 FName 类名校验候选偏移。
#
# 只编 arm64：arm64e 切片用 ldid fakesign 时容易在启动阶段被拒（表现为点开就闪退），
# arm64 切片在 arm64e 硬件上照常运行，没有 PAC 相关风险。

ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ARProbe

ARProbe_FILES = main.mm
ARProbe_CFLAGS = -fobjc-arc -std=c++17
ARProbe_FRAMEWORKS = UIKit Foundation
ARProbe_INSTALL_PATH = /Applications
ARProbe_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
