package main

import (
	"encoding/json"
	"testing"
)

func TestPrepareMacSnapshot(t *testing.T) {
	source := []byte(`{"machines":[{"id":"m1","host":"example.test","user":"alice","blinkdToken":"secret","futureFlag":true}],"tabs":[{"id":"11111111-1111-1111-1111-111111111111","machineId":"m1","workDirId":"","tmuxSession":"work","useTmux":true}],"agents":{"m1|work":"codex"},"currentId":"11111111-1111-1111-1111-111111111111","filterMachineId":"m1"}`)
	p, err := prepare(source)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Machines) != 1 || p.IDs[0] != "m1" {
		t.Fatalf("machines: %+v", p.IDs)
	}
	var machine map[string]any
	if err = json.Unmarshal(p.Machines[0], &machine); err != nil {
		t.Fatal(err)
	}
	if machine["futureFlag"] != true || machine["blinkdToken"] != "secret" {
		t.Fatalf("machine lost fields: %+v", machine)
	}
	if _, ok := machine["position"]; ok {
		t.Fatal("import added order field")
	}
	var tabs map[string]any
	if err = json.Unmarshal(p.Tabs, &tabs); err != nil {
		t.Fatal(err)
	}
	entry := tabs["tabs"].([]any)[0].(map[string]any)
	if _, ok := entry["workDirId"]; ok {
		t.Fatal("empty optional workDirId was retained")
	}
	if !sameJSON(p.Selection, []byte(`{"machineId":"m1","tabId":"11111111-1111-1111-1111-111111111111"}`)) {
		t.Fatal("selection mismatch")
	}
}

func TestPrepareRejectsEmptyMachines(t *testing.T) {
	if _, err := prepare([]byte(`{"machines":[]}`)); err == nil {
		t.Fatal("empty import accepted")
	}
}
