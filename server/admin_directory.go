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

// Create or replace one directory entry. Like machines these are shared and
// there is no position column: the list is ordered by ID.
func (a *app) putDirectoryEntry(table string) handler {
	return func(w http.ResponseWriter, r *http.Request, u user) {
		if !directoryTables[table] {
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
		result, err := a.db.ExecContext(r.Context(), `DELETE FROM `+table+` WHERE id=?`, r.PathValue("id"))
		if err != nil {
			http.Error(w, "internal error", 500)
			return
		}
		if n, _ := result.RowsAffected(); n == 0 {
			http.Error(w, "not found", 404)
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
