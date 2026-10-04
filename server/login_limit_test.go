package main

import (
	"crypto/sha256"
	"net/http/httptest"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestLoginLimitSharedBucket(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	key := sha256.Sum256([]byte("alice"))
	mock.ExpectExec("INSERT INTO login_limits").WithArgs(key[:]).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectQuery("SELECT attempts FROM login_limits").WithArgs(key[:]).WillReturnRows(sqlmock.NewRows([]string{"attempts"}).AddRow(11))
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/v1/login", nil)
	if (&app{db: db}).checkLoginLimit(w, r, "Alice") || w.Code != 429 || w.Header().Get("Retry-After") != "300" {
		t.Fatalf("expected rate limit, got %d", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
