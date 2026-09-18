package storage

import (
	"bytes"
	"context"
	"testing"
)

func TestReaderReadsSnapshotBatchInCallerOrder(t *testing.T) {
	data := bytes.Repeat([]byte("a"), 8)
	data = append(data, bytes.Repeat([]byte("b"), 8)...)
	reader := NewReader(bytes.NewReader(data))
	pages, err := reader.ReadBatch(context.Background(), Snapshot{ID: 1, PageSize: 8, MaxPages: 2}, []uint64{1, 0})
	if err != nil || len(pages) != 2 || string(pages[0].Data) != "bbbbbbbb" || string(pages[1].Data) != "aaaaaaaa" {
		t.Fatalf("unexpected pages: %#v, %v", pages, err)
	}
}
