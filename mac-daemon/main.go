// blinkd — Blink 的 Mac 端常驻终端 daemon(替代 SSH 链路)。
//
// 架构:手机 Blink ←(raw TCP / tailscale tsnet)→ blinkd ←PTY→ shell/claude
//   - PTY 常驻:手机断开、锁屏、杀 app,shell 照跑(替代 tmux 保活)
//   - 重连回放:保留最近 256KB 输出,attach 时先回放,画面立刻恢复
//   - token 握手:第一帧必须是 token,防 tailnet/局域网内他人乱连
//   - tsnet 模式:daemon 自己作为独立 tailscale 节点监听,绕过 MDM
//     防火墙对 LAN 入站的封锁(与 cmux-bridge 相同思路,已验证可行)
//
// 协议(client→server,BigEndian):
//   0x01 | u16 len | token       握手,必须是第一帧
//   0x02 | u16 len | bytes       终端输入(键盘)
//   0x03 | u16 rows | u16 cols   窗口 resize
// server→client:裸 PTY 字节流,无帧(attach 时先回放 ring buffer)。
package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"sync"

	"github.com/creack/pty"
	"tailscale.com/tsnet"
)

const ringCap = 256 * 1024

const (
	frameAuth   = 0x01
	frameData   = 0x02
	frameResize = 0x03
)

// session 是一个常驻 PTY。客户端来去自由,shell 一直活着。
type session struct {
	mu      sync.Mutex
	ptmx    *os.File
	ring    []byte
	clients map[net.Conn]struct{}
	cmdline string
	rows    uint16
	cols    uint16
}

func newSession(cmdline string) (*session, error) {
	s := &session{
		clients: make(map[net.Conn]struct{}),
		cmdline: cmdline,
		rows:    24, cols: 80,
	}
	if err := s.startShell(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *session) startShell() error {
	cmd := exec.Command(s.cmdline)
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "LANG=en_US.UTF-8")
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: s.rows, Cols: s.cols})
	if err != nil {
		return fmt.Errorf("pty start %s: %w", s.cmdline, err)
	}
	s.ptmx = ptmx
	go s.readLoop(ptmx)
	log.Printf("shell started: %s (pid %d)", s.cmdline, cmd.Process.Pid)
	return nil
}

// readLoop: PTY 输出 → ring buffer + 广播给所有在线客户端。
// shell 退出后自动重启,daemon 永不因此而死。
func (s *session) readLoop(ptmx *os.File) {
	buf := make([]byte, 32*1024)
	for {
		n, err := ptmx.Read(buf)
		if n > 0 {
			s.broadcast(buf[:n])
		}
		if err != nil {
			break
		}
	}
	// shell 退出(用户 exit / 崩溃):断开所有客户端,让它们回到 Blink 命令行,
	// 再起一个新 shell 备着下次连接。
	// 关键:PTY 保活靠的是「客户端断开时不杀 shell」(broadcast 只删连接、
	// 不动 ptmx),不是靠这里重启 —— 所以用户 exit 能真正结束会话,而不是被
	// 粘在一个重启循环里退不出来。
	s.mu.Lock()
	if s.ptmx != ptmx {
		s.mu.Unlock()
		return
	}
	for c := range s.clients {
		c.Close()
		delete(s.clients, c)
	}
	s.ring = nil // 新 shell 不带旧 shell 的历史
	if err := s.startShell(); err != nil {
		log.Printf("shell restart failed: %v", err)
	}
	s.mu.Unlock()
}

func (s *session) broadcast(p []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ring = append(s.ring, p...)
	if over := len(s.ring) - ringCap; over > 0 {
		s.ring = s.ring[over:]
	}
	for c := range s.clients {
		if _, err := c.Write(p); err != nil {
			delete(s.clients, c)
			c.Close()
		}
	}
}

// attach: 先回放历史(画面恢复),再进入实时流。
func (s *session) attach(c net.Conn) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.ring) > 0 {
		_, _ = c.Write(s.ring)
	}
	s.clients[c] = struct{}{}
	log.Printf("client attached: %s (%d online)", c.RemoteAddr(), len(s.clients))
}

func (s *session) detach(c net.Conn) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.clients[c]; ok {
		delete(s.clients, c)
		log.Printf("client detached: %s (%d online)", c.RemoteAddr(), len(s.clients))
	}
}

func (s *session) input(p []byte) {
	s.mu.Lock()
	ptmx := s.ptmx
	s.mu.Unlock()
	if ptmx != nil {
		_, _ = ptmx.Write(p)
	}
}

func (s *session) resize(rows, cols uint16) {
	s.mu.Lock()
	s.rows, s.cols = rows, cols
	ptmx := s.ptmx
	s.mu.Unlock()
	if ptmx != nil {
		_ = pty.Setsize(ptmx, &pty.Winsize{Rows: rows, Cols: cols})
	}
}

// ---- 连接处理 ----

func handleConn(c net.Conn, token string, s *session) {
	defer c.Close()
	defer s.detach(c)

	authed := false
	hdr := make([]byte, 1)
	for {
		if _, err := io.ReadFull(c, hdr); err != nil {
			return
		}
		switch hdr[0] {
		case frameAuth:
			p, err := readLenPrefixed(c)
			if err != nil {
				return
			}
			if subtle.ConstantTimeCompare(p, []byte(token)) != 1 {
				log.Printf("auth FAIL from %s", c.RemoteAddr())
				return
			}
			authed = true
			s.attach(c)
		case frameData:
			p, err := readLenPrefixed(c)
			if err != nil {
				return
			}
			if !authed {
				return
			}
			s.input(p)
		case frameResize:
			var dims [4]byte
			if _, err := io.ReadFull(c, dims[:]); err != nil {
				return
			}
			if !authed {
				return
			}
			s.resize(binary.BigEndian.Uint16(dims[0:2]), binary.BigEndian.Uint16(dims[2:4]))
		default:
			log.Printf("bad frame 0x%02x from %s", hdr[0], c.RemoteAddr())
			return
		}
	}
}

func readLenPrefixed(r io.Reader) ([]byte, error) {
	var lb [2]byte
	if _, err := io.ReadFull(r, lb[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint16(lb[:])
	p := make([]byte, n)
	if _, err := io.ReadFull(r, p); err != nil {
		return nil, err
	}
	return p, nil
}

func main() {
	var (
		port     = flag.Int("port", 7777, "listen port")
		bind     = flag.String("bind", "127.0.0.1", "bind address (plain TCP mode)")
		token    = flag.String("token", "", "auth token (empty = generate & print)")
		useTsnet = flag.Bool("tsnet", false, "listen as an independent tailscale node (bypasses MDM firewall)")
		hostname = flag.String("hostname", "blinkd", "tsnet node hostname")
		stateDir = flag.String("state", "", "tsnet state dir (default ~/.config/blinkd/tsnet)")
		cmdline  = flag.String("cmd", "/bin/zsh", "command to run in the PTY")
	)
	flag.Parse()

	if *token == "" {
		b := make([]byte, 16)
		if _, err := rand.Read(b); err != nil {
			log.Fatal(err)
		}
		*token = hex.EncodeToString(b)
	}

	sess, err := newSession(*cmdline)
	if err != nil {
		log.Fatal(err)
	}

	var ln net.Listener
	if *useTsnet {
		dir := *stateDir
		if dir == "" {
			home, _ := os.UserHomeDir()
			dir = home + "/.config/blinkd/tsnet"
		}
		_ = os.MkdirAll(dir, 0o700)
		srv := &tsnet.Server{Hostname: *hostname, Dir: dir}
		ln, err = srv.Listen("tcp", fmt.Sprintf(":%d", *port))
		if err != nil {
			log.Fatal(err)
		}
		ip4, ip6 := srv.TailscaleIPs()
		log.Printf("tsnet listening: %s %s port %d", ip4, ip6, *port)
	} else {
		ln, err = net.Listen("tcp", fmt.Sprintf("%s:%d", *bind, *port))
		if err != nil {
			log.Fatal(err)
		}
	}

	log.Printf("blinkd ready on %s | token=%s | cmd=%s", ln.Addr(), *token, *cmdline)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go handleConn(c, *token, sess)
	}
}
