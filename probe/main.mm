// probe/main.mm —— 一个持续跑 Metal 的空壳 app
//
// 为什么需要它：ARCheat.dylib 的挂点是 -[CAMetalLayer nextDrawable] 和 drawable 的
// present。要验证这两条挂点真的生效，宿主必须持续产出 drawable。MTKView 正好就是
// 走 CAMetalLayer 的，所以这个 app 是最短的验证路径：
//   注入 ARCheat.dylib -> 启动 -> 屏幕左下角出现 ImGui 菜单（三指双击切换）
// 看不到菜单就说明挂点没生效，与游戏的偏移无关，可以直接定位问题。

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <Metal/MTLCommandQueue.h>
#import <Metal/MTLCommandBuffer.h>
#import <Metal/MTLRenderPass.h>
#import <MetalKit/MetalKit.h>

@interface ProbeVC : UIViewController <MTKViewDelegate>
@end

@implementation ProbeVC {
    MTKView *_view;
    UILabel *_hud;
    NSTimeInterval _t0;
    int _frames;
    int _frameTotal;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    _view = [[MTKView alloc] initWithFrame:self.view.bounds device:dev];
    _view.delegate = self;
    _view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _view.clearColor = MTLClearColorMake(0.05, 0.06, 0.08, 1.0);
    _view.preferredFramesPerSecond = 60;
    _view.enableSetNeedsDisplay = NO;
    [self.view addSubview:_view];

    _hud = [[UILabel alloc] initWithFrame:CGRectMake(16, 48, self.view.bounds.size.width - 32, 220)];
    _hud.numberOfLines = 0;
    _hud.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _hud.textColor = [UIColor colorWithRed:0.25 green:1.0 blue:0.55 alpha:1.0];
    _hud.text = @"ARProbe / MTKView running\n\n"
                @"1) install this ipa with TrollStore\n"
                @"2) TrollFools -> pick ARProbe -> inject ARCheat.dylib\n"
                @"3) relaunch, three-finger double tap toggles the overlay\n"
                @"4) log: Documents (Files app) / Library/Caches";
    [self.view addSubview:_hud];

    _t0 = CFAbsoluteTimeGetCurrent();
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _hud.frame = CGRectMake(16, 48, self.view.bounds.size.width - 32, 220);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *rp = view.currentRenderPassDescriptor;
    if (!rp) return;

    // 注意：MTKView.device 在不同 SDK 里可能退化成无类型的 id，
    // 而 ARC 下对 id 发未知 selector 是**错误**而不是警告，所以这里显式转一次类型。
    id<MTLDevice> dev = (id<MTLDevice>)view.device;
    if (!dev) return;

    id<MTLCommandBuffer> cb = [dev newCommandBuffer];
    if (!cb) return;

    rp.colorAttachments[0].clearColor = view.clearColor;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc endEncoding];

    id drawable = view.currentDrawable;
    if (drawable) [cb presentDrawable:(id<MTLDrawable>)drawable];
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
