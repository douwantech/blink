package main

import (
	"encoding/json"
	"testing"
)

func TestPrepareImportsPinnedBookmarks(t *testing.T) {
	source := []byte(`{"machines":[{"id":"m1","host":"example.test","user":"alice"}],"tabs":[],"agents":{},"pinned":[
		{"title":"一号后台","url":"https://one.test/admin","authUser":"ops","authPassword":"s3cret"},
		{"title":"","url":"https://two.test/"},
		{"title":"同域第二个","url":"https://two.test/other"},
		{"title":"三号后台","url":"https://three.test/","position":4}]}`)
	p, err := prepare(source)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Pinned) != 4 {
		t.Fatalf("pinned count %d, want 4", len(p.Pinned))
	}
	want := []string{"one.test", "two.test", "two.test-2", "three.test"}
	for i, id := range want {
		if p.PinnedIDs[i] != id {
			t.Fatalf("bookmark %d id %q, want %q", i, p.PinnedIDs[i], id)
		}
	}
	if p.FilledTitles != 1 {
		t.Fatalf("filled titles %d, want 1 (the entry with no title)", p.FilledTitles)
	}
	var first map[string]any
	if err := json.Unmarshal(p.Pinned[0], &first); err != nil {
		t.Fatal(err)
	}
	if first["authUser"] != "ops" || first["authPassword"] != "s3cret" {
		t.Fatalf("credentials dropped: %+v", first)
	}
	var second map[string]any
	if err := json.Unmarshal(p.Pinned[1], &second); err != nil {
		t.Fatal(err)
	}
	if second["title"] != "two.test" {
		t.Fatalf("missing title was not filled from the host: %+v", second)
	}
	if _, ok := second["authUser"]; ok {
		t.Fatalf("invented credentials: %+v", second)
	}
	var fourth map[string]any
	if err := json.Unmarshal(p.Pinned[3], &fourth); err != nil {
		t.Fatal(err)
	}
	if _, ok := fourth["position"]; ok {
		t.Fatal("import added the internal order field")
	}
}

func TestPrepareStillWorksWithoutPinned(t *testing.T) {
	p, err := prepare([]byte(`{"machines":[{"id":"m1","host":"example.test","user":"alice"}],"tabs":[],"agents":{}}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Pinned) != 0 {
		t.Fatalf("pinned %d, want 0 for a snapshot without the key", len(p.Pinned))
	}
}

func TestPrepareRejectsBadPinnedEntries(t *testing.T) {
	head := `{"machines":[{"id":"m1","host":"example.test","user":"alice"}],"tabs":[],"agents":{},"pinned":`
	for name, tail := range map[string]string{
		"no url":               `[{"title":"后台"}]`,
		"relative url":         `[{"title":"后台","url":"/admin"}]`,
		"non-http scheme":      `[{"title":"后台","url":"ftp://one.test/"}]`,
		"username no password": `[{"title":"后台","url":"https://one.test/","authUser":"ops"}]`,
	} {
		if _, err := prepare([]byte(head + tail + `}`)); err == nil {
			t.Fatalf("%s: accepted invalid bookmark list", name)
		}
	}
}
