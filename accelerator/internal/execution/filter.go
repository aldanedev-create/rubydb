package execution

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/aldanedev-create/rubydb/accelerator/internal/parallel"
)

func FilterRows(rows []map[string]interface{}, condition Filter) []map[string]interface{} {
	if len(rows) < 4096 {
		filtered := make([]map[string]interface{}, 0, len(rows))
		for _, row := range rows {
			if Matches(row[condition.Column], condition.Operator, condition.Value) {
				filtered = append(filtered, row)
			}
		}
		return filtered
	}

	chunks := make([][]map[string]interface{}, parallel.ChunkCount(len(rows)))
	parallel.ForEachChunk(len(rows), func(index, start, end int) {
		filtered := make([]map[string]interface{}, 0, end-start)
		for _, row := range rows[start:end] {
			if Matches(row[condition.Column], condition.Operator, condition.Value) {
				filtered = append(filtered, row)
			}
		}
		chunks[index] = filtered
	})
	filtered := make([]map[string]interface{}, 0, len(rows))
	for _, chunk := range chunks {
		filtered = append(filtered, chunk...)
	}
	return filtered
}

func Matches(actual interface{}, operator string, expected interface{}) bool {
	if strings.EqualFold(operator, "is_null") {
		return actual == nil
	}
	if strings.EqualFold(operator, "is_not_null") {
		return actual != nil
	}
	if actual == nil || expected == nil {
		return false
	}
	if strings.EqualFold(operator, "like") {
		pattern := regexp.QuoteMeta(fmt.Sprint(expected))
		pattern = strings.ReplaceAll(pattern, "%", ".*")
		pattern = strings.ReplaceAll(pattern, "_", ".")
		matched, _ := regexp.MatchString("(?i)^"+pattern+"$", fmt.Sprint(actual))
		return matched
	}
	comparison := Compare(actual, expected)
	switch strings.ToLower(operator) {
	case "eq":
		return comparison == 0
	case "ne":
		return comparison != 0
	case "lt":
		return comparison < 0
	case "lte":
		return comparison <= 0
	case "gt":
		return comparison > 0
	case "gte":
		return comparison >= 0
	default:
		return false
	}
}
