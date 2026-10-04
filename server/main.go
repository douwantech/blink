package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"golang.org/x/crypto/bcrypt"
)

//go:embed schema.sql
var schema embed.FS

type app struct{ db *sql.DB }

// A real bcrypt comparison for unknown usernames avoids a simple timing oracle.
var dummyPasswordHash, _ = bcrypt.GenerateFromPassword([]byte("blink-invalid-user-password"), bcrypt.DefaultCost)

type user struct {
	ID       uint64 `json:"id"`
	Username string `json:"username"`
	Admin    bool   `json:"isAdmin"`
	CanWrite bool   `json:"canWrite"`
	Disabled bool   `json:"disabled"`
}

func main() {
	dsn := os.Getenv("BLINK_MYSQL_DSN")
	if dsn == "" {
		log.Fatal("BLINK_MYSQL_DSN is required")
	}
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		log.Fatal(err)
	}
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		log.Fatal(err)
	}
	if err := migrate(ctx, db); err != nil {
		log.Fatal(err)
	}
	if err := bootstrap(ctx, db); err != nil {
		log.Fatal(err)
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "9000"
	}
	log.Printf("blink config server listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, (&app{db}).routes()))
}

func migrate(ctx context.Context, db *sql.DB) error {
	b, _ := schema.ReadFile("schema.sql")
	// schema.sql is deliberately plain DDL: semicolons may only terminate statements.
	// If SQL strings or stored procedures are added, replace this splitter first.
	for _, statement := range strings.Split(string(b), ";") {
		if strings.TrimSpace(statement) == "" {
			continue
		}
		if _, err := db.ExecContext(ctx, statement); err != nil {
			return fmt.Errorf("schema: %w", err)
		}
	}
	return nil
}

// The first administrator is created once, from FC environment secrets.
func bootstrap(ctx context.Context, db *sql.DB) error {
	name, password := os.Getenv("BLINK_BOOTSTRAP_USER"), os.Getenv("BLINK_BOOTSTRAP_PASSWORD")
	if name == "" && password == "" {
		return nil
	}
	if name == "" || len(password) < 12 {
		return errors.New("bootstrap user and a password of at least 12 characters are required")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	_, err = db.ExecContext(ctx, `INSERT IGNORE INTO users (username,password_hash,is_admin,can_write) VALUES (?,?,TRUE,TRUE)`, name, hash)
	return err
}

func (a *app) routes() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) })
	m.HandleFunc("POST /v1/login", a.login)
	m.HandleFunc("POST /v1/logout", a.auth(a.logout))
	m.HandleFunc("GET /v1/config", a.auth(a.config))
	m.HandleFunc("PUT /v1/config/tabs", a.auth(a.writeUserConfig("tabs")))
	m.HandleFunc("PUT /v1/config/selection", a.auth(a.writeUserConfig("recent_selection")))
	m.HandleFunc("PUT /v1/config/agents", a.auth(a.writeUserConfig("agents")))
	m.HandleFunc("PUT /v1/machines/{id}", a.auth(a.putMachine))
	m.HandleFunc("DELETE /v1/machines/{id}", a.auth(a.deleteMachine))
	m.HandleFunc("POST /v1/admin/users", a.auth(a.createUser))
	m.HandleFunc("PATCH /v1/admin/users/{id}", a.auth(a.updateUser))
	a.adminRoutes(m)
	return m
}

func readJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(dst); err != nil {
		http.Error(w, "invalid JSON", 400)
		return false
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		http.Error(w, "extra JSON", 400)
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

type handler func(http.ResponseWriter, *http.Request, user)

func (a *app) auth(next handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(r.Header.Get("Authorization"), " ")
		if len(parts) != 2 || parts[0] != "Bearer" || len(parts[1]) != 64 {
			http.Error(w, "unauthorized", 401)
			return
		}
		b, err := hex.DecodeString(parts[1])
		if err != nil {
			http.Error(w, "unauthorized", 401)
			return
		}
		digest := sha256.Sum256(b)
		var u user
		err = a.db.QueryRowContext(r.Context(), `SELECT u.id,u.username,u.is_admin,u.can_write,u.disabled FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.expires_at>NOW()`, digest[:]).Scan(&u.ID, &u.Username, &u.Admin, &u.CanWrite, &u.Disabled)
		if err != nil || u.Disabled {
			http.Error(w, "unauthorized", 401)
			return
		}
		next(w, r, u)
	}
}

func requireAdmin(w http.ResponseWriter, u user) bool {
	if !u.Admin {
		http.Error(w, "forbidden", 403)
		return false
	}
	return true
}
func requireWrite(w http.ResponseWriter, u user) bool {
	if !u.Admin || !u.CanWrite {
		http.Error(w, "forbidden", 403)
		return false
	}
	return true
}

func (a *app) login(w http.ResponseWriter, r *http.Request) {
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
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)) != nil || u.Disabled {
		http.Error(w, "invalid credentials", 401)
		return
	}
	token := make([]byte, 32)
	if _, err := rand.Read(token); err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	digest := sha256.Sum256(token)
	expires := time.Now().Add(30 * 24 * time.Hour)
	if _, err := a.db.ExecContext(r.Context(), `INSERT INTO sessions(token_hash,user_id,expires_at) VALUES (?,?,?)`, digest[:], u.ID, expires); err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	writeJSON(w, 200, map[string]any{"token": hex.EncodeToString(token), "expiresAt": expires.UTC().Format(time.RFC3339), "user": u})
}

func (a *app) logout(w http.ResponseWriter, r *http.Request, u user) {
	b, _ := hex.DecodeString(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	d := sha256.Sum256(b)
	_, _ = a.db.ExecContext(r.Context(), `DELETE FROM sessions WHERE token_hash=?`, d[:])
	w.WriteHeader(204)
}

func parseID(w http.ResponseWriter, r *http.Request) (uint64, bool) {
	id, err := strconv.ParseUint(r.PathValue("id"), 10, 64)
	if err != nil || id == 0 {
		http.Error(w, "invalid id", 400)
		return 0, false
	}
	return id, true
}
