package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

// pinnedLink 是浏览器「后台」列表里的一条书签：标题 + URL + 可选 HTTP Basic 账密。
//
// 与 machines 同一套共享语义：全局一份（不进 user_configs），所有登录账号都能在
// GET /v1/config 的 snapshot 里拿到，只有 admin+canWrite 能增删改。JSON 字段名对齐
// 客户端 Codable 模型（iOS PinnedTab / Mac PinnedLink / 鸿蒙 PinnedTab）；未知字段
// 保留，客户端扩展不需要数据库迁移。
type pinnedLink struct {
	ID           string  `json:"id"`
	Title        string  `json:"title"`
	URL          string  `json:"url"`
	AuthUser     *string `json:"authUser,omitempty"`
	AuthPassword *string `json:"authPassword,omitempty"`
	Position     int     `json:"position"`
}

func validatePinnedLink(raw json.RawMessage) (pinnedLink, json.RawMessage, error) {
	var link pinnedLink
	if len(raw) == 0 || raw[0] != '{' {
		return link, nil, fmt.Errorf("expected object")
	}
	if err := json.Unmarshal(raw, &link); err != nil {
		return link, nil, err
	}
	if link.ID == "" || len(link.ID) > 100 || strings.ContainsAny(link.ID, "/\\") {
		return link, nil, fmt.Errorf("missing bookmark id")
	}
	if strings.TrimSpace(link.Title) == "" {
		return link, nil, fmt.Errorf("missing title")
	}
	parsed, err := url.Parse(link.URL)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return link, nil, fmt.Errorf("invalid url")
	}
	// 账密成对：客户端按 host 整对匹配凭据（PinnedLinksStore.credentials(forHost:)），
	// 只有一半的共享数据等于没有，还会让人以为配好了。
	if (link.AuthUser == nil) != (link.AuthPassword == nil) {
		return link, nil, fmt.Errorf("username and password must be set together")
	}
	if link.AuthUser != nil && (strings.TrimSpace(*link.AuthUser) == "" || strings.TrimSpace(*link.AuthPassword) == "") {
		return link, nil, fmt.Errorf("empty credential")
	}
	if link.Position < 0 {
		return link, nil, fmt.Errorf("invalid position")
	}
	// position 是内部 SQL 排序索引，不进客户端 JSON（数组顺序才是权威）。
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return link, nil, err
	}
	delete(fields, "position")
	stored, err := json.Marshal(fields)
	return link, stored, err
}

// collectPinned 读整份共享书签，按 position,id 排序（数组顺序 = 客户端展示顺序）。
func collectPinned(ctx context.Context, tx *sql.Tx) ([]json.RawMessage, error) {
	rows, err := tx.QueryContext(ctx, `SELECT data FROM pinned_bookmarks ORDER BY position,id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	pinned := make([]json.RawMessage, 0)
	for rows.Next() {
		var data []byte
		if err = rows.Scan(&data); err != nil {
			return nil, err
		}
		pinned = append(pinned, json.RawMessage(data))
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	return pinned, nil
}

func (a *app) putPinnedLink(w http.ResponseWriter, r *http.Request, u user) {
	if !requireWrite(w, u) {
		return
	}
	id := r.PathValue("id")
	if id == "" || len(id) > 100 || strings.ContainsAny(id, "/\\") {
		http.Error(w, "invalid id", 400)
		return
	}
	var raw json.RawMessage
	if !readJSON(w, r, &raw) {
		return
	}
	link, stored, err := validatePinnedLink(raw)
	if err != nil || link.ID != id {
		http.Error(w, "invalid bookmark", 400)
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(r.Context(), `INSERT INTO pinned_bookmarks(id,position,data) VALUES(?,?,?) ON DUPLICATE KEY UPDATE position=VALUES(position),data=VALUES(data)`, id, link.Position, []byte(stored))
	if err == nil {
		_, err = tx.ExecContext(r.Context(), `UPDATE config_versions SET version=version+1 WHERE id=1`)
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	writeJSON(w, 200, stored)
}

// replacePinnedLinks 给一次性导入用：数组顺序即展示顺序。空数组拒绝（防误清空
// 全局列表），与 replaceMachines 同规矩。
func (a *app) replacePinnedLinks(w http.ResponseWriter, r *http.Request, u user) {
	if !requireWrite(w, u) {
		return
	}
	var input []json.RawMessage
	if !readJSON(w, r, &input) {
		return
	}
	if len(input) == 0 {
		http.Error(w, "empty bookmark list", 400)
		return
	}
	type item struct {
		id   string
		data json.RawMessage
	}
	items := make([]item, 0, len(input))
	seen := map[string]bool{}
	for _, raw := range input {
		link, stored, err := validatePinnedLink(raw)
		if err != nil || seen[link.ID] {
			http.Error(w, "invalid bookmark list", 400)
			return
		}
		seen[link.ID] = true
		items = append(items, item{link.ID, stored})
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(r.Context(), `DELETE FROM pinned_bookmarks`)
	for i, it := range items {
		if err != nil {
			break
		}
		_, err = tx.ExecContext(r.Context(), `INSERT INTO pinned_bookmarks(id,position,data) VALUES(?,?,?)`, it.id, i, []byte(it.data))
	}
	if err == nil {
		_, err = tx.ExecContext(r.Context(), `UPDATE config_versions SET version=version+1 WHERE id=1`)
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	w.WriteHeader(204)
}

func (a *app) deletePinnedLink(w http.ResponseWriter, r *http.Request, u user) {
	if !requireWrite(w, u) {
		return
	}
	id := r.PathValue("id")
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(r.Context(), `DELETE FROM pinned_bookmarks WHERE id=?`, id)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		http.Error(w, "not found", 404)
		return
	}
	_, err = tx.ExecContext(r.Context(), `UPDATE config_versions SET version=version+1 WHERE id=1`)
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	w.WriteHeader(204)
}
