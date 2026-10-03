package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

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
