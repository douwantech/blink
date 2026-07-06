// testclient — blinkd 协议的最小验证客户端(E2E 用,模拟 Blink 端行为)。
// 用法: go run ./testclient -addr 127.0.0.1:7777 -token XXX [-send "echo hi\n"]
package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

func frame(t byte, p []byte) []byte {
	out := make([]byte, 3+len(p))
	out[0] = t
	binary.BigEndian.PutUint16(out[1:3], uint16(len(p)))
	copy(out[3:], p)
	return out
}

func main() {
	addr := flag.String("addr", "127.0.0.1:7777", "daemon address")
	token := flag.String("token", "", "auth token")
	send := flag.String("send", "echo E2E_BLINKD_OK\n", "input to send after attach")
	wait := flag.Duration("wait", 3*time.Second, "how long to read output")
	flag.Parse()

	c, err := net.DialTimeout("tcp", *addr, 5*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dial:", err)
		os.Exit(1)
	}
	defer c.Close()

	// 握手 + resize + 输入
	if _, err := c.Write(frame(0x01, []byte(*token))); err != nil {
		fmt.Fprintln(os.Stderr, "auth write:", err)
		os.Exit(1)
	}
	rs := []byte{0x03, 0, 24, 0, 80}
	_, _ = c.Write(rs)
	time.Sleep(300 * time.Millisecond) // 让 shell 启动提示先回放
	_, _ = c.Write(frame(0x02, []byte(*send)))

	// 读输出
	_ = c.SetReadDeadline(time.Now().Add(*wait))
	n, _ := io.Copy(os.Stdout, c)
	fmt.Fprintf(os.Stderr, "\n[testclient] read %d bytes\n", n)
}
