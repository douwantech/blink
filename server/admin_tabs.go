package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
)

// Keep unknown TabState fields intact: the phone owns the format and may add
// fields without a server migration.
type adminTabState struct {
	fields map[string]json.RawMessage
	tabs   []json.RawMessage
	closed []string
}

func decodeAdminTabs(raw []byte) (adminTabState, error) {
	if len(raw) == 0 {
		raw = []byte(`{"version":1,"tabs":[]}`)
	}
	var s adminTabState
	if err := json.Unmarshal(raw, &s.fields); err != nil || s.fields == nil {
		return s, errors.New("invalid tabs")
	}
	if b, ok := s.fields["tabs"]; ok {
		if err := json.Unmarshal(b, &s.tabs); err != nil || s.tabs == nil {
			return s, errors.New("invalid tabs array")
		}
	} else {
		s.tabs = []json.RawMessage{}
	}
	if b, ok := s.fields["closedIds"]; ok && string(b) != "null" {
		if err := json.Unmarshal(b, &s.closed); err != nil {
			return s, errors.New("invalid closed IDs")
		}
	}
	return s, nil
}

func (s *adminTabState) currentID() string {
	var id string
	_ = json.Unmarshal(s.fields["currentId"], &id)
	return id
}

func tabID(raw json.RawMessage) string {
	var entry struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(raw, &entry)
	return entry.ID
}

func (s *adminTabState) encode() ([]byte, error) {
	var err error
	s.fields["tabs"], err = json.Marshal(s.tabs)
	if err != nil {
		return nil, err
	}
	s.fields["closedIds"], err = json.Marshal(s.closed)
	if err != nil {
		return nil, err
	}
	s.fields["updatedAt"], err = json.Marshal(float64(time.Now().UnixNano()) / 1e9)
	if err != nil {
		return nil, err
	}
	return json.Marshal(s.fields)
}

func newTabID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return hex.EncodeToString(b[:4]) + "-" + hex.EncodeToString(b[4:6]) + "-" + hex.EncodeToString(b[6:8]) + "-" + hex.EncodeToString(b[8:10]) + "-" + hex.EncodeToString(b[10:]), nil
}

func (a *app) editUserTabs(w http.ResponseWriter, r *http.Request, edit func(*sql.Tx, uint64, *adminTabState, map[string]json.RawMessage) (int, error)) {
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer tx.Rollback()
	var exists uint64
	err = tx.QueryRowContext(r.Context(), `SELECT id FROM users WHERE id=?`, id).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "account not found", 404)
		return
	}
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	// Lock this account's config row before reading it. Client PUTs acquire the
	// same row lock, so concurrent edits cannot overwrite each other silently.
	_, err = tx.ExecContext(r.Context(), `INSERT INTO user_configs(user_id,tabs) VALUES(?,?) ON DUPLICATE KEY UPDATE user_id=user_id`, id, []byte(`{"version":1,"tabs":[]}`))
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	var tabsRaw, selectionRaw []byte
	err = tx.QueryRowContext(r.Context(), `SELECT tabs,recent_selection FROM user_configs WHERE user_id=? FOR UPDATE`, id).Scan(&tabsRaw, &selectionRaw)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	tabs, err := decodeAdminTabs(tabsRaw)
	if err != nil {
		http.Error(w, "invalid stored tabs", 500)
		return
	}
	selection := map[string]json.RawMessage{}
	if len(selectionRaw) > 0 && string(selectionRaw) != "null" {
		if err = json.Unmarshal(selectionRaw, &selection); err != nil || selection == nil {
			http.Error(w, "invalid stored selection", 500)
			return
		}
	}
	status, err := edit(tx, id, &tabs, selection)
	if err != nil {
		http.Error(w, err.Error(), status)
		return
	}
	stored, err := tabs.encode()
	if err == nil {
		selectionRaw, err = json.Marshal(selection)
	}
	if err == nil {
		_, err = tx.ExecContext(r.Context(), `UPDATE user_configs SET tabs=?,recent_selection=? WHERE user_id=?`, stored, selectionRaw, id)
	}
	if err == nil {
		_, err = tx.ExecContext(r.Context(), `UPDATE users SET config_version=config_version+1 WHERE id=?`, id)
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	w.WriteHeader(status)
}

// An admin-created tab is always the triple employee + project + machine: one
// session per employee and project, on the machine that hosts it. The session
// name is <employee>-<project>; the cc- prefix belongs to the remote startup
// convention, not to this field.
func (a *app) addUserTab(w http.ResponseWriter, r *http.Request, _ user) {
	var req struct {
		MachineID  string `json:"machineId"`
		EmployeeID string `json:"employeeId"`
		ProjectID  string `json:"projectId"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if req.MachineID == "" || len(req.MachineID) > 100 || strings.ContainsAny(req.MachineID, "/\\") {
		http.Error(w, "invalid machine", 400)
		return
	}
	if !validDirectoryID(req.EmployeeID) || !validDirectoryID(req.ProjectID) {
		http.Error(w, "invalid employee or project", 400)
		return
	}
	session := req.EmployeeID + "-" + req.ProjectID
	a.editUserTabs(w, r, func(tx *sql.Tx, uid uint64, tabs *adminTabState, selection map[string]json.RawMessage) (int, error) {
		for _, ref := range []struct{ table, id, label string }{
			{"machines", req.MachineID, "machine"},
			{"employees", req.EmployeeID, "employee"},
			{"projects", req.ProjectID, "project"},
		} {
			ok, err := directoryExists(r.Context(), tx, ref.table, ref.id)
			if err != nil {
				return 500, errors.New("internal error")
			}
			if !ok {
				return 400, errors.New(ref.label + " not found")
			}
		}
		// One session per employee, project and machine, so the same triple
		// twice is a mistake rather than a second tab.
		for _, raw := range tabs.tabs {
			var entry struct {
				MachineID   string `json:"machineId"`
				TmuxSession string `json:"tmuxSession"`
			}
			_ = json.Unmarshal(raw, &entry)
			if entry.MachineID == req.MachineID && strings.EqualFold(entry.TmuxSession, session) {
				return 409, errors.New("this tab already exists for the account")
			}
		}
		id, err := newTabID()
		if err != nil {
			return 500, errors.New("internal error")
		}
		b, _ := json.Marshal(map[string]string{"id": id, "machineId": req.MachineID, "tmuxSession": session})
		tabs.tabs = append(tabs.tabs, b)
		if len(tabs.tabs) == 1 && tabs.currentID() == "" {
			tabs.fields["currentId"], _ = json.Marshal(id)
			selection["tabId"], _ = json.Marshal(id)
			selection["machineId"], _ = json.Marshal(req.MachineID)
		}
		if _, err = tx.ExecContext(r.Context(), `INSERT INTO tab_links(user_id,tab_id,employee_id,project_id) VALUES(?,?,?,?)`, uid, id, req.EmployeeID, req.ProjectID); err != nil {
			return 500, errors.New("internal error")
		}
		return 204, nil
	})
}

func (a *app) closeUserTab(w http.ResponseWriter, r *http.Request, _ user) {
	id := r.PathValue("tabId")
	if len(id) != 36 || strings.ContainsAny(id, "/\\") {
		http.Error(w, "invalid tab", 400)
		return
	}
	a.editUserTabs(w, r, func(tx *sql.Tx, uid uint64, tabs *adminTabState, selection map[string]json.RawMessage) (int, error) {
		index := -1
		for i, raw := range tabs.tabs {
			if strings.EqualFold(tabID(raw), id) {
				index = i
				id = tabID(raw)
				break
			}
		}
		if index < 0 {
			return 404, errors.New("tab not found in account")
		}
		tabs.tabs = append(tabs.tabs[:index], tabs.tabs[index+1:]...)
		if _, err := tx.ExecContext(r.Context(), `DELETE FROM tab_links WHERE user_id=? AND tab_id=?`, uid, id); err != nil {
			return 500, errors.New("internal error")
		}
		seen := false
		for _, closed := range tabs.closed {
			if strings.EqualFold(closed, id) {
				seen = true
				break
			}
		}
		if !seen {
			tabs.closed = append(tabs.closed, id)
		}
		if len(tabs.closed) > 500 {
			tabs.closed = tabs.closed[len(tabs.closed)-500:]
		}
		var selected string
		_ = json.Unmarshal(selection["tabId"], &selected)
		if tabs.currentID() == id || strings.EqualFold(selected, id) {
			if len(tabs.tabs) == 0 {
				delete(tabs.fields, "currentId")
				delete(selection, "tabId")
				delete(selection, "machineId")
			} else {
				next := tabs.tabs[0]
				nextID := tabID(next)
				tabs.fields["currentId"], _ = json.Marshal(nextID)
				selection["tabId"], _ = json.Marshal(nextID)
				var nextEntry struct {
					MachineID string `json:"machineId"`
				}
				_ = json.Unmarshal(next, &nextEntry)
				if nextEntry.MachineID == "" {
					delete(selection, "machineId")
				} else {
					selection["machineId"], _ = json.Marshal(nextEntry.MachineID)
				}
			}
		}
		return 204, nil
	})
}
