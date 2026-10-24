// SBWindow.mm —— 在 SpringBoard 里挂一个高层级浮窗（形态 β，v2）
//
// v2 依据实测判读更新（见 Docs/SCENE_TARGET.md）：
//   切换器里浮窗正常     → 不在 app scene 里，是 SpringBoard 那一层
//   通知栏上浮窗仍在     → windowLevel 高于通知中心
//   锁屏后浮窗消失       → 不在锁屏 scene，挂在 HomeScreen scene
//
// 因此 v2 做三件事：
//   1. 按分数挑 scene，优先 HomeScreen，排除 LockScreen 与 app scene
//   2. 监听 scene 激活/失活，解锁后自动重挂（否则解锁回来浮窗就没了）
//   3. 首次运行打印完整 scene 列表，用于在这台设备上确认确切标识

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <os/log.h>

static UIWindow*          g_window    = nil;
static UIWindowScene*     g_scene     = nil;
static id                 g_obsAct    = nil;
static id                 g_obsDeact  = nil;
static BOOL               g_interactive = NO;   // 菜单是否接管触摸
static BOOL               g_debugScenes = YES;  // 首次运行打开

// ==================== scene 选择 ====================

static void dump_scenes(void) {
    if (!g_debugScenes) return;
    UIApplication* app = [UIApplication sharedApplication];
    if (!app) return;
    os_log(OS_LOG_DEFAULT, "[AROverlay] === scene 列表 ===");
    for (UIScene* s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene* ws = (UIWindowScene*)s;
        os_log(OS_LOG_DEFAULT, "[AROverlay] role=%{public}@ delegate=%{public}@ state=%ld ident=%{public}@",
               ws.session.configuration.role,
               NSStringFromClass([ws.delegate class]),
               (long)ws.activationState,
               ws.session.persistentIdentifier);
    }
}

// 打分挑 scene：HomeScreen 最强，LockScreen 与 app scene 排除
static UIWindowScene* pick_scene(void) {
    UIApplication* app = [UIApplication sharedApplication];
    if (!app) return nil;

    UIWindowScene* best = nil;
    int bestScore = -1000;

    for (UIScene* s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene* ws = (UIWindowScene*)s;
        NSString* cls   = NSStringFromClass([ws.delegate class]) ?: @"";
        NSString* role  = ws.session.configuration.role ?: @"";
        int score = 0;

        if ([cls containsString:@"HomeScreen"])          score += 100;
        if ([cls containsString:@"Deferred"])            score += 80;
        if ([cls containsString:@"Lock"])                score -= 500;   // 锁屏 scene 明确排除
        if ([cls containsString:@"Application"])         score -= 50;    // 某个 app 的 scene
        if ([cls containsString:@"SBApplicationScene"])  score -= 100;
        if ([role containsString:@"Application"])        score -= 20;
        if (ws.activationState == UISceneActivationStateForegroundActive) score += 30;
        if (ws.activationState == UISceneActivationStateBackground)       score += 5;

        os_log(OS_LOG_DEFAULT, "[AROverlay] scene %{public}@ score=%d", cls, score);
        if (score > bestScore) { bestScore = score; best = ws; }
    }
    return (bestScore > -100) ? best : nil;
}

// ==================== 视图 ====================

@interface AROverlayView : UIView
@end

@implementation AROverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = YES;
        self.multipleTouchEnabled = YES;
    }
    return self;
}

// 不打开菜单时整体穿透，点击直达下面的游戏
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    if (!g_interactive) return nil;
    return [super hitTest:point withEvent:event];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGContextSetStrokeColorWithColor(ctx,
        [UIColor colorWithRed:0 green:1 blue:0.47 alpha:0.86].CGColor);
    CGContextSetLineWidth(ctx, 1.6f);

    // TODO 接数据：实体世界坐标 -> aim::w2s -> CGRect
    //   例：
    //   for (auto& e : entities) {
    //       float sx, sy;
    //       if (!aim::w2s(pov, rect.size.width, rect.size.height, e.pos, sx, sy)) continue;
    //       CGContextStrokeRect(ctx, CGRectMake(sx - w/2, sy - h, w, h));
    //   }
    CGRect demo = CGRectMake(rect.size.width * 0.5f - 30,
                             rect.size.height * 0.5f - 60, 60, 120);
    CGContextStrokeRect(ctx, demo);
}

@end

// ==================== 挂载 / 卸载 ====================

static void teardown(void) {
    if (g_window) {
        g_window.hidden = YES;
        g_window.rootViewController = nil;
        g_window = nil;
    }
    g_scene = nil;
}

static void install_overlay(void) {
    if (g_window && g_scene) {
        g_window.hidden = NO;
        return;
    }
    teardown();

    UIWindowScene* scene = pick_scene();
    if (!scene) {
        os_log(OS_LOG_DEFAULT, "[AROverlay] 没找到可用 scene");
        return;
    }
    g_scene = scene;

    g_window = [[UIWindow alloc] initWithWindowScene:scene];

    // 高于通知中心。先用 20000000；若盖不住继续往上加，必要时用 CGFLOAT_MAX 裁剪实验
    g_window.windowLevel = 20000000.0;
    g_window.backgroundColor = [UIColor clearColor];
    g_window.opaque = NO;

    AROverlayView* v = [[AROverlayView alloc] initWithFrame:scene.coordinateSpace.bounds];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIViewController* vc = [[UIViewController alloc] init];
    vc.view = v;
    vc.view.backgroundColor = [UIColor clearColor];
    g_window.rootViewController = vc;

    g_window.hidden = NO;

    os_log(OS_LOG_DEFAULT, "[AROverlay] 已挂载 delegate=%{public}@ level=%.0f",
           NSStringFromClass([scene.delegate class]), g_window.windowLevel);
}

// 解锁 / 切换器 / scene 重建后自动重挂
static void watch_scenes(void) {
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];

    g_obsAct = [nc addObserverForName:UISceneDidActivateNotification
                               object:nil
                                queue:[NSOperationQueue mainQueue]
                           usingBlock:^(NSNotification* n) {
        if (![n.object isKindOfClass:[UIWindowScene class]]) return;
        os_log(OS_LOG_DEFAULT, "[AROverlay] scene 激活，重挂");
        g_window = nil; g_scene = nil;
        install_overlay();
    }];

    g_obsDeact = [nc addObserverForName:UISceneWillDeactivateNotification
                                 object:nil
                                  queue:[NSOperationQueue mainQueue]
                             usingBlock:^(NSNotification* n) {
        if (![n.object isKindOfClass:[UIWindowScene class]]) return;
        os_log(OS_LOG_DEFAULT, "[AROverlay] scene 失活，隐藏");
        if (g_window) g_window.hidden = YES;
        g_scene = nil;
    }];
}

// ==================== 入口（被 dlopen 后自动跑） ====================

__attribute__((constructor))
static void sb_payload_init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        dump_scenes();
        watch_scenes();
        install_overlay();
    });
}

// ==================== 对外（供 daemon 通过共享内存控制） ====================
// 菜单开关、退出等指令建议走 SharedFrame.h 里的共享内存字段，
// payload 每帧检查一次，避免再做一条 IPC 通道。

void ar_overlay_set_interactive(BOOL on) {
    g_interactive = on;
    if (g_window) [g_window.rootViewController.view setNeedsDisplay];
}

void ar_overlay_uninstall(void) {
    teardown();
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    if (g_obsAct)   { [nc removeObserver:g_obsAct];   g_obsAct = nil; }
    if (g_obsDeact) { [nc removeObserver:g_obsDeact]; g_obsDeact = nil; }
}
