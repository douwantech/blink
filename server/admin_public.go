package main

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strings"
)

// Public tabs are global. A project marked public declares the employees it is
// for, and every account that signs in gets one tab per pair, on that pair's
// machine, named <employee>-<project>. Nothing is stored per account: the set is
// derived from the project list on every read, so editing a project changes what
// every client sees and no account can drift from it.
//
// There is deliberately no reconciliation here. There is no per-account status,
// no "missing" to backfill and no "extra" to clean up, because there is nothing
// per account to compare against: the set is the same for everybody.
//
// The derivation is a pure function of the projects, so the read path
// (config.go) and the admin page agree by construction and both can be tested
// without a database.

// publicTabNamespace is the fixed UUIDv5 namespace for public tab IDs:
// uuid5(NAMESPACE_URL, "https://blink.douwantech.com/public-tab") =
// 924f04d2-3134-500d-b88c-c008790adaac. Changing it renames every public tab on
// every account at once, so it is a constant of the data, not a detail.
var publicTabNamespace = [16]byte{
	0x92, 0x4f, 0x04, 0xd2, 0x31, 0x34, 0x50, 0x0d,
	0xb8, 0x8c, 0xc0, 0x08, 0x79, 0x0a, 0xda, 0xac,
}

// publicTabID is the stable UUID a public tab is known by on every client.
//
// It is derived from the pair rather than generated and stored, so the same tab
// keeps the same ID across restarts and redeploys and a client that already
// holds the tab recognises it instead of appending a second copy. It has to be
// a well-formed v5 UUID and not the session name: TabEntry.id is a UUID in the
// client's model, and a client that cannot decode the snapshot discards it.
func publicTabID(employee, project string) string {
	h := sha1.New()
	h.Write(publicTabNamespace[:])
	h.Write([]byte(employee))
	h.Write([]byte{0}) // in neither ID, so no two pairs collide
	h.Write([]byte(project))
	sum := h.Sum(nil)
	var id [16]byte
	copy(id[:], sum[:16])
	id[6] = id[6]&0x0f | 0x50 // version 5: name based, SHA-1
	id[8] = id[8]&0x3f | 0x80 // RFC 4122 variant
	return hex.EncodeToString(id[:4]) + "-" + hex.EncodeToString(id[4:6]) + "-" +
		hex.EncodeToString(id[6:8]) + "-" + hex.EncodeToString(id[8:10]) + "-" +
		hex.EncodeToString(id[10:])
}

// One public tab as a client receives it: the fields of the client's TabEntry
// that the server fills in, exactly like the tab an admin creates for a single
// account. shared marks it as belonging to everybody; the client is expected to
// treat it as fixed (phase two), and a client that does not know the field
// ignores it and shows an ordinary tab.
type publicTabEntry struct {
	ID          string `json:"id"`
	MachineID   string `json:"machineId"`
	TmuxSession string `json:"tmuxSession"`
	WorkDir     string `json:"workDir,omitempty"`
	Shared      bool   `json:"shared"`
}

// One public tab as the admin page lists it. The page must not re-parse the
// session name to find out what a tab is, so the pair it came from is spelled
// out here, and the project name is resolved for display.
type publicTabView struct {
	ProjectID   string `json:"projectId"`
	ProjectName string `json:"projectName"`
	EmployeeID  string `json:"employeeId"`
	MachineID   string `json:"machineId"`
	Session     string `json:"session"`
	WorkDir     string `json:"workDir,omitempty"`
	TabID       string `json:"tabId"`
}

// buildPublicTabView expands the public projects into the tab set every account
// gets. Order is project ID then employee ID, so the list is identical for
// every account and does not move between reads.
func buildPublicTabView(projects []projectEntry) []publicTabView {
	public := make([]projectEntry, 0, len(projects))
	for _, p := range projects {
		if p.Public {
			public = append(public, p)
		}
	}
	sort.Slice(public, func(i, j int) bool { return public[i].ID < public[j].ID })
	out := make([]publicTabView, 0)
	for _, p := range public {
		employees := append([]projectEmployee(nil), p.Employees...)
		sort.Slice(employees, func(i, j int) bool { return employees[i].ID < employees[j].ID })
		for _, e := range employees {
			out = append(out, publicTabView{
				ProjectID:   p.ID,
				ProjectName: p.Name,
				EmployeeID:  e.ID,
				MachineID:   e.MachineID,
				Session:     e.ID + "-" + p.ID,
				WorkDir:     e.WorkDir,
				TabID:       publicTabID(e.ID, p.ID),
			})
		}
	}
	return out
}

// clientPublicTabs projects the view onto the entries a client decodes.
func clientPublicTabs(view []publicTabView) []publicTabEntry {
	out := make([]publicTabEntry, 0, len(view))
	for _, v := range view {
		out = append(out, publicTabEntry{
			ID:          v.TabID,
			MachineID:   v.MachineID,
			TmuxSession: v.Session,
			WorkDir:     v.WorkDir,
			Shared:      true,
		})
	}
	return out
}

// employeeMachines maps an employee to the machines the project lists put that
// employee on, in project ID order. More than one entry means the lists
// disagree; the page shows every one of them rather than picking a winner,
// because a machine nobody declares would otherwise hide the disagreement that
// sends somebody to the wrong host.
func employeeMachines(projects []projectEntry) map[string][]string {
	public := make([]projectEntry, 0, len(projects))
	for _, p := range projects {
		if p.Public {
			public = append(public, p)
		}
	}
	sort.Slice(public, func(i, j int) bool { return public[i].ID < public[j].ID })
	out := map[string][]string{}
	for _, p := range public {
		for _, e := range p.Employees {
			seen := false
			for _, id := range out[e.ID] {
				if id == e.MachineID {
					seen = true
					break
				}
			}
			if !seen {
				out[e.ID] = append(out[e.ID], e.MachineID)
			}
		}
	}
	return out
}

// mergePublicTabs puts the public tabs in front of the account's own tabs and
// returns the state a client receives. The stored state is never rewritten:
// this runs on the read path only, so an account's own tabs stay exactly as it
// uploaded them.
//
// Two things are adjusted on the way out. A stored tab whose ID is a public tab
// ID is dropped, because the ID is derived rather than stored: a client that
// adopts a public tab and later uploads its whole state would otherwise get the
// same tab back twice. And public IDs are dropped from closedIds, the client's
// tombstones, so a public tab closed on one device is back the next time that
// device syncs — the set is global, and closing one is not a permanent choice.
//
// Unknown top-level fields and the stored updatedAt are preserved: the phone
// owns the TabState format, and the merge must not look like a local edit.
func mergePublicTabs(stored []byte, shared []publicTabEntry) ([]byte, error) {
	state, err := decodeAdminTabs(stored)
	if err != nil {
		return nil, err
	}
	sharedIDs := make(map[string]bool, len(shared))
	tabs := make([]json.RawMessage, 0, len(shared)+len(state.tabs))
	for _, t := range shared {
		b, err := json.Marshal(t)
		if err != nil {
			return nil, err
		}
		sharedIDs[strings.ToLower(t.ID)] = true
		tabs = append(tabs, b)
	}
	for _, raw := range state.tabs {
		if sharedIDs[strings.ToLower(tabID(raw))] {
			continue
		}
		tabs = append(tabs, raw)
	}
	closed := make([]string, 0, len(state.closed))
	for _, id := range state.closed {
		if !sharedIDs[strings.ToLower(id)] {
			closed = append(closed, id)
		}
	}
	state.fields["tabs"], err = json.Marshal(tabs)
	if err != nil {
		return nil, err
	}
	state.fields["closedIds"], err = json.Marshal(closed)
	if err != nil {
		return nil, err
	}
	return json.Marshal(state.fields)
}

// decodeProjects reads the stored project rows. A row that does not parse is
// skipped: the tab set is derived from what it can read, and one broken row must
// not blank every client's tabs.
func decodeProjects(raw []json.RawMessage) []projectEntry {
	out := make([]projectEntry, 0, len(raw))
	for _, entry := range raw {
		var p projectEntry
		if json.Unmarshal(entry, &p) != nil || p.ID == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}
