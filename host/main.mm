// host/main.m —— 启动器：配置 UI + 孵化 daemon
//
// 这个 app 划掉之后浮窗必须仍然工作，所以它只做三件事：
//   1. 把 daemon 从 bundle 里 spawn 出去（daemon 自己 setsid 脱离进程组）
//   2. 显示 daemon 是否存活
//   3. 提供"停止"按钮：往容器里写一个 stop 标志文件，daemon 自己退出
//
// 不含任何作弊逻辑、不读游戏内存、不建窗口。

#import <UIKit/UIKit.h>
#include <unistd.h>
#include "DaemonSpawn.h"

// 启动探针：进程真的跑起来了才会留下文件。
// 用来区分两种完全不同的失败：
//   A. 文件完全没出现  -> 进程根本没被系统拉起（签名/权限/包结构问题）
//   B. 文件出现了      -> 进程跑起来了，之后才崩（代码问题，能拿到崩溃日志）
static void ARProbe(const char* tag) {
    @autoreleasepool {
        NSString* docDir = nil;
        NSArray* d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (d.count) docDir = [d[0] stringByAppendingPathComponent:@"arhost_probe.txt"];

        NSMutableArray* paths = [NSMutableArray array];
        [paths addObject:@"/var/mobile/Library/Caches/arhost_probe.txt"];  // 无沙盒时可写
        if ([NSTemporaryDirectory() length]) {
            [paths addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"arhost_probe.txt"]];
        }
        if (docDir) [paths addObject:docDir];

        NSString* line = [NSString stringWithFormat:@"%@ %s pid=%d\n",
                          [NSDate date], tag, getpid()];
        NSData* data = [line dataUsingEncoding:NSUTF8StringEncoding];

        for (NSString* p in paths) {
            @try {
                if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
                    [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:nil];
                }
                NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:p];
                if (!fh) continue;
                [fh seekToEndOfFile];
                [fh writeData:data];
                [fh closeFile];
            } @catch (...) {
                // 写不了就算了，探针不能影响主流程
            }
        }
    }
}

static NSString* containerPath(void) {
    NSArray* d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return d.count ? d[0] : NSTemporaryDirectory();
}

static NSString* stopFlagPath(void) {
    return [containerPath() stringByAppendingPathComponent:@"ar_daemon.stop"];
}

static NSString* daemonLogPath(void) {
    return [containerPath() stringByAppendingPathComponent:@"ar_daemon.log"];
}

static NSString* daemonPath(void) {
    return [[NSBundle mainBundle] pathForResource:@"ARDaemon" ofType:nil];
}

static NSString* payloadPath(void) {
    return [[NSBundle mainBundle] pathForResource:@"ARPayload" ofType:@"dylib"];
}

// ==================== UI ====================
@interface RootVC : UIViewController
@property (nonatomic, strong) UILabel* status;
@property (nonatomic, strong) UITextView* logView;
@end

@implementation RootVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    CGFloat w = self.view.bounds.size.width;
    CGFloat pad = 20;

    self.status = [[UILabel alloc] initWithFrame:CGRectMake(pad, 60, w - pad*2, 60)];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    [self.view addSubview:self.status];

    UIButton* start = [UIButton buttonWithType:UIButtonTypeSystem];
    start.frame = CGRectMake(pad, 130, (w - pad*3)/2, 48);
    [start setTitle:@"启动 daemon" forState:UIControlStateNormal];
    [start addTarget:self action:@selector(onStart) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:start];

    UIButton* stop = [UIButton buttonWithType:UIButtonTypeSystem];
    stop.frame = CGRectMake(pad*2 + (w - pad*3)/2, 130, (w - pad*3)/2, 48);
    [stop setTitle:@"停止 daemon" forState:UIControlStateNormal];
    [stop addTarget:self action:@selector(onStop) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:stop];

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(pad, 200, w - pad*2, self.view.bounds.size.height - 220)];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.view addSubview:self.logView];

    [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self tick];
}

- (void)tick {
    NSString* log = [NSString stringWithContentsOfFile:daemonLogPath()
                                             encoding:NSUTF8StringEncoding error:nil];
    self.logView.text = log.length ? log : @"(daemon 还没写日志)";

    NSArray* lines = [log componentsSeparatedByString:@"\n"];
    NSString* last = nil;
    for (NSString* l in [lines reverseObjectEnumerator]) {
        if (l.length) { last = l; break; }
    }
    NSString* alive = @"未知";
    if (last) {
        NSRange r = [last rangeOfString:@"pid="];
        if (r.location != NSNotFound) alive = @"运行中";
    }
    self.status.text = [NSString stringWithFormat:
        @"daemon: %@\n日志: Documents/ar_daemon.log\npayload: %@",
        alive, payloadPath() ? @"已打包" : @"缺失"];
}

- (void)onStart {
    [[NSFileManager defaultManager] removeItemAtPath:stopFlagPath() error:nil];

    NSString* dp = daemonPath();
    NSString* pp = payloadPath();
    if (!dp || !pp) {
        self.status.text = @"缺少 ARDaemon 或 ARPayload，检查打包步骤";
        return;
    }

    // 参数：argv[1]=日志路径 argv[2]=payload 路径
    char* argv[] = {
        (char*)dp.UTF8String,
        (char*)daemonLogPath().UTF8String,
        (char*)pp.UTF8String,
        NULL
    };
    int err = 0;
    pid_t pid = host::spawn_daemon(dp.UTF8String, argv, &err);
    if (pid > 0) {
        self.status.text = [NSString stringWithFormat:@"已孵化 pid=%d", pid];
    } else {
        self.status.text = [NSString stringWithFormat:
            @"spawn 失败 errno=%d (%s)\n签名了吗？", err, strerror(err)];
    }
    [self tick];
}

- (void)onStop {
    [@"stop" writeToFile:stopFlagPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    self.status.text = @"已写入 stop 标志，daemon 将在 1s 内退出";
}

@end

// ==================== App ====================
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow* window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)o {
    ARProbe("ui_ready");            // 走到这里说明 UI 已经起来了
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[RootVC alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char** argv) {
    @autoreleasepool {
        ARProbe("main_enter");          // 走到这里说明进程已被拉起
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
