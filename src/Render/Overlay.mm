// Overlay.mm —— Metal 呈现层 + ImGui 叠加 + 每帧驱动
//
// 关键设计（针对 ACE）：整个显示层的生命周期都挂在游戏自己的渲染回调里，
// 不新建线程、不开 CADisplayLink、不起定时器。从 anogs 的角度看，进程的线程数、
// 运行循环、区域映射与未注入时一致，只有"多了一个 dylib"这一点不同。
//
// 挂点选择：
//   -[CAMetalLayer nextDrawable]  ：拿到本帧 drawable
//   -[<drawable 具体类> present]  ：在游戏提交呈现之前插入我们的一次 render pass，
//                                   LoadAction=Load 保住游戏已画的像素
// 两条都是 ObjC 方法，走 method_setImplementation，不碰 __text、不涉及 PAC 指令搬家。
//
// 关于 CAMetalDrawable：它是个 @protocol，不同 SDK 版本对它是否随
// <QuartzCore/CAMetalLayer.h> 带进来并不一致（theos 的 iPhoneOS SDK 上实测不带）。
// 所以这里不依赖 SDK 里的那个协议，自己声明两个最小协议，用 id<...> 拿类型，
// 运行时把真实对象 cast 过来即可。这样编译期与 SDK 版本解耦。

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <vector>
#include <atomic>

#include "Overlay.hpp"
#include "ESP.hpp"
#include "../Core/Hook.hpp"
#include "../Core/Obfs.hpp"
#include "../Game/World.hpp"
#include "../Game/Offsets.hpp"

#include "imgui.h"
#include "imgui_impl_metal.h"

// ---------------- 最小类型约束（不依赖 SDK 的 CAMetalDrawable 声明） ----------------
@protocol ARDrawable <NSObject>
- (id<MTLTexture>)texture;
- (id)layer;
- (void)present;
- (void)presentAtTime:(CFTimeInterval)t;
@end

@protocol ARLayerLike <NSObject>
- (CGSize)drawableSize;
- (CGRect)bounds;            // 点（point）单位，用来换算 点 -> 像素
- (id<MTLDevice>)device;
@end

typedef id<ARDrawable> ARDrawableRef;

// ---------------- 全局状态 ----------------
// 只有"显示开关"，没有任何功能性状态：这个 dylib 不写游戏内存、不改视角。
// 默认开：装完启动就能看见菜单，确认渲染通不通；关掉靠左上角那个方块按钮。
static std::atomic<bool> g_on{true};
static std::atomic<bool> g_esp{true};
static ARDrawableRef g_drawable = nil;

// ---- 屏幕上的开关 ----
// 画在左上角，始终可见（菜单关着也画），点它就开/关菜单。
// 坐标用"点"，绘制时再乘 scale 换成像素。
struct BtnRect { float x, y, w, h; };
static BtnRect g_btn = { 14.f, 58.f, 44.f, 44.f };
static float     g_uiScale = 1.f;   // drawable 像素 / 屏幕点（由 layer.bounds 换算）

// ---------------- ImGui + Metal ----------------
struct Renderer {
    id<MTLDevice>       device = nil;
    id<MTLCommandQueue> queue  = nil;
    bool  init = false;
    float vpW = 0, vpH = 0;
};
static Renderer g_r;

static void imgui_bringup(id<MTLDevice> dev) {
    if (g_r.init || !dev) return;
    g_r.device = dev;
    g_r.queue  = [dev newCommandQueue];

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;              // 不落盘，少一个文件痕迹
    io.LogFilename = nullptr;
    ImGui::StyleColorsDark();

    ImGui_ImplMetal_Init(dev);
    g_r.init = true;
}

static void draw_overlay(ARDrawableRef drawable, float vpW, float vpH) {
    if (!g_r.init || !drawable) return;

    id<MTLCommandBuffer> cb = [g_r.queue commandBuffer];
    if (!cb) return;

    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture     = [drawable texture];
    rpd.colorAttachments[0].loadAction  = MTLLoadActionLoad;    // 保住游戏画面
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();

    // ---- 屏幕开关（始终画，不依赖菜单开没开）----
    // 触摸坐标是"点"，绘制坐标是像素。比例从 drawable 所在 layer 的 bounds 换算，
    // 不用 UIApplication.keyWindow / windows（iOS 13/15 起 deprecated，-Werror 会直接报错）。
    {
        id<ARLayerLike> lay = (id<ARLayerLike>)[drawable layer];
        if (lay) {
            const CGRect lb = [lay bounds];
            if (lb.size.width > 1.f) g_uiScale = vpW / (float)lb.size.width;
        }
        const float sc = g_uiScale;
        ImDrawList* bg = ImGui::GetBackgroundDrawList();
        const ImVec2 a(g_btn.x * sc, g_btn.y * sc);
        const ImVec2 b((g_btn.x + g_btn.w) * sc, (g_btn.y + g_btn.h) * sc);
        bg->AddRectFilled(a, b, IM_COL32(16, 18, 22, 190), 9.f);
        bg->AddRect(a, b, IM_COL32(90, 220, 150, 230), 9.f, 0, 2.f);
        // 三段横线，画成"菜单"的样子（ASCII，不依赖字体里的特殊字形）
        const float px = a.x + 11.f * sc, py = a.y + 10.f * sc, lw = 22.f * sc;
        for (int i = 0; i < 3; i++)
            bg->AddLine(ImVec2(px, py + i * 10.f * sc), ImVec2(px + lw, py + i * 10.f * sc),
                        IM_COL32(90, 220, 150, 255), 2.f * sc);
        if (g_on.load())
            bg->AddRect(a, b, IM_COL32(255, 210, 60, 255), 9.f, 0, 2.f);  // 打开状态描边
    }

    // ---- 显示层（骨骼 / 装备 / 物资），全部只读 ----
    if (g_esp.load()) {
        esp::render(vpW, vpH);
    }

    // ---- 菜单（只有显示开关，没有功能性按钮）----
    // UI 文本全部走 XOR 常量：anogs 会扫进程内区域的明文串。
    if (g_on.load()) {
        esp::Settings& S = esp::settings();
        ImGui::SetNextWindowPos(ImVec2((g_btn.x + g_btn.w + 10.f) * g_uiScale,
                                       g_btn.y * g_uiScale),
                                ImGuiCond_Always);
        ImGui::Begin(XSTR("s"), nullptr, ImGuiWindowFlags_AlwaysAutoResize);
        bool on = g_esp.load();
        if (ImGui::Checkbox(XSTR("a"), &on)) g_esp = on;          // 总开关
        ImGui::Checkbox(XSTR("b"), &S.skeleton);                  // 骨骼
        ImGui::Checkbox(XSTR("c"), &S.gear);                      // 装备
        ImGui::Checkbox(XSTR("d"), &S.loot);                      // 物资
        ImGui::Checkbox(XSTR("e"), &S.distance);                  // 距离
        ImGui::SliderFloat(XSTR("f"), &S.maxDistM, 20.f, 800.f);  // 半径
        ImGui::End();
    }

    ImGui::Render();
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
    [cb commit];
}

// ---------------- 方法交换 ----------------
// CAMetalDrawable 是协议不是类，objc_getClass("CAMetalDrawable") 拿不到。
// 正解：第一次 nextDrawable 返回真实对象后，取 object_getClass(d) 得到具体的私有类，
// 在那个类上交换 present / presentAtTime:。这样协议与私有实现都覆盖到。
static ARDrawableRef (*orig_nextDrawable)(id, SEL);
static void (*orig_present)(id, SEL);
static void (*orig_presentAtTime)(id, SEL, CFTimeInterval);
static void (*orig_sendEvent)(id, SEL, UIEvent*);

static bool g_presentHooked = false;

static void hook_present_on(Class concreteCls);
static void do_draw(ARDrawableRef d);

static ARDrawableRef hk_nextDrawable(id self, SEL _cmd) {
    ARDrawableRef d = orig_nextDrawable(self, _cmd);
    if (d) {
        g_drawable = d;                                 // 只记录，不画
        if (!g_presentHooked) hook_present_on(object_getClass(d));
    }
    return d;
}

static void hk_present(id self, SEL _cmd) {
    @autoreleasepool {
        do_draw((ARDrawableRef)self);
        orig_present(self, _cmd);                       // 我们画完再交给系统 present
    }
}

static void hk_presentAtTime(id self, SEL _cmd, CFTimeInterval t) {
    @autoreleasepool {
        do_draw((ARDrawableRef)self);
        orig_presentAtTime(self, _cmd, t);
    }
}

static void hook_present_on(Class concreteCls) {
    if (g_presentHooked || !concreteCls) return;

    Method mp = class_getInstanceMethod(concreteCls, @selector(present));
    if (mp) {
        orig_present = (void(*)(id, SEL))method_getImplementation(mp);
        method_setImplementation(mp, (IMP)hk_present);
    }
    Method mt = class_getInstanceMethod(concreteCls, @selector(presentAtTime:));
    if (mt) {
        orig_presentAtTime = (void(*)(id, SEL, CFTimeInterval))method_getImplementation(mt);
        method_setImplementation(mt, (IMP)hk_presentAtTime);
    }
    g_presentHooked = (mp || mt);
}

static void do_draw(ARDrawableRef d) {
    if (!d || !g_drawable) return;

    id<ARLayerLike> lay = (id<ARLayerLike>)[d layer];
    CGSize sz = lay ? [lay drawableSize] : CGSizeMake(0, 0);
    if (sz.width < 2 || sz.height < 2) return;

    if (!g_r.init) {
        id<MTLDevice> dev = lay ? [lay device] : nil;
        if (!dev) dev = MTLCreateSystemDefaultDevice();
        imgui_bringup(dev);
    }
    draw_overlay(d, (float)sz.width, (float)sz.height);
}

// 屏幕开关的命中判定：点坐标 × scale = 像素坐标，再和按钮矩形比。
// 容差 14 点：手指按不准也能点到。
static bool point_on_button(CGPoint p) {
    if (g_uiScale <= 0.f) return false;
    const float x = (float)p.x * g_uiScale;
    const float y = (float)p.y * g_uiScale;
    const float m = 14.f * g_uiScale;
    return x >= g_btn.x * g_uiScale - m && x <= (g_btn.x + g_btn.w) * g_uiScale + m &&
           y >= g_btn.y * g_uiScale - m && y <= (g_btn.y + g_btn.h) * g_uiScale + m;
}

// 输入：只认"点左上角那个方块"这一种方式。
// 原来那套三指双击的问题：iPad 上三指很难同步按下，且在对局里极易误触，删掉。
static void hk_sendEvent(id self, SEL _cmd, UIEvent* ev) {
    if (ev && ev.type == UIEventTypeTouches) {
        NSSet* all = [ev allTouches];
        if (all.count == 1) {
            for (UITouch* t in all) {
                if (t.phase == UITouchPhaseEnded) {
                    // locationInView:nil 给的是窗口坐标（点），不是 deprecated API
                    CGPoint loc = [t locationInView:nil];
                    if (point_on_button(loc)) g_on = !g_on.load();
                    break;
                }
            }
        }
    }
    orig_sendEvent(self, _cmd, ev);
}

// ---------------- 安装 ----------------
void overlay_install() {
    // 只有 CAMetalLayer 是稳定的类；drawable 侧在首次返回时按具体类挂
    orig_nextDrawable = (ARDrawableRef(*)(id, SEL))
        hook::swizzle_class_method("CAMetalLayer", @selector(nextDrawable),
                                   (IMP)hk_nextDrawable);

    orig_sendEvent = (void(*)(id, SEL, UIEvent*))
        hook::swizzle_class_method("UIApplication", @selector(sendEvent:),
                                   (IMP)hk_sendEvent);

    // 若引擎不走 CAMetalLayer（直接自建 MTLCommandBuffer presentDrawable:），
    // 回退方案见 Docs/STEALTH.md「挂点回退」。
}

bool overlay_ready() { return g_r.init; }
void overlay_set_screen(float w, float h) { g_r.vpW = w; g_r.vpH = h; }
