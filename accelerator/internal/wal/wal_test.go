package wal

import "testing"

func TestRecordChecksum(t *testing.T) {
	record := EncodeRecord(3, 42, 7, []byte("commit"))
	if !VerifyRecord(record) {
		t.Fatal("valid WAL record did not verify")
	}
	record[len(record)-1] ^= 1
	if VerifyRecord(record) {
		t.Fatal("corrupted WAL record verified")
	}
}

func TestCompressionRoundTrip(t *testing.T) {
	want := []byte("rubydb wal archive")
	compressed, err := Gzip(want, 1)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Gunzip(compressed, 1024)
	if err != nil || string(got) != string(want) {
		t.Fatalf("compression mismatch: %q, %v", got, err)
	}
}
