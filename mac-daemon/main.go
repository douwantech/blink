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
	"context"
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
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/libp2p/zeroconf/v2"
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

	// 必须 Wait 收尸:否则子进程退出后留 <defunct>,跑几天攒到 kern.maxprocperuid 上限,
	// 整台 Mac 起不了新进程(2026-09-15 事故:7174 个僵尸)。命令退出也顺手关连接。
	go func() {
		err := cmd.Wait()
		log.Printf("pty exited for %s: pid %d (%v)", co.nc.RemoteAddr(), cmd.Process.Pid, err)
		co.nc.Close()
	}()

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

// watchChildren 每分钟数一次自己名下的子进程 / 僵尸,超过阈值告警。
// 僵尸连续两轮都在(Wait 本该秒收)的,兜底用 wait4(WNOHANG) 直接收掉。
func watchChildren(limit int) {
	self := os.Getpid()
	prevZombies := map[int]bool{}
	for range time.Tick(time.Minute) {
		out, err := exec.Command("/bin/ps", "-axo", "pid=,ppid=,stat=").Output()
		if err != nil {
			log.Printf("child watch: ps: %v", err)
			continue
		}
		children, zombies := 0, map[int]bool{}
		for _, line := range strings.Split(string(out), "\n") {
			f := strings.Fields(line)
			if len(f) < 3 {
				continue
			}
			pid, _ := strconv.Atoi(f[0])
			ppid, _ := strconv.Atoi(f[1])
			if ppid != self {
				continue
			}
			children++
			if strings.HasPrefix(f[2], "Z") {
				zombies[pid] = true
			}
		}
		reaped := 0
		for pid := range zombies {
			if !prevZombies[pid] {
				continue
			}
			var ws syscall.WaitStatus
			if got, _ := syscall.Wait4(pid, &ws, syscall.WNOHANG, nil); got == pid {
				reaped++
				delete(zombies, pid)
			}
		}
		prevZombies = zombies
		if children > limit || len(zombies) > limit || reaped > 0 {
			log.Printf("child watch WARN: children=%d zombies=%d reaped=%d (limit %d)", children, len(zombies), reaped, limit)
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
		useLan   = flag.Bool("lan", true, "also listen on LAN (0.0.0.0) and advertise via Bonjour, so same-LAN clients connect directly without Tailscale")
		hostname = flag.String("hostname", "blinkd", "tsnet node hostname (also the Bonjour instance name)")
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

	// 双模式:可能同时开两个 listener —— tsnet(远程/绕 MDM/出门在外) + 纯 TCP(同一局域网直连,不经 Tailscale)。
	// 同网时客户端优先走 LAN 直连(更快、省电、不占 Tailscale),连不上再回落 tsnet;两个 listener 喂同一个 handleConn。
	var listeners []net.Listener
	var tsIP string

	if *useTsnet {
		dir := *stateDir
		if dir == "" {
			home, _ := os.UserHomeDir()
			dir = home + "/.config/blinkd/tsnet"
		}
		_ = os.MkdirAll(dir, 0o700)
		srv := &tsnet.Server{Hostname: *hostname, Dir: dir}
		// 先等 tsnet 真正上线(连上 tailnet 并分配到 IP),再 Listen ——
		// 否则 Listen 可能在 tsnet 没就绪时建立、监听无效,客户端 connect failed(之前 "invalid IP" bug)。
		if _, err := srv.Up(context.Background()); err != nil {
			log.Fatal("tsnet up: ", err)
		}
		ln, err := srv.Listen("tcp", fmt.Sprintf(":%d", *port))
		if err != nil {
			log.Fatal(err)
		}
		if ip4, _ := srv.TailscaleIPs(); ip4.IsValid() {
			tsIP = ip4.String()
		}
		log.Printf("tsnet ready: %s port %d", tsIP, *port)
		listeners = append(listeners, ln)
	}

	// LAN 纯 TCP:tsnet 模式下绑 0.0.0.0 让同网可达(否则同网也被迫走 tsnet);
	// 非 tsnet 模式沿用 --bind(默认 127.0.0.1),行为跟以前一致。
	if *useLan || !*useTsnet {
		bindAddr := *bind
		if *useTsnet {
			bindAddr = "0.0.0.0"
		}
		ln, err := net.Listen("tcp", fmt.Sprintf("%s:%d", bindAddr, *port))
		if err != nil {
			log.Fatal(err)
		}
		log.Printf("lan ready: %s", ln.Addr())
		listeners = append(listeners, ln)
		// Bonjour 广播(仅局域网):同网客户端 browse _blinkd._tcp 就能拿到当前 LAN IP,
		// DHCP 换 IP 也自动跟上,零配置。TXT 带 ts=<tailscaleIP> 让客户端把这条 LAN 记录
		// 对上它已配置的机器(按 Tailscale IP 匹配);token 不进 TXT(局域网明文,绝不广播密钥)。
		if *useLan {
			startBonjour(*hostname, *port, tsIP)
		}
	}

	log.Printf("blinkd ready | token=%s | default cmd=%s | listeners=%d", *token, *cmdline, len(listeners))
	go watchChildren(50)

	// 每个 listener 各跑一条 accept 循环,喂同一个 handleConn。某个 listener 挂了只记日志,
	// 不再 log.Fatal 拖垮整个进程(比如 LAN 网络切换导致 accept 出错,tsnet 那条还该继续)。
	for _, ln := range listeners {
		go func(l net.Listener) {
			for {
				c, err := l.Accept()
				if err != nil {
					log.Printf("accept on %s: %v", l.Addr(), err)
					return
				}
				go handleConn(c, *token, *cmdline)
			}
		}(ln)
	}
	select {} // 阻塞 main,让各 accept goroutine 长活
}

// startBonjour 在局域网用 mDNS/Bonjour 广播本 daemon,让同网客户端自动发现 LAN IP:port。
// 广播失败不致命(比如 5353 被占/无组播权限)——只记日志,客户端仍可走 tsnet 或手填。
func startBonjour(instance string, port int, tsIP string) {
	txt := []string{"v=1"}
	if tsIP != "" {
		txt = append(txt, "ts="+tsIP) // 客户端按此把 LAN 记录对上已配置机器(Tailscale IP 相同即同一台)
	}
	txt = append(txt, "host="+instance)
	server, err := zeroconf.Register(instance, "_blinkd._tcp", "local.", port, txt, nil)
	if err != nil {
		log.Printf("bonjour register failed (LAN 自动发现不可用,仍可走 tsnet): %v", err)
		return
	}
	// 持有 server 引用直到进程退出(GC 掉会停止广播)。daemon 常驻,不显式 Shutdown。
	bonjourServer = server
	log.Printf("bonjour advertised: _blinkd._tcp %q port %d ts=%s", instance, port, tsIP)
}

var bonjourServer *zeroconf.Server
