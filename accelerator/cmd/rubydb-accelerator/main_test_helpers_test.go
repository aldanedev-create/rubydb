package main

import (
	"bufio"

	"github.com/aldanedev-create/rubydb/accelerator/internal/execution"
	"github.com/aldanedev-create/rubydb/accelerator/internal/protocol"
)

const maxFrameSize = protocol.MaxFrameSize

var errFrameTooLarge = protocol.ErrFrameTooLarge

type filter = execution.Filter
type aggregate = execution.Aggregate

func matches(actual interface{}, operator string, expected interface{}) bool {
	return execution.Matches(actual, operator, expected)
}

func compare(left, right interface{}) int { return execution.Compare(left, right) }

func aggregateRows(rows []map[string]interface{}, groupBy []string, definitions []aggregate) []map[string]interface{} {
	return execution.AggregateRows(rows, groupBy, definitions)
}

func hashJoinRows(left, right []map[string]interface{}, leftKey, rightKey string) []map[string]interface{} {
	return execution.HashJoinRows(left, right, leftKey, rightKey)
}

func encodeColumnarRows(rows []map[string]interface{}) ([]byte, error) {
	return protocol.EncodeRows(rows)
}
func decodeColumnarRows(data []byte) ([]map[string]interface{}, error) {
	return protocol.DecodeRows(data)
}

func readFrame(reader *bufio.Reader) ([]byte, error) { return protocol.ReadFrame(reader) }
