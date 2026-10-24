# probe app —— 只用来验证注入链路，不参与任何作弊逻辑
#
# 产出：ARProbe.ipa（TrollStore 装），里面就是一个 MTKView 在跑 Metal。
# 用途：先证明 TrollFools 注入 + dylib 加载 + Metal 挂点 + ImGui 叠加这条链能通，
# 再拿游戏去试。游戏那份包现在偏移全是占位符，装上去也什么都看不到，
# 拿它当第一验证目标是浪费时间。

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ARProbe

ARProbe_FILES = main.mm
ARProbe_CFLAGS = -fobjc-arc -std=c++17
ARProbe_FRAMEWORKS = UIKit Foundation Metal MetalKit QuartzCore
ARProbe_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
