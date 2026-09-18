package protocol

import (
	"bufio"
	"bytes"
	"errors"
	"testing"
)

func TestColumnarRowsRoundTrip(t *testing.T) {
	want := []map[string]interface{}{{"id": int64(1), "name": "Ruby", "active": true, "missing": nil}}
	encoded, err := EncodeRows(want)
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeRows(encoded)
	if err != nil || got[0]["id"] != int64(1) || got[0]["active"] != true || got[0]["missing"] != nil {
		t.Fatalf("round trip mismatch: %#v, %v", got, err)
	}
}

func TestFrameLimitIsEnforced(t *testing.T) {
	_, err := ReadFrame(bufio.NewReader(bytes.NewReader(append(make([]byte, MaxFrameSize+1), '\n'))))
	if !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("error = %v", err)
	}
}
