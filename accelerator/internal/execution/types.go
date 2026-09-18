package execution

import (
	"context"
	"encoding/json"
)

type RowsRequest struct {
	Rows            []map[string]interface{} `json:"rows"`
	Filters         []Filter                 `json:"filters,omitempty"`
	OrderBy         []Order                  `json:"order_by,omitempty"`
	GroupBy         []string                 `json:"group_by,omitempty"`
	Aggregate       []Aggregate              `json:"aggregates,omitempty"`
	Having          []Filter                 `json:"having,omitempty"`
	Projection      []string                 `json:"projection,omitempty"`
	Distinct        bool                     `json:"distinct,omitempty"`
	DistinctColumns []string                 `json:"distinct_columns,omitempty"`
	Windows         []Window                 `json:"windows,omitempty"`
	BatchSize       int                      `json:"batch_size,omitempty"`
	Limit           *int                     `json:"limit,omitempty"`
	Offset          int                      `json:"offset,omitempty"`
}

type Filter struct {
	Column   string      `json:"column"`
	Operator string      `json:"operator"`
	Value    interface{} `json:"value,omitempty"`
}

type Order struct {
	Column    string `json:"column"`
	Direction string `json:"direction,omitempty"`
}

type Aggregate struct {
	Function string `json:"function"`
	Column   string `json:"column,omitempty"`
	Alias    string `json:"alias,omitempty"`
}

// Window describes the portable window subset used by the accelerator. Ruby
// remains the authority for parsing and deciding whether this representation
// is semantically safe to delegate.
type Window struct {
	Function    string   `json:"function"`
	Column      string   `json:"column,omitempty"`
	Alias       string   `json:"alias,omitempty"`
	PartitionBy []string `json:"partition_by,omitempty"`
	OrderBy     []Order  `json:"order_by,omitempty"`
}

type RowsResult struct {
	Rows       []map[string]interface{}
	Aggregates []map[string]interface{}
}

func (result RowsResult) AsMap() map[string]interface{} {
	payload := map[string]interface{}{
		"rows":      result.Rows,
		"row_count": len(result.Rows),
	}
	if len(result.Aggregates) > 0 {
		payload["aggregates"] = result.Aggregates
	}
	return payload
}

func ExecuteRowsPipeline(payload RowsRequest) (RowsResult, error) {
	return ExecuteRowsPipelineContext(context.Background(), payload)
}

func ExecuteRowsPipelineContext(ctx context.Context, payload RowsRequest) (RowsResult, error) {
	rows := payload.Rows
	for _, condition := range payload.Filters {
		filtered, err := FilterRowsContext(ctx, rows, condition)
		if err != nil {
			return RowsResult{}, err
		}
		rows = filtered
	}
	if len(payload.OrderBy) > 0 {
		if err := SortRowsContext(ctx, rows, payload.OrderBy); err != nil {
			return RowsResult{}, err
		}
	}
	result := RowsResult{}
	var aggregateRows []map[string]interface{}
	if len(payload.Aggregate) > 0 {
		aggregateRows = AggregateRows(rows, payload.GroupBy, payload.Aggregate)
		for _, condition := range payload.Having {
			filtered, err := FilterRowsContext(ctx, aggregateRows, condition)
			if err != nil {
				return RowsResult{}, err
			}
			aggregateRows = filtered
		}
		if len(payload.Projection) > 0 {
			rows = aggregateRows
		}
	}
	if payload.Distinct {
		columns := payload.DistinctColumns
		if len(columns) == 0 {
			columns = payload.Projection
		}
		if len(columns) == 0 && len(rows) > 0 {
			for column := range rows[0] {
				columns = append(columns, column)
			}
		}
		rows = DistinctRows(rows, columns)
	}
	if len(payload.Projection) > 0 {
		rows = ProjectRows(rows, payload.Projection)
	}
	if len(payload.Windows) > 0 {
		var err error
		rows, err = ApplyWindowsContext(ctx, rows, payload.Windows)
		if err != nil {
			return RowsResult{}, err
		}
	}
	rows, err := ApplyWindow(rows, payload.Offset, payload.Limit)
	if err != nil {
		return RowsResult{}, err
	}
	result.Rows = rows
	if len(payload.Aggregate) > 0 {
		result.Aggregates = aggregateRows
	}
	return result, nil
}

func MarshalRowsResult(result RowsResult) ([]byte, error) {
	return json.Marshal(result.AsMap())
}
