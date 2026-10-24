// Overlay.mm —— Metal 呈现层 + ImGui 叠加 + 每帧驱动。
//
// 关键设计（针对 ACE）：整个 cheat 的生命周期都挂在游戏自己的渲染回调里，
// 不新建线程、不开 CADisplayLink、不起定时器。从 anogs 的角度看，进程里的线程数、
// 运行循环、区域映射与未注入时一致，只有"多了一个 dylib"这一点不同。
//
// 挂点选择：
//   -[CAMetalLayer nextDrawable]  ：拿到本帧 drawable（只在需要画的时候才动）
//   -[CAMetalDrawable present]    ：在游戏提交呈现之前插入我们的一次 render pass，
//                                    LoadAction=Load 保住游戏已画的像素
// 两条都是 ObjC 方法，走 method_setImplementation，不碰 __text、不涉及 PAC 指令搬家。

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <vector>
#include <atomic>

#include "Overlay.hpp"
#include "../Core/Hook.hpp"
#include "../Core/SafeMem.h"
#include "../Game/World.hpp"
#include "../Game/Aim.hpp"
#include "../Game/Offsets.hpp"

#include "imgui.h"
#include "imgui_impl_metal.h"

using namespace aim;

// ---------------- 全局状态 ----------------
static std::atomic<bool> g_on{false};      // 总开关（三指双击切）
static std::atomic<bool> g_esp{true};
static std::atomic<bool> g_aimOn{false};
static AimSettingsBox g_aimCfg;            // 定义在 Overlay.hpp
static CAMetalDrawable* g_drawable = nil;

// ---------------- ImGui + Metal ----------------
struct Renderer {
    id<MTLDevice>        device = nil;
    id<MTLCommandQueue>  queue  = nil;
    bool init = false;
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

static void draw_overlay(CAMetalDrawable* drawable, float vpW, float vpH) {
    if (!g_r.init || !drawable) return;

    id<MTLCommandBuffer> cb = [g_r.queue commandBuffer];
    if (!cb) return;

    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture     = drawable.texture;
    rpd.colorAttachments[0].loadAction  = MTLLoadActionLoad;    // 保住游戏画面
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();

    // ---- ESP ----
    if (g_esp.load()) {
        ImDrawList* dl = ImGui::GetBackgroundDrawList();
        world::Context ctx = world::resolve();
        FMinimalViewInfo pov{};
        if (world::camera(ctx, pov)) {
            std::vector<uintptr_t> list;
            if (world::actors(ctx, list)) {
                for (uintptr_t a : list) {
                    FVector pos{};
                    if (!world::actor_location(a, pos)) continue;
                    float sx, sy;
                    if (!w2s(pov, vpW, vpH, pos, sx, sy)) continue;
                    if (sx < -100 || sy < -100 || sx > vpW + 100 || sy > vpH + 100) continue;

                    // 距离
                    float dx = pos.X - pov.Location.X, dy = pos.Y - pov.Location.Y;
                    float dz = pos.Z - pov.Location.Z;
                    float dist = sqrtf(dx*dx + dy*dy + dz*dz) / 100.f;   // UE4 单位 cm

                    // 高度按距离做透视缩放（粗略，骨骼版接 bone_transforms 再精修）
                    float h = 1200.f / (dist + 1.f) * (vpH / 800.f);
                    float w = h * 0.45f;
                    ImU32 col = IM_COL32(0, 255, 120, 220);
                    dl->AddRect(ImVec2(sx - w*0.5f, sy - h),
                                ImVec2(sx + w*0.5f, sy), col, 1.5f, 0, 1.6f);
                    char buf[32];
                    snprintf(buf, sizeof(buf), "%.0fm", dist);
                    dl->AddText(ImVec2(sx - w*0.5f, sy + 2), col, buf);
                }
            }

            // ---- 自瞄 ----
            if (g_aimOn.load()) {
                std::vector<uintptr_t> list2;
                if (world::actors(ctx, list2)) {
                    aim::Settings s;
                    s.enabled   = true;
                    s.fov       = g_aimCfg.fov;
                    s.smooth    = g_aimCfg.smooth;
                    s.teamCheck = g_aimCfg.team;
                    aim::tick(ctx, 0, list2, s);
                }
            }
        }
    }

    // ---- 菜单 ----
    if (g_on.load()) {
        ImGui::Begin("ARCheat", nullptr, ImGuiWindowFlags_AlwaysAutoResize);
        bool e = g_esp.load();  if (ImGui::Checkbox("ESP", &e)) g_esp = e;
        bool a = g_aimOn.load(); if (ImGui::Checkbox("Aim", &a)) g_aimOn = a;
        ImGui::SliderFloat("FOV",    &g_aimCfg.fov,    1.f, 90.f);
        ImGui::SliderFloat("Smooth", &g_aimCfg.smooth, 0.05f, 1.f);
        ImGui::Checkbox("Team check", &g_aimCfg.team);
        ImGui::TextDisabled("3-finger double tap: toggle");
        ImGui::End();
    }

    ImGui::Render();
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
    [cb commit];
}

// ---------------- 方法交换 ----------------
// 注意：CAMetalDrawable 是**协议**不是类，objc_getClass("CAMetalDrawable") 拿不到。
// 正解：第一次 nextDrawable 返回真实对象后，取 object_getClass(d) 得到具体的私有类，
// 在那个类上交换 present / presentAtTime:。这样协议与私有实现都覆盖到。
static CAMetalDrawable* (*orig_nextDrawable)(id, SEL);
static void (*orig_present)(id, SEL);
static void (*orig_presentAtTime)(id, SEL, CFTimeInterval);

static bool  g_presentHooked = false;
static void  hook_present_on(Class concreteCls);
static void  do_draw(CAMetalDrawable* d);

static CAMetalDrawable* hk_nextDrawable(id self, SEL _cmd) {
    CAMetalDrawable* d = orig_nextDrawable(self, _cmd);
    if (d) {
        g_drawable = d;                                 // 只记录，不画
        if (!g_presentHooked) hook_present_on(object_getClass(d));
    }
    return d;
}

static void hk_present(id self, SEL _cmd) {
    @autoreleasepool {
        do_draw((CAMetalDrawable*)self);
        orig_present(self, _cmd);                       // 我们画完再交给系统 present
    }
}

static void hk_presentAtTime(id self, SEL _cmd, CFTimeInterval t) {
    @autoreleasepool {
        do_draw((CAMetalDrawable*)self);
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

static void do_draw(CAMetalDrawable* d) {
    if (!d || !g_drawable) return;
    CGSize sz = d.layer ? d.layer.drawableSize : CGSizeMake(0, 0);
    if (sz.width < 2 || sz.height < 2) return;
    if (!g_r.init) {
        id<MTLDevice> dev = d.layer.device ?: MTLCreateSystemDefaultDevice();
        imgui_bringup(dev);
    }
    draw_overlay(d, (float)sz.width, (float)sz.height);
}

// 三指双击开关：挂在 UIApplication sendEvent:，不新增手势识别器（少一个可见对象）
static void (*orig_sendEvent)(id, SEL, UIEvent*);
static NSTimeInterval g_lastTap = 0;
static void hk_sendEvent(id self, SEL _cmd, UIEvent* ev) {
    if (ev && ev.type == UIEventTypeTouches) {
        NSSet* all = [ev allTouches];
        if (all.count >= 3) {
            for (UITouch* t in all) {
                if (t.phase == UITouchPhaseEnded) {
                    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
                    if (now - g_lastTap < 0.4) g_on = !g_on.load();
                    g_lastTap = now;
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
    orig_nextDrawable = (CAMetalDrawable*(*)(id, SEL))
        hook::swizzle_class_method("CAMetalLayer", @selector(nextDrawable),
                                   (IMP)hk_nextDrawable);

    orig_sendEvent = (void(*)(id, SEL, UIEvent*))
        hook::swizzle_class_method("UIApplication", @selector(sendEvent:),
                                   (IMP)hk_sendEvent);

    // 若引擎不走 CAMetalLayer（直接自建 MTLCommandBuffer presentDrawable:），
    // 回退方案见 README「挂点回退」一节。
}

bool overlay_ready() { return g_r.init; }
void overlay_set_screen(float w, float h) { g_r.vpW = w; g_r.vpH = h; }
