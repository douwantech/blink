package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestAdminPageAndAPIRequireAdminSession(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a := &app{db: db}
	routes := a.routes()
	for _, tc := range []struct {
		path   string
		status int
	}{{"/admin", 303}, {"/admin/api/state", 401}} {
		w := httptest.NewRecorder()
		routes.ServeHTTP(w, httptest.NewRequest("GET", tc.path, nil))
		if w.Code != tc.status {
			t.Fatalf("%s got %d", tc.path, w.Code)
		}
	}
	w := httptest.NewRecorder()
	routes.ServeHTTP(w, httptest.NewRequest("GET", "/admin/login", nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Blink 配置管理") {
		t.Fatalf("login page: %d", w.Code)
	}
	token := make([]byte, 32)
	digest := sha256.Sum256(token)
	mock.ExpectQuery("SELECT u.id,u.username,u.is_admin").WithArgs(digest[:]).WillReturnRows(sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(7, "member", false, false, false))
	r := httptest.NewRequest("GET", "/admin/api/state", nil)
	r.AddCookie(&http.Cookie{Name: adminCookie, Value: hex.EncodeToString(token)})
	w = httptest.NewRecorder()
	routes.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatalf("non-admin got %d", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestAdminMutationRequiresCustomHeader(t *testing.T) {
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/admin/session", strings.NewReader(`{"username":"x","password":"y"}`))
	r.Header.Set("Content-Type", "application/json")
	(&app{}).adminSession(w, r)
	if w.Code != 403 {
		t.Fatalf("got %d", w.Code)
	}
}
