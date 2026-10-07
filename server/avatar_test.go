package main

import (
	"bytes"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestEmployeeAvatarReturnsPNG(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	png := []byte("\x89PNG\r\n\x1a\navatar")
	mock.ExpectQuery("SELECT data FROM employee_avatars").WithArgs("jack").WillReturnRows(sqlmock.NewRows([]string{"data"}).AddRow(png))
	r := httptest.NewRequest(http.MethodGet, "/v1/employees/jack/avatar", nil)
	r.SetPathValue("id", "jack")
	w := httptest.NewRecorder()
	(&app{db: db}).employeeAvatar(w, r, user{ID: 1})
	if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "image/png" || !bytes.Equal(w.Body.Bytes(), png) {
		t.Fatalf("status=%d type=%q body=%q", w.Code, w.Header().Get("Content-Type"), w.Body.Bytes())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestAdminPutEmployeeAvatarStoresPNGAndDirectoryURL(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	png := []byte("\x89PNG\r\n\x1a\navatar")
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT data FROM employees WHERE id").WithArgs("jack").WillReturnRows(sqlmock.NewRows([]string{"data"}).AddRow([]byte(`{"id":"jack","name":"Jack"}`)))
	mock.ExpectExec("UPDATE employees SET data=").WithArgs(sqlmock.AnyArg(), "jack").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("INSERT INTO employee_avatars").WithArgs("jack", png, "image/png").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	r := httptest.NewRequest(http.MethodPut, "/admin/api/employees/jack/avatar", bytes.NewReader(png))
	r.SetPathValue("id", "jack")
	r.Header.Set("Content-Type", "image/png")
	w := httptest.NewRecorder()
	(&app{db: db}).putEmployeeAvatar(w, r, user{ID: 1, Admin: true})
	if w.Code != http.StatusNoContent {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestAdminPutEmployeeAvatarRejectsNonPNG(t *testing.T) {
	db, _, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := httptest.NewRequest(http.MethodPut, "/admin/api/employees/jack/avatar", bytes.NewBufferString("not an image"))
	r.SetPathValue("id", "jack")
	r.Header.Set("Content-Type", "image/png")
	w := httptest.NewRecorder()
	(&app{db: db}).putEmployeeAvatar(w, r, user{ID: 1, Admin: true})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status=%d, want 400", w.Code)
	}
}

// The employee table's <img> sends the admin session cookie, not a bearer
// token, so the avatar must also be reachable through /admin/api. Without this
// route the column stays empty even though the upload succeeded.
func TestAdminEmployeeAvatarRouteServesPNGToAdminSession(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	png := []byte("\x89PNG\r\n\x1a\navatar")
	mock.ExpectQuery("SELECT u.id,u.username,u.is_admin").WithArgs(sqlmock.AnyArg()).WillReturnRows(sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(1, "tom", true, true, false))
	mock.ExpectQuery("SELECT data FROM employee_avatars").WithArgs("jack").WillReturnRows(sqlmock.NewRows([]string{"data"}).AddRow(png))
	token := make([]byte, 32)
	r := httptest.NewRequest(http.MethodGet, "/admin/api/employees/jack/avatar", nil)
	r.AddCookie(&http.Cookie{Name: adminCookie, Value: hex.EncodeToString(token)})
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "image/png" || !bytes.Equal(w.Body.Bytes(), png) {
		t.Fatalf("status=%d type=%q body=%q", w.Code, w.Header().Get("Content-Type"), w.Body.Bytes())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestAdminEmployeeAvatarRouteRejectsAnonymous(t *testing.T) {
	w := httptest.NewRecorder()
	(&app{}).routes().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/admin/api/employees/jack/avatar", nil))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d, want 401", w.Code)
	}
}

// default-src 'none' also blocks <img> unless img-src is listed, which would
// silently blank the avatar column in the browser.
func TestAdminPageCSPAllowsSelfImages(t *testing.T) {
	w := httptest.NewRecorder()
	serveAdminPage(w)
	if csp := w.Header().Get("Content-Security-Policy"); !strings.Contains(csp, "img-src 'self'") {
		t.Fatalf("CSP lacks img-src 'self': %q", csp)
	}
}
