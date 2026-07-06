////////////////////////////////////////////////////////////////////////////////
//
// blinkd — 连接 Mac 端 blinkd daemon 的原始 TCP 会话(不走 SSH)。
// 骨架照抄 SSHSession 的「socket + poll 双向桥」,去掉 libssh2:
//   sock 可读 → fwrite(_stream.out) 渲染;_stream.in 可读 → 0x02 帧发 daemon;
//   sigwinch → 0x03 resize 帧;kill → fclose(_stream.in) 唤醒 poll 退出。
//
////////////////////////////////////////////////////////////////////////////////

#import "BlinkdSession.h"

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

static const char *usage_format = "Usage: blinkd host port token";

@implementation BlinkdSession {
  int _sock;
}

- (int)main:(int)argc argv:(char **)argv
{
  if (argc != 4) {
    fprintf(_stream.out, "%s\r\n", usage_format);
    return -1;
  }
  const char *host = argv[1];
  int port = atoi(argv[2]);
  const char *token = argv[3];
  if (port <= 0 || port > 65535) {
    fprintf(_stream.out, "blinkd: bad port %s\r\n", argv[2]);
    return -1;
  }

  // 解析 + 非阻塞 connect(8s 超时,tailscale IP 不通时不至于挂死)
  _sock = [self connectTo:host port:port];
  if (_sock < 0) {
    return -1;
  }

  // 握手:token,再上报当前窗口尺寸
  [self sendFrame:BLINKD_FRAME_AUTH payload:token length:strlen(token)];
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
