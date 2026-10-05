package main

import (
	"crypto/sha256"
	"database/sql/driver"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

type tabsArg struct {
	count     int
	closed    string
	machineID string
}

func (want tabsArg) Match(value driver.Value) bool {
	b, ok := value.([]byte)
	if !ok {
		return false
	}
	var state struct {
		Tabs []struct {
			ID        string `json:"id"`
			MachineID string `json:"machineId"`
			FutureTab string `json:"futureTab"`
		} `json:"tabs"`
		ClosedIDs []string `json:"closedIds"`
		CurrentID string   `json:"currentId"`
		Future    string   `json:"future"`
	}
	if json.Unmarshal(b, &state) != nil || len(state.Tabs) != want.count || state.Future != "keep" {
		return false
	}
	if want.machineID != "" && (len(state.Tabs) == 0 || state.Tabs[len(state.Tabs)-1].MachineID != want.machineID) {
		return false
	}
	if want.machineID != "" && state.Tabs[0].FutureTab != "keep" {
		return false
	}
	if want.closed != "" && (len(state.ClosedIDs) != 1 || state.ClosedIDs[0] != want.closed || state.CurrentID != "") {
		return false
	}
	return true
}

// Stored state with a tab and two fields this server does not model, so edits
// prove unknown fields survive a round trip.
const originalTabState = `{"version":1,"tabs":[{"id":"11111111-1111-4111-8111-111111111111","machineId":"m1","futureTab":"keep"}],"currentId":"11111111-1111-4111-8111-111111111111","future":"keep"}`

func TestAdminTabMutationsStayWithTargetAccount(t *testing.T) {
	for _, tc := range []struct {
		name    string
		method  string
		path    string
		body    string
		count   int
		closed  string
		machine string
	}{
		{"add", "POST", "/admin/api/users/8/tabs", `{"machineId":"m2"}`, 2, "", "m2"},
		{"close", "DELETE", "/admin/api/users/8/tabs/11111111-1111-4111-8111-111111111111", "", 0, "11111111-1111-4111-8111-111111111111", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			mock.ExpectBegin()
			mock.ExpectQuery("SELECT id FROM users WHERE id").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(8))
			mock.ExpectExec("INSERT INTO user_configs").WithArgs(uint64(8), []byte(`{"version":1,"tabs":[]}`)).WillReturnResult(sqlmock.NewResult(0, 0))
			mock.ExpectQuery("SELECT tabs,recent_selection FROM user_configs").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"tabs", "recent_selection"}).AddRow([]byte(originalTabState), []byte(`{"tabId":"11111111-1111-4111-8111-111111111111","machineId":"m1"}`)))
			if tc.machine != "" {
				mock.ExpectQuery("SELECT id FROM machines").WithArgs(tc.machine).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(tc.machine))
			}
			mock.ExpectExec("UPDATE user_configs SET tabs=").WithArgs(tabsArg{count: tc.count, closed: tc.closed, machineID: tc.machine}, sqlmock.AnyArg(), uint64(8)).WillReturnResult(sqlmock.NewResult(0, 1))
			mock.ExpectExec("UPDATE users SET config_version").WithArgs(uint64(8)).WillReturnResult(sqlmock.NewResult(0, 1))
			mock.ExpectCommit()
			r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
			r.SetPathValue("id", "8")
			if tc.closed != "" {
				r.SetPathValue("tabId", tc.closed)
			}
			w := httptest.NewRecorder()
			a := &app{db: db}
			if tc.method == "POST" {
				a.addUserTab(w, r, user{ID: 7, Admin: true})
			} else {
				a.closeUserTab(w, r, user{ID: 7, Admin: true})
			}
			if w.Code != http.StatusNoContent {
				t.Fatalf("status %d: %s", w.Code, w.Body.String())
			}
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestAdminCannotCloseAnotherAccountsTab(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT id FROM users WHERE id").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(8))
	mock.ExpectExec("INSERT INTO user_configs").WithArgs(uint64(8), []byte(`{"version":1,"tabs":[]}`)).WillReturnResult(sqlmock.NewResult(0, 0))
	mock.ExpectQuery("SELECT tabs,recent_selection FROM user_configs").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"tabs", "recent_selection"}).AddRow([]byte(`{"version":1,"tabs":[]}`), nil))
	mock.ExpectRollback()
	r := httptest.NewRequest("DELETE", "/admin/api/users/8/tabs/11111111-1111-4111-8111-111111111111", nil)
	r.SetPathValue("id", "8")
	r.SetPathValue("tabId", "11111111-1111-4111-8111-111111111111")
	w := httptest.NewRecorder()
	(&app{db: db}).closeUserTab(w, r, user{ID: 7, Admin: true})
	if w.Code != 404 {
		t.Fatalf("status %d", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// Editing another account's tabs is what the account-isolation rule (#29)
// forbids ordinary accounts from doing, so these routes are the only place it
// happens and must stay behind the admin session plus the mutation header.
// Guards the wiring: a route registered outside adminAuth, or one whose method
// skips adminMutation, fails here.
func TestAdminTabRoutesStayBehindAdminAuth(t *testing.T) {
	adminToken := []byte("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	memberToken := []byte("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
	adminDigest := sha256.Sum256(adminToken)
	memberDigest := sha256.Sum256(memberToken)
	const tabPath = "/admin/api/users/8/tabs/11111111-1111-4111-8111-111111111111"
	for _, tc := range []struct {
		name   string
		token  []byte
		digest []byte
		admin  bool
		header bool
		method string
		path   string
		status int
	}{
		{"member add", memberToken, memberDigest[:], false, true, "POST", "/admin/api/users/8/tabs", 401},
		{"member close", memberToken, memberDigest[:], false, true, "DELETE", tabPath, 401},
		{"admin add without header", adminToken, adminDigest[:], true, false, "POST", "/admin/api/users/8/tabs", 403},
		{"admin close without header", adminToken, adminDigest[:], true, false, "DELETE", tabPath, 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			mock.ExpectQuery("SELECT u.id,u.username,u.is_admin").WithArgs(tc.digest).WillReturnRows(sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(7, "who", tc.admin, false, false))
			r := httptest.NewRequest(tc.method, tc.path, nil)
			r.AddCookie(&http.Cookie{Name: adminCookie, Value: hex.EncodeToString(tc.token)})
			if tc.header {
				r.Header.Set("X-Blink-Admin", "1")
			}
			w := httptest.NewRecorder()
			(&app{db: db}).routes().ServeHTTP(w, r)
			if w.Code != tc.status {
				t.Fatalf("status %d: %s", w.Code, w.Body.String())
			}
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// The dashboard reads and writes through the router, so a passing handler test
// is not enough: the add route has to be reachable with an admin session and
// the mutation header, and it must write the account named in the path.
func TestAdminAddTabRouteReachesTargetAccount(t *testing.T) {
	token := []byte("cccccccccccccccccccccccccccccccc")
	digest := sha256.Sum256(token)
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	mock.ExpectQuery("SELECT u.id,u.username,u.is_admin").WithArgs(digest[:]).WillReturnRows(sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(7, "who", true, false, false))
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT id FROM users WHERE id").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(8))
	mock.ExpectExec("INSERT INTO user_configs").WithArgs(uint64(8), []byte(`{"version":1,"tabs":[]}`)).WillReturnResult(sqlmock.NewResult(0, 0))
	mock.ExpectQuery("SELECT tabs,recent_selection FROM user_configs").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"tabs", "recent_selection"}).AddRow([]byte(originalTabState), []byte(`{}`)))
	mock.ExpectQuery("SELECT id FROM machines").WithArgs("m1").WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow("m1"))
	mock.ExpectExec("UPDATE user_configs SET tabs=").WithArgs(tabsArg{count: 2, machineID: "m1"}, sqlmock.AnyArg(), uint64(8)).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE users SET config_version").WithArgs(uint64(8)).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	r := httptest.NewRequest("POST", "/admin/api/users/8/tabs", strings.NewReader(`{"machineId":"m1"}`))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Blink-Admin", "1")
	r.AddCookie(&http.Cookie{Name: adminCookie, Value: hex.EncodeToString(token)})
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != http.StatusNoContent {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
