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

func TestDeleteUserGuardsAndCascades(t *testing.T) {
	t.Run("unauthenticated", func(t *testing.T) {
		w := httptest.NewRecorder()
		(&app{}).routes().ServeHTTP(w, httptest.NewRequest(http.MethodDelete, "/admin/api/users/8", nil))
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("got %d", w.Code)
		}
	})
	t.Run("non-admin", func(t *testing.T) {
		db, mock, _ := sqlmock.New()
		defer db.Close()
		token := make([]byte, 32)
		digest := sha256.Sum256(token)
		mock.ExpectQuery("SELECT u.id,u.username,u.is_admin").WithArgs(digest[:]).WillReturnRows(sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(9, "member", false, false, false))
		r := httptest.NewRequest(http.MethodDelete, "/admin/api/users/8", nil)
		r.AddCookie(&http.Cookie{Name: adminCookie, Value: hex.EncodeToString(token)})
		w := httptest.NewRecorder()
		(&app{db: db}).routes().ServeHTTP(w, r)
		if w.Code != http.StatusForbidden {
			t.Fatalf("got %d", w.Code)
		}
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("self", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodDelete, "/admin/api/users/7", nil)
		r.SetPathValue("id", "7")
		w := httptest.NewRecorder()
		(&app{}).deleteUser(w, r, user{ID: 7, Admin: true})
		if w.Code != http.StatusBadRequest {
			t.Fatalf("got %d", w.Code)
		}
	})
	t.Run("last admin", func(t *testing.T) {
		db, mock, _ := sqlmock.New()
		defer db.Close()
		mock.ExpectBegin()
		mock.ExpectQuery("SELECT id,is_admin FROM users").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"id", "is_admin"}).AddRow(8, true))
		mock.ExpectQuery("SELECT id FROM users WHERE is_admin=1").WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(8))
		r := httptest.NewRequest(http.MethodDelete, "/admin/api/users/8", nil)
		r.SetPathValue("id", "8")
		w := httptest.NewRecorder()
		(&app{db: db}).deleteUser(w, r, user{ID: 7, Admin: true})
		if w.Code != http.StatusBadRequest {
			t.Fatalf("got %d", w.Code)
		}
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("normal delete commits cascade", func(t *testing.T) {
		db, mock, _ := sqlmock.New()
		defer db.Close()
		mock.ExpectBegin()
		mock.ExpectQuery("SELECT id,is_admin FROM users").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"id", "is_admin"}).AddRow(8, false))
		mock.ExpectQuery("SELECT id FROM users WHERE is_admin=1").WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(7).AddRow(8))
		mock.ExpectExec("DELETE FROM users").WithArgs(uint64(8)).WillReturnResult(sqlmock.NewResult(0, 1))
		mock.ExpectCommit()
		r := httptest.NewRequest(http.MethodDelete, "/admin/api/users/8", nil)
		r.SetPathValue("id", "8")
		w := httptest.NewRecorder()
		(&app{db: db}).deleteUser(w, r, user{ID: 7, Admin: true})
		if w.Code != http.StatusNoContent {
			t.Fatalf("got %d", w.Code)
		}
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	})
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

func TestAdminMutationAllowsPNGOnlyForEmployeeAvatar(t *testing.T) {
	for _, tc := range []struct {
		path   string
		header string
		want   bool
	}{
		{"/admin/api/employees/jack/avatar", "1", true},
		{"/admin/api/employees/jack", "1", false},
		{"/admin/api/employees/jack/avatar", "", false},
	} {
		r := httptest.NewRequest(http.MethodPut, tc.path, nil)
		r.Header.Set("Content-Type", "image/png")
		r.Header.Set("X-Blink-Admin", tc.header)
		w := httptest.NewRecorder()
		if got := adminMutation(w, r); got != tc.want {
			t.Errorf("%s header=%q: got %v, want %v", tc.path, tc.header, got, tc.want)
		}
	}
}
