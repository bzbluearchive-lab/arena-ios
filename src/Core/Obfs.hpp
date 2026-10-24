// Obfs.hpp —— 编译期字符串加密
//
// 为什么必须做：anogs 会对进程内区域做 walk + macho 扫描，明文串是最好用的指纹。
// 我们的 dylib 里现在有这些明文，任何一个都够它写一条可上报事件：
//     "ARCheat"            dylib 名 + ImGui 窗口标题
//     "ESP" "Aim" "Smooth"  菜单控件标签
//     "archeat.off"        kill switch 路径
//     "[ARCheat]"          NSLog 标签（会进系统日志）
//
// 用 XStr{"..."} 之后这些字节在 __cstring 里以 XOR 形式存在，静态提取（strings/
// IDA 字符串窗口/正则扫包）拿不到，运行时才解码到栈/静态缓冲区。
//
// 注意：这不是加密强度问题，是"降低静态可判定性"。别指望它能挡住动态内存扫描
// 命中解码后的缓冲；解码后的缓冲用完就 memset 掉。

#pragma once
#include <stddef.h>

#ifndef AR_XKEY
#define AR_XKEY 0x5B
#endif

template <size_t N>
struct XStr {
    char e[N];

    constexpr XStr(const char (&s)[N]) : e{} {
        for (size_t i = 0; i < N; ++i) e[i] = (char)(s[i] ^ AR_XKEY);
    }

    // 首次调用解码，之后复用；不分配堆，不留文件痕迹
    const char* get() const {
        static char buf[N] = {0};
        if (buf[0] == 0) {
            for (size_t i = 0; i < N; ++i) buf[i] = (char)(e[i] ^ AR_XKEY);
        }
        return buf;
    }
};

// C 字符串：XSTR("ARCheat") -> const char*
#define XSTR(lit) (XStr{lit}.get())

#ifdef __OBJC__
// NSString：XNS(@"ARCheat") -> NSString*
#define XNS(lit) ([NSString stringWithUTF8String:XStr{lit}.get()])
#endif
