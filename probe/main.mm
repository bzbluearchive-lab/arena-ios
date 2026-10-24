// probe/main.mm —— 一个持续产出 drawable 的空壳 app
//
// 为什么需要它：ARCheat.dylib 的挂点是 -[CAMetalLayer nextDrawable] 和 drawable 的
// present。要验证这两条挂点真的生效，宿主必须持续产 drawable。MTKView 正好走
// CAMetalLayer，所以这个 app 是最短的验证路径：
//   注入 ARCheat.dylib -> 启动 -> 三指双击出现 ImGui 菜单
// 看不到菜单 = 挂点没生效，与游戏的偏移无关，可以直接定位问题。
//
// 注意：这里对 Metal 的调用全部走"自带的最小协议"（AR* 那一组），不直接用 MTLDevice /
// MTLCommandBuffer 的声明。原因：theos 的 iPhoneOS SDK 里这些协议的方法声明并不总是
// 完整可见，而 ARC 下对 id 发未知 selector 是**硬错误**。自带协议后编译期与 SDK 解耦，
// 运行时按对象真实类型派发，行为不变。

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

// ---------------- 最小 Metal 协议（只要能编码 + 呈现一次清除） ----------------
@protocol ARDevice <NSObject>
- (id)newCommandQueue;
@end

@protocol ARQueue <NSObject>
- (id)commandBuffer;
@end

@protocol ARBuffer <NSObject>
- (id)renderCommandEncoderWithDescriptor:(id)rp;
- (void)presentDrawable:(id)drawable;
- (void)commit;
@end

@protocol AREncoder <NSObject>
- (void)endEncoding;
@end

@interface ProbeVC : UIViewController <MTKViewDelegate>
@end

@implementation ProbeVC {
    MTKView *_view;
    UILabel *_hud;
    NSTimeInterval _t0;
    int _frames;
    int _frameTotal;
    id _queue;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    id dev = (id)MTLCreateSystemDefaultDevice();
    if (dev) _queue = [(id<ARDevice>)dev newCommandQueue];

    _view = [[MTKView alloc] initWithFrame:self.view.bounds device:(id<MTLDevice>)dev];
    _view.delegate = self;
    _view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _view.clearColor = MTLClearColorMake(0.05, 0.06, 0.08, 1.0);
    _view.preferredFramesPerSecond = 60;
    _view.enableSetNeedsDisplay = NO;
    [self.view addSubview:_view];

    _hud = [[UILabel alloc] initWithFrame:CGRectMake(16, 48, self.view.bounds.size.width - 32, 240)];
    _hud.numberOfLines = 0;
    _hud.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _hud.textColor = [UIColor colorWithRed:0.25 green:1.0 blue:0.55 alpha:1.0];
    _hud.text = @"ARProbe / MTKView running\n\n"
                @"1) install this ipa with TrollStore\n"
                @"2) TrollFools -> pick ARProbe -> inject ARCheat.dylib\n"
                @"3) relaunch, three-finger double tap toggles the overlay\n"
                @"4) logs land in Library/Caches (visible via Files app)";
    [self.view addSubview:_hud];

    _t0 = CFAbsoluteTimeGetCurrent();
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _hud.frame = CGRectMake(16, 48, self.view.bounds.size.width - 32, 240);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    // currentRenderPassDescriptor 内部会调 -[CAMetalLayer nextDrawable]，
    // 这一步就是我们要验证的挂点；拿到 rp 说明 drawable 已经产出。
    id rp = (id)view.currentRenderPassDescriptor;
    id drawable = (id)view.currentDrawable;
    if (!rp || !drawable || !_queue) return;

    id<ARBuffer> cb = (id<ARBuffer>)[(id<ARQueue>)_queue commandBuffer];
    if (!cb) return;

    id<AREncoder> enc = (id<AREncoder>)[cb renderCommandEncoderWithDescriptor:rp];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];

    _frames++;
    _frameTotal++;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - _t0 >= 1.0) {
        const double fps = _frames / (now - _t0);
        _frames = 0;
        _t0 = now;
        const CGSize sz = view.drawableSize;
        _hud.text = [NSString stringWithFormat:
                     @"ARProbe / MTKView running\n"
                     @"fps      : %.1f\n"
                     @"drawable : %.0f x %.0f\n"
                     @"frames   : %d\n\n"
                     @"three-finger double tap -> overlay",
                     fps, sz.width, sz.height, _frameTotal];
    }
}

@end

@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProbeDelegate {
    UIWindow *_win;
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    _win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _win.rootViewController = [ProbeVC new];
    [_win makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([ProbeDelegate class]));
    }
}
