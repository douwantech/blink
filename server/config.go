package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

// Machine JSON uses BlinkMachine's Codable field names. Unknown fields are
// retained so clients can extend the shared model without a database migration.
type machine struct {
	ID               string  `json:"id"`
	Name             string  `json:"name"`
	Host             string  `json:"host"`
	Host2            *string `json:"host2,omitempty"`
	LanHost          *string `json:"lanHost,omitempty"`
	User             string  `json:"user"`
	Transport        *string `json:"transport,omitempty"`
	BlinkdHost       *string `json:"blinkdHost,omitempty"`
	BlinkdPort       *int    `json:"blinkdPort,omitempty"`
	BlinkdToken      *string `json:"blinkdToken,omitempty"`
	RustdeskID       *string `json:"rustdeskId,omitempty"`
	RustdeskPassword *string `json:"rustdeskPassword,omitempty"`
	Position         int     `json:"position"`
}

func (a *app) config(w http.ResponseWriter, r *http.Request, u user) {
	tx, err := a.db.BeginTx(r.Context(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer tx.Rollback()
	var global, personal uint64
	if err = tx.QueryRowContext(r.Context(), `SELECT version FROM config_versions WHERE id=1`).Scan(&global); err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	if err = tx.QueryRowContext(r.Context(), `SELECT config_version FROM users WHERE id=?`, u.ID).Scan(&personal); err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	version := fmt.Sprintf("%d:%d", global, personal)
	if r.URL.Query().Get("version") == version {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Config-Version", version)
		w.WriteHeader(304)
		return
	}
	rows, err := tx.QueryContext(r.Context(), `SELECT data FROM machines ORDER BY position,id`)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	machines := make([]json.RawMessage, 0)
	for rows.Next() {
		var data []byte
		if err = rows.Scan(&data); err != nil {
			break
		}
		machines = append(machines, json.RawMessage(data))
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	var tabs, selection, agents []byte
	err = tx.QueryRowContext(r.Context(), `SELECT tabs,recent_selection,agents FROM user_configs WHERE user_id=?`, u.ID).Scan(&tabs, &selection, &agents)
	if err != nil && err != sql.ErrNoRows {
		http.Error(w, "internal error", 500)
		return
	}
	if len(tabs) == 0 {
		tabs = []byte(`{"version":1,"tabs":[]}`)
	}
	if len(selection) == 0 {
		selection = []byte(`{}`)
	}
	if len(agents) == 0 {
		agents = []byte(`{}`)
	}
	w.Header().Set("X-Config-Version", version)
	writeJSON(w, 200, map[string]any{"version": version, "machines": machines, "tabs": json.RawMessage(tabs), "recentSelection": json.RawMessage(selection), "agents": json.RawMessage(agents), "user": u})
}

func (a *app) putMachine(w http.ResponseWriter, r *http.Request, u user) {
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
	if len(raw) == 0 || raw[0] != '{' {
		http.Error(w, "expected JSON object", 400)
		return
	}
	m, stored, err := validateMachine(raw)
	if err != nil || m.ID != id || m.Position < 0 {
		http.Error(w, "invalid machine", 400)
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(r.Context(), `INSERT INTO machines(id,position,data) VALUES(?,?,?) ON DUPLICATE KEY UPDATE position=VALUES(position),data=VALUES(data)`, id, m.Position, []byte(stored))
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

// The array order is authoritative. position is an internal SQL index and is
// never part of the machine JSON sent to clients.
func (a *app) replaceMachines(w http.ResponseWriter, r *http.Request, u user) {
	if !requireWrite(w, u) {
		return
	}
	var input []json.RawMessage
	if !readJSON(w, r, &input) {
		return
	}
	if len(input) == 0 {
		http.Error(w, "empty machine list", 400)
		return
	}
	type item struct {
		id   string
		data json.RawMessage
	}
	items := make([]item, 0, len(input))
	seen := map[string]bool{}
	for _, raw := range input {
		m, stored, err := validateMachine(raw)
		if err != nil || seen[m.ID] {
			http.Error(w, "invalid machine list", 400)
			return
		}
		seen[m.ID] = true
		items = append(items, item{m.ID, stored})
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(r.Context(), `DELETE FROM machines`)
	for i, it := range items {
		if err != nil {
			break
		}
		_, err = tx.ExecContext(r.Context(), `INSERT INTO machines(id,position,data) VALUES(?,?,?)`, it.id, i, []byte(it.data))
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

func validateMachine(raw json.RawMessage) (machine, json.RawMessage, error) {
	var m machine
	if len(raw) == 0 || raw[0] != '{' {
		return m, nil, fmt.Errorf("expected object")
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		return m, nil, err
	}
	if m.ID == "" || len(m.ID) > 100 || strings.ContainsAny(m.ID, "/\\") || strings.TrimSpace(m.Host) == "" || strings.TrimSpace(m.User) == "" {
		return m, nil, fmt.Errorf("missing machine fields")
	}
	if m.Transport != nil && *m.Transport != "ssh" && *m.Transport != "blinkd" {
		return m, nil, fmt.Errorf("invalid transport")
	}
	if m.BlinkdPort != nil && (*m.BlinkdPort < 1 || *m.BlinkdPort > 65535) {
		return m, nil, fmt.Errorf("invalid port")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return m, nil, err
	}
	delete(fields, "position")
	stored, err := json.Marshal(fields)
	return m, stored, err
}

func (a *app) deleteMachine(w http.ResponseWriter, r *http.Request, u user) {
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
	result, err := tx.ExecContext(r.Context(), `DELETE FROM machines WHERE id=?`, id)
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

func (a *app) writeUserConfig(column string) handler {
	return func(w http.ResponseWriter, r *http.Request, u user) {
		var query string
		switch column {
		case "tabs":
			query = `INSERT INTO user_configs(user_id,tabs) VALUES(?,?) ON DUPLICATE KEY UPDATE tabs=VALUES(tabs)`
		case "recent_selection":
			query = `INSERT INTO user_configs(user_id,recent_selection) VALUES(?,?) ON DUPLICATE KEY UPDATE recent_selection=VALUES(recent_selection)`
		case "agents":
			query = `INSERT INTO user_configs(user_id,agents) VALUES(?,?) ON DUPLICATE KEY UPDATE agents=VALUES(agents)`
		default:
			http.Error(w, "internal error", 500)
			return
		}
		var body json.RawMessage
		if !readJSON(w, r, &body) {
			return
		}
		if len(body) == 0 || body[0] != '{' {
			http.Error(w, "expected JSON object", 400)
			return
		}
		tx, err := a.db.BeginTx(r.Context(), nil)
		if err != nil {
			http.Error(w, "internal error", 500)
			return
		}
		defer tx.Rollback()
		_, err = tx.ExecContext(r.Context(), query, u.ID, []byte(body))
		if err == nil {
			_, err = tx.ExecContext(r.Context(), `UPDATE users SET config_version=config_version+1 WHERE id=?`, u.ID)
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
}
