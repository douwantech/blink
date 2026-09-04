// watchrelay — 腕上助手的真数据后端(第一阶段:轮询版)。
//
// 职责:
//  1. watcher: 定时扫 tmux 里的 cc-* 会话,capture-pane 判定"这个 tab 是不是在等你",
//     从 claude 状态行抽 员工/项目/分支,从输入框上方抽最后一段助手输出当卡点。
//  2. HTTP API(表用 URLSession 访问,token 鉴权):
//       GET  /queue           → 当前在等你的标签列表(JSON)
//       POST /reply {id,text} → 把 text 真打回对应 tmux 会话(send-keys + Enter)
//       GET  /health          → ok
//  3. 对外暴露:默认走 tsnet Funnel(公网 https,表走蜂窝也能连);
//     -plain 模式起裸 HTTP 供本地/局域网自测。
//
// 判定"在等你"(启发式,先跑通再调):
//   - 忙:pane 里有 `esc to interrupt`,或结尾是活动 spinner(…ing… (Xs)/进度条) → 跳过
//   - 否则:有 claude 状态行(👾…💼…) + 空 ❯ 输入框 → 判为在等你
package main

import (
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"tailscale.com/tsnet"
)

// ttsVoice 由 -voice 指定,默认微软自然女声。
var ttsVoice = "zh-CN-XiaoxiaoNeural"

// genAudio 用 edge-tts 把文本合成 mp3,按 voice+text 哈希缓存,返回文件路径。
func genAudio(text string) (string, error) {
	dir := filepath.Join(os.TempDir(), "blinkwatch-tts")
	_ = os.MkdirAll(dir, 0o755)
	sum := sha1.Sum([]byte(ttsVoice + "\x00" + text))
	path := filepath.Join(dir, hex.EncodeToString(sum[:])+".mp3")
	if fi, err := os.Stat(path); err == nil && fi.Size() > 0 {
		return path, nil
	}
	cmd := exec.Command("python3", "-m", "edge_tts", "--voice", ttsVoice, "--text", text, "--write-media", path)
	cmd.Env = append(os.Environ(), "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"+os.Getenv("PATH"))
	if out, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("edge-tts: %v (%s)", err, strings.TrimSpace(string(out)))
	}
	return path, nil
}

func speakTextFor(sid string) string {
	mu.RLock()
	defer mu.RUnlock()
	for _, it := range queue {
		if it.ID == sid {
			return it.Speak
		}
	}
	return ""
}

// Item 一条"标签在等你"。id = tmux 会话名(稳定,一会话至多一条)。
type Item struct {
	ID     string   `json:"id"`
	Emp    string   `json:"emp"`
	Proj   string   `json:"proj"`
	Branch string   `json:"branch"`
	Head   string   `json:"head"`
	Body   string   `json:"body"`
	Speak  string   `json:"speak"`
	Chips  []string `json:"chips"`
	Urgent bool     `json:"urgent"`
	TS     int64    `json:"ts"`
}

var (
	mu    sync.RWMutex
	queue []Item
)

func tmuxBin() string {
	for _, p := range []string{"/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "tmux"} {
		if _, err := exec.LookPath(p); err == nil {
			return p
		}
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return "tmux"
}

func tmux(args ...string) (string, error) {
	cmd := exec.Command(tmuxBin(), args...)
	cmd.Env = append(os.Environ(), "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
	out, err := cmd.CombinedOutput()
	return string(out), err
}

var (
	reEmp    = regexp.MustCompile(`👾\s*([^\s🧠💼🌿]+)`)
	reProj   = regexp.MustCompile(`💼\s*([^\s🧠👾🌿]+)`)
	reBranch = regexp.MustCompile(`🌿\s*([^\s🧠👾💼]+)`)
	// 输入框上下的长横线分隔条(含会话名的那条 or 纯横线)
	reSep     = regexp.MustCompile(`^[─—]{6,}`)
	reBusy = regexp.MustCompile(`esc to interrupt`)
	// 活动行:带进行时省略号 + 计时器 `(12s` / `(1m 2s`。用于判"忙"(需再排除已完成的 done 行)。
	reActive = regexp.MustCompile(`(…|\.\.\.).*\(\d+m?\s?\d*s`)
	reErr     = regexp.MustCompile(`(?i)error|失败|报错|签名错误|overloaded|529|errSec`)
)

func firstGroup(re *regexp.Regexp, s string) string {
	m := re.FindStringSubmatch(s)
	if len(m) > 1 {
		return strings.TrimSpace(m[1])
	}
	return ""
}

// scanSession 判定单个 cc-* 会话是否在等你,返回 (item, waiting)。
func scanSession(name string) (Item, bool) {
	out, err := tmux("capture-pane", "-t", name, "-p", "-S", "-60")
	if err != nil {
		return Item{}, false
	}
	lines := strings.Split(out, "\n")

	// 状态行(取最后一次出现的 👾 行)
	statusLine := ""
	for _, ln := range lines {
		if strings.Contains(ln, "👾") {
			statusLine = ln
		}
	}
	if statusLine == "" {
		return Item{}, false // 不是 claude tab,跳过
	}

	// 尾部若在活动 → 忙,不打扰
	tailN := lines
	if len(tailN) > 12 {
		tailN = tailN[len(tailN)-12:]
	}
	tail := strings.Join(tailN, "\n")
	if reBusy.MatchString(tail) {
		return Item{}, false
	}
	// 活动 spinner 行(有计时器且非 done)= 正在干活,不打扰
	for _, ln := range tailN {
		if reActive.MatchString(ln) && !strings.Contains(ln, "done") {
			return Item{}, false
		}
	}

	emp := firstGroup(reEmp, statusLine)
	proj := firstGroup(reProj, statusLine)
	branch := firstGroup(reBranch, statusLine)
	// 兜底:从会话名 cc-<emp>-<proj> 补
	if emp == "" || proj == "" {
		rest := strings.TrimPrefix(name, "cc-")
		if i := strings.Index(rest, "-"); i > 0 {
			if emp == "" {
				emp = rest[:i]
			}
			if proj == "" {
				proj = rest[i+1:]
			}
		}
	}

	// 卡点内容:找输入框顶端分隔条,取其上方最后几行"实内容"
	sepIdx := -1
	for i := len(lines) - 1; i >= 0; i-- {
		if reSep.MatchString(strings.TrimSpace(lines[i])) {
			sepIdx = i
			break
		}
	}
	var content []string
	upper := sepIdx
	if upper < 0 {
		upper = len(lines)
	}
	for i := upper - 1; i >= 0 && len(content) < 6; i-- {
		t := strings.TrimSpace(lines[i])
		if t == "" || strings.Contains(t, "👾") || strings.HasPrefix(t, "CTX") ||
			strings.HasPrefix(t, "⏵⏵") || strings.HasPrefix(t, "/") ||
			strings.HasPrefix(t, "✻") || strings.HasPrefix(t, "✳") || strings.HasPrefix(t, "✢") ||
			strings.HasPrefix(t, "❯") || strings.HasPrefix(t, "⏺") ||
			strings.HasPrefix(t, "📁") || strings.HasPrefix(t, "🌿") || strings.HasPrefix(t, "📋") ||
			strings.HasPrefix(t, "---") || strings.HasPrefix(t, "Ran ") ||
			reSep.MatchString(t) {
			continue
		}
		content = append([]string{t}, content...)
	}
	body := strings.Join(content, " ")
	body = strings.TrimSpace(body)
	if len([]rune(body)) > 90 {
		body = string([]rune(body)[:90]) + "…"
	}
	if body == "" {
		body = "刚忙完,在等你下一步。"
	}

	urgent := reErr.MatchString(tail) || reErr.MatchString(body)
	head := "【" + proj + "】"
	if branch != "" {
		head = "【" + proj + " · " + branch + "】"
	}
	brief := body
	if len([]rune(brief)) > 40 {
		brief = string([]rune(brief)[:40]) + "…"
	}
	speak := fmt.Sprintf("%s 在 %s 等你拍板。%s", strings.Title(emp), proj, brief)
	if urgent {
		speak = fmt.Sprintf("%s 那边有点急。%s 里%s", strings.Title(emp), proj, brief)
	}

	return Item{
		ID: name, Emp: emp, Proj: proj, Branch: branch,
		Head: head, Body: body, Speak: speak,
		Chips:  []string{"继续", "先停一下,等我细说", "跑一下看看"},
		Urgent: urgent, TS: time.Now().Unix(),
	}, true
}

func scanLoop(interval time.Duration) {
	for {
		out, err := tmux("list-sessions", "-F", "#{session_name}")
		if err == nil {
			var items []Item
			for _, name := range strings.Split(out, "\n") {
				name = strings.TrimSpace(name)
				if !strings.HasPrefix(name, "cc-") {
					continue
				}
				if it, ok := scanSession(name); ok {
					items = append(items, it)
				}
			}
			mu.Lock()
			queue = items
			mu.Unlock()
			log.Printf("scan: %d tab(s) waiting", len(items))
		} else {
			log.Printf("tmux list-sessions: %v (%s)", err, strings.TrimSpace(out))
		}
		time.Sleep(interval)
	}
}

// pushLoop:把当前扫描到的队列 POST 到云中继,执行云带回的回复(tmux send-keys)。
func pushLoop(cloud, token string, interval time.Duration) {
	client := &http.Client{Timeout: 15 * time.Second}
	url := strings.TrimRight(cloud, "/") + "/push?token=" + token
	for {
		mu.RLock()
		items := queue
		mu.RUnlock()
		if items == nil {
			items = []Item{}
		}
		payload, _ := json.Marshal(map[string]any{"items": items})
		resp, err := client.Post(url, "application/json", bytes.NewReader(payload))
		if err != nil {
			log.Printf("push: %v", err)
			time.Sleep(interval)
			continue
		}
		var out struct {
			Replies []struct {
				ID   string `json:"id"`
				Text string `json:"text"`
			} `json:"replies"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&out)
		resp.Body.Close()
		for _, rp := range out.Replies {
			if err := sendReply(rp.ID, rp.Text); err != nil {
				log.Printf("exec reply %s: %v", rp.ID, err)
			} else {
				log.Printf("executed reply → %s: %s", rp.ID, rp.Text)
			}
		}
		time.Sleep(interval)
	}
}

func sendReply(id, text string) error {
	// 打字面文字,再单独发 Enter,避免特殊键被解释
	if _, err := tmux("send-keys", "-t", id, "-l", text); err != nil {
		return err
	}
	_, err := tmux("send-keys", "-t", id, "Enter")
	return err
}

func main() {
	var (
		token    = flag.String("token", "", "auth token (必填)")
		interval = flag.Duration("interval", 4*time.Second, "扫描间隔")
		plain    = flag.String("plain", "", "裸 HTTP 监听地址(如 127.0.0.1:8899);留空则走 tsnet Funnel")
		push     = flag.String("push", "", "云中继地址(如 https://xxx.fcapp.run);设了就走 push 模式,只推不监听")
		hostname = flag.String("hostname", "blink-watch", "tsnet 节点名")
		stateDir = flag.String("state", "", "tsnet state dir(默认 ~/.config/blink-watch/tsnet)")
		voice    = flag.String("voice", "zh-CN-XiaoxiaoNeural", "edge-tts 语音")
	)
	flag.Parse()
	if *token == "" {
		log.Fatal("必须 -token")
	}
	ttsVoice = *voice

	go scanLoop(*interval)

	// push 模式:推到云中继,不本地监听
	if *push != "" {
		log.Printf("watchrelay (push) → %s  interval=%s", *push, *interval)
		pushLoop(*push, *token, *interval)
		return
	}

	mux := http.NewServeMux()
	logmw := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			log.Printf("HTTP %s %s from %s ua=%q", r.Method, r.URL.Path, r.RemoteAddr, r.UserAgent())
			h(w, r)
		}
	}
	auth := func(r *http.Request) bool {
		t := r.Header.Get("X-Token")
		if t == "" {
			t = r.URL.Query().Get("token")
		}
		return t == *token
	}
	mux.HandleFunc("/health", logmw(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	}))
	mux.HandleFunc("/queue", logmw(func(w http.ResponseWriter, r *http.Request) {
		if !auth(r) {
			http.Error(w, "unauthorized", 401)
			return
		}
		mu.RLock()
		items := queue
		mu.RUnlock()
		if items == nil {
			items = []Item{}
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		json.NewEncoder(w).Encode(map[string]any{"items": items})
	}))
	mux.HandleFunc("/audio", logmw(func(w http.ResponseWriter, r *http.Request) {
		if !auth(r) {
			http.Error(w, "unauthorized", 401)
			return
		}
		text := r.URL.Query().Get("text")
		if text == "" {
			text = speakTextFor(r.URL.Query().Get("id"))
		}
		if text == "" {
			http.Error(w, "no text", 404)
			return
		}
		path, err := genAudio(text)
		if err != nil {
			log.Printf("audio: %v", err)
			http.Error(w, "tts failed", 500)
			return
		}
		w.Header().Set("Content-Type", "audio/mpeg")
		w.Header().Set("Cache-Control", "public, max-age=86400")
		http.ServeFile(w, r, path)
	}))

	mux.HandleFunc("/reply", logmw(func(w http.ResponseWriter, r *http.Request) {
		if !auth(r) {
			http.Error(w, "unauthorized", 401)
			return
		}
		var body struct {
			ID   string `json:"id"`
			Text string `json:"text"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.ID == "" {
			http.Error(w, "bad request", 400)
			return
		}
		if err := sendReply(body.ID, body.Text); err != nil {
			log.Printf("reply %s: %v", body.ID, err)
			http.Error(w, "send failed", 500)
			return
		}
		log.Printf("reply → %s: %s", body.ID, body.Text)
		// 立即从队列移除(下次扫会重建真实状态)
		mu.Lock()
		var nq []Item
		for _, it := range queue {
			if it.ID != body.ID {
				nq = append(nq, it)
			}
		}
		queue = nq
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintln(w, `{"ok":true}`)
	}))

	// 顶层路由:同时认根路径和 /w 前缀(funnel 挂 443 子路径时用,无论 tailscale 剥不剥前缀都能命中)
	root := http.NewServeMux()
	root.Handle("/w/", http.StripPrefix("/w", mux))
	root.Handle("/", mux)

	if *plain != "" {
		log.Printf("watchrelay (plain) on http://%s  token=%s", *plain, *token)
		ln, err := net.Listen("tcp", *plain)
		if err != nil {
			log.Fatal(err)
		}
		log.Fatal(http.Serve(ln, root))
	}

	dir := *stateDir
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = home + "/.config/blink-watch/tsnet"
	}
	_ = os.MkdirAll(dir, 0o700)
	srv := &tsnet.Server{Hostname: *hostname, Dir: dir}
	ln, err := srv.ListenFunnel("tcp", ":443")
	if err != nil {
		log.Fatal("ListenFunnel(需 tailnet 开启 Funnel 权限): ", err)
	}
	st, _ := srv.Up(nil)
	if st != nil && len(st.CertDomains) > 0 {
		log.Printf("watchrelay (funnel) https://%s/  token=%s", st.CertDomains[0], *token)
	} else {
		log.Printf("watchrelay (funnel) up on :443  token=%s", *token)
	}
	log.Fatal(http.Serve(ln, mux))
}
