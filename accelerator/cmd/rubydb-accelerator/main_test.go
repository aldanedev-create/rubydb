package main

import (
	"bufio"
	"bytes"
	"errors"
	"testing"
)

func TestMatches(t *testing.T) {
	row := map[string]interface{}{"name": "RubyDB", "count": 4}
	checks := []struct {
		operator string
		value    interface{}
		want     bool
	}{
		{"eq", "RubyDB", true},
		{"gte", 3, true},
		{"lt", 4, false},
		{"like", "Ruby%", true},
		{"is_null", nil, false},
	}
	for _, check := range checks {
		if got := matches(row["name"], check.operator, check.value); got != check.want {
			t.Fatalf("matches(%q, %v) = %v, want %v", check.operator, check.value, got, check.want)
		}
	}
	if !matches(nil, "is_null", nil) {
		t.Fatal("NULL should match is_null")
	}
}

func TestAggregateRows(t *testing.T) {
	rows := []map[string]interface{}{
		{"team": "a", "score": 2},
		{"team": "a", "score": 4},
		{"team": "b", "score": 8},
	}
	result := aggregateRows(rows, []string{"team"}, []aggregate{
		{Function: "COUNT", Column: "*", Alias: "count"},
		{Function: "SUM", Column: "score", Alias: "total"},
	})
	if len(result) != 2 {
		t.Fatalf("got %d groups, want 2", len(result))
	}
	for _, group := range result {
		if group["team"] == "a" && (group["count"] != 2 || group["total"] != float64(6)) {
			t.Fatalf("unexpected group: %#v", group)
		}
	}
}

func TestCompareNumbers(t *testing.T) {
	if compare(2, 10) >= 0 || compare(10, 2) <= 0 || compare(2, 2.0) != 0 {
		t.Fatal("numeric comparisons are not ordered numerically")
	}
}

func TestReadFrameIsBounded(t *testing.T) {
	frame, err := readFrame(bufio.NewReader(bytes.NewBufferString("{\"id\":\"x\"}\n")))
	if err != nil || len(frame) == 0 {
		t.Fatalf("readFrame returned (%q, %v)", frame, err)
	}

	_, err = readFrame(bufio.NewReader(bytes.NewReader(append(make([]byte, maxFrameSize+1), '\n'))))
	if !errors.Is(err, errFrameTooLarge) {
		t.Fatalf("oversized frame error = %v", err)
	}
}

func TestColumnarBatchRoundTrip(t *testing.T) {
	want := []map[string]interface{}{
		{"id": int64(1), "name": "Ruby", "active": true, "deleted_at": nil},
		{"id": int64(2), "name": "Rails", "active": false, "deleted_at": "2026-01-01"},
	}
	encoded, err := encodeColumnarRows(want)
	if err != nil {
		t.Fatalf("encodeColumnarRows failed: %v", err)
	}
	got, err := decodeColumnarRows(encoded)
	if err != nil {
		t.Fatalf("decodeColumnarRows failed: %v", err)
	}
	if len(got) != len(want) || got[0]["id"] != int64(1) || got[1]["active"] != false || got[0]["deleted_at"] != nil {
		t.Fatalf("columnar round trip mismatch: %#v", got)
	}
}

func TestBinaryHashJoinPreservesLeftAndRightOrder(t *testing.T) {
	left := []map[string]interface{}{{"left.id": int64(1)}, {"left.id": int64(2)}}
	right := []map[string]interface{}{{"right.left_id": int64(2), "right.value": "b"}, {"right.left_id": int64(1), "right.value": "a"}}
	joined := hashJoinRows(left, right, "left.id", "right.left_id")
	if len(joined) != 2 || joined[0]["right.value"] != "a" || joined[1]["right.value"] != "b" {
		t.Fatalf("unexpected hash join result: %#v", joined)
	}
}
