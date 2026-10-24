// DaemonSpawn.mm —— 已被 DaemonSpawn.h 取代（header-only），保留此文件作说明。
//
// 实际实现见 DaemonSpawn.h：host::spawn_daemon(path, argv, &err) / host::pid_alive(pid)
//
// daemon 侧要做的事（见 daemon/main.m）：
//   int main(int argc, char** argv) {
//       setsid();                        // 双保险：脱离会话
//       signal(SIGPIPE, SIG_IGN);
//       // argv[1] = 日志路径  argv[2] = payload dylib 路径
//       // 1) task_for_pid(SpringBoard)  2) 远程 dlopen payload
//       // 3) 每秒写心跳 + 检查 stop 标志文件
//   }
//
// 验证顺序（每一步都是一个能独立判定成败的实验）：
//   1. spawn 后划掉 app → daemon 日志还在涨？        ← 证明能 daemonize
//   2. ps 里 daemon 的 PPID 变成 1？                 ← 证明被 launchd 收养
//   3. daemon 日志里 task_for_pid 返回 0？            ← 证明 entitlement 生效
//   4. SpringBoard 日志出现 [AROverlay] 已挂载？      ← 证明注入链通
//   5. 屏幕中央出现示例方框，且切到通知中心仍在最上？ ← 证明浮窗层级对
//
// 任何一步失败都停在那一步，不要往下跑 —— 否则出错时无法定位是哪一层。

#include "DaemonSpawn.h"
