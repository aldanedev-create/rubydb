package execution

import "context"

// FilterRowsContext is the cancellation-aware form used by server workers.
// The non-context API remains intentionally small for the stdio protocol.
func FilterRowsContext(ctx context.Context, rows []map[string]interface{}, condition Filter) ([]map[string]interface{}, error) {
	filtered := make([]map[string]interface{}, 0, len(rows))
	for _, row := range rows {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
		if Matches(row[condition.Column], condition.Operator, condition.Value) {
			filtered = append(filtered, row)
		}
	}
	return filtered, nil
}
