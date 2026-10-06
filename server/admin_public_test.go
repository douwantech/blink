package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

// Two public projects plus one that is not public, which must stay out of every
// list.
func publicProjectsFixture() []projectEntry {
	return []projectEntry{
		{ID: "huum", Name: "Huum", Public: true, Employees: []projectEmployee{{ID: "jack", MachineID: "m1"}, {ID: "tom", MachineID: "m2"}}},
		{ID: "lotly", Name: "Lotly", Public: true, Employees: []projectEmployee{{ID: "tom", MachineID: "m2"}}},
		{ID: "blink", Name: "Blink"},
	}
}

func sharedFixture() []publicTabEntry {
	return clientPublicTabs(buildPublicTabView(publicProjectsFixture()))
}

func decodeMerged(t *testing.T, out []byte) (fields map[string]json.RawMessage, tabs []map[string]any, closed []string) {
	t.Helper()
	if err := json.Unmarshal(out, &fields); err != nil {
		t.Fatalf("merged state is not an object: %v (%s)", err, out)
	}
	if err := json.Unmarshal(fields["tabs"], &tabs); err != nil {
		t.Fatalf("merged tabs are not an array: %v", err)
	}
	if b, ok := fields["closedIds"]; ok {
		if err := json.Unmarshal(b, &closed); err != nil {
			t.Fatalf("merged closedIds are not an array: %v", err)
		}
	}
	return fields, tabs, closed
}

func TestPublicTabViewExpandsEveryList(t *testing.T) {
	view := buildPublicTabView(publicProjectsFixture())
	if len(view) != 3 {
		t.Fatalf("view %+v, want one tab per public pair", view)
	}
	bySession := map[string]publicTabView{}
	for _, v := range view {
		bySession[v.Session] = v
	}
	jack := bySession["jack-huum"]
	if jack.ProjectID != "huum" || jack.EmployeeID != "jack" || jack.MachineID != "m1" || jack.ProjectName != "Huum" {
		t.Fatalf("jack-huum %+v", jack)
	}
	if tom := bySession["tom-lotly"]; tom.MachineID != "m2" || tom.ProjectName != "Lotly" {
		t.Fatalf("tom-lotly %+v", tom)
	}
	for _, v := range view {
		if v.ProjectID == "blink" {
			t.Fatalf("a project that is not public must contribute nothing: %+v", v)
		}
	}
}

func TestPublicTabViewIsOrderedAndSkipsNonPublicProjects(t *testing.T) {
	// Deliberately unsorted, with the employee list unsorted too: the set has to
	// come out in the same order for every account or the tab bar would shuffle
	// between clients.
	projects := []projectEntry{
		{ID: "talkai", Name: "Talk", Public: true, Employees: []projectEmployee{{ID: "tom", MachineID: "m2"}, {ID: "adam", MachineID: "m1"}}},
		{ID: "ben", Name: "Ben", Public: true, Employees: []projectEmployee{{ID: "quan", MachineID: "m3"}}},
		{ID: "main", Name: "Main"},
	}
	var got []string
	for _, v := range buildPublicTabView(projects) {
		got = append(got, v.Session)
	}
	want := []string{"quan-ben", "adam-talkai", "tom-talkai"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("order %v, want %v", got, want)
	}
}

// The IDs are UUIDv5 in a fixed namespace and are checked against values
// computed independently (python uuid.uuid5 over the same namespace and name),
// because a client decodes TabEntry.id as a UUID and a wrong one would be
// dropped or rejected.
func TestPublicTabIDsAreStableNameBasedUUIDs(t *testing.T) {
	cases := []struct{ employee, project, want string }{
		{"jack", "huum", "c58c3b7b-a2f3-57c9-9cdb-c80dc468c20e"},
		{"tom", "printer", "30cc71d4-8b19-5ac1-8464-7fac3535f758"},
	}
	for _, c := range cases {
		got := publicTabID(c.employee, c.project)
		if got != c.want {
			t.Errorf("publicTabID(%q, %q) = %q, want %q", c.employee, c.project, got, c.want)
		}
		if len(got) != 36 || strings.Count(got, "-") != 4 {
			t.Errorf("%q is not a UUID", got)
		}
		if got[14] != '5' || !strings.ContainsRune("89ab", rune(got[19])) {
			t.Errorf("%q is not a version 5 RFC 4122 UUID", got)
		}
		if got != strings.ToLower(got) {
			t.Errorf("%q is not lowercase", got)
		}
	}
	// Derived, not generated: the same pair is the same ID on every read, and
	// two pairs never share one.
	if publicTabID("jack", "huum") != publicTabID("jack", "huum") {
		t.Error("the same pair must get the same ID every time")
	}
	if publicTabID("jack", "huum") == publicTabID("tom", "huum") {
		t.Error("two employees on one project must not share an ID")
	}
}

// A separator has to be used when hashing, or the pair (a-b, c) and the pair
// (a, b-c) produce one ID and a client loses a tab.
func TestPublicTabIDsSeparateAmbiguousPairs(t *testing.T) {
	first := publicTabID("a-b", "c")
	second := publicTabID("a", "b-c")
	if first == second {
		t.Fatalf("a-b|c and a|b-c must not collide: %q", first)
	}
	if first != "3b72ee12-f0d8-5380-86da-e69b1203cd62" || second != "7889f261-c458-51ea-9a07-7f10015d24c1" {
		t.Fatalf("unexpected IDs: %q %q", first, second)
	}
}

func TestClientPublicTabsAreSharedEntries(t *testing.T) {
	entries := sharedFixture()
	if len(entries) != 3 {
		t.Fatalf("entries %+v", entries)
	}
	for _, e := range entries {
		if !e.Shared {
			t.Errorf("%+v must be marked shared", e)
		}
		if e.ID == "" || e.MachineID == "" || e.TmuxSession == "" {
			t.Errorf("%+v is missing a field a client needs to open the tab", e)
		}
	}
	// Only the three fields the client's TabEntry knows, so an old client that
	// does not model `shared` still decodes an ordinary tab.
	b, err := json.Marshal(entries[0])
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) > 0 && strings.Contains(string(b), "position") {
		t.Fatalf("entry JSON %s carries a field the client does not model", b)
	}
}

func TestEmployeeMachinesAreDerivedFromTheLists(t *testing.T) {
	got := employeeMachines(publicProjectsFixture())
	if len(got["jack"]) != 1 || got["jack"][0] != "m1" {
		t.Fatalf("jack %v, want m1", got["jack"])
	}
	if len(got["tom"]) != 1 || got["tom"][0] != "m2" {
		t.Fatalf("tom %v, want m2 once even though two lists name him", got["tom"])
	}
	if _, ok := got["ben"]; ok {
		t.Fatalf("ben is on no list: %v", got)
	}
}

// Two lists putting one employee on different machines is a data error that
// would send somebody to the wrong host, so both are reported rather than one
// being picked.
func TestEmployeeMachinesReportsADisagreementWithBoth(t *testing.T) {
	projects := []projectEntry{
		{ID: "huum", Name: "Huum", Public: true, Employees: []projectEmployee{{ID: "jack", MachineID: "m1"}}},
		{ID: "ben", Name: "Ben", Public: true, Employees: []projectEmployee{{ID: "jack", MachineID: "m9"}}},
		{ID: "talkai", Name: "Talk", Employees: []projectEmployee{{ID: "jack", MachineID: "m3"}}},
	}
	got := employeeMachines(projects)
	if strings.Join(got["jack"], ",") != "m9,m1" {
		t.Fatalf("jack %v, want both machines in project order", got["jack"])
	}
}

func TestMergePublicTabsPutsThemFirstAndKeepsTheAccountsOwn(t *testing.T) {
	stored := `{"version":1,"updatedAt":1234.5,"tabs":[{"id":"11111111-1111-4111-8111-111111111111","machineId":"m1","tmuxSession":"mine"}],"closedIds":["22222222-2222-4222-8222-222222222222"]}`
	fields, tabs, closed := decodeMerged(t, mustMerge(t, stored, sharedFixture()))
	if len(tabs) != 4 {
		t.Fatalf("tabs %+v, want the three public ones and the account's own", tabs)
	}
	for i := 0; i < 3; i++ {
		if tabs[i]["shared"] != true {
			t.Fatalf("tab %d is not a public tab first: %+v", i, tabs[i])
		}
	}
	if tabs[3]["tmuxSession"] != "mine" {
		t.Fatalf("the account's own tab must follow: %+v", tabs[3])
	}
	if len(closed) != 1 || closed[0] != "22222222-2222-4222-8222-222222222222" {
		t.Fatalf("a tombstone for the account's own tab must survive: %v", closed)
	}
	// The read path must not look like a local edit: the client gates its merge
	// on updatedAt, and the stored version is untouched.
	if string(fields["updatedAt"]) != "1234.5" || string(fields["version"]) != "1" {
		t.Fatalf("updatedAt/version must be preserved: %s %s", fields["updatedAt"], fields["version"])
	}
}

func TestMergePublicTabsDropsAnAdoptedCopyOfAPublicTab(t *testing.T) {
	// A client that adopted a public tab and uploaded its whole state comes back
	// with the same derived ID. Two tabs under one ID would show twice.
	id := publicTabID("jack", "huum")
	stored := `{"version":1,"tabs":[{"id":"` + id + `","machineId":"m1","tmuxSession":"jack-huum"},{"id":"11111111-1111-4111-8111-111111111111","machineId":"m1","tmuxSession":"mine"}]}`
	_, tabs, _ := decodeMerged(t, mustMerge(t, stored, sharedFixture()))
	if len(tabs) != 4 {
		t.Fatalf("tabs %+v, want three public plus one own", tabs)
	}
	count := 0
	for _, tab := range tabs {
		if tab["id"] == id {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("the public tab appears %d times", count)
	}
	// The uppercase form of an ID is the same tab to the client, so it must be
	// recognised too.
	upper := strings.ToUpper(id)
	stored = `{"version":1,"tabs":[{"id":"` + upper + `","machineId":"m1","tmuxSession":"jack-huum"}]}`
	_, tabs, _ = decodeMerged(t, mustMerge(t, stored, sharedFixture()))
	if len(tabs) != 3 {
		t.Fatalf("tabs %+v, want only the three public ones", tabs)
	}
}

func TestMergePublicTabsDropsTombstonesOfPublicTabs(t *testing.T) {
	// Closing a public tab is not a permanent choice: the set is global, so the
	// tombstone is not carried back or it would suppress the tab on a client
	// that honours it.
	id := publicTabID("jack", "huum")
	stored := `{"version":1,"tabs":[],"closedIds":["` + id + `","22222222-2222-4222-8222-222222222222"]}`
	_, _, closed := decodeMerged(t, mustMerge(t, stored, sharedFixture()))
	if len(closed) != 1 || closed[0] != "22222222-2222-4222-8222-222222222222" {
		t.Fatalf("closedIds %v, want only the account's own tombstone", closed)
	}
}

func TestMergePublicTabsKeepsUnreadableStateAnError(t *testing.T) {
	if _, err := mergePublicTabs([]byte(`not json`), sharedFixture()); err == nil {
		t.Fatal("an unreadable state must not be replaced silently")
	}
}

func TestMergePublicTabsOnAnEmptyAccount(t *testing.T) {
	// An account with no config row at all still gets the public tabs.
	_, tabs, closed := decodeMerged(t, mustMerge(t, "", sharedFixture()))
	if len(tabs) != 3 || len(closed) != 0 {
		t.Fatalf("tabs %+v closed %v", tabs, closed)
	}
}

func TestMergePublicTabsWithNoPublicProjects(t *testing.T) {
	stored := `{"version":1,"tabs":[{"id":"11111111-1111-4111-8111-111111111111","machineId":"m1","tmuxSession":"mine"}]}`
	_, tabs, closed := decodeMerged(t, mustMerge(t, stored, nil))
	if len(tabs) != 1 || len(closed) != 0 {
		t.Fatalf("tabs %+v, want the account's own untouched", tabs)
	}
}

func mustMerge(t *testing.T, stored string, shared []publicTabEntry) []byte {
	t.Helper()
	out, err := mergePublicTabs([]byte(stored), shared)
	if err != nil {
		t.Fatalf("merge failed: %v", err)
	}
	return out
}

// putProject is a read-modify-write, so a request that names only some fields
// must leave the others as they were. Getting this wrong is how an edit that
// only changes the name would silently empty the employee list.
func TestPutProjectKeepsFieldsTheRequestOmits(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	stored := `{"id":"huum","name":"Huum","public":true,"employees":[{"id":"jack","machineId":"m1"}],"future":"keep"}`
	r := adminRequest(t, mock, "PUT", "/admin/api/projects/huum", `{"id":"huum","name":"Huum 2"}`)
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT data FROM projects").WithArgs("huum").WillReturnRows(sqlmock.NewRows([]string{"data"}).AddRow([]byte(stored)))
	mock.ExpectExec("INSERT INTO projects").WithArgs("huum", jsonArg(`{"id":"huum","name":"Huum 2","public":true,"employees":[{"id":"jack","machineId":"m1"}],"future":"keep"}`)).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE config_versions").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestPutProjectReplacesTheEmployeeList(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := adminRequest(t, mock, "PUT", "/admin/api/projects/huum", `{"id":"huum","name":"Huum","public":true,"employees":[{"id":"jack","machineId":"m1"},{"id":"tom","machineId":"m2"}]}`)
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT data FROM projects").WithArgs("huum").WillReturnError(sql.ErrNoRows)
	for _, ref := range []struct{ table, id string }{{"employees", "jack"}, {"machines", "m1"}, {"employees", "tom"}, {"machines", "m2"}} {
		mock.ExpectQuery("SELECT id FROM " + ref.table).WithArgs(ref.id).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(ref.id))
	}
	mock.ExpectExec("INSERT INTO projects").WithArgs("huum", jsonArg(`{"id":"huum","name":"Huum","public":true,"employees":[{"id":"jack","machineId":"m1"},{"id":"tom","machineId":"m2"}]}`)).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE config_versions").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// The public tab set is derived from the project list, so a project write that
// does not move the shared version reaches nobody who has already synced.
func TestPutProjectBumpsTheSharedVersion(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := adminRequest(t, mock, "PUT", "/admin/api/projects/huum", `{"id":"huum","name":"Huum","public":false}`)
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT data FROM projects").WithArgs("huum").WillReturnError(sql.ErrNoRows)
	mock.ExpectExec("INSERT INTO projects").WithArgs("huum", jsonArg(`{"id":"huum","name":"Huum","public":false}`)).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE config_versions SET version=version\\+1 WHERE id=1").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestDeletingAProjectBumpsTheSharedVersion(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := adminRequest(t, mock, "DELETE", "/admin/api/projects/huum", "")
	mock.ExpectBegin()
	mock.ExpectExec("DELETE FROM projects").WithArgs("huum").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE config_versions").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != 204 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// An employee carries no client-visible state, so removing one must not make
// every client re-fetch.
func TestDeletingAnEmployeeDoesNotBumpTheSharedVersion(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := adminRequest(t, mock, "DELETE", "/admin/api/employees/jack", "")
	mock.ExpectBegin()
	mock.ExpectExec("DELETE FROM employees").WithArgs("jack").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != 204 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestPutProjectRejectsAnUnknownEmployee(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := adminRequest(t, mock, "PUT", "/admin/api/projects/huum", `{"id":"huum","name":"Huum","public":true,"employees":[{"id":"nobody","machineId":"m1"}]}`)
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT data FROM projects").WithArgs("huum").WillReturnError(sql.ErrNoRows)
	// The employee is looked up first, so a missing one never reaches the
	// machine.
	mock.ExpectQuery("SELECT id FROM employees").WithArgs("nobody").WillReturnError(sql.ErrNoRows)
	mock.ExpectRollback()
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "employee not found: nobody") {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestPutProjectRejectsAnUnknownMachine(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := adminRequest(t, mock, "PUT", "/admin/api/projects/huum", `{"id":"huum","name":"Huum","public":true,"employees":[{"id":"jack","machineId":"m9"}]}`)
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT data FROM projects").WithArgs("huum").WillReturnError(sql.ErrNoRows)
	mock.ExpectQuery("SELECT id FROM employees").WithArgs("jack").WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow("jack"))
	mock.ExpectQuery("SELECT id FROM machines").WithArgs("m9").WillReturnError(sql.ErrNoRows)
	mock.ExpectRollback()
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "machine not found: m9") {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestPutProjectRejectsADuplicateEmployee(t *testing.T) {
	// Caught before the transaction opens, so no database work happens.
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := adminRequest(t, mock, "PUT", "/admin/api/projects/huum", `{"id":"huum","name":"Huum","public":true,"employees":[{"id":"jack","machineId":"m1"},{"id":"jack","machineId":"m2"}]}`)
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "twice") {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// The generic directory handler writes only the ID and the name, so letting it
// at a project would empty the public flag and the employee list. It refuses
// projects outright, and the nil database proves nothing reaches a query.
func TestGenericDirectoryHandlerRefusesProjects(t *testing.T) {
	a := &app{}
	admin := user{Admin: true, CanWrite: true}
	r := httptest.NewRequest("PUT", "/admin/api/projects/huum", strings.NewReader(`{"id":"huum","name":"Huum"}`))
	r.Header.Set("Content-Type", "application/json")
	r.SetPathValue("id", "huum")
	w := httptest.NewRecorder()
	a.putDirectoryEntry("projects")(w, r, admin)
	if w.Code != 500 {
		t.Fatalf("status %d, want 500", w.Code)
	}
}

// The state the page reads carries the global tab list, not a per-account
// reconciliation, and the machines the employee table shows come from the same
// project lists.
func TestAdminStateCarriesTheGlobalPublicTabs(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r := adminRequest(t, mock, "GET", "/admin/api/state", "")
	mock.ExpectQuery("SELECT id,username,is_admin").WillReturnRows(sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(7, "laoda", true, true, false).AddRow(1, "jack", false, true, false))
	mock.ExpectQuery("SELECT position,data FROM machines").WillReturnRows(sqlmock.NewRows([]string{"position", "data"}).AddRow(0, []byte(`{"id":"m1","host":"h"}`)))
	mock.ExpectQuery("SELECT data FROM employees").WillReturnRows(sqlmock.NewRows([]string{"data"}).AddRow([]byte(`{"id":"jack","name":"Jack"}`)))
	mock.ExpectQuery("SELECT data FROM projects").WillReturnRows(sqlmock.NewRows([]string{"data"}).AddRow([]byte(`{"id":"huum","name":"Huum","public":true,"employees":[{"id":"jack","machineId":"m1"}]}`)))
	mock.ExpectQuery("SELECT position,data FROM pinned_bookmarks").WillReturnRows(sqlmock.NewRows([]string{"position", "data"}))
	mock.ExpectQuery("SELECT user_id,tab_id,employee_id,project_id FROM tab_links").WillReturnRows(sqlmock.NewRows([]string{"user_id", "tab_id", "employee_id", "project_id"}))
	mock.ExpectQuery("SELECT u.id,c.tabs,c.recent_selection").WillReturnRows(sqlmock.NewRows([]string{"id", "tabs", "recent_selection"}).AddRow(1, []byte(`{"version":1,"tabs":[]}`), nil).AddRow(7, []byte(`{"version":1,"tabs":[]}`), nil))
	// 引擎列：没人配过这个标签，所以每条都落默认，但字段必须在。
	mock.ExpectQuery("SELECT u.username,COALESCE\\(c.agents").WillReturnRows(
		sqlmock.NewRows([]string{"username", "agents"}).AddRow("laoda", []byte(`{}`)))
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var payload struct {
		PublicTabs       []publicTabView     `json:"publicTabs"`
		EmployeeMachines map[string][]string `json:"employeeMachines"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.PublicTabs) != 1 {
		t.Fatalf("publicTabs %+v, want the jack-huum tab", payload.PublicTabs)
	}
	row := payload.PublicTabs[0]
	if row.ProjectID != "huum" || row.EmployeeID != "jack" || row.Session != "jack-huum" || row.MachineID != "m1" || row.ProjectName != "Huum" {
		t.Fatalf("row %+v", row)
	}
	if row.TabID != publicTabID("jack", "huum") {
		t.Fatalf("row %+v must carry the ID the client will see", row)
	}
	if row.Engine != defaultEngine {
		t.Fatalf("row %+v must carry the engine, defaulted when nobody configured it", row)
	}
	if got := payload.EmployeeMachines["jack"]; len(got) != 1 || got[0] != "m1" {
		t.Fatalf("employeeMachines %v, want jack on m1", payload.EmployeeMachines)
	}
	// The same tab goes to every account, so it is listed once and never per
	// account.
	if strings.Contains(w.Body.String(), `"status"`) || strings.Contains(w.Body.String(), `"extras"`) {
		t.Fatalf("the reconciliation vocabulary is gone: %s", w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// The admin page reads the derived list rather than reconciling, so it must not
// offer the per-account buttons that went with the report.
func TestAdminPageShowsTheGlobalPublicTabs(t *testing.T) {
	page, err := adminPage.ReadFile("web/admin.html")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"public-rows", "public-summary", "employeeMachines", "state.publicTabs"} {
		if !strings.Contains(string(page), want) {
			t.Fatalf("admin page is missing %q", want)
		}
	}
	for _, gone := range []string{"PUBLIC_STATUS", "fillProject", "createPublicTab", "extra-rows"} {
		if strings.Contains(string(page), gone) {
			t.Fatalf("admin page still carries %q from the reconciliation view", gone)
		}
	}
}

// The agents column is keyed by the client, so the server has to build the key
// the client builds: "<machineId>|<title>", the title lowercased. A mismatch
// here shows every tab as claude and looks like nobody configured anything.
func TestEngineKeyMatchesTheClientsStoreKey(t *testing.T) {
	if got := engineKey("m2", "tom-lotly"); got != "m2|tom-lotly" {
		t.Fatalf("engineKey %q", got)
	}
	if got := engineKey("m2", "TOM-Lotly"); got != engineKey("m2", "tom-lotly") {
		t.Fatalf("title must be matched case-insensitively, got %q", got)
	}
	// The machine ID is a UUID and the client does not touch its case.
	if got := engineKey("M2", "tom-lotly"); got != "M2|tom-lotly" {
		t.Fatalf("engineKey %q, want the machine ID left alone", got)
	}
}

// The tab list is global and the agent choice is per account, so the page reads
// every account's map as one table. Two accounts naming one tab differently is
// settled by the order the query returns (username order), which only has to be
// stable: there is no per-account row for a disagreement to be reported on.
func TestMergeTabEnginesFoldsEveryAccountInOrder(t *testing.T) {
	engines := mergeTabEngines([]accountAgents{
		{Username: "ann", Agents: map[string]string{"m2|tom-lotly": "deepseek", "m1|jack-huum": "codex"}},
		{Username: "bob", Agents: map[string]string{"m2|tom-lotly": "codex"}},
		{Username: "cid", Agents: map[string]string{"m2|tom-huum": ""}},
	})
	if engines["m2|tom-lotly"] != "codex" {
		t.Fatalf("the later account must win: %v", engines)
	}
	if engines["m1|jack-huum"] != "codex" {
		t.Fatalf("an account only has to name a tab to be heard: %v", engines)
	}
	if _, ok := engines["m2|tom-huum"]; ok {
		t.Fatalf("an empty value means nothing and must not shadow a real one: %v", engines)
	}
	if got := mergeTabEngines(nil); len(got) != 0 {
		t.Fatalf("no accounts, no engines: %v", got)
	}
}

func TestWithEnginesFillsEveryRowAndLeavesTheViewAlone(t *testing.T) {
	view := buildPublicTabView(publicProjectsFixture())
	filled := withEngines(view, map[string]string{
		"m2|tom-lotly": "deepseek",
		"m1|jack-huum": "some-new-cli",
	})
	bySession := map[string]string{}
	for _, v := range filled {
		bySession[v.Session] = v.Engine
	}
	if bySession["tom-lotly"] != "deepseek" {
		t.Fatalf("configured tab: %v", bySession)
	}
	// An id the server does not know is passed through rather than rewritten to
	// the default: the page then shows the new CLI instead of a wrong name.
	if bySession["jack-huum"] != "some-new-cli" {
		t.Fatalf("unknown id: %v", bySession)
	}
	if bySession["tom-huum"] != defaultEngine {
		t.Fatalf("unconfigured tab must show the default: %v", bySession)
	}
	for _, v := range view {
		if v.Engine != "" {
			t.Fatalf("the derivation the read path sees must stay engine-free: %+v", v)
		}
	}
}

// The badge is display-only and lives on the page, so a CLI the server passes
// through but the page has never heard of must still render as itself.
func TestAdminPageRendersTheEngineBadge(t *testing.T) {
	page, err := adminPage.ReadFile("web/admin.html")
	if err != nil {
		t.Fatal(err)
	}
	html := string(page)
	for _, want := range []string{"<th>引擎</th>", "const ENGINES = {", "engineBadge", "tab.engine"} {
		if !strings.Contains(html, want) {
			t.Fatalf("admin page is missing %q", want)
		}
	}
	for _, engine := range []string{"claude:", "codex:", "deepseek:"} {
		if !strings.Contains(html, engine) {
			t.Fatalf("admin page has no display entry for %q", engine)
		}
	}
}

// The wiring end to end: what the page gets per row is the engine the accounts
// named for that machine and session, and the default for the rest.
func TestAdminStateFillsPublicTabEngines(t *testing.T) {
	a, mock := mustApp(t)
	mock.ExpectQuery("SELECT id,username,is_admin,can_write,disabled FROM users").WillReturnRows(
		sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(1, "boss", true, true, false))
	mock.ExpectQuery("SELECT position,data FROM machines").WillReturnRows(sqlmock.NewRows([]string{"position", "data"}))
	mock.ExpectQuery("SELECT data FROM employees ORDER BY id").WillReturnRows(sqlmock.NewRows([]string{"data"}))
	mock.ExpectQuery("SELECT data FROM projects ORDER BY id").WillReturnRows(sqlmock.NewRows([]string{"data"}).
		AddRow([]byte(`{"id":"huum","name":"Huum","public":true,"employees":[{"id":"jack","machineId":"m1"},{"id":"kim","machineId":"m3"},{"id":"tom","machineId":"m2"}]}`)))
	mock.ExpectQuery("SELECT position,data FROM pinned_bookmarks").WillReturnRows(sqlmock.NewRows([]string{"position", "data"}))
	mock.ExpectQuery("SELECT user_id,tab_id,employee_id,project_id FROM tab_links").
		WillReturnRows(sqlmock.NewRows([]string{"user_id", "tab_id", "employee_id", "project_id"}))
	mock.ExpectQuery("SELECT u.id,c.tabs,c.recent_selection FROM users u LEFT JOIN user_configs").WillReturnRows(
		sqlmock.NewRows([]string{"id", "tabs", "recent_selection"}))
	// 两个账号各配了一部分：合并后才覆盖到两条，剩下的落默认。
	mock.ExpectQuery("SELECT u.username,COALESCE\\(c.agents").WillReturnRows(
		sqlmock.NewRows([]string{"username", "agents"}).
			AddRow("ann", []byte(`{"m1|jack-huum":"deepseek"}`)).
			AddRow("bob", []byte(`{"m2|tom-huum":"codex"}`)).
			AddRow("cid", []byte(`{"m2|tom-other":"codex"}`)))

	w := httptest.NewRecorder()
	a.adminState(w, httptest.NewRequest(http.MethodGet, "/admin/api/state", nil), user{ID: 1, Admin: true, CanWrite: true})
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var state struct {
		PublicTabs []publicTabView `json:"publicTabs"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	if len(state.PublicTabs) != 3 {
		t.Fatalf("one public project with three employees: %+v", state.PublicTabs)
	}
	engines := map[string]string{}
	for _, tab := range state.PublicTabs {
		engines[tab.Session] = tab.Engine
	}
	if engines["jack-huum"] != "deepseek" || engines["tom-huum"] != "codex" {
		t.Fatalf("engines %v", engines)
	}
	// 一个账号配的是别的会话（tom-other），不该串到同名以外的行上；没人配的落默认。
	if engines["kim-huum"] != defaultEngine {
		t.Fatalf("unconfigured row must show the default: %v", engines)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
