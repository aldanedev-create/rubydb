package execution

import "encoding/json"

func DistinctRows(rows []map[string]interface{}, columns []string) []map[string]interface{} {
	seen := make(map[string]struct{}, len(rows))
	result := make([]map[string]interface{}, 0, len(rows))
	for _, row := range rows {
		values := make([]interface{}, len(columns))
		for index, column := range columns {
			values[index] = row[column]
		}
		keyBytes, _ := json.Marshal(values)
		key := string(keyBytes)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, row)
	}
	return result
}
