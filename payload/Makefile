# payload：注入 SpringBoard 的 dylib
#
# 产出：.theos/obj/arm64/ARPayload.dylib
# 内容：只做"选 scene + 建高层级 UIWindow + 画"这一件事。
#
# ★ 必须只编 arm64，不要 arm64e：
#   arm64e 的 chained fixups 绑定需要 ptrauth 签名，手动/远程加载会多一堆坑。
#   arm64e 硬件跑 arm64 代码完全没问题。
# ★ payload 里不要定义需要 ObjC runtime 自注册的类以外的东西 —— 这里不是 manual map，
#   是 dlopen，所以类能正常注册；但如果将来换成 manual map，就要把类去掉。

ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = ARPayload

ARPayload_FILES = SBWindow.mm
ARPayload_CFLAGS = -fobjc-arc -I../src -I../src/Inject -I../src/Core -I../src/Game
ARPayload_FRAMEWORKS = UIKit Foundation QuartzCore
ARPayload_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
