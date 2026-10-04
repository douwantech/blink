package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

//go:embed web/admin.html
var adminPage embed.FS

const adminCookie = "blink_admin_session"

func (a *app) adminRoutes(m *http.ServeMux) {
	m.HandleFunc("GET /admin/login", a.adminLoginPage)
	m.HandleFunc("POST /admin/session", a.adminSession)
	m.HandleFunc("GET /admin", a.adminAuth(a.adminHome))
	m.HandleFunc("DELETE /admin/session", a.adminAuth(a.adminLogout))
	m.HandleFunc("GET /admin/api/state", a.adminAuth(a.adminState))
	m.HandleFunc("POST /admin/api/users", a.adminAuth(a.createUser))
	m.HandleFunc("PATCH /admin/api/users/{id}", a.adminAuth(a.updateUser))
	m.HandleFunc("PUT /admin/api/machines/{id}", a.adminAuth(a.putMachine))
	m.HandleFunc("DELETE /admin/api/machines/{id}", a.adminAuth(a.deleteMachine))
}

func serveAdminPage(w http.ResponseWriter) {
	b, err := adminPage.ReadFile("web/admin.html")
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
	_, _ = w.Write(b)
}

func (a *app) adminLoginPage(w http.ResponseWriter, r *http.Request)    { serveAdminPage(w) }
func (a *app) adminHome(w http.ResponseWriter, r *http.Request, u user) { serveAdminPage(w) }

func secureCookie(r *http.Request) bool {
	return r.TLS != nil || !strings.HasPrefix(r.Host, "localhost:") && r.Host != "localhost" && !strings.HasPrefix(r.Host, "127.0.0.1:") && r.Host != "127.0.0.1"
}

func (a *app) adminSession(w http.ResponseWriter, r *http.Request) {
	if !adminMutation(w, r) {
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if !a.checkLoginLimit(w, r, req.Username) {
		return
	}
	var u user
	var hash string
	err := a.db.QueryRowContext(r.Context(), `SELECT id,username,password_hash,is_admin,can_write,disabled FROM users WHERE username=?`, req.Username).Scan(&u.ID, &u.Username, &hash, &u.Admin, &u.CanWrite, &u.Disabled)
	if errors.Is(err, sql.ErrNoRows) {
		_ = bcrypt.CompareHashAndPassword(dummyPasswordHash, []byte(req.Password))
		http.Error(w, "invalid credentials", 401)
		return
	}
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)) != nil || u.Disabled || !u.Admin {
		http.Error(w, "invalid credentials", 401)
		return
	}
	token := make([]byte, 32)
	if _, err = rand.Read(token); err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	digest := sha256.Sum256(token)
	expires := time.Now().Add(12 * time.Hour)
	if _, err = a.db.ExecContext(r.Context(), `INSERT INTO sessions(token_hash,user_id,expires_at) VALUES (?,?,?)`, digest[:], u.ID, expires); err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: adminCookie, Value: hex.EncodeToString(token), Path: "/admin", Expires: expires, HttpOnly: true, Secure: secureCookie(r), SameSite: http.SameSiteStrictMode})
	writeJSON(w, 200, map[string]any{"user": u})
}

func adminMutation(w http.ResponseWriter, r *http.Request) bool {
	if r.Header.Get("X-Blink-Admin") != "1" || !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") && r.Method != "DELETE" {
		http.Error(w, "forbidden", 403)
		return false
	}
	// Custom header forces cross-origin browser requests through CORS preflight.
	// The server never enables cross-origin requests; Strict cookies add a second guard.
	return true
}

func (a *app) adminAuth(next handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := r.Cookie(adminCookie)
		if err != nil || len(c.Value) != 64 {
			a.adminUnauthorized(w, r)
			return
		}
		token, err := hex.DecodeString(c.Value)
		if err != nil {
			a.adminUnauthorized(w, r)
			return
		}
		digest := sha256.Sum256(token)
		var u user
		err = a.db.QueryRowContext(r.Context(), `SELECT u.id,u.username,u.is_admin,u.can_write,u.disabled FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.expires_at>NOW()`, digest[:]).Scan(&u.ID, &u.Username, &u.Admin, &u.CanWrite, &u.Disabled)
		if err != nil || u.Disabled || !u.Admin {
			a.adminUnauthorized(w, r)
			return
		}
		if r.Method != "GET" && !adminMutation(w, r) {
			return
		}
		next(w, r, u)
	}
}

func (a *app) adminUnauthorized(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/admin" {
		http.Redirect(w, r, "/admin/login", http.StatusSeeOther)
		return
	}
	http.Error(w, "unauthorized", 401)
}

func (a *app) adminLogout(w http.ResponseWriter, r *http.Request, u user) {
	c, _ := r.Cookie(adminCookie)
	b, _ := hex.DecodeString(c.Value)
	d := sha256.Sum256(b)
	_, _ = a.db.ExecContext(r.Context(), `DELETE FROM sessions WHERE token_hash=?`, d[:])
	http.SetCookie(w, &http.Cookie{Name: adminCookie, Path: "/admin", MaxAge: -1, HttpOnly: true, Secure: secureCookie(r), SameSite: http.SameSiteStrictMode})
	w.WriteHeader(204)
}

func (a *app) adminState(w http.ResponseWriter, r *http.Request, u user) {
	rows, err := a.db.QueryContext(r.Context(), `SELECT id,username,is_admin,can_write,disabled FROM users ORDER BY username`)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	users := make([]user, 0)
	for rows.Next() {
		var v user
		if err = rows.Scan(&v.ID, &v.Username, &v.Admin, &v.CanWrite, &v.Disabled); err != nil {
			break
		}
		users = append(users, v)
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	rows, err = a.db.QueryContext(r.Context(), `SELECT position,data FROM machines ORDER BY position,id`)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	machines := make([]json.RawMessage, 0)
	for rows.Next() {
		var position int
		var data []byte
		if err = rows.Scan(&position, &data); err != nil {
			break
		}
		var fields map[string]json.RawMessage
		if err = json.Unmarshal(data, &fields); err != nil {
			break
		}
		fields["position"], _ = json.Marshal(position)
		data, err = json.Marshal(fields)
		if err != nil {
			break
		}
		machines = append(machines, json.RawMessage(data))
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	rows, err = a.db.QueryContext(r.Context(), `SELECT u.id,c.tabs,c.recent_selection FROM users u LEFT JOIN user_configs c ON c.user_id=u.id ORDER BY u.username`)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	personal := make([]map[string]any, 0)
	for rows.Next() {
		var id uint64
		var tabs, selection []byte
		if err = rows.Scan(&id, &tabs, &selection); err != nil {
			break
		}
		if len(tabs) == 0 {
			tabs = []byte(`{"version":1,"tabs":[]}`)
		}
		if len(selection) == 0 {
			selection = []byte(`{}`)
		}
		personal = append(personal, map[string]any{"userId": id, "tabs": json.RawMessage(tabs), "recentSelection": json.RawMessage(selection)})
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	writeJSON(w, 200, map[string]any{"me": u, "users": users, "machines": machines, "personal": personal})
}
