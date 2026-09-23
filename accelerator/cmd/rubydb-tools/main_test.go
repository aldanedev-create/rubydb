package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/aldanedev-create/rubydb/accelerator/internal/storage"
)

func exportFixture(t *testing.T) string {
	t.Helper()
	const pageSize = 4096
	data := make([]byte, pageSize*2)
	for page := 0; page < 2; page++ {
		p := data[page*pageSize : (page+1)*pageSize]
		binary.BigEndian.PutUint64(p[0:8], uint64(page))
		binary.BigEndian.PutUint64(p[8:16], pageSize)
		binary.BigEndian.PutUint32(p[16:20], 64)
		binary.BigEndian.PutUint32(p[20:24], 64)
	}
	binary.BigEndian.PutUint32(data[32:36], 1)
	p := data[pageSize : pageSize*2]
	// Null bitmap + big-endian INTEGER(7) + text length + "ruby".
	record := []byte{0, 0, 0, 0, 7, 0, 0, 0, 4, 'r', 'u', 'b', 'y'}
	binary.BigEndian.PutUint64(p[64:72], 1)
	binary.BigEndian.PutUint32(p[72:76], uint32(len(record)))
	binary.BigEndian.PutUint16(p[76:78], 0x02|0x04)
	binary.LittleEndian.PutUint16(p[78:80], 2)
	copy(p[80:], record)
	binary.BigEndian.PutUint32(p[20:24], uint32(80+len(record)))

	directory := t.TempDir()
	snapshotPath := filepath.Join(directory, "fixture.rdb")
	if err := os.WriteFile(snapshotPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(data)
	manifest := storage.SnapshotManifest{
		FormatVersion: 1, SnapshotID: "fixture", SnapshotPath: snapshotPath,
		PageSize: pageSize, PageCount: 2, FileSHA256: hex.EncodeToString(digest[:]),
		Tables: map[string]storage.SnapshotTable{"items": {
			Pages: []uint64{1}, Columns: []storage.SnapshotColumn{{Name: "id", Type: "integer"}, {Name: "name", Type: "text"}},
		}},
	}
	contents, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(directory, "manifest.json")
	if err := os.WriteFile(manifestPath, contents, 0600); err != nil {
		t.Fatal(err)
	}
	return manifestPath
}

func TestRunExportsFilteredProjectionAtomically(t *testing.T) {
	manifest := exportFixture(t)
	out := filepath.Join(filepath.Dir(manifest), "items.jsonl")
	var stderr bytes.Buffer
	code := run([]string{"export", "--manifest", manifest, "--table", "items", "--columns", "name", "--where", "id eq 7", "--out", out, "--json-stats"}, &stderr)
	if code != 0 {
		t.Fatalf("export failed (%d): %s", code, stderr.String())
	}
	contents, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if actual, expected := string(contents), "{\"name\":\"ruby\"}\n"; actual != expected {
		t.Fatalf("output = %q, want %q", actual, expected)
	}
	if _, err := os.Stat(out + ".partial"); !os.IsNotExist(err) {
		t.Fatalf("partial output leaked: %v", err)
	}
	if code := run([]string{"export", "--manifest", manifest, "--table", "items", "--out", out}, &stderr); code != 1 {
		t.Fatalf("existing output exit = %d, want 1", code)
	}
}

func TestRunRejectsInvalidUsage(t *testing.T) {
	var stderr bytes.Buffer
	if code := run([]string{"export", "--format", "xml"}, &stderr); code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
}
