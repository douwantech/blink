package main

import (
	"crypto/sha256"
	"database/sql"
	"errors"
	"net/http"
	"strings"
)

// Shared MySQL bucket: all FC instances enforce the same account-level limit.
// Gateway/IP throttling is still useful against arbitrary-username floods.
//
// 计数语义（2026-10-05 事故后修正）：只有失败的登录才累计 attempts，成功
// 拿到 token 不计数。之前 checkLoginLimit 在密码校验前无条件 +1，正常用户
// 在 5 分钟里反复登录 11 次（客户端 bug 导致每次登录后回到登录页）就被 429
// 锁死。check 只读不写；bump 由 login() 的失败分支调用。

func loginLimitKey(username string) []byte {
	key := sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(username))))
	return key[:]
}

func validLoginUsername(username string) bool {
	return len(username) <= 100 && strings.TrimSpace(username) != ""
}

func (a *app) checkLoginLimit(w http.ResponseWriter, r *http.Request, username string) bool {
	if !validLoginUsername(username) {
		http.Error(w, "invalid username", 400)
		return false
	}
	// 窗口过期与否交给 SQL 用 NOW() 判断，和 bump 的窗口重置同源，避免 Go/MySQL
	// 时区差异把旧计数误判为仍有效。无记录（从未失败）直接放行。
	var attempts int
	var stale bool
	err := a.db.QueryRowContext(r.Context(),
		`SELECT attempts, window_start<NOW()-INTERVAL 5 MINUTE AS stale FROM login_limits WHERE identity_hash=?`,
		loginLimitKey(username)).Scan(&attempts, &stale)
	if errors.Is(err, sql.ErrNoRows) {
		return true
	}
	if err != nil {
		http.Error(w, "internal error", 500)
		return false
	}
	if !stale && attempts > 10 {
		w.Header().Set("Retry-After", "300")
		http.Error(w, "too many login attempts", 429)
		return false
	}
	return true
}

// bumpLoginLimit 在一次登录尝试失败后调用：5 分钟窗口内 +1，窗口过期则重置为 1。
func (a *app) bumpLoginLimit(r *http.Request, username string) {
	if !validLoginUsername(username) {
		return
	}
	_, _ = a.db.ExecContext(r.Context(),
		`INSERT INTO login_limits(identity_hash,window_start,attempts) VALUES (?,NOW(),1)
		 ON DUPLICATE KEY UPDATE
		   attempts=IF(window_start<NOW()-INTERVAL 5 MINUTE,1,attempts+1),
		   window_start=IF(window_start<NOW()-INTERVAL 5 MINUTE,NOW(),window_start)`,
		loginLimitKey(username))
}
