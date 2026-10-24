# 顶层：一键构建 + 打包
#
# 环境二选一：
#   macOS ：Xcode + Theos（export THEOS=~/theos）
#   Windows：WSL2 + Theos + iPhoneOS SDK（见 README-BUILD.md）
#
# 用法：
#   make            三件一起编（host app / daemon / payload dylib）
#   make package    编完组装成可分发的 ARHost.app，签名并打 zip
#   make clean
#
# 旧方案（整包注入游戏的 tweak）保留在 Makefile.legacy-tweak，用
#   make -f Makefile.legacy-tweak
# 触发，只是用来验证 src/Game 里的偏移解析与 W2S。

THEOS ?= $(HOME)/theos
export THEOS

.PHONY: all host daemon payload package clean

all: host daemon payload

host:
	@$(MAKE) -C host

daemon:
	@$(MAKE) -C daemon

payload:
	@$(MAKE) -C payload

package: all
	@bash tools/package.sh

clean:
	@$(MAKE) -C host clean    || true
	@$(MAKE) -C daemon clean  || true
	@$(MAKE) -C payload clean || true
	@rm -rf build
