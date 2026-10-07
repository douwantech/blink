package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
)

const maxEmployeeAvatarBytes = 2 << 20

// employeeAvatar serves the binary separately from the config snapshot. The
// client is authenticated before it can learn or fetch an employee image.
func (a *app) employeeAvatar(w http.ResponseWriter, r *http.Request, _ user) {
	var data []byte
	if err := a.db.QueryRowContext(r.Context(), `SELECT data FROM employee_avatars WHERE employee_id=?`, r.PathValue("id")).Scan(&data); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "private, max-age=300")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

// storeEmployeeAvatar accepts only PNG bytes. The directory JSON gets a stable
// URL marker while the bytes remain in the dedicated RDS table.
//
// It deliberately checks no permission: the two entry points below decide who
// may call it (admin session vs. Bearer with canWrite), so the validation and
// write path stay in one place and cannot drift apart.
func (a *app) storeEmployeeAvatar(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validDirectoryID(id) || !strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "image/png") {
		http.Error(w, "PNG image required", http.StatusBadRequest)
		return
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, maxEmployeeAvatarBytes+1))
	if err != nil || len(data) == 0 || len(data) > maxEmployeeAvatarBytes || len(data) < 8 || string(data[:8]) != "\x89PNG\r\n\x1a\n" {
		http.Error(w, "invalid PNG", http.StatusBadRequest)
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()
	var stored []byte
	if err = tx.QueryRowContext(r.Context(), `SELECT data FROM employees WHERE id=? FOR UPDATE`, id).Scan(&stored); errors.Is(err, sql.ErrNoRows) {
		http.NotFound(w, r)
		return
	} else if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	var doc map[string]json.RawMessage
	if err = json.Unmarshal(stored, &doc); err != nil {
		http.Error(w, "invalid employee", http.StatusInternalServerError)
		return
	}
	doc["avatar"] = json.RawMessage(`"/v1/employees/` + id + `/avatar"`)
	stored, err = json.Marshal(doc)
	if err == nil {
		_, err = tx.ExecContext(r.Context(), `UPDATE employees SET data=? WHERE id=?`, stored, id)
	}
	if err == nil {
		_, err = tx.ExecContext(r.Context(), `INSERT INTO employee_avatars(employee_id,data,content_type) VALUES(?,?,?) ON DUPLICATE KEY UPDATE data=VALUES(data),content_type=VALUES(content_type)`, id, data, "image/png")
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// putEmployeeAvatar is the admin page's upload route. The session cookie alone
// is not enough: adminAuth already rejected non-admins, and the account must
// still be an administrator here.
func (a *app) putEmployeeAvatar(w http.ResponseWriter, r *http.Request, u user) {
	if !requireAdmin(w, u) {
		return
	}
	a.storeEmployeeAvatar(w, r)
}

// putEmployeeAvatarV1 is the Bearer route used by tooling when no admin browser
// session exists. Same authorization as PUT /v1/machines/{id}: admin with
// canWrite. The admin route above keeps its own (requireAdmin) semantics.
func (a *app) putEmployeeAvatarV1(w http.ResponseWriter, r *http.Request, u user) {
	if !requireWrite(w, u) {
		return
	}
	a.storeEmployeeAvatar(w, r)
}
