// Stealth.hpp —— 隐藏面。
//
// 依据 ACE(anogs) 的实际结构，这里的设计和"常见的粗暴隐藏"是反的：
//   anogs 会交叉比对 _dyld_get_image_name / task_info(TASK_DYLD_INFO) /
//   proc_regionfilename 三份结果，任何"自相矛盾"比"存在一个陌生 dylib"更像攻击。
//   所以默认策略不是"抹掉自己"，而是"让三份视图彼此一致，且不产生新异常面"：
//
//   ✔ 不新建线程（逻辑全挂在游戏自己的主线程 / Metal 呈现回调里）
//   ✔ 不新建匿名 RX region（hook 只 patch 到既有代码页，trampoline 单个小页且挂在
//     自己 dylib 的映射里）
//   ✔ dylib 命名伪装成系统框架风格，放 app 包内 PlugIns
//   ✔ 不 hook anogs 的任何符号，不碰它的 __text（它自校验 __text，改一个字节
//     就等于自己给自己发一张"被篡改"报告）
//
//   ⚠ dyld 视图过滤是可选项，默认关闭。开启必须四件套同时改（count/name/header/
//     slide 保持索引一致），并且要同步 TASK_DYLD_INFO 的回读结果，否则是负收益。

#pragma once
#include <stdint.h>

namespace stealth {

struct Options {
    bool filter_dyld_view = false;  // 默认关。开之前先读完上面的说明。
    bool deny_ptrace      = true;   // PT_DENY_ATTACH
    bool clear_p_traced   = true;   // sysctl 回读清 P_TRACED 位
    bool scrub_env        = true;   // 清 DYLD_INSERT_LIBRARIES 等环境变量
    bool hide_trollstore  = true;   // stat/fopen 对 TrollStore 路径返回不存在
};

// 在 constructor 里尽早调用（越早拦截窗口越小）
void install(const Options& opt);

// 诊断用：打印当前 dyld 视图与我们自身在表中的索引（仅在开启日志时输出到
// /var/mobile/Containers/Data/Application/<uuid>/tmp/archeat.log）
void dump_self_info();

} // namespace stealth
