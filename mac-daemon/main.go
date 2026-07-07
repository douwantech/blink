// blinkd — Blink 的 Mac 端常驻终端 daemon(替代 SSH 链路)。
//
// 架构:手机 Blink ←(raw TCP / tailscale tsnet)→ blinkd ←PTY→ shell/tmux/claude
//   - 一连接一 PTY:每个 tab 一条连接、一个独立 PTY,互不干扰(替代 ssh 一连接一会话)
//   - 握手带命令:客户端 auth 后可发 exec 帧指定这条连接跑什么(比如
//     `tmux new -A -s cc-<tab> …`),daemon fork PTY 跑它;不发则跑默认 -cmd
//     (向后兼容手动 `blinkd <host> <port> <token>` 连一个 shell)
//   - 保活:靠远端 tmux(自动 tab 跑 tmux new -A -s,连接断 → PTY SIGHUP →
//     tmux detach,会话在 mac 上继续,重连再 attach 回去)——和 SSH+tmux 一样
//   - token 握手:第一帧必须是 token,防 tailnet/局域网内他人乱连
//   - tsnet 模式:daemon 自己作为独立 tailscale 节点监听,绕过 MDM
//     防火墙对 LAN 入站的封锁
//
// 协议(client→server,BigEndian):
//   0x01 | u16 len | token       握手,必须第一帧
//   0x04 | u16 len | cmdline      指定这条连接跑的命令(auth 后,PTY 起之前;可选)
//   0x02 | u16 len | bytes        终端输入(键盘)
//   0x03 | u16 rows | u16 cols    窗口 resize
// server→client:裸 PTY 字节流,无帧。
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

const (
	frameAuth   = 0x01
	frameData   = 0x02
	frameResize = 0x03
	frameExec   = 0x04
)

// conn 是一条客户端连接 + 它专属的 PTY。PTY 懒启动:
// 第一个 exec 帧决定跑什么命令;若在 exec 前先来 input/resize,则用默认 shell 起 PTY。
type conn struct {
	nc     net.Conn
	defCmd string
	mu     sync.Mutex
	ptmx   *os.File
	rows   uint16
	cols   uint16
}

func handleConn(nc net.Conn, token, defCmd string) {
	defer nc.Close()
	co := &conn{nc: nc, defCmd: defCmd, rows: 24, cols: 80}
	defer co.closePTY()

	authed := false
	hdr := make([]byte, 1)
	for {
		if _, err := io.ReadFull(nc, hdr); err != nil {
			return
		}
		switch hdr[0] {
		case frameAuth:
			p, err := readLenPrefixed(nc)
			if err != nil {
				return
			}
			if subtle.ConstantTimeCompare(p, []byte(token)) != 1 {
				log.Printf("auth FAIL from %s", nc.RemoteAddr())
				return
			}
			authed = true

		case frameExec:
			p, err := readLenPrefixed(nc)
			if err != nil {
				return
			}
			if !authed {
				return
			}
			// 指定命令起 PTY(一条连接只起一次;重复 exec 忽略)
			co.startPTY("/bin/bash", []string{"-c", string(p)})

		case frameData:
			p, err := readLenPrefixed(nc)
			if err != nil {
				return
			}
			if !authed {
				return
			}
			// 没 exec 就先来输入 → 用默认 shell 起 PTY(手动 blinkd 场景)
			co.startPTY(co.defCmd, nil)
			co.writePTY(p)

		case frameResize:
			var dims [4]byte
			if _, err := io.ReadFull(nc, dims[:]); err != nil {
				return
			}
			if !authed {
				return
			}
			co.resize(binary.BigEndian.Uint16(dims[0:2]), binary.BigEndian.Uint16(dims[2:4]))

		default:
			log.Printf("bad frame 0x%02x from %s", hdr[0], nc.RemoteAddr())
			return
		}
	}
}

// startPTY 懒启动这条连接的 PTY(已启动则忽略)。PTY 输出 → 写回 conn;
// shell/命令退出 → 关连接(客户端回到 Blink 命令行)。
func (co *conn) startPTY(name string, args []string) {
	co.mu.Lock()
	if co.ptmx != nil {
		co.mu.Unlock()
		return
	}
	cmd := exec.Command(name, args...)
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "LANG=en_US.UTF-8")
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: co.rows, Cols: co.cols})
	if err != nil {
		co.mu.Unlock()
		log.Printf("pty start %s %v: %v", name, args, err)
		co.nc.Close()
		return
	}
	co.ptmx = ptmx
	co.mu.Unlock()
	log.Printf("pty started for %s: %s (pid %d)", co.nc.RemoteAddr(), name, cmd.Process.Pid)

	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := ptmx.Read(buf)
			if n > 0 {
				if _, werr := co.nc.Write(buf[:n]); werr != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		// 命令退出(用户 exit / tmux detach 后 shell 结束):关连接,客户端回 blink 命令行。
		// 远端 tmux 会话不受影响(仍在 mac 上跑,重连再 attach)。
		co.nc.Close()
	}()
}

func (co *conn) writePTY(p []byte) {
	co.mu.Lock()
	ptmx := co.ptmx
	co.mu.Unlock()
	if ptmx != nil {
		_, _ = ptmx.Write(p)
	}
}

func (co *conn) resize(rows, cols uint16) {
	co.mu.Lock()
	co.rows, co.cols = rows, cols
	ptmx := co.ptmx
	co.mu.Unlock()
	if ptmx != nil {
		_ = pty.Setsize(ptmx, &pty.Winsize{Rows: rows, Cols: cols})
	}
}

func (co *conn) closePTY() {
	co.mu.Lock()
	ptmx := co.ptmx
	co.ptmx = nil
	co.mu.Unlock()
	if ptmx != nil {
		_ = ptmx.Close() // SIGHUP → 远端 tmux detach,会话保留
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
		cmdline  = flag.String("cmd", "/bin/zsh", "default command when a connection sends no exec frame")
	)
	flag.Parse()

	if *token == "" {
		b := make([]byte, 16)
		if _, err := rand.Read(b); err != nil {
			log.Fatal(err)
		}
		*token = hex.EncodeToString(b)
	}

	var ln net.Listener
	var err error
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

	log.Printf("blinkd ready on %s | token=%s | default cmd=%s", ln.Addr(), *token, *cmdline)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go handleConn(c, *token, *cmdline)
	}
}
