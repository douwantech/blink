package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"
)

// The shared org directories the admin page maintains. Handlers take the table
// name as a literal from this file and reject anything else, so the name that
// gets spliced into SQL can never come from a request.
var directoryTables = map[string]bool{"employees": true, "projects": true}

// An employee or project ID is concatenated into a tmux session name
// (<employee>-<project>), so keep it to characters that survive a shell and a
// tmux target. Lowercase only: the ID is half of a session name people type,
// and two entries differing only in case would be two different sessions that
// are hard to tell apart. It also keeps the exact lookup used to check that an
// entry exists and the case-insensitive comparison used to spot a duplicate
// session from disagreeing.
var directoryIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,59}$`)

func validDirectoryID(id string) bool { return directoryIDPattern.MatchString(id) }

type directoryEntry struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// One employee a project is valid for, with the machine that pair's session
// runs on. The machine sits on the pair rather than on the project because two
// employees on the same project may not run on the same host.
type projectEmployee struct {
	ID        string `json:"id"`
	MachineID string `json:"machineId"`
}

// A project as stored in projects.data. Every field is optional on the wire so
// a request that does not mention one leaves the stored value alone.
type projectEntry struct {
	ID        string            `json:"id"`
	Name      string            `json:"name"`
	Public    bool              `json:"public"`
	Employees []projectEmployee `json:"employees"`
}

// validateEmployeeList checks the parts of the list that do not need the
// database: the IDs and machines have to be usable as a session name, and an
// employee may appear once. Whether they exist is checked in the transaction.
func validateEmployeeList(list []projectEmployee) error {
	seen := map[string]bool{}
	for _, e := range list {
		if !validDirectoryID(e.ID) {
			return errors.New("invalid employee")
		}
		if e.MachineID == "" || len(e.MachineID) > 100 || strings.ContainsAny(e.MachineID, "/\\") {
			return errors.New("invalid machine")
		}
		if seen[e.ID] {
			return errors.New("employee listed twice")
		}
		seen[e.ID] = true
	}
	return nil
}

// Create or replace one directory entry. Like machines these are shared and
// there is no position column: the list is ordered by ID.
//
// Projects are refused here even though they are a directory table: they carry
// the public flag and the employee list, and this handler writes only the ID
// and the name, so it would drop them. putProject is their writer.
func (a *app) putDirectoryEntry(table string) handler {
	return func(w http.ResponseWriter, r *http.Request, u user) {
		if !directoryTables[table] || table == "projects" {
			http.Error(w, "internal error", 500)
			return
		}
		if !requireAdmin(w, u) {
			return
		}
		id := r.PathValue("id")
		var req directoryEntry
		if !readJSON(w, r, &req) {
			return
		}
		req.Name = strings.TrimSpace(req.Name)
		if !validDirectoryID(id) || req.ID != id || req.Name == "" || len(req.Name) > 100 {
			http.Error(w, "invalid entry", 400)
			return
		}
		stored, err := json.Marshal(req)
		if err != nil {
			http.Error(w, "internal error", 500)
			return
		}
		if _, err = a.db.ExecContext(r.Context(), `INSERT INTO `+table+`(id,data) VALUES(?,?) ON DUPLICATE KEY UPDATE data=VALUES(data)`, id, stored); err != nil {
			http.Error(w, "internal error", 500)
			return
		}
		writeJSON(w, 200, json.RawMessage(stored))
	}
}

// Create or replace a project. Unlike the other directories a project carries
// fields the page edits in more than one place, so this reads the stored row
// and replaces only the fields the request names: a caller that sends just the
// name cannot wipe the public flag or the employee list. Unknown fields another
// writer added survive for the same reason.
func (a *app) putProject(w http.ResponseWriter, r *http.Request, u user) {
	if !requireAdmin(w, u) {
		return
	}
	id := r.PathValue("id")
	var req struct {
		ID        string             `json:"id"`
		Name      string             `json:"name"`
		Public    *bool              `json:"public"`
		Employees *[]projectEmployee `json:"employees"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if !validDirectoryID(id) || req.ID != id || req.Name == "" || len(req.Name) > 100 {
		http.Error(w, "invalid project", 400)
		return
	}
	employees := []projectEmployee{}
	if req.Employees != nil {
		employees = *req.Employees
	}
	if err := validateEmployeeList(employees); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer tx.Rollback()
	// Lock the row before reading it so two admins editing at once cannot drop
	// each other's fields.
	fields := map[string]json.RawMessage{}
	var data []byte
	err = tx.QueryRowContext(r.Context(), `SELECT data FROM projects WHERE id=? FOR UPDATE`, id).Scan(&data)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "internal error", 500)
		return
	}
	if len(data) > 0 {
		if err = json.Unmarshal(data, &fields); err != nil || fields == nil {
			http.Error(w, "invalid stored project", 500)
			return
		}
	}
	if req.Employees != nil {
		for _, e := range employees {
			for _, ref := range []struct{ table, id, label string }{
				{"employees", e.ID, "employee"},
				{"machines", e.MachineID, "machine"},
			} {
				ok, err := directoryExists(r.Context(), tx, ref.table, ref.id)
				if err != nil {
					http.Error(w, "internal error", 500)
					return
				}
				if !ok {
					http.Error(w, ref.label+" not found: "+ref.id, 400)
					return
				}
			}
		}
	}
	fields["id"], _ = json.Marshal(req.ID)
	fields["name"], _ = json.Marshal(req.Name)
	if req.Public != nil {
		fields["public"], _ = json.Marshal(*req.Public)
	}
	if req.Employees != nil {
		fields["employees"], _ = json.Marshal(employees)
	}
	stored, err := json.Marshal(fields)
	if err == nil {
		_, err = tx.ExecContext(r.Context(), `INSERT INTO projects(id,data) VALUES(?,?) ON DUPLICATE KEY UPDATE data=VALUES(data)`, id, stored)
	}
	// The public tab set every client receives is derived from this list, and a
	// client that already holds a snapshot sends its version back and is served
	// 304. Without a bump the edit would reach nobody who has synced before.
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
	writeJSON(w, 200, json.RawMessage(stored))
}

// Deleting an entry that tabs still reference is allowed: the tab keeps its
// session name, and the admin page falls back to showing the bare ID.
func (a *app) deleteDirectoryEntry(table string) handler {
	return func(w http.ResponseWriter, r *http.Request, u user) {
		if !directoryTables[table] {
			http.Error(w, "internal error", 500)
			return
		}
		if !requireAdmin(w, u) {
			return
		}
		tx, err := a.db.BeginTx(r.Context(), nil)
		if err != nil {
			http.Error(w, "internal error", 500)
			return
		}
		defer tx.Rollback()
		result, err := tx.ExecContext(r.Context(), `DELETE FROM `+table+` WHERE id=?`, r.PathValue("id"))
		if err != nil {
			http.Error(w, "internal error", 500)
			return
		}
		if n, _ := result.RowsAffected(); n == 0 {
			http.Error(w, "not found", 404)
			return
		}
		// Removing a project drops the public tabs derived from it, so the shared
		// version has to move for clients to stop sending back the old one.
		if table == "projects" {
			if _, err = tx.ExecContext(r.Context(), `UPDATE config_versions SET version=version+1 WHERE id=1`); err != nil {
				http.Error(w, "internal error", 500)
				return
			}
		}
		if err = tx.Commit(); err != nil {
			http.Error(w, "internal error", 500)
			return
		}
		w.WriteHeader(204)
	}
}

func (a *app) listDirectory(ctx context.Context, table string) ([]json.RawMessage, error) {
	if !directoryTables[table] {
		return nil, errors.New("unknown directory")
	}
	rows, err := a.db.QueryContext(ctx, `SELECT data FROM `+table+` ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]json.RawMessage, 0)
	for rows.Next() {
		var data []byte
		if err = rows.Scan(&data); err != nil {
			return nil, err
		}
		out = append(out, json.RawMessage(data))
	}
	return out, rows.Err()
}

// directoryExists reports whether id is present in one of the shared directory
// tables. table is always a literal from this file, never request data.
func directoryExists(ctx context.Context, tx *sql.Tx, table, id string) (bool, error) {
	var found string
	err := tx.QueryRowContext(ctx, `SELECT id FROM `+table+` WHERE id=?`, id).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}
