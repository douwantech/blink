package main

import (
	"crypto/sha256"
	"net/http"
	"strings"
)

// Shared MySQL bucket: all FC instances enforce the same account-level limit.
// Gateway/IP throttling is still useful against arbitrary-username floods.
func (a *app) checkLoginLimit(w http.ResponseWriter, r *http.Request, username string) bool {
	if len(username) > 100 || strings.TrimSpace(username) == "" {
		http.Error(w, "invalid username", 400)
		return false
	}
	key := sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(username))))
	_, err := a.db.ExecContext(r.Context(), `INSERT INTO login_limits(identity_hash,window_start,attempts) VALUES (?,NOW(),1) ON DUPLICATE KEY UPDATE attempts=IF(window_start<NOW()-INTERVAL 5 MINUTE,1,attempts+1),window_start=IF(window_start<NOW()-INTERVAL 5 MINUTE,NOW(),window_start)`, key[:])
	if err != nil {
		http.Error(w, "internal error", 500)
		return false
	}
	var attempts int
	if err = a.db.QueryRowContext(r.Context(), `SELECT attempts FROM login_limits WHERE identity_hash=?`, key[:]).Scan(&attempts); err != nil {
		http.Error(w, "internal error", 500)
		return false
	}
	if attempts > 10 {
		w.Header().Set("Retry-After", "300")
		http.Error(w, "too many login attempts", 429)
		return false
	}
	return true
}
