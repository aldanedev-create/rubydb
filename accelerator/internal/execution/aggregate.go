package execution

import (
	"encoding/json"
	"strings"
)

func AggregateRows(rows []map[string]interface{}, groupBy []string, definitions []Aggregate) []map[string]interface{} {
	groups := map[string][]map[string]interface{}{}
	keys := map[string][]interface{}{}
	order := make([]string, 0)
	if len(groupBy) == 0 {
		groups["_"] = rows
		order = append(order, "_")
	} else {
		for _, row := range rows {
			values := make([]interface{}, len(groupBy))
			for i, column := range groupBy {
				values[i] = row[column]
			}
			keyBytes, _ := json.Marshal(values)
			key := string(keyBytes)
			if _, exists := groups[key]; !exists {
				order = append(order, key)
			}
			groups[key] = append(groups[key], row)
			keys[key] = values
		}
	}
	result := make([]map[string]interface{}, 0, len(groups))
	for _, key := range order {
		group := groups[key]
		row := map[string]interface{}{}
		for i, column := range groupBy {
			row[column] = keys[key][i]
		}
		for _, definition := range definitions {
			name := definition.Alias
			if name == "" {
				name = strings.ToLower(definition.Function) + "(" + definition.Column + ")"
			}
			row[name] = AggregateValue(group, definition)
		}
		result = append(result, row)
	}
	return result
}

func AggregateValue(rows []map[string]interface{}, definition Aggregate) interface{} {
	values := make([]interface{}, 0, len(rows))
	for _, row := range rows {
		value := row[definition.Column]
		if value != nil {
			values = append(values, value)
		}
	}
	switch strings.ToUpper(definition.Function) {
	case "COUNT":
		if definition.Column == "*" {
			return len(rows)
		}
		return len(values)
	case "SUM", "AVG":
		var sum float64
		for _, value := range values {
			number, ok := NumberValue(value)
			if !ok {
				return nil
			}
			sum += number
		}
		if strings.EqualFold(definition.Function, "AVG") {
			if len(values) == 0 {
				return nil
			}
			return sum / float64(len(values))
		}
		return sum
	case "MIN", "MAX":
		if len(values) == 0 {
			return nil
		}
		best := values[0]
		for _, value := range values[1:] {
			comparison := Compare(value, best)
			if (strings.EqualFold(definition.Function, "MIN") && comparison < 0) || (strings.EqualFold(definition.Function, "MAX") && comparison > 0) {
				best = value
			}
		}
		return best
	default:
		return nil
	}
}
