package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
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
