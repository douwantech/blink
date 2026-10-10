package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
)

// Each account has its own favorites and submission history. Clients send
// edits, never a stale replacement snapshot, so concurrent devices keep each
// other's additions and a deletion cannot be undone by a background refresh.
type voiceInputDocument struct {
	Favorites      []string       `json:"favorites"`
	History        []string       `json:"history"`
	FavoriteCounts map[string]int `json:"favoriteCounts"`
}

type voiceInputOperation struct {
	ID   string              `json:"id"`
	Kind string              `json:"kind"`
	Text string              `json:"text,omitempty"`
	Data *voiceInputDocument `json:"data,omitempty"`
}

func emptyVoiceInput() voiceInputDocument {
	return voiceInputDocument{[]string{}, []string{}, map[string]int{}}
}

func withoutText(values []string, text string) []string {
	out := make([]string, 0, len(values))
	for _, value := range values {
		if value != text {
			out = append(out, value)
		}
	}
	return out
}

func (doc *voiceInputDocument) apply(op voiceInputOperation) {
	switch op.Kind {
	case "addFavorite":
		for _, value := range doc.Favorites {
			if value == op.Text {
				return
			}
		}
		doc.Favorites = append(doc.Favorites, op.Text)
	case "removeFavorite":
		doc.Favorites = withoutText(doc.Favorites, op.Text)
		delete(doc.FavoriteCounts, op.Text)
	case "clearFavorites":
		doc.Favorites = []string{}
		doc.FavoriteCounts = map[string]int{}
	case "useFavorite":
		for _, value := range doc.Favorites {
			if value == op.Text {
				doc.FavoriteCounts[value]++
				break
			}
		}
	case "recordHistory":
		doc.History = append(withoutText(doc.History, op.Text), op.Text)
		if len(doc.History) > 40 {
			doc.History = doc.History[len(doc.History)-40:]
		}
	case "removeHistory":
		doc.History = withoutText(doc.History, op.Text)
	case "clearHistory":
		doc.History = []string{}
	}
}

func validateVoiceInputOperation(op *voiceInputOperation) error {
	if len(op.ID) < 16 || len(op.ID) > 100 {
		return errors.New("invalid operation id")
	}
	op.Text = strings.TrimSpace(op.Text)
	switch op.Kind {
	case "addFavorite", "removeFavorite", "useFavorite", "recordHistory", "removeHistory":
		if op.Text == "" || len(op.Text) > 65536 {
			return errors.New("invalid text")
		}
	case "clearFavorites", "clearHistory":
	case "seed":
		if op.Data == nil {
			return errors.New("missing initial data")
		}
		for _, values := range [][]string{op.Data.Favorites, op.Data.History} {
			for _, value := range values {
				if strings.TrimSpace(value) == "" || len(value) > 65536 {
					return errors.New("invalid initial text")
				}
			}
		}
		for _, count := range op.Data.FavoriteCounts {
			if count < 0 || count > 1000000000 {
				return errors.New("invalid count")
			}
		}
	default:
		return errors.New("unknown operation")
	}
	return nil
}

func (a *app) writeVoiceInput(w http.ResponseWriter, r *http.Request, u user) {
	var body struct {
		Operations []voiceInputOperation `json:"operations"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if len(body.Operations) == 0 || len(body.Operations) > 100 {
		http.Error(w, "expected 1-100 operations", 400)
		return
	}
	for i := range body.Operations {
		if err := validateVoiceInputOperation(&body.Operations[i]); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	defer tx.Rollback()
	// Lock the account before the document: all personal endpoints increment
	// users.config_version, so using one lock order avoids cross-endpoint deadlocks.
	var version uint64
	if err = tx.QueryRowContext(r.Context(), `SELECT config_version FROM users WHERE id=? FOR UPDATE`, u.ID).Scan(&version); err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	var raw []byte
	err = tx.QueryRowContext(r.Context(), `SELECT data FROM voice_input_configs WHERE user_id=? FOR UPDATE`, u.ID).Scan(&raw)
	newAccountData := err == sql.ErrNoRows
	if err != nil && !newAccountData {
		http.Error(w, "internal error", 500)
		return
	}
	doc := emptyVoiceInput()
	if len(raw) > 0 {
		if json.Unmarshal(raw, &doc) != nil {
			http.Error(w, "internal error", 500)
			return
		}
	}
	if doc.FavoriteCounts == nil {
		doc.FavoriteCounts = map[string]int{}
	}
	changed := false
	for _, op := range body.Operations {
		result, err := tx.ExecContext(r.Context(), `INSERT IGNORE INTO voice_input_operations(user_id,operation_id) VALUES(?,?)`, u.ID, op.ID)
		if err != nil {
			http.Error(w, "internal error", 500)
			return
		}
		rows, err := result.RowsAffected()
		if err != nil {
			http.Error(w, "internal error", 500)
			return
		}
		if rows == 0 {
			continue
		} // A retry after a lost response must not count twice.
		if op.Kind == "seed" {
			// First upgraded device migrates the old local/iCloud data. Later
			// devices adopt account data, including an intentionally empty list.
			if newAccountData {
				for _, text := range op.Data.Favorites {
					doc.apply(voiceInputOperation{Kind: "addFavorite", Text: strings.TrimSpace(text)})
				}
				for _, text := range op.Data.History {
					doc.apply(voiceInputOperation{Kind: "recordHistory", Text: strings.TrimSpace(text)})
				}
				for _, text := range doc.Favorites {
					doc.FavoriteCounts[text] = op.Data.FavoriteCounts[text]
				}
				newAccountData = false
			}
		} else {
			doc.apply(op)
			// Any accepted edit establishes the account document. A stale seed
			// later in this batch must not restore data that edit removed.
			newAccountData = false
		}
		changed = true
	}
	if changed {
		stored, err := json.Marshal(doc)
		if err != nil {
			http.Error(w, "internal error", 500)
			return
		}
		if _, err = tx.ExecContext(r.Context(), `INSERT INTO voice_input_configs(user_id,data) VALUES(?,?) ON DUPLICATE KEY UPDATE data=VALUES(data)`, u.ID, stored); err != nil {
			http.Error(w, "internal error", 500)
			return
		}
		if _, err = tx.ExecContext(r.Context(), `UPDATE users SET config_version=config_version+1 WHERE id=?`, u.ID); err != nil {
			http.Error(w, "internal error", 500)
			return
		}
	}
	if err = tx.Commit(); err != nil {
		http.Error(w, "internal error", 500)
		return
	}
	if changed {
		version++
	}
	w.Header().Set("X-Personal-Version", strconv.FormatUint(version, 10))
	writeJSON(w, 200, doc)
}
