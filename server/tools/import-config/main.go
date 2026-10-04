// import-config imports a Mac sync snapshot into an existing Blink account.
// Dry run is the default; --apply performs API writes and verifies the result.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"reflect"
	"regexp"
	"strings"
	"time"
)

var uuid = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

type source struct {
	Machines        []json.RawMessage `json:"machines"`
	Tabs            []map[string]any  `json:"tabs"`
	Agents          map[string]string `json:"agents"`
	CurrentID       string            `json:"currentId"`
	ClosedIDs       []string          `json:"closedIds"`
	FilterMachineID string            `json:"filterMachineId"`
}

type plan struct {
	Machines  []json.RawMessage
	IDs       []string
	Tabs      json.RawMessage
	Agents    json.RawMessage
	Selection json.RawMessage
}

func prepare(data []byte) (plan, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return plan{}, err
	}
	for _, key := range []string{"machines", "tabs", "agents"} {
		value, ok := fields[key]
		if !ok || string(value) == "null" {
			return plan{}, fmt.Errorf("source is missing %s", key)
		}
	}
	var src source
	if err := json.Unmarshal(data, &src); err != nil {
		return plan{}, err
	}
	if len(src.Machines) == 0 {
		return plan{}, errors.New("source has no machines; refusing empty import")
	}
	p := plan{Machines: make([]json.RawMessage, 0, len(src.Machines)), IDs: make([]string, 0, len(src.Machines))}
	seen := map[string]bool{}
	for i, raw := range src.Machines {
		var m map[string]any
		if err := json.Unmarshal(raw, &m); err != nil {
			return plan{}, fmt.Errorf("machine %d: %w", i, err)
		}
		id, _ := m["id"].(string)
		host, _ := m["host"].(string)
		user, _ := m["user"].(string)
		if id == "" || host == "" || user == "" || seen[id] {
			return plan{}, fmt.Errorf("machine %d has missing/duplicate id, host or user", i)
		}
		seen[id] = true
		if _, ok := m["position"]; !ok {
			m["position"] = i
		}
		b, err := json.Marshal(m)
		if err != nil {
			return plan{}, err
		}
		p.Machines = append(p.Machines, b)
		p.IDs = append(p.IDs, id)
	}
	closed := make([]string, 0, len(src.ClosedIDs))
	for _, id := range src.ClosedIDs {
		if !uuid.MatchString(id) {
			return plan{}, fmt.Errorf("invalid closed tab id %q", id)
		}
		closed = append(closed, id)
	}
	tabs := make([]map[string]any, 0, len(src.Tabs))
	for i, t := range src.Tabs {
		id, _ := t["id"].(string)
		if !uuid.MatchString(id) {
			return plan{}, fmt.Errorf("invalid tab id at index %d", i)
		}
		entry := map[string]any{"id": id}
		for _, key := range []string{"machineId", "workDirId", "tmuxSession"} {
			if v, ok := t[key].(string); ok && v != "" {
				entry[key] = v
			}
		}
		if v, ok := t["useTmux"].(bool); ok {
			entry["useTmux"] = v
		}
		tabs = append(tabs, entry)
	}
	state := map[string]any{"version": 1, "tabs": tabs, "closedIds": closed, "updatedAt": float64(time.Now().Unix())}
	if src.CurrentID != "" {
		if !uuid.MatchString(src.CurrentID) {
			return plan{}, errors.New("invalid currentId")
		}
		state["currentId"] = src.CurrentID
	}
	p.Tabs, _ = json.Marshal(state)
	if src.Agents == nil {
		src.Agents = map[string]string{}
	}
	p.Agents, _ = json.Marshal(src.Agents)
	selection := map[string]string{}
	if src.FilterMachineID != "" {
		selection["machineId"] = src.FilterMachineID
	}
	if src.CurrentID != "" {
		selection["tabId"] = src.CurrentID
	}
	p.Selection, _ = json.Marshal(selection)
	return p, nil
}

type client struct {
	base  string
	token string
	http  *http.Client
}

func (c *client) request(ctx context.Context, method, path string, body []byte, out any) error {
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	res, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		io.Copy(io.Discard, res.Body)
		return fmt.Errorf("%s %s: HTTP %d", method, path, res.StatusCode)
	}
	if out != nil {
		return json.NewDecoder(io.LimitReader(res.Body, 2<<20)).Decode(out)
	}
	return nil
}

func apply(ctx context.Context, p plan, base, username, password string) error {
	parsed, err := url.Parse(base)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && !(parsed.Scheme == "http" && (parsed.Hostname() == "localhost" || parsed.Hostname() == "127.0.0.1"))) {
		return errors.New("base URL must be HTTPS (or localhost HTTP)")
	}
	if username == "" || password == "" {
		return errors.New("BLINK_IMPORT_USER and BLINK_IMPORT_PASSWORD are required with --apply")
	}
	c := &client{base: strings.TrimRight(base, "/"), http: &http.Client{Timeout: 20 * time.Second}}
	credentials, _ := json.Marshal(map[string]string{"username": username, "password": password})
	var login struct {
		Token string `json:"token"`
		User  struct {
			Admin    bool `json:"isAdmin"`
			CanWrite bool `json:"canWrite"`
		} `json:"user"`
	}
	if err = c.request(ctx, "POST", "/v1/login", credentials, &login); err != nil {
		return err
	}
	if !login.User.Admin || !login.User.CanWrite {
		return errors.New("target account needs admin and canWrite to import machines")
	}
	c.token = login.Token
	for i, m := range p.Machines {
		if err = c.request(ctx, "PUT", "/v1/machines/"+url.PathEscape(p.IDs[i]), m, nil); err != nil {
			return err
		}
	}
	for _, item := range []struct {
		path string
		body []byte
	}{{"/v1/config/tabs", p.Tabs}, {"/v1/config/agents", p.Agents}, {"/v1/config/selection", p.Selection}} {
		if err = c.request(ctx, "PUT", item.path, item.body, nil); err != nil {
			return err
		}
	}
	var snapshot struct {
		Machines        []json.RawMessage `json:"machines"`
		Tabs            json.RawMessage   `json:"tabs"`
		Agents          json.RawMessage   `json:"agents"`
		RecentSelection json.RawMessage   `json:"recentSelection"`
	}
	if err = c.request(ctx, "GET", "/v1/config", nil, &snapshot); err != nil {
		return err
	}
	machines := map[string]json.RawMessage{}
	for _, raw := range snapshot.Machines {
		var m struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(raw, &m); err != nil {
			return err
		}
		machines[m.ID] = raw
	}
	for i, id := range p.IDs {
		if !sameJSON(machines[id], p.Machines[i]) {
			return fmt.Errorf("verification failed: machine %s differs", id)
		}
	}
	if !sameJSON(snapshot.Tabs, p.Tabs) || !sameJSON(snapshot.Agents, p.Agents) || !sameJSON(snapshot.RecentSelection, p.Selection) {
		return errors.New("verification failed: personal config differs")
	}
	fmt.Printf("Verified %d imported machines and personal tabs/agents/selection.\n", len(p.IDs))
	return nil
}

func sameJSON(a, b []byte) bool {
	var x, y any
	return json.Unmarshal(a, &x) == nil && json.Unmarshal(b, &y) == nil && reflect.DeepEqual(x, y)
}

func main() {
	input := flag.String("input", "", "path to Mac blink_config.json")
	base := flag.String("base-url", "https://blink-api.douwantech.com", "Blink API root")
	doApply := flag.Bool("apply", false, "write config to server after preview")
	flag.Parse()
	if *input == "" {
		fmt.Fprintln(os.Stderr, "--input is required")
		os.Exit(2)
	}
	data, err := os.ReadFile(*input)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	p, err := prepare(data)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var tabs struct {
		Tabs []any `json:"tabs"`
	}
	_ = json.Unmarshal(p.Tabs, &tabs)
	var agents map[string]string
	_ = json.Unmarshal(p.Agents, &agents)
	fmt.Printf("Preview: %d machines, %d tabs, %d agent choices. Machine IDs: %s\n", len(p.IDs), len(tabs.Tabs), len(agents), strings.Join(p.IDs, ", "))
	if !*doApply {
		fmt.Println("Dry run only. Add --apply to write.")
		return
	}
	if err = apply(context.Background(), p, *base, os.Getenv("BLINK_IMPORT_USER"), os.Getenv("BLINK_IMPORT_PASSWORD")); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
