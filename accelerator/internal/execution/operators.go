package execution

import (
	"context"
	"fmt"
	"sort"
)

func ProjectRows(rows []map[string]interface{}, columns []string) []map[string]interface{} {
	result := make([]map[string]interface{}, 0, len(rows))
	for _, row := range rows {
		projected := make(map[string]interface{}, len(columns))
		for _, column := range columns {
			projected[column] = row[column]
		}
		result = append(result, projected)
	}
	return result
}

func SortRowsContext(ctx context.Context, rows []map[string]interface{}, orderBy []Order) error {
	cancelled := false
	sort.SliceStable(rows, func(left, right int) bool {
		select {
		case <-ctx.Done():
			cancelled = true
			return false
		default:
		}
		for _, item := range orderBy {
			comparison := Compare(rows[left][item.Column], rows[right][item.Column])
			if comparison == 0 {
				continue
			}
			if equalFold(item.Direction, "desc") {
				return comparison > 0
			}
			return comparison < 0
		}
		return false
	})
	if cancelled {
		return ctx.Err()
	}
	return nil
}

func ApplyWindowsContext(ctx context.Context, rows []map[string]interface{}, windows []Window) ([]map[string]interface{}, error) {
	for _, definition := range windows {
		if err := applyWindowContext(ctx, rows, definition); err != nil {
			return nil, err
		}
	}
	return rows, nil
}

func applyWindowContext(ctx context.Context, rows []map[string]interface{}, definition Window) error {
	partitions := map[string][]map[string]interface{}{}
	for _, row := range rows {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		values := make([]interface{}, len(definition.PartitionBy))
		for index, column := range definition.PartitionBy {
			values[index] = row[column]
		}
		key := JoinKey(values)
		partitions[key] = append(partitions[key], row)
	}
	for _, partition := range partitions {
		if err := SortRowsContext(ctx, partition, definition.OrderBy); err != nil {
			return err
		}
		for index, row := range partition {
			select {
			case <-ctx.Done():
				return ctx.Err()
			default:
			}
			value, err := windowValue(definition, partition, index)
			if err != nil {
				return err
			}
			alias := definition.Alias
			if alias == "" {
				alias = definition.Function
			}
			row[alias] = value
		}
	}
	return nil
}

func windowValue(definition Window, partition []map[string]interface{}, index int) (interface{}, error) {
	switch normalizeFunction(definition.Function) {
	case "ROW_NUMBER":
		return int64(index + 1), nil
	case "RANK":
		if index == 0 || len(definition.OrderBy) == 0 {
			return int64(index + 1), nil
		}
		rank := 1
		for previous := 1; previous <= index; previous++ {
			if compareOrderRow(partition[previous-1], partition[previous], definition.OrderBy) != 0 {
				rank = previous + 1
			}
		}
		return int64(rank), nil
	case "DENSE_RANK":
		rank := 1
		for previous := 1; previous <= index; previous++ {
			if compareOrderRow(partition[previous-1], partition[previous], definition.OrderBy) != 0 {
				rank++
			}
		}
		return int64(rank), nil
	case "LAG", "LEAD":
		delta := -1
		if normalizeFunction(definition.Function) == "LEAD" {
			delta = 1
		}
		position := index + delta
		if position < 0 || position >= len(partition) {
			return nil, nil
		}
		return partition[position][definition.Column], nil
	case "COUNT":
		count := int64(0)
		for _, row := range partition {
			if definition.Column == "*" || row[definition.Column] != nil {
				count++
			}
		}
		return count, nil
	case "SUM", "AVG", "MIN", "MAX":
		return AggregateValue(partition, Aggregate{Function: definition.Function, Column: definition.Column}), nil
	default:
		return nil, fmt.Errorf("unsupported window function %q", definition.Function)
	}
}

func compareOrderRow(left, right map[string]interface{}, orderBy []Order) int {
	for _, order := range orderBy {
		comparison := Compare(left[order.Column], right[order.Column])
		if comparison == 0 {
			continue
		}
		if equalFold(order.Direction, "desc") {
			return -comparison
		}
		return comparison
	}
	return 0
}

func normalizeFunction(value string) string {
	result := make([]byte, 0, len(value))
	for _, character := range value {
		if character >= 'a' && character <= 'z' {
			character -= 'a' - 'A'
		}
		result = append(result, byte(character))
	}
	return string(result)
}
