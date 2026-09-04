// cloudrelay — 腕上助手的云端瘦中继(部署到阿里云 FC)。
//
// 它不碰 tmux。数据两头对接:
//   - Mac 上的 watchrelay(-push 模式)定时 POST /push 上传"谁在等你"的快照,
//     响应里带回累积的回复,Mac 执行 tmux send-keys。
//   - 表 GET /queue 拿快照、POST /reply 提交决定。
//
// 端点(token 鉴权,token 走环境变量 RELAY_TOKEN):
//   GET  /health            → ok
//   GET  /queue?token=      → {"items":[...],"ts":n}   最新快照(Mac 推的原样透传)
//   POST /reply?token=      {"id","text"}              表提交决定 → 进回复缓冲
//   POST /push?token=       {"items":[...]}            Mac 上传快照 → 响应 {"replies":[...]} 并清空缓冲
//
// 注:FC 实例可能冷启回收,快照与回复缓冲存内存。Mac 每几秒重推快照,回复也几秒内被取走,
// 冷启窗口丢一条回复的概率很低;要绝对可靠再接持久层(暂不做)。
package main

import (
	"crypto/subtle"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

type Reply struct {
	ID   string `json:"id"`
	Text string `json:"text"`
}

var (
	mu       sync.Mutex
	snapshot json.RawMessage = json.RawMessage("[]")
	snapTS   int64
	replies  []Reply
)

func main() {
	token := os.Getenv("RELAY_TOKEN")
	addr := ":9000"
	if p := os.Getenv("FC_SERVER_PORT"); p != "" {
		addr = ":" + p
	} else if p := os.Getenv("PORT"); p != "" {
		addr = ":" + p
	}

	auth := func(r *http.Request) bool {
		if token == "" {
			return false // fail-closed
		}
		t := r.Header.Get("X-Token")
		if t == "" {
			t = r.URL.Query().Get("token")
		}
		return subtle.ConstantTimeCompare([]byte(t), []byte(token)) == 1
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	mux.HandleFunc("/queue", func(w http.ResponseWriter, r *http.Request) {
		if !auth(r) {
			http.Error(w, "unauthorized", 401)
			return
		}
		mu.Lock()
		snap, ts := snapshot, snapTS
		mu.Unlock()
		out, _ := json.Marshal(map[string]any{
			"items": snap,
			"ts":    ts,
		})
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Write(out)
	})

	mux.HandleFunc("/reply", func(w http.ResponseWriter, r *http.Request) {
		if !auth(r) {
			http.Error(w, "unauthorized", 401)
			return
		}
		var rp Reply
		if err := json.NewDecoder(r.Body).Decode(&rp); err != nil || rp.ID == "" {
			http.Error(w, "bad request", 400)
			return
		}
		mu.Lock()
		replies = append(replies, rp)
		mu.Unlock()
		log.Printf("reply queued: %s -> %s", rp.ID, rp.Text)
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"ok":true}`))
	})

	mux.HandleFunc("/push", func(w http.ResponseWriter, r *http.Request) {
		if !auth(r) {
			http.Error(w, "unauthorized", 401)
			return
		}
		var body struct {
			Items json.RawMessage `json:"items"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "bad request", 400)
			return
		}
		mu.Lock()
		if len(body.Items) > 0 {
			snapshot = body.Items
		} else {
			snapshot = json.RawMessage("[]")
		}
		snapTS = time.Now().Unix()
		out := replies
		replies = nil
		mu.Unlock()
		if out == nil {
			out = []Reply{}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"replies": out})
	})

	log.Printf("cloudrelay on %s (auth=%v)", addr, token != "")
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}
