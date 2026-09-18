package execution

import (
	"context"
	"testing"
)

func TestRowsPipelineFiltersSortsAndLimits(t *testing.T) {
	limit := 2
	result, err := ExecuteRowsPipeline(RowsRequest{
		Rows: []map[string]interface{}{
			{"id": 1, "score": 10},
			{"id": 2, "score": 30},
			{"id": 3, "score": 20},
		},
		Filters: []Filter{{Column: "score", Operator: "gte", Value: 10}},
		OrderBy: []Order{{Column: "score", Direction: "DESC"}},
		Limit:   &limit,
	})
	if err != nil || len(result.Rows) != 2 || result.Rows[0]["id"] != 2 || result.Rows[1]["id"] != 3 {
		t.Fatalf("unexpected pipeline result: %#v, %v", result, err)
	}
}

func TestMergeJoinMatchesDuplicateKeys(t *testing.T) {
	left := []map[string]interface{}{{"id": 2, "l": "a"}, {"id": 1, "l": "b"}}
	right := []map[string]interface{}{{"id": 1, "r": "x"}, {"id": 2, "r": "y"}}
	joined := MergeJoinRows(left, right, "id", "id")
	if len(joined) != 2 || joined[0]["r"] != "x" || joined[1]["r"] != "y" {
		t.Fatalf("unexpected merge join: %#v", joined)
	}
}

func TestDistinctRowsPreservesFirstOccurrence(t *testing.T) {
	rows := []map[string]interface{}{{"id": 1, "name": "a"}, {"id": 1, "name": "b"}, {"id": 2, "name": "c"}}
	result := DistinctRows(rows, []string{"id"})
	if len(result) != 2 || result[0]["name"] != "a" {
		t.Fatalf("unexpected distinct result: %#v", result)
	}
}

func TestPipelineSupportsProjectionDistinctHavingAndWindows(t *testing.T) {
	result, err := ExecuteRowsPipeline(RowsRequest{
		Rows: []map[string]interface{}{
			{"id": 2, "group": "a", "value": 4},
			{"id": 1, "group": "a", "value": 6},
			{"id": 1, "group": "a", "value": 6},
		},
		GroupBy:    []string{"group"},
		Aggregate:  []Aggregate{{Function: "COUNT", Column: "*", Alias: "count"}},
		Having:     []Filter{{Column: "count", Operator: "gte", Value: 1}},
		Projection: []string{"group", "count"},
		Windows:    []Window{{Function: "ROW_NUMBER", Alias: "position", PartitionBy: []string{"group"}, OrderBy: []Order{{Column: "count"}}}},
	})
	if err != nil || len(result.Rows) != 1 || result.Rows[0]["count"] != 3 || result.Rows[0]["position"] != int64(1) {
		t.Fatalf("unexpected extended pipeline result: %#v, %v", result, err)
	}
}

func TestPipelineHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := ExecuteRowsPipelineContext(ctx, RowsRequest{Rows: []map[string]interface{}{{"id": 1}}, Filters: []Filter{{Column: "id", Operator: "gte", Value: 0}}})
	if err != context.Canceled {
		t.Fatalf("error = %v, want context cancellation", err)
	}
}
