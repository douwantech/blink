package main

import (
	"database/sql"
	"net/http"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

func (a *app) deleteUser(w http.ResponseWriter, r *http.Request, u user) {
	if !requireAdmin(w, u) {
		return
	}
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	if id == u.ID {
		http.Error(w, "cannot delete yourself", http.StatusBadRequest)
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer tx.Rollback()
	var targetID uint64
	var targetAdmin bool
	if err = tx.QueryRowContext(r.Context(), `SELECT id,is_admin FROM users WHERE id=? FOR UPDATE`, id).Scan(&targetID, &targetAdmin); err == sql.ErrNoRows {
		http.Error(w, "not found", 404)
		return
	} else if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	rows, err := tx.QueryContext(r.Context(), `SELECT id FROM users WHERE is_admin=1 FOR UPDATE`)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	adminCount := 0
	for rows.Next() {
		adminCount++
	}
	rowsErr := rows.Err()
	rows.Close()
	if rowsErr != nil {
		http.Error(w, "internal error", 500)
		return
	}
	if targetAdmin && adminCount <= 1 {
		http.Error(w, "cannot delete the last administrator", http.StatusBadRequest)
		return
	}
	if _, err = tx.ExecContext(r.Context(), `DELETE FROM users WHERE id=?`, targetID); err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	if err = tx.Commit(); err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *app) createUser(w http.ResponseWriter, r *http.Request, u user) {
	if !requireAdmin(w, u) {
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
		Admin    bool   `json:"isAdmin"`
		CanWrite bool   `json:"canWrite"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	if len(req.Username) < 2 || len(req.Username) > 100 || len(req.Password) < 12 || (req.CanWrite && !req.Admin) {
		http.Error(w, "invalid user", 400)
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	result, err := a.db.ExecContext(r.Context(), `INSERT INTO users(username,password_hash,is_admin,can_write) VALUES(?,?,?,?)`, req.Username, hash, req.Admin, req.CanWrite)
	if err != nil {
		http.Error(w, "username unavailable", 409)
		return
	}
	id, _ := result.LastInsertId()
	writeJSON(w, 201, user{ID: uint64(id), Username: req.Username, Admin: req.Admin, CanWrite: req.CanWrite})
}

func (a *app) updateUser(w http.ResponseWriter, r *http.Request, u user) {
	if !requireAdmin(w, u) {
		return
	}
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	var req struct {
		Password *string `json:"password"`
		Admin    *bool   `json:"isAdmin"`
		CanWrite *bool   `json:"canWrite"`
		Disabled *bool   `json:"disabled"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if req.Password == nil && req.Admin == nil && req.CanWrite == nil && req.Disabled == nil {
		http.Error(w, "empty update", 400)
		return
	}
	if id == u.ID && ((req.Admin != nil && !*req.Admin) || (req.Disabled != nil && *req.Disabled)) {
		http.Error(w, "cannot remove own admin access", 400)
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer tx.Rollback()
	var current user
	var hash string
	err = tx.QueryRowContext(r.Context(), `SELECT id,username,password_hash,is_admin,can_write,disabled FROM users WHERE id=? FOR UPDATE`, id).Scan(&current.ID, &current.Username, &hash, &current.Admin, &current.CanWrite, &current.Disabled)
	if err != nil {
		http.Error(w, "not found", 404)
		return
	}
	if req.Admin != nil {
		current.Admin = *req.Admin
	}
	if req.CanWrite != nil {
		current.CanWrite = *req.CanWrite
	}
	if req.Disabled != nil {
		current.Disabled = *req.Disabled
	}
	if !current.Admin && current.CanWrite {
		http.Error(w, "write access requires admin", 400)
		return
	}
	if req.Password != nil {
		if len(*req.Password) < 12 {
			http.Error(w, "password too short", 400)
			return
		}
		b, e := bcrypt.GenerateFromPassword([]byte(*req.Password), bcrypt.DefaultCost)
		if e != nil {
			http.Error(w, "internal error", 500)
			return
		}
		hash = string(b)
	}
	_, err = tx.ExecContext(r.Context(), `UPDATE users SET password_hash=?,is_admin=?,can_write=?,disabled=? WHERE id=?`, hash, current.Admin, current.CanWrite, current.Disabled, id)
	if err == nil && (req.Password != nil || current.Disabled) {
		_, err = tx.ExecContext(r.Context(), `DELETE FROM sessions WHERE user_id=?`, id)
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	writeJSON(w, 200, current)
}
