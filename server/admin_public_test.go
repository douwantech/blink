package main

import (
	"database/sql"
	"encoding/json"
	"fmt"

	"net/http/httptest"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

// Two public projects plus one that is not public, which must stay out of the
// view entirely.
func publicProjectsFixture() []projectEntry {
	return []projectEntry{
		{ID: "huum", Name: "Huum", Public: true, Employees: []projectEmployee{{ID: "jack", MachineID: "m1"}, {ID: "tom", MachineID: "m2"}}},
		{ID: "lotly", Name: "Lotly", Public: true, Employees: []projectEmployee{{ID: "tom", MachineID: "m2"}}},
		{ID: "blink", Name: "Blink"},
	}
}

// publicAcct describes an account's tabs compactly:
//
//	"jack-huum@m1"            a tab the client created, known by its session name
//	"jack-huum@m1|jack>huum"  the same tab with the link row an admin-created tab has
func publicAcct(id uint64, name string, specs ...string) publicAccount {
	account := publicAccount{ID: id, Name: name, Links: map[string]publicLink{}}
	for i, spec := range specs {
		tabPart, linkPart, _ := strings.Cut(spec, "|")
		session, machine, _ := strings.Cut(tabPart, "@")
		tab := publicTab{ID: fmt.Sprintf("tab-%d-%d", id, i), MachineID: machine, Session: session}
		if linkPart != "" {
			employee, project, ok := strings.Cut(linkPart, ">")
			if !ok {
				panic("bad link spec: " + spec)
			}
			account.Links[tab.ID] = publicLink{EmployeeID: employee, ProjectID: project}
		}
		account.Tabs = append(account.Tabs, tab)
	}
	return account
}

func publicRow(t *testing.T, report publicReport, employee, project string) publicTabRow {
	t.Helper()
	for _, row := range report.Rows {
		if row.EmployeeID == employee && row.ProjectID == project {
			return row
		}
	}
	t.Fatalf("no row for %s-%s in %+v", employee, project, report.Rows)
	return publicTabRow{}
}

func TestPublicReportFindsMissingTabs(t *testing.T) {
	report := buildPublicReport(publicProjectsFixture(), []publicAccount{publicAcct(1, "jack"), publicAcct(2, "tom")})
	if report.Summary.Projects != 2 || report.Summary.Expected != 3 || report.Summary.Missing != 3 {
		t.Fatalf("summary %+v, want 2 projects and 3 missing", report.Summary)
	}
	if len(report.Extras) != 0 {
		t.Fatalf("unexpected extras: %+v", report.Extras)
	}
	row := publicRow(t, report, "jack", "huum")
	if row.Status != publicStatusMissing || row.Session != "jack-huum" || row.MachineID != "m1" {
		t.Fatalf("row %+v, want a missing jack-huum on m1", row)
	}
	if row.AccountID != 1 || row.AccountName != "jack" {
		t.Fatalf("row must name the account to create the tab for: %+v", row)
	}
	// The non-public project contributes nothing.
	for _, r := range report.Rows {
		if r.ProjectID == "blink" {
			t.Fatalf("blink must not appear: %+v", r)
		}
	}
}

func TestPublicReportMarksTabsThatAreReady(t *testing.T) {
	report := buildPublicReport(publicProjectsFixture(), []publicAccount{
		publicAcct(1, "jack", "jack-huum@m1"),
		publicAcct(2, "tom", "tom-huum@m2", "tom-lotly@m2"),
	})
	if report.Summary.Missing != 0 || report.Summary.Expected != 3 {
		t.Fatalf("summary %+v, want everything ready", report.Summary)
	}
	for _, row := range report.Rows {
		if row.Status != publicStatusOK {
			t.Fatalf("row %+v, want ok", row)
		}
	}
	if len(report.Extras) != 0 {
		t.Fatalf("unexpected extras: %+v", report.Extras)
	}
}

func TestPublicReportFlagsWrongMachine(t *testing.T) {
	report := buildPublicReport(publicProjectsFixture(), []publicAccount{
		publicAcct(1, "jack", "jack-huum@m9"),
		publicAcct(2, "tom", "tom-huum@m2", "tom-lotly@m2"),
	})
	row := publicRow(t, report, "jack", "huum")
	if row.Status != publicStatusWrongMachine || row.ActualMachine != "m9" || row.MachineID != "m1" {
		t.Fatalf("row %+v, want a machine mismatch m1 -> m9", row)
	}
	if report.Summary.WrongMachine != 1 || report.Summary.Missing != 0 {
		t.Fatalf("summary %+v, want one mismatch and nothing missing", report.Summary)
	}
}

func TestPublicReportFlagsEmployeeWithoutAnAccount(t *testing.T) {
	// The list names ben, but no account has that username, so there is nobody
	// to create the tab for.
	projects := []projectEntry{{ID: "huum", Name: "Huum", Public: true, Employees: []projectEmployee{{ID: "ben", MachineID: "m1"}}}}
	report := buildPublicReport(projects, []publicAccount{publicAcct(1, "jack")})
	row := publicRow(t, report, "ben", "huum")
	if row.Status != publicStatusNoAccount || row.AccountID != 0 {
		t.Fatalf("row %+v, want noAccount", row)
	}
	if report.Summary.NoAccount != 1 || report.Summary.Missing != 0 {
		t.Fatalf("summary %+v, want one accountless row", report.Summary)
	}
}

func TestPublicReportLeavesNonPublicProjectsAlone(t *testing.T) {
	report := buildPublicReport(publicProjectsFixture(), []publicAccount{
		publicAcct(1, "jack", "jack-blink@m1"),
		publicAcct(2, "tom", "tom-huum@m2", "tom-lotly@m2"),
	})
	for _, row := range report.Rows {
		if row.ProjectID == "blink" {
			t.Fatalf("blink must not appear: %+v", row)
		}
	}
	// A tab for a project outside the view is not an extra either.
	if len(report.Extras) != 0 {
		t.Fatalf("a tab for a non-public project must not be flagged: %+v", report.Extras)
	}
}

func TestPublicReportFlagsTabsOutsideTheEmployeeList(t *testing.T) {
	report := buildPublicReport(publicProjectsFixture(), []publicAccount{
		// adam is on no list, and jack holds a session that belongs to tom.
		publicAcct(1, "jack", "jack-huum@m1", "tom-lotly@m2"),
		publicAcct(2, "tom", "tom-huum@m2", "tom-lotly@m2"),
		publicAcct(3, "adam", "adam-huum@m1"),
	})
	if report.Summary.Extra != 2 {
		t.Fatalf("summary %+v, want 2 extras: %+v", report.Summary, report.Extras)
	}
	byAccount := map[string][]publicTabRow{}
	for _, extra := range report.Extras {
		byAccount[extra.AccountName] = append(byAccount[extra.AccountName], extra)
	}
	if len(byAccount["adam"]) != 1 || byAccount["adam"][0].Session != "adam-huum" || byAccount["adam"][0].Status != publicStatusExtra {
		t.Fatalf("adam's out-of-list tab must be flagged: %+v", byAccount["adam"])
	}
	if len(byAccount["jack"]) != 1 || byAccount["jack"][0].EmployeeID != "tom" || byAccount["jack"][0].ProjectID != "lotly" {
		t.Fatalf("tom's session sitting on jack's account must be flagged: %+v", byAccount["jack"])
	}
	if _, ok := byAccount["tom"]; ok {
		t.Fatalf("tom holds only what his list calls for: %+v", byAccount["tom"])
	}
}

func TestPublicReportReadsTheLinkRowBeforeTheSessionName(t *testing.T) {
	// The link row is what the admin page recorded, so it wins over a session
	// name that says something else.
	report := buildPublicReport(publicProjectsFixture(), []publicAccount{
		publicAcct(1, "jack", "jack-wrong@m1|jack>huum"),
		publicAcct(2, "tom", "tom-huum@m2", "tom-lotly@m2"),
	})
	if row := publicRow(t, report, "jack", "huum"); row.Status != publicStatusOK {
		t.Fatalf("row %+v, want ok from the link row", row)
	}
	if len(report.Extras) != 0 {
		t.Fatalf("the session name must not also be read as a project: %+v", report.Extras)
	}
}

func TestPublicReportIgnoresALinkToANonPublicProject(t *testing.T) {
	// The link row is authoritative: it says blink, so the session name that
	// looks like huum must not be used as a fallback.
	report := buildPublicReport(publicProjectsFixture(), []publicAccount{
		publicAcct(1, "jack", "jack-huum@m1|jack>blink"),
		publicAcct(2, "tom", "tom-huum@m2", "tom-lotly@m2"),
	})
	if row := publicRow(t, report, "jack", "huum"); row.Status != publicStatusMissing {
		t.Fatalf("row %+v, want missing: the link says this tab is not the huum one", row)
	}
}

func TestPublicReportResolvesDashedEmployeeIDs(t *testing.T) {
	// An employee ID may contain a dash, so the project half is matched whole
	// and the employee half is whatever is left.
	projects := []projectEntry{{ID: "huum", Name: "Huum", Public: true, Employees: []projectEmployee{{ID: "a-b", MachineID: "m1"}}}}
	report := buildPublicReport(projects, []publicAccount{publicAcct(1, "a-b", "a-b-huum@m1")})
	row := publicRow(t, report, "a-b", "huum")
	if row.Status != publicStatusOK {
		t.Fatalf("row %+v, want ok", row)
	}
	if report.Summary.Extra != 0 {
		t.Fatalf("a-huum must not be read as a separate pair: %+v", report.Extras)
	}
}

func TestPublicReportMatchesTheLongestProjectID(t *testing.T) {
	projects := []projectEntry{
		{ID: "ben", Name: "Ben", Public: true, Employees: []projectEmployee{{ID: "jack", MachineID: "m1"}}},
		{ID: "xx-ben", Name: "XX Ben", Public: true, Employees: []projectEmployee{{ID: "jack", MachineID: "m1"}}},
	}
	report := buildPublicReport(projects, []publicAccount{publicAcct(1, "jack", "jack-xx-ben@m1")})
	if row := publicRow(t, report, "jack", "xx-ben"); row.Status != publicStatusOK {
		t.Fatalf("row %+v, want the longer project ID to win", row)
	}
	if row := publicRow(t, report, "jack", "ben"); row.Status != publicStatusMissing {
		t.Fatalf("row %+v, jack-ben does not exist", row)
	}
}

func TestPublicReportCountsARepeatedTabOnce(t *testing.T) {
	// Two tabs for the same pair, on different machines. The first one is the
	// one reported, so the row follows the order the account lists its tabs in
	// rather than flipping with the map.
	report := buildPublicReport(publicProjectsFixture(), []publicAccount{
		publicAcct(1, "jack", "jack-huum@m1", "jack-huum@m9"),
		publicAcct(2, "tom", "tom-huum@m2", "tom-lotly@m2"),
	})
	row := publicRow(t, report, "jack", "huum")
	if row.Status != publicStatusOK || row.TabID != "tab-1-0" {
		t.Fatalf("row %+v, want the first tab and an ok status", row)
	}
	if len(report.Extras) != 0 {
		t.Fatalf("a duplicate of an expected tab is not an extra: %+v", report.Extras)
	}
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

// The route has to actually carry the reconciliation, not just the directories.
func TestAdminStateCarriesThePublicReport(t *testing.T) {
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
	mock.ExpectQuery("SELECT user_id,tab_id,employee_id,project_id FROM tab_links").WillReturnRows(sqlmock.NewRows([]string{"user_id", "tab_id", "employee_id", "project_id"}))
	mock.ExpectQuery("SELECT u.id,c.tabs,c.recent_selection").WillReturnRows(sqlmock.NewRows([]string{"id", "tabs", "recent_selection"}).AddRow(1, []byte(`{"version":1,"tabs":[]}`), nil).AddRow(7, []byte(`{"version":1,"tabs":[]}`), nil))
	w := httptest.NewRecorder()
	(&app{db: db}).routes().ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var payload struct {
		PublicTabs publicReport `json:"publicTabs"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.PublicTabs.Rows) != 1 {
		t.Fatalf("rows %+v, want the jack-huum row", payload.PublicTabs.Rows)
	}
	row := payload.PublicTabs.Rows[0]
	if row.ProjectID != "huum" || row.EmployeeID != "jack" || row.Status != publicStatusMissing {
		t.Fatalf("row %+v, want a missing jack-huum", row)
	}
	if row.AccountID != 1 || row.AccountName != "jack" {
		t.Fatalf("row %+v must point at jack's account", row)
	}
	if payload.PublicTabs.Summary.Expected != 1 || payload.PublicTabs.Summary.Missing != 1 {
		t.Fatalf("summary %+v", payload.PublicTabs.Summary)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
