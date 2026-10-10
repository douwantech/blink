package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	mysql "github.com/go-sql-driver/mysql"
)

// Run with BLINK_TEST_MYSQL_DSN pointing at an isolated test database. No
// production account or database is used by the normal go test invocation.
func TestVoiceInputMySQLIntegration(t *testing.T) {
	dsn := os.Getenv("BLINK_TEST_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set BLINK_TEST_MYSQL_DSN to an isolated MySQL test database")
	}
	parsed, err := mysql.ParseDSN(dsn)
	if err != nil || !strings.HasPrefix(parsed.DBName, "blink_voice_test") {
		t.Fatal("BLINK_TEST_MYSQL_DSN must name an isolated blink_voice_test database")
	}
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	db.SetMaxOpenConns(8)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := migrate(ctx, db); err != nil {
		t.Fatal(err)
	}

	newAccount := func(name string) (uint64, string) {
		t.Helper()
		result, err := db.ExecContext(ctx, `INSERT INTO users(username,password_hash) VALUES(?,?)`, name, "test-only")
		if err != nil {
			t.Fatal(err)
		}
		id, err := result.LastInsertId()
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _, _ = db.Exec(`DELETE FROM users WHERE id=?`, id) })
		token := make([]byte, 32)
		if _, err := rand.Read(token); err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(token)
		if _, err := db.ExecContext(ctx, `INSERT INTO sessions(token_hash,user_id,expires_at) VALUES(?,?,DATE_ADD(NOW(), INTERVAL 1 HOUR))`,
			digest[:], id); err != nil {
			t.Fatal(err)
		}
		return uint64(id), hex.EncodeToString(token)
	}
	suffix := fmt.Sprintf("%d", time.Now().UnixNano())
	_, tokenA := newAccount("voice-a-" + suffix)
	_, tokenB := newAccount("voice-b-" + suffix)
	srv := httptest.NewServer((&app{db}).routes())
	defer srv.Close()

	request := func(method, path, token string, body any) (*http.Response, []byte, error) {
		var encoded []byte
		if body != nil {
			var err error
			encoded, err = json.Marshal(body)
			if err != nil {
				return nil, nil, err
			}
		}
		req, err := http.NewRequest(method, srv.URL+path, bytes.NewReader(encoded))
		if err != nil {
			return nil, nil, err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		response, err := srv.Client().Do(req)
		if err != nil {
			return nil, nil, err
		}
		defer response.Body.Close()
		var data bytes.Buffer
		_, err = data.ReadFrom(response.Body)
		return response, data.Bytes(), err
	}
	post := func(token string, ops ...voiceInputOperation) (voiceInputDocument, string, error) {
		response, data, err := request(http.MethodPost, "/v1/config/voice-input", token, map[string]any{"operations": ops})
		if err != nil {
			return voiceInputDocument{}, "", err
		}
		if response.StatusCode != http.StatusOK {
			return voiceInputDocument{}, "", fmt.Errorf("POST status %d", response.StatusCode)
		}
		var doc voiceInputDocument
		if err := json.Unmarshal(data, &doc); err != nil {
			return voiceInputDocument{}, "", err
		}
		return doc, response.Header.Get("X-Personal-Version"), nil
	}
	get := func(token string) (*voiceInputDocument, string) {
		t.Helper()
		response, data, err := request(http.MethodGet, "/v1/config", token, nil)
		if err != nil || response.StatusCode != http.StatusOK {
			t.Fatalf("GET config: status=%v err=%v", response, err)
		}
		var snapshot struct {
			Version    string              `json:"version"`
			VoiceInput *voiceInputDocument `json:"voiceInput"`
		}
		if err := json.Unmarshal(data, &snapshot); err != nil {
			t.Fatal(err)
		}
		return snapshot.VoiceInput, snapshot.Version
	}
	id := func(n int) string { return fmt.Sprintf("voice-op-%016d", n) }
	if doc, _ := get(tokenA); doc != nil {
		t.Fatal("new account must return null voiceInput before migration")
	}
	seedID := id(1)
	seedA := voiceInputOperation{ID: seedID, Kind: "seed", Data: &voiceInputDocument{
		Favorites: []string{"old"}, History: []string{"old submission"}, FavoriteCounts: map[string]int{"old": 3}}}
	if doc, version, err := post(tokenA, seedA); err != nil || version != "2" || doc.FavoriteCounts["old"] != 3 {
		t.Fatalf("seed A: version=%q doc=%+v err=%v", version, doc, err)
	}
	if doc, version, err := post(tokenA, seedA); err != nil || version != "2" || doc.FavoriteCounts["old"] != 3 {
		t.Fatalf("idempotent retry: version=%q doc=%+v err=%v", version, doc, err)
	}
	seedB := voiceInputOperation{ID: seedID, Kind: "seed", Data: &voiceInputDocument{
		Favorites: []string{"other account"}, History: []string{}, FavoriteCounts: map[string]int{}}}
	if doc, version, err := post(tokenB, seedB); err != nil || version != "2" || len(doc.Favorites) != 1 || doc.Favorites[0] != "other account" {
		t.Fatalf("separate account with same operation ID: version=%q doc=%+v err=%v", version, doc, err)
	}

	for _, op := range []voiceInputOperation{
		{ID: id(2), Kind: "removeFavorite", Text: "old"},
		{ID: id(3), Kind: "removeHistory", Text: "old submission"},
		{ID: id(4), Kind: "clearFavorites"},
		{ID: id(5), Kind: "clearHistory"},
	} {
		if _, _, err := post(tokenA, op); err != nil {
			t.Fatal(err)
		}
	}
	if doc, _, err := post(tokenA, voiceInputOperation{ID: id(6), Kind: "seed", Data: seedA.Data}); err != nil || len(doc.Favorites) != 0 || len(doc.History) != 0 {
		t.Fatalf("stale migration restored cleared data: doc=%+v err=%v", doc, err)
	}

	// Two devices write from the same prior snapshot. The account row lock
	// serializes both operations; neither complete list replaces the other.
	var wg sync.WaitGroup
	type writeResult struct {
		version string
		err     error
	}
	results := make(chan writeResult, 2)
	for n, text := range []string{"device A", "device B"} {
		wg.Add(1)
		go func(n int, text string) {
			defer wg.Done()
			_, version, err := post(tokenA, voiceInputOperation{ID: id(7 + n), Kind: "addFavorite", Text: text})
			results <- writeResult{version, err}
		}(n, text)
	}
	wg.Wait()
	close(results)
	versions := make([]string, 0, 2)
	for result := range results {
		if result.err != nil {
			t.Fatal(result.err)
		}
		versions = append(versions, result.version)
	}
	sort.Strings(versions)
	if versions[0] != "8" || versions[1] != "9" {
		t.Fatalf("concurrent writes have unexpected versions: %v", versions)
	}
	docA, _ := get(tokenA)
	sort.Strings(docA.Favorites)
	if fmt.Sprint(docA.Favorites) != "[device A device B]" {
		t.Fatalf("concurrent writes lost an edit: %+v", docA)
	}
	docB, _ := get(tokenB)
	if len(docB.Favorites) != 1 || docB.Favorites[0] != "other account" {
		t.Fatalf("account B changed with A's writes: %+v", docB)
	}
}
