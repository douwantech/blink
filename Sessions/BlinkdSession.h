////////////////////////////////////////////////////////////////////////////////
//
// blinkd — 连接 Mac 端 blinkd daemon 的原始 TCP 会话(不走 SSH)。
// 协议见 mac-daemon/main.go:
//   client→server 帧: 0x01|u16|token  0x02|u16|input  0x03|u16 rows|u16 cols
//   server→client: 裸 PTY 字节流(attach 时先回放 ring buffer)
//
////////////////////////////////////////////////////////////////////////////////

#import "Session.h"

@interface BlinkdSession : Session

/// 服务端是否回过终端数据；握手失败/网络不通时供机器自动连接回退 SSH。
@property (nonatomic, readonly) BOOL receivedOutput;

@end
