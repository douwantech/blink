package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
)

const pinnedBody = `{"id":"admin-x","title":"一号后台","url":"https://admin.test/","position":2,"authUser":"ops","authPassword":"s3cret"}`

func mustApp(t *testing.T) (*app, sqlmock.Sqlmock) {
	t.Helper()
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return &app{db}, mock
}

func assertSameJSON(t *testing.T, got []byte, want string) {
	t.Helper()
	var g, w any
	if err := json.Unmarshal(got, &g); err != nil {
		t.Fatalf("not JSON: %s (%v)", got, err)
	}
	if err := json.Unmarshal([]byte(want), &w); err != nil {
		t.Fatal(err)
	}
	gb, _ := json.Marshal(g)
	wb, _ := json.Marshal(w)
	if string(gb) != string(wb) {
		t.Fatalf("JSON mismatch:\n got %s\nwant %s", gb, wb)
	}
}

// 只有 admin+canWrite 能改共享书签；被拒的请求绝不能碰数据库（sqlmock 没给任何期望，
// 任何一次查询/写入都会让本次测试失败）。
func TestPinnedManagementRequiresWriteAccess(t *testing.T) {
	a, mock := mustApp(t)
	cases := []struct {
		name string
		run  handler
	}{
		{"put", a.putPinnedLink},
		{"batch", a.replacePinnedLinks},
		{"delete", a.deletePinnedLink},
	}
	for _, c := range cases {
		for _, u := range []user{{}, {Admin: true}, {CanWrite: true}} {
			body := pinnedBody
			if c.name == "batch" {
				body = "[" + pinnedBody + "]"
			}
			r := httptest.NewRequest(http.MethodPut, "/v1/pinned/admin-x", strings.NewReader(body))
			r.SetPathValue("id", "admin-x")
			w := httptest.NewRecorder()
			c.run(w, r, u)
			if w.Code != http.StatusForbidden {
				t.Fatalf("%s with %+v: status %d, want 403", c.name, u, w.Code)
			}
		}
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestValidatePinnedLink(t *testing.T) {
	valid := []string{
		`{"id":"a","title":"后台","url":"https://admin.test/"}`,
		`{"id":"a","title":"后台","url":"http://admin.test:8080/x?y=1"}`,
		`{"id":"a","title":"后台","url":"https://admin.test/","authUser":"u","authPassword":"p","futureFlag":true}`,
	}
	for _, raw := range valid {
		if _, _, err := validatePinnedLink(json.RawMessage(raw)); err != nil {
			t.Fatalf("rejected valid bookmark %s: %v", raw, err)
		}
	}
	invalid := map[string]string{
		"missing id":           `{"title":"后台","url":"https://admin.test/"}`,
		"slash in id":          `{"id":"a/b","title":"后台","url":"https://admin.test/"}`,
		"overlong id":          `{"id":"` + strings.Repeat("x", 101) + `","title":"后台","url":"https://admin.test/"}`,
		"blank title":          `{"id":"a","title":"   ","url":"https://admin.test/"}`,
		"no scheme":            `{"id":"a","title":"后台","url":"admin.test/admin"}`,
		"non-http scheme":      `{"id":"a","title":"后台","url":"ftp://admin.test/"}`,
		"hostless":             `{"id":"a","title":"后台","url":"https:///admin"}`,
		"username only":        `{"id":"a","title":"后台","url":"https://admin.test/","authUser":"u"}`,
		"password only":        `{"id":"a","title":"后台","url":"https://admin.test/","authPassword":"p"}`,
		"empty password":       `{"id":"a","title":"后台","url":"https://admin.test/","authUser":"u","authPassword":"  "}`,
		"negative position":    `{"id":"a","title":"后台","url":"https://admin.test/","position":-1}`,
		"array instead of obj": `[]`,
	}
	for name, raw := range invalid {
		if _, _, err := validatePinnedLink(json.RawMessage(raw)); err == nil {
			t.Fatalf("%s: accepted invalid bookmark %s", name, raw)
		}
	}
}

// position 是内部排序索引，不能漏给客户端；未知字段要留着（客户端扩展不需要迁移）。
func TestValidatePinnedLinkStripsPositionKeepsExtensions(t *testing.T) {
	link, stored, err := validatePinnedLink(json.RawMessage(`{"id":"a","title":"后台","url":"https://admin.test/","position":7,"futureFlag":true}`))
	if err != nil {
		t.Fatal(err)
	}
	if link.Position != 7 {
		t.Fatalf("position not parsed: %d", link.Position)
	}
	assertSameJSON(t, stored, `{"id":"a","title":"后台","url":"https://admin.test/","futureFlag":true}`)
}

func TestPutPinnedLinkWritesSharedRowAndBumpsSharedVersion(t *testing.T) {
	a, mock := mustApp(t)
	mock.ExpectBegin()
	mock.ExpectExec("INSERT INTO pinned_bookmarks").WithArgs("admin-x", 2, sqlmock.AnyArg()).WillReturnResult(sqlmock.NewResult(0, 1))
	// 共享版本自增；写成 users.config_version 就是「每个账号各存一份」，这条期望会挡住。
	mock.ExpectExec("UPDATE config_versions SET version=version\\+1 WHERE id=1").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	r := httptest.NewRequest(http.MethodPut, "/v1/pinned/admin-x", strings.NewReader(pinnedBody))
	r.SetPathValue("id", "admin-x")
	w := httptest.NewRecorder()
	a.putPinnedLink(w, r, user{ID: 3, Admin: true, CanWrite: true})
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	assertSameJSON(t, w.Body.Bytes(), `{"id":"admin-x","title":"一号后台","url":"https://admin.test/","authUser":"ops","authPassword":"s3cret"}`)
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestPutPinnedLinkRejectsIDMismatchAndBadPayload(t *testing.T) {
	a, mock := mustApp(t)
	for _, tc := range []struct{ id, body string }{
		{"other", pinnedBody}, // URL 里的 id 和 body 里的 id 必须一致
		{"admin-x", `{"id":"admin-x","title":"","url":"https://admin.test/"}`},
		{"admin-x", `{"id":"admin-x","title":"后台","url":"javascript:alert(1)"}`},
		{"admin-x", `garbage`},
	} {
		r := httptest.NewRequest(http.MethodPut, "/v1/pinned/"+tc.id, strings.NewReader(tc.body))
		r.SetPathValue("id", tc.id)
		w := httptest.NewRecorder()
		a.putPinnedLink(w, r, user{Admin: true, CanWrite: true})
		if w.Code != http.StatusBadRequest {
			t.Fatalf("body %s under id %q: status %d, want 400", tc.body, tc.id, w.Code)
		}
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestDeletePinnedLink(t *testing.T) {
	t.Run("not found is 404 and bumps nothing", func(t *testing.T) {
		a, mock := mustApp(t)
		mock.ExpectBegin()
		mock.ExpectExec("DELETE FROM pinned_bookmarks").WithArgs("gone").WillReturnResult(sqlmock.NewResult(0, 0))
		mock.ExpectRollback()
		r := httptest.NewRequest(http.MethodDelete, "/v1/pinned/gone", nil)
		r.SetPathValue("id", "gone")
		w := httptest.NewRecorder()
		a.deletePinnedLink(w, r, user{Admin: true, CanWrite: true})
		if w.Code != http.StatusNotFound {
			t.Fatalf("status %d, want 404", w.Code)
		}
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("delete bumps shared version", func(t *testing.T) {
		a, mock := mustApp(t)
		mock.ExpectBegin()
		mock.ExpectExec("DELETE FROM pinned_bookmarks").WithArgs("old").WillReturnResult(sqlmock.NewResult(0, 1))
		mock.ExpectExec("UPDATE config_versions SET version=version\\+1 WHERE id=1").WillReturnResult(sqlmock.NewResult(0, 1))
		mock.ExpectCommit()
		r := httptest.NewRequest(http.MethodDelete, "/v1/pinned/old", nil)
		r.SetPathValue("id", "old")
		w := httptest.NewRecorder()
		a.deletePinnedLink(w, r, user{Admin: true, CanWrite: true})
		if w.Code != http.StatusNoContent {
			t.Fatalf("status %d: %s", w.Code, w.Body.String())
		}
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	})
}

func TestReplacePinnedLinksKeepsArrayOrder(t *testing.T) {
	a, mock := mustApp(t)
	mock.ExpectBegin()
	mock.ExpectExec("DELETE FROM pinned_bookmarks").WillReturnResult(sqlmock.NewResult(0, 3))
	mock.ExpectExec("INSERT INTO pinned_bookmarks").WithArgs("b", 0, sqlmock.AnyArg()).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("INSERT INTO pinned_bookmarks").WithArgs("a", 1, sqlmock.AnyArg()).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE config_versions SET version=version\\+1 WHERE id=1").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	body := `[{"id":"b","title":"B","url":"https://b.test/","position":9},{"id":"a","title":"A","url":"https://a.test/"}]`
	r := httptest.NewRequest(http.MethodPut, "/v1/pinned/batch", strings.NewReader(body))
	w := httptest.NewRecorder()
	a.replacePinnedLinks(w, r, user{Admin: true, CanWrite: true})
	if w.Code != http.StatusNoContent {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestReplacePinnedLinksRefusesEmptyAndDuplicateLists(t *testing.T) {
	a, mock := mustApp(t)
	for name, body := range map[string]string{
		"empty":      `[]`,
		"duplicates": `[{"id":"a","title":"A","url":"https://a.test/"},{"id":"a","title":"A2","url":"https://a.test/2"}]`,
	} {
		r := httptest.NewRequest(http.MethodPut, "/v1/pinned/batch", strings.NewReader(body))
		w := httptest.NewRecorder()
		a.replacePinnedLinks(w, r, user{Admin: true, CanWrite: true})
		if w.Code != http.StatusBadRequest {
			t.Fatalf("%s: status %d, want 400", name, w.Code)
		}
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// 每个登录账号（不只是管理员）都能在快照里拿到同一份共享书签，顺序 = position,id。
func TestConfigSnapshotShipsPinnedToEveryAccount(t *testing.T) {
	for _, viewer := range []user{{ID: 4, Username: "alice"}, {ID: 9, Username: "bob", Admin: true}} {
		a, mock := mustApp(t)
		mock.ExpectBegin()
		mock.ExpectQuery("SELECT version FROM config_versions").WillReturnRows(sqlmock.NewRows([]string{"version"}).AddRow(uint64(12)))
		mock.ExpectQuery("SELECT config_version FROM users").WithArgs(viewer.ID).WillReturnRows(sqlmock.NewRows([]string{"config_version"}).AddRow(uint64(3)))
		mock.ExpectQuery("SELECT data FROM machines").WillReturnRows(sqlmock.NewRows([]string{"data"}).
			AddRow([]byte(`{"id":"m1","host":"h","user":"u"}`)))
		mock.ExpectQuery("SELECT data FROM pinned_bookmarks").WillReturnRows(sqlmock.NewRows([]string{"data"}).
			AddRow([]byte(`{"id":"p1","title":"一号后台","url":"https://a.test/","authUser":"ops","authPassword":"s"}`)).
			AddRow([]byte(`{"id":"p2","title":"二号后台","url":"https://b.test/"}`)))
		mock.ExpectQuery("SELECT tabs,recent_selection,agents FROM user_configs").WithArgs(viewer.ID).
			WillReturnRows(sqlmock.NewRows([]string{"tabs", "recent_selection", "agents"}))
		// 公用标签由项目目录推导，读快照时并进去：没有项目行就是空表，不是错误。
		mock.ExpectQuery("SELECT data FROM projects").
			WillReturnRows(sqlmock.NewRows([]string{"data"}))
		// #43 起快照还带个人语音纠正与共享 AI 配置；共享那份必须有一行（ErrNoRows 会 500）。
		mock.ExpectQuery("SELECT data FROM voice_corrections").WithArgs(viewer.ID).
			WillReturnRows(sqlmock.NewRows([]string{"data"}))
		mock.ExpectQuery("SELECT data FROM shared_ai_config").
			WillReturnRows(sqlmock.NewRows([]string{"data"}).AddRow([]byte(`{}`)))
		mock.ExpectRollback()

		r := httptest.NewRequest(http.MethodGet, "/v1/config", nil)
		w := httptest.NewRecorder()
		a.config(w, r, viewer)
		if w.Code != http.StatusOK {
			t.Fatalf("%s: status %d: %s", viewer.Username, w.Code, w.Body.String())
		}
		if got := w.Header().Get("X-Config-Version"); got != "12:3" {
			t.Fatalf("%s: version header %q, want 12:3", viewer.Username, got)
		}
		var snapshot struct {
			Version string            `json:"version"`
			Pinned  []json.RawMessage `json:"pinned"`
			User    user              `json:"user"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &snapshot); err != nil {
			t.Fatal(err)
		}
		if len(snapshot.Pinned) != 2 {
			t.Fatalf("%s: pinned count %d, want 2", viewer.Username, len(snapshot.Pinned))
		}
		assertSameJSON(t, snapshot.Pinned[0], `{"id":"p1","title":"一号后台","url":"https://a.test/","authUser":"ops","authPassword":"s"}`)
		assertSameJSON(t, snapshot.Pinned[1], `{"id":"p2","title":"二号后台","url":"https://b.test/"}`)
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Fatal(err)
		}
	}
}

// 未改动的客户端带 version 再来，应该拿到 304 —— 共享书签的变更走的就是这个共享版本。
func TestConfigReturnsNotModifiedForUnchangedSharedVersion(t *testing.T) {
	a, mock := mustApp(t)
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT version FROM config_versions").WillReturnRows(sqlmock.NewRows([]string{"version"}).AddRow(uint64(12)))
	mock.ExpectQuery("SELECT config_version FROM users").WithArgs(uint64(4)).WillReturnRows(sqlmock.NewRows([]string{"config_version"}).AddRow(uint64(3)))
	mock.ExpectRollback()
	r := httptest.NewRequest(http.MethodGet, "/v1/config?version=12:3", nil)
	w := httptest.NewRecorder()
	a.config(w, r, user{ID: 4})
	if w.Code != http.StatusNotModified {
		t.Fatalf("status %d, want 304", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// 管理后台必须能看能改：state 里带 pinned，页面里带书签那一块。
func TestAdminStateAndPageExposePinned(t *testing.T) {
	a, mock := mustApp(t)
	mock.ExpectQuery("SELECT id,username,is_admin,can_write,disabled FROM users").WillReturnRows(
		sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(1, "boss", true, true, false))
	mock.ExpectQuery("SELECT position,data FROM machines").WillReturnRows(sqlmock.NewRows([]string{"position", "data"}))
	mock.ExpectQuery("SELECT data FROM employees ORDER BY id").WillReturnRows(sqlmock.NewRows([]string{"data"}))
	mock.ExpectQuery("SELECT data FROM projects ORDER BY id").WillReturnRows(sqlmock.NewRows([]string{"data"}))
	mock.ExpectQuery("SELECT position,data FROM pinned_bookmarks").WillReturnRows(
		sqlmock.NewRows([]string{"position", "data"}).AddRow(0, []byte(`{"id":"p1","title":"一号后台","url":"https://a.test/"}`)))
	mock.ExpectQuery("SELECT user_id,tab_id,employee_id,project_id FROM tab_links").
		WillReturnRows(sqlmock.NewRows([]string{"user_id", "tab_id", "employee_id", "project_id"}))
	mock.ExpectQuery("SELECT u.id,c.tabs,c.recent_selection FROM users u LEFT JOIN user_configs").WillReturnRows(
		sqlmock.NewRows([]string{"id", "tabs", "recent_selection"}))
	// 公用标签的引擎列要各账号的 agents 配置，所以 state 多读一次。
	mock.ExpectQuery("SELECT u.username,COALESCE\\(c.agents").WillReturnRows(
		sqlmock.NewRows([]string{"username", "agents"}))
	w := httptest.NewRecorder()
	a.adminState(w, httptest.NewRequest(http.MethodGet, "/admin/api/state", nil), user{ID: 1, Admin: true, CanWrite: true})
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var state struct {
		Pinned []json.RawMessage `json:"pinned"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	if len(state.Pinned) != 1 {
		t.Fatalf("admin state pinned count %d, want 1", len(state.Pinned))
	}
	assertSameJSON(t, state.Pinned[0], `{"id":"p1","title":"一号后台","url":"https://a.test/","position":0}`)
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}

	page, err := adminPage.ReadFile("web/admin.html")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"pinned-rows", "add-pinned", "/admin/api/pinned/", "p-password"} {
		if !strings.Contains(string(page), want) {
			t.Fatalf("admin page is missing %q", want)
		}
	}
}

func TestSchemaShipsPinnedTable(t *testing.T) {
	b, err := schema.ReadFile("schema.sql")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "CREATE TABLE IF NOT EXISTS pinned_bookmarks") {
		t.Fatal("schema.sql does not create pinned_bookmarks")
	}
	for _, column := range []string{"id VARCHAR(100)", "position INT", "data JSON"} {
		if !strings.Contains(string(b), column) {
			t.Fatalf("pinned_bookmarks is missing %q", column)
		}
	}
}

// 路由必须真的挂在 mux 上。handler 直接调用的单测看不出注册被吞，而 ServeMux 对
// 未匹配的路径回 404，所以每条探针都用「只有注册了才可能出现的状态码」：
//
//	· /v1/pinned/{id} 与 /admin/api/pinned/{id}：匿名 → 401（未注册是 404）；
//	· /v1/pinned/batch 会被 {id} 模式吞掉，光看状态码分不清，所以用可写账号 +
//	  合法数组体走完整条链：注册对 → 204（replacePinnedLinks 落库），
//	  注册丢了 → 400（落进 putPinnedLink，把数组当对象校验）。
func TestPinnedRoutesAreRegisteredAndGated(t *testing.T) {
	db, mock, err := sqlmock.New()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	routes := (&app{db: db}).routes()

	for _, tc := range []struct{ method, path string }{
		{http.MethodPut, "/v1/pinned/one.test"},
		{http.MethodDelete, "/v1/pinned/one.test"},
		{http.MethodPut, "/admin/api/pinned/one.test"},
		{http.MethodDelete, "/admin/api/pinned/one.test"},
	} {
		w := httptest.NewRecorder()
		routes.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, strings.NewReader(`{}`)))
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("%s %s: status %d, want 401 (404 means the route is not registered)", tc.method, tc.path, w.Code)
		}
	}

	// 可写账号 + 合法数组体：走完 batch 全链，状态码必须只可能来自 replacePinnedLinks。
	token := make([]byte, 32)
	digest := sha256.Sum256(token)
	mock.ExpectQuery("SELECT u.id,u.username,u.is_admin,u.can_write,u.disabled FROM sessions").WithArgs(digest[:]).
		WillReturnRows(sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(3, "boss", true, true, false))
	mock.ExpectBegin()
	mock.ExpectExec("DELETE FROM pinned_bookmarks").WillReturnResult(sqlmock.NewResult(0, 0))
	mock.ExpectExec("INSERT INTO pinned_bookmarks").WithArgs("one.test", 0, sqlmock.AnyArg()).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectExec("UPDATE config_versions SET version=version\\+1 WHERE id=1").WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	r := httptest.NewRequest(http.MethodPut, "/v1/pinned/batch",
		strings.NewReader(`[{"id":"one.test","title":"一号后台","url":"https://one.test/"}]`))
	r.Header.Set("Authorization", "Bearer "+hex.EncodeToString(token))
	w := httptest.NewRecorder()
	routes.ServeHTTP(w, r)
	if w.Code != http.StatusNoContent {
		t.Fatalf("PUT /v1/pinned/batch: status %d, want 204 (400 = fell through to /v1/pinned/{id}, i.e. batch is not registered)", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}

	// admin 侧：有 session 但不是管理员 → 401（不是 404，也不是放行）。
	member := make([]byte, 32)
	memberDigest := sha256.Sum256(member)
	mock.ExpectQuery("SELECT u.id,u.username,u.is_admin,u.can_write,u.disabled FROM sessions").WithArgs(memberDigest[:]).
		WillReturnRows(sqlmock.NewRows([]string{"id", "username", "is_admin", "can_write", "disabled"}).AddRow(7, "member", false, false, false))
	r = httptest.NewRequest(http.MethodPut, "/admin/api/pinned/one.test",
		strings.NewReader(`{"id":"one.test","title":"一号后台","url":"https://one.test/"}`))
	r.Header.Set("X-Blink-Admin", "1")
	r.Header.Set("Content-Type", "application/json")
	r.AddCookie(&http.Cookie{Name: adminCookie, Value: hex.EncodeToString(member)})
	w = httptest.NewRecorder()
	routes.ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("non-admin pinned write: status %d, want 401", w.Code)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
