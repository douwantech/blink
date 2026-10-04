#!/usr/bin/env python3
"""blinkd-pull — blinkd daemon 的最小 Python 客户端。

认证后把命令敲进 PTY，收完输出退出。适合脚本化取数 / 巡检，
不需要交互终端（交互用 Blink App 的 blinkd 命令）。

用法:
  ./blinkd-pull.py <host> <port> <token> '<命令>' [读秒=10]

协议(mac-daemon/main.go, BigEndian):
  0x01 | u16 len | token   握手,必须第一帧
  0x02 | u16 len | bytes   终端输入
  0x03 | u16 rows | u16 cols  窗口 resize
  0x04 | u16 len | cmdline    exec 指定命令(新版 daemon)
  server -> client: 裸 PTY 字节流

注意:
  - 2026-10 实测线上 daemon 为老版本,0x03/0x04 帧一发即被重置,
    本客户端只发 0x01 + 0x02。
  - PTY 里跑 zsh:标记别用以 = 开头的词(zsh 的 =word 路径展开会吃掉)。
  - 远端 shell 的 PATH 未必完整(如 Homebrew tmux 在 /usr/local/bin),
    命令尽量用绝对路径。
"""
import re
import socket
import struct
import sys
import time

HOST, PORT, TOKEN, CMD = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
WAIT = float(sys.argv[5]) if len(sys.argv) > 5 else 10


def frame(kind: int, payload: bytes) -> bytes:
    return bytes([kind]) + struct.pack('>H', len(payload)) + payload


def main() -> None:
    s = socket.create_connection((HOST, PORT), timeout=10)
    s.sendall(frame(0x01, TOKEN.encode()))
    time.sleep(1)  # 等握手完成再敲键,老 daemon 抢跑会被重置
    s.sendall(frame(0x02, CMD.encode() + b'\n'))
    s.settimeout(2)
    out, deadline = b'', time.time() + WAIT
    while time.time() < deadline:
        try:
            chunk = s.recv(65536)
            if not chunk:
                break
            out += chunk
        except socket.timeout:
            pass
        except ConnectionResetError:
            break
    s.close()
    text = out.decode('utf-8', errors='replace')
    text = re.sub(r'\x1b\][^\x07]*\x07', '', text)      # OSC 标题
    text = re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]', '', text)  # CSI 序列
    sys.stdout.write(text)


if __name__ == '__main__':
    main()
