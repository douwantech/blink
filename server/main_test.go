package main

import (
	"database/sql/driver"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

type jsonArg []byte

func (want jsonArg) Match(value driver.Value) bool {
	got, ok := value.([]byte)
	if !ok {
		return false
	}
	var a, b any
	return json.Unmarshal(got, &a) == nil && json.Unmarshal(want, &b) == nil && reflect.DeepEqual(a, b)
}

func TestReadJSONRejectsTrailingInput(t *testing.T) {
	for _, body := range []string{`{"username":"a"} {}`, `{"username":"a"} garbage`} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))
		var dst struct {
			Username string `json:"username"`
		}
		if readJSON(w, r, &dst) || w.Code != 400 {
			t.Fatalf("accepted trailing input: %q", body)
		}
	}
}

func TestWriteAccessRequiresBothFlags(t *testing.T) {
	for _, u := range []user{{Admin: false, CanWrite: false}, {Admin: false, CanWrite: true}, {Admin: true, CanWrite: false}} {
		w := httptest.NewRecorder()
		if requireWrite(w, u) || w.Code != 403 {
			t.Fatalf("unexpected write access for %+v", u)
		}
	}
	if !requireWrite(httptest.NewRecorder(), user{Admin: true, CanWrite: true}) {
		t.Fatal("writer denied")
	}
}

func TestPersonalWritesUseSignedInUser(t *testing.T) {
	for _, tc := range []struct{ path, column string }{
		{"/v1/config/tabs", "tabs"},
		{"/v1/config/selection", "recent_selection"},
		{"/v1/config/agents", "agents"},
	} {
		t.Run(tc.column, func(t *testing.T) {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			mock.ExpectBegin()
			mock.ExpectExec("INSERT INTO user_configs").WithArgs(uint64(7), []byte(`{"key":"value"}`)).WillReturnResult(sqlmock.NewResult(0, 1))
			mock.ExpectExec("UPDATE users SET config_version").WithArgs(uint64(7)).WillReturnResult(sqlmock.NewResult(0, 1))
			mock.ExpectCommit()
			r := httptest.NewRequest(http.MethodPut, tc.path, strings.NewReader(`{"key":"value"}`))
			w := httptest.NewRecorder()
			(&app{db}).writeUserConfig(tc.column)(w, r, user{ID: 7})
			if w.Code != 204 {
				t.Fatalf("status %d: %s", w.Code, w.Body.String())
			}
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestPutMachinePreservesUnknownFields(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	body := `{"id":"m1","host":"example.test","user":"alice","position":4,"futureSetting":{"enabled":true}}`
	mock.ExpectBegin()
	mock.ExpectExec("INSERT INTO machines").WithArgs("m1", 4, jsonArg(`{"id":"m1","host":"example.test","user":"alice","futureSetting":{"enabled":true}}`)).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE config_versions").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	r := httptest.NewRequest(http.MethodPut, "/v1/machines/m1", strings.NewReader(body))
	r.SetPathValue("id", "m1")
	w := httptest.NewRecorder()
	(&app{db}).putMachine(w, r, user{Admin: true, CanWrite: true})
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"futureSetting"`) || strings.Contains(w.Body.String(), `"position"`) {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestReplaceMachinesPreservesArrayOrder(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	mock.ExpectBegin()
	mock.ExpectExec("DELETE FROM machines").WillReturnResult(sqlmock.NewResult(0, 0))
	mock.ExpectExec("INSERT INTO machines").WithArgs("second", 0, jsonArg(`{"id":"second","host":"b.test","user":"u"}`)).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("INSERT INTO machines").WithArgs("first", 1, jsonArg(`{"id":"first","host":"a.test","user":"u"}`)).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE config_versions").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	body := `[{"id":"second","host":"b.test","user":"u"},{"id":"first","host":"a.test","user":"u"}]`
	r := httptest.NewRequest("PUT", "/v1/machines/batch", strings.NewReader(body))
	w := httptest.NewRecorder()
	(&app{db: db}).replaceMachines(w, r, user{Admin: true, CanWrite: true})
	if w.Code != 204 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
