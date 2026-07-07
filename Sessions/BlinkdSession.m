////////////////////////////////////////////////////////////////////////////////
//
// blinkd — 连接 Mac 端 blinkd daemon 的原始 TCP 会话(不走 SSH)。
// 骨架照抄 SSHSession 的「socket + poll 双向桥」,去掉 libssh2:
//   sock 可读 → fwrite(_stream.out) 渲染;_stream.in 可读 → 0x02 帧发 daemon;
//   sigwinch → 0x03 resize 帧;kill → fclose(_stream.in) 唤醒 poll 退出。
//
// 命令语法(步骤2:别名短命令,不用每次敲 IP+token):
//   blinkd <alias>                              用别名连
//   blinkd <host> <port> <token>                直接连(原始形式,保留)
//   blinkd save <alias> <host> <port> <token>   存别名
//   blinkd ls                                   列已存别名(token 脱敏)
//   blinkd rm <alias>                           删别名
// 别名存 ~/Library/.../blink/blinkd_hosts.json(隐藏,Files app 不可见,
// 与 SSH host 配置同级),格式 { "mac": {"host":..,"port":..,"token":..} }。
//
////////////////////////////////////////////////////////////////////////////////

#import "BlinkdSession.h"
#import "BlinkPaths.h"

#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>

#define BLINKD_FRAME_AUTH   0x01
#define BLINKD_FRAME_DATA   0x02
#define BLINKD_FRAME_RESIZE 0x03
#define BLINKD_FRAME_EXEC   0x04

static NSString *const kBlinkdHostsFile = @"blinkd_hosts.json";

@implementation BlinkdSession {
  int _sock;
}

// ---- 别名配置存储 ----

// 配置文件路径:blink 隐藏目录下,Files app 看不到,和 SSH host 同级
- (NSString *)configPath
{
  return [[BlinkPaths blink] stringByAppendingPathComponent:kBlinkdHostsFile];
}

- (NSMutableDictionary *)loadConfigs
{
  NSData *data = [NSData dataWithContentsOfFile:[self configPath]];
  if (!data) {
    return [NSMutableDictionary dictionary];
  }
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![obj isKindOfClass:[NSDictionary class]]) {
    return [NSMutableDictionary dictionary];
  }
  return [obj mutableCopy];
}

- (BOOL)saveConfigs:(NSDictionary *)configs
{
  NSData *data = [NSJSONSerialization dataWithJSONObject:configs
                                                options:NSJSONWritingPrettyPrinted
                                                  error:nil];
  return data && [data writeToFile:[self configPath] atomically:YES];
}

// token 脱敏(防截图/肩窥泄露):头 6 位 + …
- (NSString *)maskToken:(NSString *)t
{
  if (t.length <= 6) {
    return @"******";
  }
  return [NSString stringWithFormat:@"%@…", [t substringToIndex:6]];
}

- (void)printList
{
  NSDictionary *cfgs = [self loadConfigs];
  if (cfgs.count == 0) {
    fprintf(_stream.out, "  (还没有已存别名,用 blinkd save <alias> <host> <port> <token> 存一个)\r\n");
    return;
  }
  fprintf(_stream.out, "已存别名:\r\n");
  for (NSString *alias in cfgs) {
    NSDictionary *c = cfgs[alias];
    if (![c isKindOfClass:[NSDictionary class]]) { continue; }
    fprintf(_stream.out, "  %-12s %s:%d  token=%s\r\n",
            alias.UTF8String,
            [c[@"host"] UTF8String],
            [c[@"port"] intValue],
            [self maskToken:c[@"token"]].UTF8String);
  }
}

- (void)printUsage
{
  fprintf(_stream.out,
    "blinkd — 连 Mac 本地 daemon(不走 SSH)\r\n"
    "\r\n"
    "  blinkd <alias>                              用别名连\r\n"
    "  blinkd <host> <port> <token>                直接连\r\n"
    "  blinkd save <alias> <host> <port> <token>   存别名\r\n"
    "  blinkd ls                                   列已存别名\r\n"
    "  blinkd rm <alias>                           删别名\r\n"
    "\r\n");
  [self printList];
}

// ---- 入口 ----

- (int)main:(int)argc argv:(char **)argv
{
  // 先抽出 --exec <base64>(远端脚本):auth 后发 exec 帧,让 daemon fork 独立 PTY 跑它
  // (tmux new -A -s cc-<tab> + claude resume)。就地压缩 argv 去掉这两项,
  // 剩下的按 host/port/token 或别名原样解析。
  NSString *execScript = nil;
  int w = 0;
  for (int i = 0; i < argc; i++) {
    if (strcmp(argv[i], "--exec") == 0 && i + 1 < argc) {
      NSData *dec = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:argv[i + 1]] options:0];
      if (dec) {
        execScript = [[NSString alloc] initWithData:dec encoding:NSUTF8StringEncoding];
      }
      i++;  // 跳过 base64 参数
      continue;
    }
    argv[w++] = argv[i];
  }
  argc = w;

  NSString *sub = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";

  // 管理子命令(不建连,打印完直接返回)
  if (argc == 1 || [sub isEqualToString:@"help"] ||
      [sub isEqualToString:@"-h"] || [sub isEqualToString:@"--help"]) {
    [self printUsage];
    return 0;
  }
  if ([sub isEqualToString:@"ls"]) {
    [self printList];
    return 0;
  }
  // 连接方式(SSH / Socket)改在每台机器的编辑页里选(设置→机器→连接方式)。
  if ([sub isEqualToString:@"save"]) {
    if (argc != 6) {
      fprintf(_stream.out, "Usage: blinkd save <alias> <host> <port> <token>\r\n");
      return -1;
    }
    NSString *alias = [NSString stringWithUTF8String:argv[2]];
    NSString *host  = [NSString stringWithUTF8String:argv[3]];
    int port        = atoi(argv[4]);
    NSString *token = [NSString stringWithUTF8String:argv[5]];
    if (port <= 0 || port > 65535) {
      fprintf(_stream.out, "blinkd: bad port %s\r\n", argv[4]);
      return -1;
    }
    NSMutableDictionary *cfgs = [self loadConfigs];
    cfgs[alias] = @{ @"host": host, @"port": @(port), @"token": token };
    if ([self saveConfigs:cfgs]) {
      fprintf(_stream.out, "blinkd: saved '%s' → %s:%d(以后 blinkd %s 直连)\r\n",
              alias.UTF8String, host.UTF8String, port, alias.UTF8String);
      return 0;
    }
    fprintf(_stream.out, "blinkd: 保存失败\r\n");
    return -1;
  }
  if ([sub isEqualToString:@"rm"]) {
    if (argc != 3) {
      fprintf(_stream.out, "Usage: blinkd rm <alias>\r\n");
      return -1;
    }
    NSString *alias = [NSString stringWithUTF8String:argv[2]];
    NSMutableDictionary *cfgs = [self loadConfigs];
    if (!cfgs[alias]) {
      fprintf(_stream.out, "blinkd: 没有别名 '%s'\r\n", alias.UTF8String);
      return -1;
    }
    [cfgs removeObjectForKey:alias];
    [self saveConfigs:cfgs];
    fprintf(_stream.out, "blinkd: removed '%s'\r\n", alias.UTF8String);
    return 0;
  }

  // 建连:别名(argc==2)或原始 host/port/token(argc==4)
  NSString *host = nil;
  int port = 0;
  NSString *token = nil;
  if (argc == 2) {
    NSDictionary *cfgs = [self loadConfigs];
    NSDictionary *c = cfgs[sub];
    if (![c isKindOfClass:[NSDictionary class]]) {
      fprintf(_stream.out, "blinkd: 没有别名 '%s'(blinkd ls 看已存,blinkd save 存新)\r\n", sub.UTF8String);
      return -1;
    }
    host  = c[@"host"];
    port  = [c[@"port"] intValue];
    token = c[@"token"];
    fprintf(_stream.out, "blinkd: %s → %s:%d\r\n", sub.UTF8String, host.UTF8String, port);
  } else if (argc == 4) {
    host  = [NSString stringWithUTF8String:argv[1]];
    port  = atoi(argv[2]);
    token = [NSString stringWithUTF8String:argv[3]];
  } else {
    [self printUsage];
    return -1;
  }
  if (port <= 0 || port > 65535) {
    fprintf(_stream.out, "blinkd: bad port %d\r\n", port);
    return -1;
  }

  // 解析 + 非阻塞 connect(8s 超时,tailscale IP 不通时不至于挂死)
  _sock = [self connectTo:host.UTF8String port:port];
  if (_sock < 0) {
    return -1;
  }

  // 握手:token → (可选)exec 远端脚本 → 上报窗口尺寸
  const char *tok = token.UTF8String;
  [self sendFrame:BLINKD_FRAME_AUTH payload:tok length:strlen(tok)];
  if (execScript.length > 0) {
    const char *es = execScript.UTF8String;
    [self sendFrame:BLINKD_FRAME_EXEC payload:es length:strlen(es)];
  }
  [self sendResize];

  BOOL rawWas = [_device rawMode];
  [_device setRawMode:YES];

  [self pollLoop];

  [_device setRawMode:rawWas];
  if (_sock >= 0) {
    close(_sock);
    _sock = -1;
  }
  fprintf(_stream.out, "\r\nblinkd: connection closed\r\n");
  return 0;
}

- (int)connectTo:(const char *)host port:(int)port
{
  char strport[16];
  snprintf(strport, sizeof strport, "%d", port);
  struct addrinfo hints, *res, *ai;
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host, strport, &hints, &res) != 0) {
    fprintf(_stream.out, "blinkd: could not resolve %s\r\n", host);
    return -1;
  }
  int sock = -1;
  for (ai = res; ai; ai = ai->ai_next) {
    if (ai->ai_family != AF_INET && ai->ai_family != AF_INET6) {
      continue;
    }
    sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (sock < 0) {
      continue;
    }
    fcntl(sock, F_SETFL, O_NONBLOCK);
    int r = connect(sock, ai->ai_addr, ai->ai_addrlen);
    if (r < 0 && errno == EINPROGRESS) {
      struct pollfd p = { .fd = sock, .events = POLLOUT };
      if (poll(&p, 1, 8000) > 0) {
        int soerr = 0;
        socklen_t slen = sizeof soerr;
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &soerr, &slen);
        if (soerr == 0) {
          break; // connected
        }
      }
    } else if (r == 0) {
      break; // connected immediately
    }
    close(sock);
    sock = -1;
  }
  freeaddrinfo(res);
  if (sock < 0) {
    fprintf(_stream.out, "blinkd: connect to %s port %d failed\r\n", host, port);
    return -1;
  }
  fprintf(_stream.out, "blinkd: connected to %s:%d\r\n", host, port);
  return sock;
}

// 帧发送(poll 线程发 0x02,主线程 sigwinch 发 0x03,加锁防交叉)
- (void)sendFrame:(uint8_t)type payload:(const void *)p length:(size_t)len
{
  if (_sock < 0 || len > 0xffff) {
    return;
  }
  uint8_t hdr[3] = { type, (uint8_t)(len >> 8), (uint8_t)(len & 0xff) };
  @synchronized (self) {
    [self writeAll:hdr length:3];
    if (len > 0) {
      [self writeAll:p length:len];
    }
  }
}

- (void)sendResize
{
  if (_sock < 0 || !_device) {
    return;
  }
  uint16_t rows = (uint16_t)_device->win.ws_row;
  uint16_t cols = (uint16_t)_device->win.ws_col;
  uint8_t f[5] = { BLINKD_FRAME_RESIZE,
                   (uint8_t)(rows >> 8), (uint8_t)(rows & 0xff),
                   (uint8_t)(cols >> 8), (uint8_t)(cols & 0xff) };
  @synchronized (self) {
    [self writeAll:f length:5];
  }
}

// 非阻塞 sock 上把 len 字节写完(EAGAIN 时 poll 等可写)
- (void)writeAll:(const void *)buf length:(size_t)len
{
  const uint8_t *p = buf;
  size_t off = 0;
  while (off < len && _sock >= 0) {
    ssize_t n = write(_sock, p + off, len - off);
    if (n > 0) {
      off += n;
    } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      struct pollfd w = { .fd = _sock, .events = POLLOUT };
      poll(&w, 1, 5000);
    } else if (n < 0 && errno != EINTR) {
      return;
    }
  }
}

- (void)pollLoop
{
  int infd = fileno(_stream.in);
  fcntl(infd, F_SETFL, fcntl(infd, F_GETFL) | O_NONBLOCK);

  struct pollfd pfds[2];
  pfds[0].fd = _sock;
  pfds[0].events = POLLIN;
  pfds[1].fd = infd;
  pfds[1].events = POLLIN;

  char buf[BUFSIZ];
  while (1) {
    pfds[0].revents = 0;
    pfds[1].revents = 0;
    int rc = poll(pfds, 2, 15000);
    if (rc < 0 && errno != EINTR) {
      break;
    }

    // daemon → 终端渲染
    if (pfds[0].revents & (POLLIN | POLLHUP)) {
      ssize_t n;
      while ((n = read(_sock, buf, sizeof buf)) > 0) {
        fwrite(buf, n, 1, _stream.out);
      }
      if (n == 0) {
        break; // daemon 关闭
      }
      if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        break;
      }
    }
    if (pfds[0].revents & (POLLERR | POLLNVAL)) {
      break;
    }

    // 键盘输入 → daemon
    if (pfds[1].revents & POLLIN) {
      ssize_t n = read(infd, buf, sizeof buf);
      if (n > 0) {
        [self sendFrame:BLINKD_FRAME_DATA payload:buf length:n];
      } else if (n == 0) {
        break; // stream 关闭(kill)
      }
    }
    if (pfds[1].revents & (POLLHUP | POLLERR | POLLNVAL)) {
      break; // kill 里 fclose 后 fd 失效
    }
    if (!_stream.in || feof(_stream.in)) {
      break;
    }
  }
}

- (void)sigwinch
{
  [self sendResize];
}

- (void)kill
{
  if (_sock >= 0) {
    shutdown(_sock, SHUT_RDWR);
  }
  if (_stream.in) {
    fclose(_stream.in);
  }
}

@end
