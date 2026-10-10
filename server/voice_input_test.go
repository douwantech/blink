package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestVoiceInputDeviceEditsDoNotReplaceOtherDeviceData(t *testing.T) {
	doc := emptyVoiceInput()
	// Device A then B: neither uploads its older complete list.
	doc.apply(voiceInputOperation{Kind: "addFavorite", Text: "A"})
	doc.apply(voiceInputOperation{Kind: "addFavorite", Text: "B"})
	doc.apply(voiceInputOperation{Kind: "useFavorite", Text: "A"})
	doc.apply(voiceInputOperation{Kind: "removeFavorite", Text: "A"})
	doc.apply(voiceInputOperation{Kind: "recordHistory", Text: "from B"})
	if !reflect.DeepEqual(doc.Favorites, []string{"B"}) || len(doc.FavoriteCounts) != 0 {
		t.Fatalf("device B resurrected A: %+v", doc)
	}
	doc.apply(voiceInputOperation{Kind: "clearFavorites"})
	doc.apply(voiceInputOperation{Kind: "useFavorite", Text: "B"})
	if len(doc.Favorites) != 0 || len(doc.FavoriteCounts) != 0 {
		t.Fatal("using a cleared favorite resurrected it")
	}
	for i := 0; i < 45; i++ {
		doc.apply(voiceInputOperation{Kind: "recordHistory", Text: strings.Repeat("x", i+1)})
	}
	latest := doc.History[0]
	doc.apply(voiceInputOperation{Kind: "recordHistory", Text: latest})
	if len(doc.History) != 40 || doc.History[39] != latest {
		t.Fatal("history must be bounded, deduplicated and ordered by latest use")
	}
	doc.apply(voiceInputOperation{Kind: "clearHistory"})
	if len(doc.History) != 0 {
		t.Fatal("history clear did not apply")
	}
}

func TestVoiceInputSignedInAccountAndRetry(t *testing.T) {
	for _, account := range []uint64{7, 8} {
		for _, retry := range []bool{false, true} {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			stored := `{"favorites":["hello"],"history":[],"favoriteCounts":{"hello":2}}`
			mock.ExpectBegin()
			mock.ExpectQuery("SELECT config_version FROM users").WithArgs(account).
				WillReturnRows(sqlmock.NewRows([]string{"config_version"}).AddRow(12))
			mock.ExpectQuery("SELECT data FROM voice_input_configs").WithArgs(account).
				WillReturnRows(sqlmock.NewRows([]string{"data"}).AddRow([]byte(stored)))
			rows := int64(1)
			if retry {
				rows = 0
			}
			mock.ExpectExec("INSERT IGNORE INTO voice_input_operations").WithArgs(account, "operation-id-0001").
				WillReturnResult(sqlmock.NewResult(0, rows))
			if !retry {
				mock.ExpectExec("INSERT INTO voice_input_configs").WithArgs(account,
					jsonArg(`{"favorites":["hello"],"history":[],"favoriteCounts":{"hello":3}}`)).
					WillReturnResult(sqlmock.NewResult(0, 1))
				mock.ExpectExec("UPDATE users SET config_version").WithArgs(account).WillReturnResult(sqlmock.NewResult(0, 1))
			}
			mock.ExpectCommit()
			r := httptest.NewRequest(http.MethodPost, "/v1/config/voice-input", strings.NewReader(
				`{"operations":[{"id":"operation-id-0001","kind":"useFavorite","text":"hello"}]}`))
			w := httptest.NewRecorder()
			(&app{db}).writeVoiceInput(w, r, user{ID: account})
			var doc voiceInputDocument
			if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &doc) != nil {
				t.Fatalf("account=%d retry=%v: %d %s", account, retry, w.Code, w.Body.String())
			}
			want := 3
			if retry {
				want = 2
			}
			if doc.FavoriteCounts["hello"] != want {
				t.Fatal("retry incremented twice")
			}
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
			db.Close()
		}
	}
}

func TestVoiceInputMigrationDoesNotRestoreClearedAccount(t *testing.T) {
	for _, existing := range []bool{false, true} {
		db, mock, err := sqlmock.New()
		if err != nil {
			t.Fatal(err)
		}
		mock.ExpectBegin()
		mock.ExpectQuery("SELECT config_version FROM users").WithArgs(uint64(7)).
			WillReturnRows(sqlmock.NewRows([]string{"config_version"}).AddRow(2))
		query := mock.ExpectQuery("SELECT data FROM voice_input_configs").WithArgs(uint64(7))
		if existing {
			query.WillReturnRows(sqlmock.NewRows([]string{"data"}).AddRow([]byte(`{"favorites":[],"history":[],"favoriteCounts":{}}`)))
		} else {
			query.WillReturnError(sql.ErrNoRows)
		}
		mock.ExpectExec("INSERT IGNORE INTO voice_input_operations").WithArgs(uint64(7), "migration-id-0001").WillReturnResult(sqlmock.NewResult(0, 1))
		want := `{"favorites":["old"],"history":["sent"],"favoriteCounts":{"old":4}}`
		if existing {
			want = `{"favorites":[],"history":[],"favoriteCounts":{}}`
		}
		mock.ExpectExec("INSERT INTO voice_input_configs").WithArgs(uint64(7), jsonArg(want)).WillReturnResult(sqlmock.NewResult(0, 1))
		mock.ExpectExec("UPDATE users SET config_version").WithArgs(uint64(7)).WillReturnResult(sqlmock.NewResult(0, 1))
		mock.ExpectCommit()
		r := httptest.NewRequest(http.MethodPost, "/v1/config/voice-input", strings.NewReader(
			`{"operations":[{"id":"migration-id-0001","kind":"seed","data":{"favorites":["old"],"history":["sent"],"favoriteCounts":{"old":4}}}]}`))
		w := httptest.NewRecorder()
		(&app{db}).writeVoiceInput(w, r, user{ID: 7})
		if w.Code != 200 || !jsonArg(want).Match(w.Body.Bytes()) {
			t.Fatalf("migration existing=%v: %d %s", existing, w.Code, w.Body.String())
		}
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
		db.Close()
	}
}

func TestVoiceInputRejectsInvalidOperationsBeforeWriting(t *testing.T) {
	for _, body := range []string{
		`{"userId":999,"operations":[]}`,
		`{"operations":[]}`,
		`{"operations":[{"id":"operation-id-0001","kind":"replaceEverything"}]}`,
		`{"operations":[{"id":"operation-id-0001","kind":"addFavorite","text":"  "}]}`,
		`{"operations":[{"id":"operation-id-0001","kind":"seed"}]}`,
	} {
		w := httptest.NewRecorder()
		(&app{}).writeVoiceInput(w, httptest.NewRequest("POST", "/v1/config/voice-input", strings.NewReader(body)), user{ID: 7})
		if w.Code != 400 {
			t.Fatalf("accepted %s: %d", body, w.Code)
		}
	}
	w := httptest.NewRecorder()
	(&app{}).routes().ServeHTTP(w, httptest.NewRequest("POST", "/v1/config/voice-input", strings.NewReader(`{}`)))
	if w.Code != 401 {
		t.Fatalf("anonymous caller got %d", w.Code)
	}
}
