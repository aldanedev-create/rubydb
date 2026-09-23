package storage

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/aldanedev-create/rubydb/accelerator/internal/execution"
)

func streamFixture(t *testing.T) SnapshotScanRequest {
	t.Helper()
	const pageSize = 4096
	data := make([]byte, pageSize*3)
	for page := 0; page < 3; page++ {
		p := data[page*pageSize : (page+1)*pageSize]
		binary.BigEndian.PutUint64(p[0:8], uint64(page))
		binary.BigEndian.PutUint64(p[8:16], pageSize)
		binary.BigEndian.PutUint32(p[16:20], pageHeaderSize)
		binary.BigEndian.PutUint32(p[20:24], pageHeaderSize)
	}
	binary.BigEndian.PutUint32(data[32:36], 1)
	for page := 1; page <= 2; page++ {
		p := data[page*pageSize : (page+1)*pageSize]
		record := []byte{0, 0, 0, 0, 0, 0, 0, 0, 1, 'x'}
		binary.BigEndian.PutUint32(record[1:5], uint32(page))
		binary.BigEndian.PutUint64(p[64:72], uint64(page))
		binary.BigEndian.PutUint32(p[72:76], uint32(len(record)))
		binary.BigEndian.PutUint16(p[76:78], nullBitmapFlag|variablePrefixFlag)
		binary.LittleEndian.PutUint16(p[78:80], 2)
		copy(p[80:], record)
		binary.BigEndian.PutUint32(p[20:24], uint32(80+len(record)))
	}
	path := filepath.Join(t.TempDir(), "fixture.rdb")
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(data)
	return SnapshotScanRequest{
		Snapshot: SnapshotManifest{
			FormatVersion: 1, SnapshotID: "fixture", SnapshotPath: path,
			PageSize: pageSize, PageCount: 3, FileSHA256: hex.EncodeToString(digest[:]),
			Tables: map[string]SnapshotTable{"items": {
				Pages: []uint64{1, 2}, Columns: []SnapshotColumn{{Name: "id", Type: "integer"}, {Name: "name", Type: "text"}},
			}},
		},
		Table: "items", Filters: []execution.Filter{{Column: "id", Operator: "gte", Value: 1}},
	}
}

func TestStreamSnapshotScanMatchesMaterializedScan(t *testing.T) {
	req := streamFixture(t)
	materialized, err := ExecuteSnapshotScanContext(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	var streamed []map[string]interface{}
	err = StreamSnapshotScan(context.Background(), req, func(rows []map[string]interface{}) error {
		streamed = append(streamed, rows...)
		return nil
	})
	if err != nil || !reflect.DeepEqual(streamed, materialized.Rows) {
		t.Fatalf("streamed %v, materialized %v, error %v", streamed, materialized.Rows, err)
	}
}

func TestStreamSnapshotScanRejectsCancellationAndCorruption(t *testing.T) {
	req := streamFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := StreamSnapshotScan(ctx, req, func([]map[string]interface{}) error { t.Fatal("emitted after cancel"); return nil }); err == nil {
		t.Fatal("expected cancellation")
	}
	req.Snapshot.Tables["items"] = SnapshotTable{Pages: []uint64{9}, Columns: req.Snapshot.Tables["items"].Columns}
	if err := StreamSnapshotScan(context.Background(), req, func([]map[string]interface{}) error { return nil }); err == nil {
		t.Fatal("expected out-of-range page rejection")
	}
	req = streamFixture(t)
	req.Snapshot.FileSHA256 = "0000000000000000000000000000000000000000000000000000000000000000"
	if err := StreamSnapshotScan(context.Background(), req, func([]map[string]interface{}) error { return nil }); err == nil {
		t.Fatal("expected checksum rejection")
	}
}

func TestStreamSnapshotScanFiltersBooleanColumnsNotInOutput(t *testing.T) {
	const pageSize = 4096
	data := make([]byte, pageSize*2)
	for page := 0; page < 2; page++ {
		p := data[page*pageSize : (page+1)*pageSize]
		binary.BigEndian.PutUint64(p[0:8], uint64(page))
		binary.BigEndian.PutUint64(p[8:16], pageSize)
		binary.BigEndian.PutUint32(p[16:20], pageHeaderSize)
		binary.BigEndian.PutUint32(p[20:24], pageHeaderSize)
	}
	binary.BigEndian.PutUint32(data[32:36], 1)
	p := data[pageSize:]
	// Null bitmap + INTEGER(1) + BOOLEAN(true).
	record := []byte{0, 0, 0, 0, 1, 1}
	binary.BigEndian.PutUint64(p[64:72], 1)
	binary.BigEndian.PutUint32(p[72:76], uint32(len(record)))
	binary.BigEndian.PutUint16(p[76:78], nullBitmapFlag|variablePrefixFlag)
	binary.LittleEndian.PutUint16(p[78:80], 2)
	copy(p[80:], record)
	binary.BigEndian.PutUint32(p[20:24], uint32(80+len(record)))
	path := filepath.Join(t.TempDir(), "boolean.rdb")
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(data)
	req := SnapshotScanRequest{
		Snapshot: SnapshotManifest{FormatVersion: 1, SnapshotID: "boolean", SnapshotPath: path, PageSize: pageSize, PageCount: 2,
			FileSHA256: hex.EncodeToString(digest[:]), Tables: map[string]SnapshotTable{"items": {
				Pages: []uint64{1}, Columns: []SnapshotColumn{{Name: "id", Type: "integer"}, {Name: "active", Type: "boolean"}},
			}}},
		Table: "items", Columns: []string{"id", "active"}, Filters: []execution.Filter{{Column: "active", Operator: "eq", Value: true}},
	}
	var rows []map[string]interface{}
	if err := StreamSnapshotScan(context.Background(), req, func(batch []map[string]interface{}) error {
		rows = append(rows, batch...)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(rows, []map[string]interface{}{{"id": int64(1), "active": true, "_row_id": uint64(1)}}) {
		t.Fatalf("unexpected filtered rows: %#v", rows)
	}
}
