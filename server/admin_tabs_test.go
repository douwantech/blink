package main

import (
	"context"
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

// Stored state with a tab and two fields this server does not model, so edits
// prove unknown fields survive a round trip.
const originalTabState = `{"version":1,"tabs":[{"id":"11111111-1111-4111-8111-111111111111","machineId":"m1","futureTab":"keep"}],"currentId":"11111111-1111-4111-8111-111111111111","future":"keep"}`

// A tab already linked to the jack/blink stream on m1: the triple an admin
// must not be able to add a second time.
const linkedTabState = `{"version":1,"tabs":[{"id":"22222222-2222-4222-8222-222222222222","machineId":"m1","tmuxSession":"jack-blink","futureTab":"keep"}],"currentId":"22222222-2222-4222-8222-222222222222","future":"keep"}`

type tabsArg struct {
	count     int
	closed    string
	machineID string
	session   string
}

func (want tabsArg) Match(value driver.Value) bool {
	b, ok := value.([]byte)
	if !ok {
		return false
	}
	var state struct {
		Tabs []struct {
			ID          string `json:"id"`
			MachineID   string `json:"machineId"`
			TmuxSession string `json:"tmuxSession"`
			FutureTab   string `json:"futureTab"`
		} `json:"tabs"`
		ClosedIDs []string `json:"closedIds"`
		CurrentID string   `json:"currentId"`
		Future    string   `json:"future"`
	}
	if json.Unmarshal(b, &state) != nil || len(state.Tabs) != want.count || state.Future != "keep" {
		return false
	}
	if want.machineID != "" {
		last := state.Tabs[len(state.Tabs)-1]
		if last.MachineID != want.machineID || last.TmuxSession != want.session || state.Tabs[0].FutureTab != "keep" {
			return false
		}
	}
	if want.closed != "" && (len(state.ClosedIDs) != 1 || state.ClosedIDs[0] != want.closed || state.CurrentID != "") {
		return false
	}
	return true
}

// adminRequest returns a request carrying a valid admin session cookie and the
// same-origin mutation header, and queues the session lookup the router runs
// for it. body may be empty for DELETE.
func adminRequest(t *testing.T, mock sqlmock.Sqlmock, method, path, body string) *http.Request {
	t.Helper()
	return sessionRequest(t, mock, method, path, body, true, true)
}

func sessionRequest(t *testing.T, mock sqlmock.Sqlmock, method, path, body string, admin, header bool) *http.Request {
	t.Helper()
	token := []byte(strings.Repeat("k", 32))
	digest := sha256.Sum256(token)
	mock.ExpectQuery("SELECT u.id,u.username,u.is_admin").WithArgs(digest[:]).
		WillReturnRows(sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(7, "laoda", admin, true, false))
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		r.Header.Set("Content-Type", "application/json")
	}
	if header {
		r.Header.Set("X-Blink-Admin", "1")
	}
	r.AddCookie(&http.Cookie{Name: adminCookie, Value: hex.EncodeToString(token)})
	return r
}

// expectAddTab queues everything an admin add runs once the account row is
// locked. The stored state is originalTabState, so an add must land at
// count tabs with the new one last.
func expectAddTab(mock sqlmock.Sqlmock, uid uint64, machine, employee, project string, count int) {
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT id FROM users WHERE id").WithArgs(uid).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(uid))
	mock.ExpectExec("INSERT INTO user_configs").WithArgs(uid, []byte(`{"version":1,"tabs":[]}`)).WillReturnResult(sqlmock.NewResult(0, 0))
	mock.ExpectQuery("SELECT tabs,recent_selection FROM user_configs").WithArgs(uid).WillReturnRows(sqlmock.NewRows([]string{"tabs", "recent_selection"}).AddRow([]byte(originalTabState), []byte(`{}`)))
	for _, ref := range []struct{ table, id string }{{"machines", machine}, {"employees", employee}, {"projects", project}} {
		mock.ExpectQuery("SELECT id FROM " + ref.table).WithArgs(ref.id).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(ref.id))
	}
	mock.ExpectExec("INSERT INTO tab_links").WithArgs(uid, sqlmock.AnyArg(), employee, project).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE user_configs SET tabs=").WithArgs(tabsArg{count: count, machineID: machine, session: employee + "-" + project}, sqlmock.AnyArg(), uid).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE users SET config_version").WithArgs(uid).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
}

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
		{"add", "POST", "/admin/api/users/8/tabs", `{"machineId":"m2","employeeId":"jack","projectId":"blink"}`, 2, "", "m2"},
		{"close", "DELETE", "/admin/api/users/8/tabs/11111111-1111-4111-8111-111111111111", "", 0, "11111111-1111-4111-8111-111111111111", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			if tc.method == "POST" {
				expectAddTab(mock, 8, "m2", "jack", "blink", 2)
			} else {
				mock.ExpectBegin()
				mock.ExpectQuery("SELECT id FROM users WHERE id").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(8))
				mock.ExpectExec("INSERT INTO user_configs").WithArgs(uint64(8), []byte(`{"version":1,"tabs":[]}`)).WillReturnResult(sqlmock.NewResult(0, 0))
				mock.ExpectQuery("SELECT tabs,recent_selection FROM user_configs").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"tabs", "recent_selection"}).AddRow([]byte(originalTabState), []byte(`{"tabId":"11111111-1111-4111-8111-111111111111","machineId":"m1"}`)))
				mock.ExpectExec("DELETE FROM tab_links").WithArgs(uint64(8), "11111111-1111-4111-8111-111111111111").WillReturnResult(sqlmock.NewResult(0, 1))
				mock.ExpectExec("UPDATE user_configs SET tabs=").WithArgs(tabsArg{count: tc.count, closed: tc.closed}, sqlmock.AnyArg(), uint64(8)).WillReturnResult(sqlmock.NewResult(0, 1))
				mock.ExpectExec("UPDATE users SET config_version").WithArgs(uint64(8)).WillReturnResult(sqlmock.NewResult(0, 1))
				mock.ExpectCommit()
			}
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

// A tab is the triple employee + project + machine, so a partial request must
// not reach the database at all.
func TestAddTabRequiresAllThreeReferences(t *testing.T) {
	for _, tc := range []struct{ name, body string }{
		{"no machine", `{"employeeId":"jack","projectId":"blink"}`},
		{"no employee", `{"machineId":"m1","projectId":"blink"}`},
		{"no project", `{"machineId":"m1","employeeId":"jack"}`},
		{"empty body", `{}`},
		{"employee with a slash", `{"machineId":"m1","employeeId":"jack/x","projectId":"blink"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			r := httptest.NewRequest("POST", "/admin/api/users/8/tabs", strings.NewReader(tc.body))
			r.SetPathValue("id", "8")
			w := httptest.NewRecorder()
			(&app{db: db}).addUserTab(w, r, user{ID: 7, Admin: true})
			if w.Code != 400 {
				t.Fatalf("status %d: %s", w.Code, w.Body.String())
			}
			// No transaction was opened: the request was rejected on shape.
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestAddTabRejectsReferenceThatDoesNotExist(t *testing.T) {
	for _, tc := range []struct{ name, table, id string }{
		{"unknown machine", "machines", "m9"},
		{"unknown employee", "employees", "nobody"},
		{"unknown project", "projects", "nothing"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			want := map[string]string{"machines": "m1", "employees": "jack", "projects": "blink"}
			mock.ExpectBegin()
			mock.ExpectQuery("SELECT id FROM users WHERE id").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(8))
			mock.ExpectExec("INSERT INTO user_configs").WithArgs(uint64(8), []byte(`{"version":1,"tabs":[]}`)).WillReturnResult(sqlmock.NewResult(0, 0))
			mock.ExpectQuery("SELECT tabs,recent_selection FROM user_configs").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"tabs", "recent_selection"}).AddRow([]byte(originalTabState), []byte(`{}`)))
			// The handler checks the three references in order and stops at the
			// first one missing, so queue only up to and including it.
			for _, table := range []string{"machines", "employees", "projects"} {
				rows := sqlmock.NewRows([]string{"id"})
				if table != tc.table {
					rows.AddRow(want[table])
				}
				mock.ExpectQuery("SELECT id FROM " + table).WithArgs(want[table]).WillReturnRows(rows)
				if table == tc.table {
					break
				}
			}
			mock.ExpectRollback()
			body := `{"machineId":"m1","employeeId":"jack","projectId":"blink"}`
			r := httptest.NewRequest("POST", "/admin/api/users/8/tabs", strings.NewReader(body))
			r.SetPathValue("id", "8")
			w := httptest.NewRecorder()
			(&app{db: db}).addUserTab(w, r, user{ID: 7, Admin: true})
			if w.Code != 400 {
				t.Fatalf("status %d: %s", w.Code, w.Body.String())
			}
			if err := mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// One session per employee, project and machine — a second identical triple is
// a mistake, and nothing may be written for it.
func TestAddTabRejectsDuplicateTriple(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT id FROM users WHERE id").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(8))
	mock.ExpectExec("INSERT INTO user_configs").WithArgs(uint64(8), []byte(`{"version":1,"tabs":[]}`)).WillReturnResult(sqlmock.NewResult(0, 0))
	mock.ExpectQuery("SELECT tabs,recent_selection FROM user_configs").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"tabs", "recent_selection"}).AddRow([]byte(linkedTabState), []byte(`{}`)))
	for _, table := range []string{"machines", "employees", "projects"} {
		mock.ExpectQuery("SELECT id FROM " + table).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow("x"))
	}
	// No INSERT INTO tab_links and no UPDATE: the duplicate stops the edit.
	mock.ExpectRollback()
	body := `{"machineId":"m1","employeeId":"jack","projectId":"blink"}`
	r := httptest.NewRequest("POST", "/admin/api/users/8/tabs", strings.NewReader(body))
	r.SetPathValue("id", "8")
	w := httptest.NewRecorder()
	(&app{db: db}).addUserTab(w, r, user{ID: 7, Admin: true})
	if w.Code != 409 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// The same employee and project on another machine is a different session, so
// it stays allowed.
func TestAddTabAllowsSamePairOnAnotherMachine(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT id FROM users WHERE id").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(8))
	mock.ExpectExec("INSERT INTO user_configs").WithArgs(uint64(8), []byte(`{"version":1,"tabs":[]}`)).WillReturnResult(sqlmock.NewResult(0, 0))
	mock.ExpectQuery("SELECT tabs,recent_selection FROM user_configs").WithArgs(uint64(8)).WillReturnRows(sqlmock.NewRows([]string{"tabs", "recent_selection"}).AddRow([]byte(linkedTabState), []byte(`{}`)))
	for _, table := range []string{"machines", "employees", "projects"} {
		mock.ExpectQuery("SELECT id FROM " + table).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow("x"))
	}
	mock.ExpectExec("INSERT INTO tab_links").WithArgs(uint64(8), sqlmock.AnyArg(), "jack", "blink").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE user_configs SET tabs=").WithArgs(tabsArg{count: 2, machineID: "m2", session: "jack-blink"}, sqlmock.AnyArg(), uint64(8)).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE users SET config_version").WithArgs(uint64(8)).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	body := `{"machineId":"m2","employeeId":"jack","projectId":"blink"}`
	r := httptest.NewRequest("POST", "/admin/api/users/8/tabs", strings.NewReader(body))
	r.SetPathValue("id", "8")
	w := httptest.NewRecorder()
	(&app{db: db}).addUserTab(w, r, user{ID: 7, Admin: true})
	if w.Code != http.StatusNoContent {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestDirectoryIDValidation(t *testing.T) {
	for _, tc := range []struct {
		id   string
		want bool
	}{
		{"jack", true}, {"peter", true}, {"blink", true}, {"huum-2", true}, {"a.b_c", true},
		{"", false}, {"-lead", false}, {"jack/x", false}, {"jack x", false}, {"j\\x", false},
		// Uppercase is rejected so two entries cannot differ only by case and
		// produce two session names nobody can tell apart.
		{"Jack", false}, {"BLINK", false}, {"jackJ", false},
		{strings.Repeat("a", 60), true}, {strings.Repeat("a", 61), false},
	} {
		if got := validDirectoryID(tc.id); got != tc.want {
			t.Errorf("validDirectoryID(%q) = %v, want %v", tc.id, got, tc.want)
		}
	}
}

// Editing another account's tabs is what the account-isolation rule (#29)
// forbids ordinary accounts from doing, so these routes are the only place it
// happens and must stay behind the admin session plus the mutation header.
// Guards the wiring: a route registered outside adminAuth, or one whose method
// skips adminMutation, fails here.
func TestAdminMutationRoutesStayBehindAdminAuth(t *testing.T) {
	for _, tc := range []struct{ name, method, path, body string }{
		{"add tab", "POST", "/admin/api/users/8/tabs", `{"machineId":"m1","employeeId":"jack","projectId":"blink"}`},
		{"close tab", "DELETE", "/admin/api/users/8/tabs/11111111-1111-4111-8111-111111111111", ""},
		{"put employee", "PUT", "/admin/api/employees/jack", `{"id":"jack","name":"Jack"}`},
		{"delete employee", "DELETE", "/admin/api/employees/jack", ""},
		{"put project", "PUT", "/admin/api/projects/blink", `{"id":"blink","name":"Blink"}`},
		{"delete project", "DELETE", "/admin/api/projects/blink", ""},
	} {
		for _, who := range []struct {
			name   string
			admin  bool
			header bool
			status int
		}{
			{"member", false, true, 401},
			{"admin without mutation header", true, false, 403},
		} {
			t.Run(tc.name+"/"+who.name, func(t *testing.T) {
				db, mock, err := sqlmock.New()
				if err != nil {
					t.Fatal(err)
				}
				defer db.Close()
				r := sessionRequest(t, mock, tc.method, tc.path, tc.body, who.admin, who.header)
				w := httptest.NewRecorder()
				(&app{db: db}).routes().ServeHTTP(w, r)
				if w.Code != who.status {
					t.Fatalf("status %d: %s", w.Code, w.Body.String())
				}
				if err := mock.ExpectationsWereMet(); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

// The dashboard reads and writes through the router, so a passing handler test
// is not enough: the add route has to be reachable with an admin session and
// the mutation header, and it must write the account named in the path.
func TestAdminAddTabRouteReachesTargetAccount(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := adminRequest(t, mock, "POST", "/admin/api/users/8/tabs", `{"machineId":"m1","employeeId":"peter","projectId":"huum"}`)
	expectAddTab(mock, 8, "m1", "peter", "huum", 2)
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != http.StatusNoContent {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestDirectoryRoutesThroughRouter(t *testing.T) {
	t.Run("create", func(t *testing.T) {
		db, mock, err := sqlmock.New()
		if err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		r := adminRequest(t, mock, "PUT", "/admin/api/employees/jack", `{"id":"jack","name":"Jack"}`)
		mock.ExpectExec("INSERT INTO employees").WithArgs("jack", jsonArg(`{"id":"jack","name":"Jack"}`)).WillReturnResult(sqlmock.NewResult(0, 1))
		w := httptest.NewRecorder()
		(&app{db: db}).routes().ServeHTTP(w, r)
		if w.Code != 200 || !strings.Contains(w.Body.String(), `"name":"Jack"`) {
			t.Fatalf("status %d: %s", w.Code, w.Body.String())
		}
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("delete missing", func(t *testing.T) {
		db, mock, err := sqlmock.New()
		if err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		r := adminRequest(t, mock, "DELETE", "/admin/api/projects/nothing", "")
		mock.ExpectExec("DELETE FROM projects").WithArgs("nothing").WillReturnResult(sqlmock.NewResult(0, 0))
		w := httptest.NewRecorder()
		(&app{db: db}).routes().ServeHTTP(w, r)
		if w.Code != 404 {
			t.Fatalf("status %d: %s", w.Code, w.Body.String())
		}
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("rejects mismatched path and body", func(t *testing.T) {
		db, mock, err := sqlmock.New()
		if err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		r := adminRequest(t, mock, "PUT", "/admin/api/projects/blink", `{"id":"huum","name":"Huum"}`)
		w := httptest.NewRecorder()
		(&app{db: db}).routes().ServeHTTP(w, r)
		if w.Code != 400 {
			t.Fatalf("status %d: %s", w.Code, w.Body.String())
		}
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	})
}

// The directory handlers splice their table name into SQL, so the name must
// come from the literals in admin_directory.go and never from a caller. Today
// only the routes call these, but a request-derived name must not be able to
// reach a query: the guard rejects it before touching the database.
func TestDirectoryHandlersRejectUnknownTable(t *testing.T) {
	for _, table := range []string{"users", "sessions", "employees; DROP TABLE users", "tab_links"} {
		t.Run(table, func(t *testing.T) {
			// A nil *sql.DB panics the moment anything dereferences it, so this
			// proves the rejection happened before the handler reached a query
			// rather than because a query failed. sqlmock could not tell the two
			// apart: an unexpected statement is an error, and so is a rejection.
			a := &app{}
			admin := user{Admin: true, CanWrite: true}

			r := httptest.NewRequest("PUT", "/admin/api/employees/jack", strings.NewReader(`{"id":"jack","name":"Jack"}`))
			r.Header.Set("Content-Type", "application/json")
			r.SetPathValue("id", "jack")
			w := httptest.NewRecorder()
			a.putDirectoryEntry(table)(w, r, admin)
			if w.Code != 500 {
				t.Fatalf("put %q: status %d, want 500", table, w.Code)
			}

			r = httptest.NewRequest("DELETE", "/admin/api/employees/jack", nil)
			r.SetPathValue("id", "jack")
			w = httptest.NewRecorder()
			a.deleteDirectoryEntry(table)(w, r, admin)
			if w.Code != 500 {
				t.Fatalf("delete %q: status %d, want 500", table, w.Code)
			}

			if _, err := a.listDirectory(context.Background(), table); err == nil {
				t.Fatalf("listDirectory(%q) returned no error", table)
			}
		})
	}
}

// These handlers check the caller themselves instead of trusting the router's
// wrapper, so a non-admin is refused even when the handler is invoked directly
// with a checked user. The nil database again turns "touched the database"
// into a panic rather than a status code.
func TestDirectoryHandlersRefuseNonAdminOnTheirOwn(t *testing.T) {
	a := &app{}
	for _, u := range []user{{}, {CanWrite: true}} {
		r := httptest.NewRequest("PUT", "/admin/api/employees/jack", strings.NewReader(`{"id":"jack","name":"Jack"}`))
		r.Header.Set("Content-Type", "application/json")
		r.SetPathValue("id", "jack")
		w := httptest.NewRecorder()
		a.putDirectoryEntry("employees")(w, r, u)
		if w.Code != 403 {
			t.Fatalf("put with %+v: status %d, want 403", u, w.Code)
		}

		r = httptest.NewRequest("DELETE", "/admin/api/employees/jack", nil)
		r.SetPathValue("id", "jack")
		w = httptest.NewRecorder()
		a.deleteDirectoryEntry("employees")(w, r, u)
		if w.Code != 403 {
			t.Fatalf("delete with %+v: status %d, want 403", u, w.Code)
		}
	}
}

// The whitelist is what keeps a table name out of the SQL string, so pin the
// exact set it admits. Reachable names come only from admin_directory.go.
func TestDirectoryWhitelistAdmitsOnlyTheSharedDirectories(t *testing.T) {
	for _, table := range []string{"employees", "projects"} {
		if !directoryTables[table] {
			t.Fatalf("%s must be an allowed directory table", table)
		}
	}
	for _, table := range []string{"", "users", "sessions", "machines", "user_configs", "tab_links", "employees_archive"} {
		if directoryTables[table] {
			t.Fatalf("%q must not be an allowed directory table", table)
		}
	}
	if len(directoryTables) != 2 {
		t.Fatalf("directoryTables has %d entries, want exactly 2: %v", len(directoryTables), directoryTables)
	}
}

// The dashboard needs the two directories plus each tab's link to show the
// employee and the project next to a tab.
func TestAdminStateExposesDirectoriesAndTabLinks(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := adminRequest(t, mock, "GET", "/admin/api/state", "")
	mock.ExpectQuery("SELECT id,username,is_admin").WillReturnRows(sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(7, "laoda", true, true, false))
	mock.ExpectQuery("SELECT position,data FROM machines").WillReturnRows(sqlmock.NewRows([]string{"position", "data"}))
	mock.ExpectQuery("SELECT data FROM employees").WillReturnRows(sqlmock.NewRows([]string{"data"}).AddRow([]byte(`{"id":"jack","name":"Jack"}`)))
	mock.ExpectQuery("SELECT data FROM projects").WillReturnRows(sqlmock.NewRows([]string{"data"}).AddRow([]byte(`{"id":"blink","name":"Blink"}`)))
	mock.ExpectQuery("SELECT user_id,tab_id,employee_id,project_id FROM tab_links").WillReturnRows(sqlmock.NewRows([]string{"user_id", "tab_id", "employee_id", "project_id"}).AddRow(7, "22222222-2222-4222-8222-222222222222", "jack", "blink"))
	mock.ExpectQuery("SELECT u.id,c.tabs,c.recent_selection").WillReturnRows(sqlmock.NewRows([]string{"id", "tabs", "recent_selection"}).AddRow(7, []byte(linkedTabState), nil))
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	for _, want := range []string{`"employees":[{"id":"jack"`, `"projects":[{"id":"blink"`, `"22222222-2222-4222-8222-222222222222":{"employeeId":"jack","projectId":"blink"}`} {
		if !strings.Contains(body, want) {
			t.Fatalf("state is missing %s:\n%s", want, body)
		}
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
