package execution

import "sort"

func SortRows(rows []map[string]interface{}, orderBy []Order) {
	sort.SliceStable(rows, func(i, j int) bool {
		for _, item := range orderBy {
			comparison := Compare(rows[i][item.Column], rows[j][item.Column])
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
}

func ApplyWindow(rows []map[string]interface{}, offset int, limit *int) ([]map[string]interface{}, error) {
	if offset < 0 {
		return nil, ErrInvalidWindow("offset cannot be negative")
	}
	if limit != nil && *limit < 0 {
		return nil, ErrInvalidWindow("limit cannot be negative")
	}
	if offset >= len(rows) {
		return []map[string]interface{}{}, nil
	}
	if offset > 0 {
		rows = rows[offset:]
	}
	if limit != nil && *limit < len(rows) {
		rows = rows[:*limit]
	}
	return rows, nil
}

type invalidWindowError string

func (err invalidWindowError) Error() string { return string(err) }
func ErrInvalidWindow(message string) error  { return invalidWindowError(message) }

func equalFold(left, right string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		l, r := left[index], right[index]
		if l >= 'A' && l <= 'Z' {
			l += 'a' - 'A'
		}
		if r >= 'A' && r <= 'Z' {
			r += 'a' - 'A'
		}
		if l != r {
			return false
		}
	}
	return true
}
