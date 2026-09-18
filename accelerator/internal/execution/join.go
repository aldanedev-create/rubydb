package execution

import (
	"encoding/json"
	"sort"
)

func HashJoinRows(leftRows, rightRows []map[string]interface{}, leftKey, rightKey string) []map[string]interface{} {
	index := make(map[string][]map[string]interface{}, len(rightRows))
	for _, row := range rightRows {
		key := JoinKey(row[rightKey])
		index[key] = append(index[key], row)
	}
	rows := make([]map[string]interface{}, 0)
	for _, left := range leftRows {
		for _, right := range index[JoinKey(left[leftKey])] {
			merged := make(map[string]interface{}, len(left)+len(right))
			for key, value := range right {
				merged[key] = value
			}
			for key, value := range left {
				merged[key] = value
			}
			rows = append(rows, merged)
		}
	}
	return rows
}

// MergeJoinRows is used when both inputs are already ordered by their join
// keys. It avoids allocating a hash table for large, sorted relations.
func MergeJoinRows(leftRows, rightRows []map[string]interface{}, leftKey, rightKey string) []map[string]interface{} {
	left := append([]map[string]interface{}(nil), leftRows...)
	right := append([]map[string]interface{}(nil), rightRows...)
	sort.SliceStable(left, func(i, j int) bool { return Compare(left[i][leftKey], left[j][leftKey]) < 0 })
	sort.SliceStable(right, func(i, j int) bool { return Compare(right[i][rightKey], right[j][rightKey]) < 0 })
	result := make([]map[string]interface{}, 0)
	for i, j := 0, 0; i < len(left) && j < len(right); {
		comparison := Compare(left[i][leftKey], right[j][rightKey])
		if comparison < 0 {
			i++
			continue
		}
		if comparison > 0 {
			j++
			continue
		}
		leftEnd, rightEnd := i, j
		for leftEnd < len(left) && Compare(left[leftEnd][leftKey], left[i][leftKey]) == 0 {
			leftEnd++
		}
		for rightEnd < len(right) && Compare(right[rightEnd][rightKey], right[j][rightKey]) == 0 {
			rightEnd++
		}
		for leftIndex := i; leftIndex < leftEnd; leftIndex++ {
			for rightIndex := j; rightIndex < rightEnd; rightIndex++ {
				result = append(result, mergeRows(left[leftIndex], right[rightIndex]))
			}
		}
		i, j = leftEnd, rightEnd
	}
	return result
}

func mergeRows(left, right map[string]interface{}) map[string]interface{} {
	merged := make(map[string]interface{}, len(left)+len(right))
	for key, value := range right {
		merged[key] = value
	}
	for key, value := range left {
		merged[key] = value
	}
	return merged
}

func JoinKey(value interface{}) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}
