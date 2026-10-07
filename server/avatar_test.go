package main

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
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

func employeeAvatarPut(t *testing.T, id string, body []byte) (*httptest.ResponseRecorder, *http.Request) {
	t.Helper()
	r := httptest.NewRequest(http.MethodPut, "/v1/employees/"+id+"/avatar", bytes.NewReader(body))
	r.SetPathValue("id", id)
	r.Header.Set("Content-Type", "image/png")
	return httptest.NewRecorder(), r
}

func TestV1PutEmployeeAvatarStoresPNGForCanWriteAccount(t *testing.T) {
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
	w, r := employeeAvatarPut(t, "jack", png)
	(&app{db: db}).putEmployeeAvatarV1(w, r, user{ID: 1, Admin: true, CanWrite: true})
	if w.Code != http.StatusNoContent {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// A signed-in admin without canWrite must be refused, and refused before the
// body is read, so no database work happens for an unauthorized caller.
func TestV1PutEmployeeAvatarForbidsReadOnlyAccount(t *testing.T) {
	png := []byte("\x89PNG\r\n\x1a\navatar")
	for _, u := range []user{{ID: 1, Admin: true, CanWrite: false}, {ID: 1, Admin: false, CanWrite: false}} {
		w, r := employeeAvatarPut(t, "jack", png)
		(&app{}).putEmployeeAvatarV1(w, r, u)
		if w.Code != http.StatusForbidden {
			t.Fatalf("user=%+v status=%d, want 403", u, w.Code)
		}
	}
}

func TestV1PutEmployeeAvatarRejectsNonPNG(t *testing.T) {
	w, r := employeeAvatarPut(t, "jack", []byte("not an image"))
	(&app{}).putEmployeeAvatarV1(w, r, user{ID: 1, Admin: true, CanWrite: true})
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status=%d, want 400", w.Code)
	}
}

func TestV1PutEmployeeAvatarUnknownEmployeeIs404(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	png := []byte("\x89PNG\r\n\x1a\navatar")
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT data FROM employees WHERE id").WithArgs("ghost").WillReturnError(sql.ErrNoRows)
	mock.ExpectRollback()
	w, r := employeeAvatarPut(t, "ghost", png)
	(&app{db: db}).putEmployeeAvatarV1(w, r, user{ID: 1, Admin: true, CanWrite: true})
	if w.Code != http.StatusNotFound {
		t.Fatalf("status=%d, want 404", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// Route-level check: PUT /v1/employees/{id}/avatar must exist (a missing route
// would answer 405, not 403) and a Bearer session without canWrite must get 403
// — the same path the simtest account exercises against prod.
func TestV1PutEmployeeAvatarRouteForbidsReadOnlyBearer(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	token := make([]byte, 32)
	digest := sha256.Sum256(token)
	mock.ExpectQuery("SELECT u.id,u.username,u.is_admin").WithArgs(digest[:]).WillReturnRows(sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(2, "quan", true, false, false))
	r := httptest.NewRequest(http.MethodPut, "/v1/employees/jack/avatar", bytes.NewReader([]byte("\x89PNG\r\n\x1a\navatar")))
	r.Header.Set("Authorization", "Bearer "+hex.EncodeToString(token))
	r.Header.Set("Content-Type", "image/png")
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != http.StatusForbidden {
		t.Fatalf("status=%d, want 403", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestV1PutEmployeeAvatarRouteRejectsAnonymous(t *testing.T) {
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPut, "/v1/employees/jack/avatar", bytes.NewReader([]byte("\x89PNG\r\n\x1a\navatar")))
	r.Header.Set("Content-Type", "image/png")
	(&app{}).routes().ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d, want 401", w.Code)
	}
}
