package main

import (
	"encoding/json"
	"sort"
	"strings"
)

// The public-tabs view answers one question per employee and project: the
// account that employee signs in with should hold one tab for the session
// <employee>-<project>. Expected comes from the employee list each public
// project declares; actual comes from the accounts themselves.
//
// Only projects marked public take part, so main and blink never appear.
// Reconciliation is per account, and the account is matched by username: an
// employee ID is a username.

const (
	// The tab is what the project's employee list calls for.
	publicStatusOK = "ok"
	// No tab for this employee and project exists on the account.
	publicStatusMissing = "missing"
	// A tab exists but points at a different machine than the pair declares,
	// so the employee would connect to the wrong host.
	publicStatusWrongMachine = "wrongMachine"
	// No account has this username, so there is nobody to create the tab for.
	publicStatusNoAccount = "noAccount"
	// The account holds a tab for a public project its employee list does not
	// call for: an employee who is not on that project, or a tab for someone
	// else's session sitting on the wrong account.
	publicStatusExtra = "extra"
)

// One tab of an account, reduced to what reconciliation reads.
type publicTab struct {
	ID        string
	MachineID string
	Session   string
}

// The link row an admin-created tab has. Empty for a tab the client created
// itself, which reconciliation then reads off the session name.
type publicLink struct {
	EmployeeID string
	ProjectID  string
}

// One account as reconciliation sees it.
type publicAccount struct {
	ID    uint64
	Name  string
	Tabs  []publicTab
	Links map[string]publicLink
}

// One line of the view.
type publicTabRow struct {
	ProjectID     string `json:"projectId"`
	ProjectName   string `json:"projectName"`
	EmployeeID    string `json:"employeeId"`
	AccountID     uint64 `json:"accountId"`
	AccountName   string `json:"accountName"`
	MachineID     string `json:"machineId"`
	ActualMachine string `json:"actualMachineId,omitempty"`
	Session       string `json:"session"`
	TabID         string `json:"tabId,omitempty"`
	Status        string `json:"status"`
}

type publicSummary struct {
	Projects     int `json:"projects"`
	Expected     int `json:"expected"`
	Missing      int `json:"missing"`
	WrongMachine int `json:"wrongMachine"`
	NoAccount    int `json:"noAccount"`
	Extra        int `json:"extra"`
}

type publicReport struct {
	Rows    []publicTabRow `json:"rows"`
	Extras  []publicTabRow `json:"extras"`
	Summary publicSummary  `json:"summary"`
}

// publicPairKey identifies an employee and project pair inside one account.
// The separator cannot occur in either ID, so no two pairs collide.
func publicPairKey(employee, project string) string { return employee + "\x00" + project }

// resolvePublicPair reads the employee and project a tab stands for, and
// reports false for a tab that is not one of the public projects at all.
//
// A link row wins when the tab has one, because it is what the admin page
// recorded. Other tabs only have a session name, whose project half is matched
// whole against the known project IDs so that an employee ID containing a dash
// still resolves.
func resolvePublicPair(tab publicTab, link publicLink, public map[string]bool, longest []string) (string, string, bool) {
	if link.ProjectID != "" || link.EmployeeID != "" {
		if link.EmployeeID == "" || !public[link.ProjectID] {
			return "", "", false
		}
		return link.EmployeeID, link.ProjectID, true
	}
	for _, project := range longest {
		suffix := "-" + project
		if len(tab.Session) > len(suffix) && strings.HasSuffix(tab.Session, suffix) {
			return tab.Session[:len(tab.Session)-len(suffix)], project, true
		}
	}
	return "", "", false
}

// publicTabsOf reads an account's own tab state. Unreadable state yields no
// tabs rather than an error: this view only reports, and the accounts card
// already shows the account.
func publicTabsOf(raw []byte) []publicTab {
	state, err := decodeAdminTabs(raw)
	if err != nil {
		return nil
	}
	out := make([]publicTab, 0, len(state.tabs))
	for _, entry := range state.tabs {
		var tab struct {
			ID          string `json:"id"`
			MachineID   string `json:"machineId"`
			TmuxSession string `json:"tmuxSession"`
		}
		if json.Unmarshal(entry, &tab) != nil {
			continue
		}
		out = append(out, publicTab{ID: tab.ID, MachineID: tab.MachineID, Session: tab.TmuxSession})
	}
	return out
}

// buildPublicReport reconciles the declared employee lists against what the
// accounts hold. It is pure so the rules can be tested without a database.
func buildPublicReport(projects []projectEntry, accounts []publicAccount) publicReport {
	report := publicReport{Rows: []publicTabRow{}, Extras: []publicTabRow{}}
	public := map[string]bool{}
	for _, p := range projects {
		if p.Public {
			public[p.ID] = true
		}
	}
	// Longest first so a project ID that is the suffix of another cannot win
	// the match on the shorter one.
	longest := make([]string, 0, len(public))
	for id := range public {
		longest = append(longest, id)
	}
	sort.Slice(longest, func(i, j int) bool {
		if len(longest[i]) != len(longest[j]) {
			return len(longest[i]) > len(longest[j])
		}
		return longest[i] < longest[j]
	})

	byName := map[string]*publicAccount{}
	for i := range accounts {
		byName[accounts[i].Name] = &accounts[i]
	}

	// What each account actually holds, keyed by employee and project. The
	// first tab for a pair wins, so an accidental duplicate is not also
	// reported as an extra.
	actual := map[uint64]map[string]publicTab{}
	for i := range accounts {
		account := &accounts[i]
		for _, tab := range account.Tabs {
			employee, project, ok := resolvePublicPair(tab, account.Links[tab.ID], public, longest)
			if !ok {
				continue
			}
			if actual[account.ID] == nil {
				actual[account.ID] = map[string]publicTab{}
			}
			key := publicPairKey(employee, project)
			if _, seen := actual[account.ID][key]; !seen {
				actual[account.ID][key] = tab
			}
		}
	}

	expected := map[uint64]map[string]bool{}
	ordered := make([]projectEntry, 0, len(projects))
	for _, p := range projects {
		if p.Public {
			ordered = append(ordered, p)
		}
	}
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].ID < ordered[j].ID })
	for _, p := range ordered {
		for _, want := range p.Employees {
			row := publicTabRow{
				ProjectID:   p.ID,
				ProjectName: p.Name,
				EmployeeID:  want.ID,
				MachineID:   want.MachineID,
				Session:     want.ID + "-" + p.ID,
			}
			account := byName[want.ID]
			switch {
			case account == nil:
				row.Status = publicStatusNoAccount
			default:
				row.AccountID, row.AccountName = account.ID, account.Name
				if expected[account.ID] == nil {
					expected[account.ID] = map[string]bool{}
				}
				expected[account.ID][publicPairKey(want.ID, p.ID)] = true
				tab, held := actual[account.ID][publicPairKey(want.ID, p.ID)]
				switch {
				case !held:
					row.Status = publicStatusMissing
				case tab.MachineID != want.MachineID:
					row.Status = publicStatusWrongMachine
					row.ActualMachine = tab.MachineID
					row.TabID = tab.ID
				default:
					row.Status = publicStatusOK
					row.TabID = tab.ID
				}
			}
			report.Rows = append(report.Rows, row)
			report.Summary.Expected++
			switch row.Status {
			case publicStatusMissing:
				report.Summary.Missing++
			case publicStatusWrongMachine:
				report.Summary.WrongMachine++
			case publicStatusNoAccount:
				report.Summary.NoAccount++
			}
		}
	}
	report.Summary.Projects = len(ordered)

	// Anything an account holds for a public project that its own list does
	// not call for.
	for i := range accounts {
		account := &accounts[i]
		for key, tab := range actual[account.ID] {
			if expected[account.ID][key] {
				continue
			}
			employee, project, _ := strings.Cut(key, "\x00")
			report.Extras = append(report.Extras, publicTabRow{
				ProjectID:   project,
				ProjectName: projectNameOf(projects, project),
				EmployeeID:  employee,
				AccountID:   account.ID,
				AccountName: account.Name,
				MachineID:   tab.MachineID,
				Session:     employee + "-" + project,
				TabID:       tab.ID,
				Status:      publicStatusExtra,
			})
		}
	}
	sort.Slice(report.Extras, func(i, j int) bool {
		a, b := report.Extras[i], report.Extras[j]
		if a.AccountName != b.AccountName {
			return a.AccountName < b.AccountName
		}
		if a.ProjectID != b.ProjectID {
			return a.ProjectID < b.ProjectID
		}
		return a.EmployeeID < b.EmployeeID
	})
	report.Summary.Extra = len(report.Extras)
	return report
}

func projectNameOf(projects []projectEntry, id string) string {
	for _, p := range projects {
		if p.ID == id {
			return p.Name
		}
	}
	return id
}

// decodeProjects reads the stored project rows. A row that does not parse is
// skipped: this view reports, and a broken row must not blank the whole page.
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
