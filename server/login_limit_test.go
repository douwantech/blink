package main

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"golang.org/x/crypto/bcrypt"
)

func TestLoginLimitBlocksWhenWindowActive(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	key := sha256.Sum256([]byte("alice"))
	mock.ExpectQuery("SELECT attempts").WithArgs(key[:]).
		WillReturnRows(sqlmock.NewRows([]string{"attempts", "stale"}).AddRow(11, false))
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/v1/login", nil)
	if (&app{db: db}).checkLoginLimit(w, r, "Alice") || w.Code != 429 || w.Header().Get("Retry-After") != "300" {
		t.Fatalf("expected rate limit, got %d", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestLoginLimitIgnoresStaleWindow(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	key := sha256.Sum256([]byte("alice"))
	mock.ExpectQuery("SELECT attempts").WithArgs(key[:]).
		WillReturnRows(sqlmock.NewRows([]string{"attempts", "stale"}).AddRow(11, true))
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/v1/login", nil)
	if !(&app{db: db}).checkLoginLimit(w, r, "Alice") || w.Code != 200 {
		t.Fatalf("expected stale window to pass, got %d", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestLoginLimitNoRecordPasses(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	key := sha256.Sum256([]byte("bob"))
	mock.ExpectQuery("SELECT attempts").WithArgs(key[:]).WillReturnError(sql.ErrNoRows)
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/v1/login", nil)
	if !(&app{db: db}).checkLoginLimit(w, r, "bob") || w.Code != 200 {
		t.Fatalf("expected no-record to pass, got %d", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// 语义回归：check 只读不写 —— 若有人把计数塞回 check（2026-10-05 前的写法，
// 每次登录无条件 +1），这里会因未期望的 Exec 失败。
func TestLoginLimitCheckDoesNotCount(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	key := sha256.Sum256([]byte("alice"))
	mock.ExpectQuery("SELECT attempts").WithArgs(key[:]).
		WillReturnRows(sqlmock.NewRows([]string{"attempts", "stale"}).AddRow(3, false))
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/v1/login", nil)
	if !(&app{db: db}).checkLoginLimit(w, r, "Alice") || w.Code != 200 {
		t.Fatalf("expected pass, got %d", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// 失败登录必须累计：mock 一次 users 查询（密码 hash 不匹配）+ 一次 bump。
func TestLoginFailureBumpsLimit(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	key := sha256.Sum256([]byte("bob"))
	mock.ExpectQuery("SELECT attempts").WithArgs(key[:]).
		WillReturnRows(sqlmock.NewRows([]string{"attempts", "stale"}).AddRow(0, false))
	hash, _ := bcrypt.GenerateFromPassword([]byte("right"), bcrypt.MinCost)
	mock.ExpectQuery("SELECT id,username,password_hash").WithArgs("bob").
		WillReturnRows(sqlmock.NewRows([]string{"id", "username", "password_hash", "is_admin", "can_write", "disabled"}).
			AddRow(1, "bob", string(hash), false, true, false))
	mock.ExpectExec("INSERT INTO login_limits").WithArgs(key[:]).WillReturnResult(sqlmock.NewResult(0, 1))

	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/v1/login", bytes.NewBufferString(`{"username":"bob","password":"nope"}`))
	(&app{db: db}).login(w, r)
	if w.Code != 401 {
		t.Fatalf("expected 401, got %d", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// 成功登录绝不计数：整个 login 不产生任何 login_limits 写入（未期望的 Exec 会报错）。
func TestLoginSuccessDoesNotBumpLimit(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	key := sha256.Sum256([]byte("bob"))
	mock.ExpectQuery("SELECT attempts").WithArgs(key[:]).
		WillReturnRows(sqlmock.NewRows([]string{"attempts", "stale"}).AddRow(0, false))
	hash, _ := bcrypt.GenerateFromPassword([]byte("right"), bcrypt.MinCost)
	mock.ExpectQuery("SELECT id,username,password_hash").WithArgs("bob").
		WillReturnRows(sqlmock.NewRows([]string{"id", "username", "password_hash", "is_admin", "can_write", "disabled"}).
			AddRow(1, "bob", string(hash), false, true, false))
	mock.ExpectExec("INSERT INTO sessions").WithArgs(sqlmock.AnyArg(), 1, sqlmock.AnyArg()).
		WillReturnResult(sqlmock.NewResult(0, 1))

	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/v1/login", bytes.NewBufferString(`{"username":"bob","password":"right"}`))
	(&app{db: db}).login(w, r)
	if w.Code != 200 {
		t.Fatalf("expected 200, got %d body=%s", w.Code, w.Body.String())
	}
	var out struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil || len(out.Token) != 64 {
		t.Fatalf("expected 64-hex token, got %q err=%v", out.Token, err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
