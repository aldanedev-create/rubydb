package storage

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"strings"
	"time"

	"github.com/aldanedev-create/rubydb/accelerator/internal/execution"
)

const (
	snapshotFormatVersion = 1
	pageHeaderSize        = 64
	recordHeaderSize      = 16
	nullBitmapFlag        = 0x02
	variablePrefixFlag    = 0x04
	deletedRecordFlag     = 0x01
)

var (
	ErrInvalidSnapshot = errors.New("invalid immutable storage snapshot")
	ErrSnapshotSchema  = errors.New("immutable snapshot schema is invalid")
)

type SnapshotManifest struct {
	FormatVersion int                      `json:"format_version"`
	SnapshotID    string                   `json:"snapshot_id"`
	SnapshotPath  string                   `json:"snapshot_path"`
	PageSize      int                      `json:"page_size"`
	PageCount     uint64                   `json:"page_count"`
	FileSHA256    string                   `json:"file_sha256"`
	Tables        map[string]SnapshotTable `json:"tables"`
	HiddenRowIDs  []uint64                 `json:"hidden_row_ids"`
}

type SnapshotTable struct {
	Pages    []uint64         `json:"pages"`
	Columns  []SnapshotColumn `json:"columns"`
	Indexes  []SnapshotIndex  `json:"indexes"`
	RowCount int              `json:"row_count"`
}

type SnapshotColumn struct {
	Name     string      `json:"name"`
	Type     string      `json:"type"`
	Nullable bool        `json:"nullable"`
	Default  interface{} `json:"default,omitempty"`
}

type SnapshotIndex struct {
	Name    string          `json:"name"`
	Type    string          `json:"type"`
	Columns []string        `json:"columns"`
	Unique  bool            `json:"unique"`
	Entries []SnapshotEntry `json:"entries"`
}

type SnapshotEntry struct {
	Key   interface{} `json:"key"`
	RowID uint64      `json:"row_id"`
}

type SnapshotScanRequest struct {
	Snapshot        SnapshotManifest   `json:"snapshot"`
	Table           string             `json:"table"`
	Columns         []string           `json:"columns"`
	ColumnTypes     map[string]string  `json:"column_types,omitempty"`
	Filters         []execution.Filter `json:"filters,omitempty"`
	OrderBy         []execution.Order  `json:"order_by,omitempty"`
	IndexName       string             `json:"index_name,omitempty"`
	Limit           *int               `json:"limit,omitempty"`
	Offset          int                `json:"offset,omitempty"`
	Distinct        bool               `json:"distinct,omitempty"`
	DistinctColumns []string           `json:"distinct_columns,omitempty"`
	BatchSize       int                `json:"batch_size,omitempty"`
	MaxRows         int                `json:"max_rows,omitempty"`
}

type SnapshotScanResult struct {
	Rows        []map[string]interface{}
	ColumnTypes map[string]string
}

// ExecuteSnapshotScan validates and reads only the file named by the
// lock-protected manifest. In direct mode that is the already-flushed live
// file; in detached mode it is a short-lived copy. It never consults WAL or
// MVCC state; Ruby has already established the eligible read snapshot.
func ExecuteSnapshotScan(request SnapshotScanRequest) (SnapshotScanResult, error) {
	return ExecuteSnapshotScanContext(context.Background(), request)
}

// ExecuteSnapshotScanContext is cancellation-aware and stops page work as
// soon as the request context is cancelled. Ruby owns snapshot creation and
// visibility; Go only reads the file named by the manifest while Ruby holds
// the engine snapshot lock.
func ExecuteSnapshotScanContext(ctx context.Context, request SnapshotScanRequest) (SnapshotScanResult, error) {
	if err := validateManifest(request.Snapshot); err != nil {
		return SnapshotScanResult{}, err
	}
	file, err := os.Open(request.Snapshot.SnapshotPath)
	if err != nil {
		return SnapshotScanResult{}, fmt.Errorf("open snapshot: %w", err)
	}
	defer file.Close()

	if err := validateSnapshotFile(file, request.Snapshot); err != nil {
		return SnapshotScanResult{}, err
	}
	table, ok := findTable(request.Snapshot.Tables, request.Table)
	if !ok || len(table.Columns) == 0 {
		return SnapshotScanResult{}, fmt.Errorf("%w: table %q", ErrSnapshotSchema, request.Table)
	}
	columns, err := selectedColumns(table.Columns, request.Columns)
	if err != nil {
		return SnapshotScanResult{}, err
	}
	hidden := make(map[uint64]struct{}, len(request.Snapshot.HiddenRowIDs))
	for _, rowID := range request.Snapshot.HiddenRowIDs {
		hidden[rowID] = struct{}{}
	}
	indexed, useIndex, err := indexedRowIDs(table.Indexes, request)
	if err != nil {
		return SnapshotScanResult{}, err
	}

	rows := make([]map[string]interface{}, 0, table.RowCount)
	needed := -1
	if len(request.OrderBy) == 0 && !request.Distinct && request.Limit != nil {
		if *request.Limit < 0 || request.Offset < 0 {
			return SnapshotScanResult{}, execution.ErrInvalidWindow("limit and offset cannot be negative")
		}
		needed = request.Offset + *request.Limit
	}
	for _, pageNumber := range table.Pages {
		select {
		case <-ctx.Done():
			return SnapshotScanResult{}, ctx.Err()
		default:
		}
		page, err := readSnapshotPage(file, request.Snapshot, pageNumber)
		if err != nil {
			return SnapshotScanResult{}, err
		}
		pageRows, err := scanPage(page, table.Columns, columns, hidden, indexed, useIndex, request.Filters)
		if err != nil {
			return SnapshotScanResult{}, fmt.Errorf("scan page %d: %w", pageNumber, err)
		}
		rows = append(rows, pageRows...)
		if request.MaxRows > 0 && len(rows) > request.MaxRows {
			return SnapshotScanResult{}, fmt.Errorf("snapshot scan exceeds configured row limit")
		}
		if needed >= 0 && len(rows) >= needed {
			break
		}
	}

	if len(request.OrderBy) > 0 {
		execution.SortRows(rows, request.OrderBy)
	}
	if request.Distinct {
		columns := request.DistinctColumns
		if len(columns) == 0 {
			columns = request.Columns
		}
		rows = execution.DistinctRows(rows, columns)
	}
	rows = applyWindow(rows, request.Offset, request.Limit)
	columnTypes := make(map[string]string, len(columns))
	for _, column := range columns {
		columnTypes[column.Name] = column.Type
	}
	return SnapshotScanResult{Rows: rows, ColumnTypes: columnTypes}, nil
}

func validateManifest(manifest SnapshotManifest) error {
	if manifest.FormatVersion != snapshotFormatVersion || manifest.SnapshotID == "" || manifest.SnapshotPath == "" {
		return ErrInvalidSnapshot
	}
	if manifest.PageSize < pageHeaderSize || manifest.PageSize > 64*1024*1024 || manifest.PageCount == 0 {
		return ErrInvalidSnapshot
	}
	if len(manifest.Tables) == 0 {
		return ErrInvalidSnapshot
	}
	if manifest.FileSHA256 != "" {
		if len(manifest.FileSHA256) != sha256.Size*2 {
			return ErrInvalidSnapshot
		}
		if _, err := hex.DecodeString(manifest.FileSHA256); err != nil {
			return ErrInvalidSnapshot
		}
	}
	return nil
}

func validateSnapshotFile(file *os.File, manifest SnapshotManifest) error {
	info, err := file.Stat()
	if err != nil || info.Size() != int64(manifest.PageSize)*int64(manifest.PageCount) {
		return ErrInvalidSnapshot
	}
	if manifest.FileSHA256 != "" {
		if _, err := file.Seek(0, io.SeekStart); err != nil {
			return ErrInvalidSnapshot
		}
		digest := sha256.New()
		if _, err := io.Copy(digest, file); err != nil || !strings.EqualFold(hex.EncodeToString(digest.Sum(nil)), manifest.FileSHA256) {
			return ErrInvalidSnapshot
		}
	}
	page, err := readSnapshotPage(file, manifest, 0)
	if err != nil || binary.BigEndian.Uint64(page[0:8]) != 0 || binary.BigEndian.Uint64(page[8:16]) != uint64(manifest.PageSize) ||
		binary.BigEndian.Uint32(page[16:20]) != pageHeaderSize || binary.BigEndian.Uint32(page[32:36]) != 1 {
		return ErrInvalidSnapshot
	}
	return nil
}

func readSnapshotPage(file *os.File, manifest SnapshotManifest, pageNumber uint64) ([]byte, error) {
	if pageNumber >= manifest.PageCount {
		return nil, ErrInvalidSnapshot
	}
	page := make([]byte, manifest.PageSize)
	read, err := file.ReadAt(page, int64(pageNumber)*int64(manifest.PageSize))
	if read != len(page) || (err != nil && !errors.Is(err, io.EOF)) {
		return nil, ErrInvalidSnapshot
	}
	if binary.BigEndian.Uint64(page[0:8]) != pageNumber || binary.BigEndian.Uint64(page[8:16]) != uint64(manifest.PageSize) {
		return nil, ErrInvalidSnapshot
	}
	dataEnd := binary.BigEndian.Uint32(page[20:24])
	if dataEnd < pageHeaderSize || dataEnd > uint32(len(page)) {
		return nil, ErrInvalidSnapshot
	}
	return page, nil
}

func findTable(tables map[string]SnapshotTable, name string) (SnapshotTable, bool) {
	if table, ok := tables[name]; ok {
		return table, true
	}
	for tableName, table := range tables {
		if strings.EqualFold(tableName, name) {
			return table, true
		}
	}
	return SnapshotTable{}, false
}

func selectedColumns(all []SnapshotColumn, requested []string) ([]SnapshotColumn, error) {
	if len(requested) == 0 {
		return all, nil
	}
	byName := make(map[string]SnapshotColumn, len(all))
	for _, column := range all {
		byName[strings.ToLower(column.Name)] = column
	}
	selected := make([]SnapshotColumn, 0, len(requested))
	for _, name := range requested {
		column, ok := byName[strings.ToLower(name)]
		if !ok {
			return nil, fmt.Errorf("%w: unknown column %q", ErrSnapshotSchema, name)
		}
		selected = append(selected, column)
	}
	return selected, nil
}

func scanPage(page []byte, schema, selected []SnapshotColumn, hidden, indexed map[uint64]struct{}, useIndex bool, filters []execution.Filter) ([]map[string]interface{}, error) {
	dataEnd := int(binary.BigEndian.Uint32(page[20:24]))
	rows := make([]map[string]interface{}, 0)
	for offset := pageHeaderSize; offset < dataEnd; {
		if dataEnd-offset < recordHeaderSize {
			return nil, fmt.Errorf("record header at offset %d: %w", offset, ErrInvalidSnapshot)
		}
		rowID := binary.BigEndian.Uint64(page[offset : offset+8])
		recordSize := int(binary.BigEndian.Uint32(page[offset+8 : offset+12]))
		// Ruby's record header is Q>L>S>S: the flags field is explicitly
		// big-endian while the final column-count S is native-endian.
		flags := binary.BigEndian.Uint16(page[offset+12 : offset+14])
		columnCount := int(binary.LittleEndian.Uint16(page[offset+14 : offset+16]))
		offset += recordHeaderSize
		if recordSize < 0 || offset+recordSize > dataEnd || columnCount < 0 || columnCount > len(schema) {
			return nil, fmt.Errorf("record at offset %d has size %d and %d columns: %w", offset-recordHeaderSize, recordSize, columnCount, ErrInvalidSnapshot)
		}
		record := page[offset : offset+recordSize]
		offset += recordSize
		if flags&deletedRecordFlag != 0 {
			continue
		}
		if _, ok := hidden[rowID]; ok {
			continue
		}
		if useIndex {
			if _, ok := indexed[rowID]; !ok {
				continue
			}
		}
		row, err := decodeRow(record, flags, columnCount, schema, selected)
		if err != nil {
			return nil, fmt.Errorf("row %d: %w", rowID, err)
		}
		row["_row_id"] = rowID
		if !matchesFilters(row, filters) {
			continue
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func decodeRow(data []byte, flags uint16, columnCount int, schema, selected []SnapshotColumn) (map[string]interface{}, error) {
	bitmapSize := 0
	if flags&nullBitmapFlag != 0 {
		bitmapSize = (len(schema) + 7) / 8
		if bitmapSize > len(data) {
			return nil, ErrInvalidSnapshot
		}
	}
	bitmap := data[:bitmapSize]
	offset := bitmapSize
	selectedNames := make(map[string]struct{}, len(selected))
	for _, column := range selected {
		selectedNames[strings.ToLower(column.Name)] = struct{}{}
	}
	row := make(map[string]interface{}, len(selected))
	for index := 0; index < len(schema); index++ {
		column := schema[index]
		if index >= columnCount {
			if _, ok := selectedNames[strings.ToLower(column.Name)]; ok {
				row[column.Name] = column.Default
			}
			continue
		}
		value, next, err := decodeColumn(data, offset, column.Type, flags&variablePrefixFlag != 0)
		if err != nil {
			return nil, fmt.Errorf("column %q: %w", column.Name, err)
		}
		offset = next
		if bitmapSet(bitmap, index) {
			value = nil
		}
		if value == nil && column.Default != nil {
			value = column.Default
		}
		if _, ok := selectedNames[strings.ToLower(column.Name)]; ok {
			row[column.Name] = value
		}
	}
	if offset > len(data) {
		return nil, ErrInvalidSnapshot
	}
	return row, nil
}

func decodeColumn(data []byte, offset int, typeName string, variablePrefixes bool) (interface{}, int, error) {
	typeName = strings.ToLower(typeName)
	size := fixedSize(typeName)
	if size > 0 {
		if offset+size > len(data) {
			return nil, offset, ErrInvalidSnapshot
		}
		raw := data[offset : offset+size]
		return decodeFixed(raw, typeName), offset + size, nil
	}
	if !variablePrefixes {
		return nil, len(data), nil
	}
	if offset+4 > len(data) {
		return nil, offset, ErrInvalidSnapshot
	}
	length := int(binary.BigEndian.Uint32(data[offset : offset+4]))
	offset += 4
	if length < 0 || offset+length > len(data) {
		return nil, offset, ErrInvalidSnapshot
	}
	return decodeVariable(data[offset:offset+length], typeName), offset + length, nil
}

func fixedSize(typeName string) int {
	switch typeName {
	case "integer", "date":
		return 4
	case "smallint":
		return 2
	case "bigint", "float", "time", "timestamp":
		return 8
	case "boolean":
		return 1
	case "uuid":
		return 16
	default:
		return 0
	}
}

func decodeFixed(raw []byte, typeName string) interface{} {
	switch typeName {
	case "integer":
		return int64(int32(binary.BigEndian.Uint32(raw)))
	case "smallint":
		return int64(int16(binary.BigEndian.Uint16(raw)))
	case "bigint":
		return int64(binary.BigEndian.Uint64(raw))
	case "float":
		return math.Float64frombits(binary.BigEndian.Uint64(raw))
	case "boolean":
		return raw[0] == 1
	case "date":
		return time.Unix(int64(int32(binary.BigEndian.Uint32(raw)))*86400, 0).UTC().Format("2006-01-02")
	case "time":
		total := int64(binary.BigEndian.Uint64(raw))
		seconds, micros := total/1_000_000, total%1_000_000
		value := time.Unix(0, 0).UTC().Add(time.Duration(seconds)*time.Second + time.Duration(micros)*time.Microsecond)
		return value.Format(time.RFC3339Nano)
	case "timestamp":
		return time.Unix(int64(binary.BigEndian.Uint64(raw)), 0).UTC().Format(time.RFC3339Nano)
	case "uuid":
		encoded := hex.EncodeToString(raw)
		return encoded[0:8] + "-" + encoded[8:12] + "-" + encoded[12:16] + "-" + encoded[16:20] + "-" + encoded[20:32]
	default:
		return string(raw)
	}
}

func decodeVariable(raw []byte, typeName string) interface{} {
	if typeName == "blob" {
		return append([]byte(nil), raw...)
	}
	if typeName == "json" {
		var value interface{}
		if json.Unmarshal(raw, &value) == nil {
			return value
		}
	}
	return string(raw)
}

func bitmapSet(bitmap []byte, index int) bool {
	return len(bitmap) > index/8 && bitmap[index/8]&(1<<uint(index%8)) != 0
}

func matchesFilters(row map[string]interface{}, filters []execution.Filter) bool {
	for _, filter := range filters {
		column := filter.Column
		if dot := strings.LastIndex(column, "."); dot >= 0 {
			column = column[dot+1:]
		}
		if !execution.Matches(row[column], filter.Operator, filter.Value) {
			return false
		}
	}
	return true
}

func indexedRowIDs(indexes []SnapshotIndex, request SnapshotScanRequest) (map[uint64]struct{}, bool, error) {
	if request.IndexName == "" {
		return nil, false, nil
	}
	var selected *SnapshotIndex
	for index := range indexes {
		if strings.EqualFold(indexes[index].Name, request.IndexName) {
			selected = &indexes[index]
			break
		}
	}
	if selected == nil || !strings.EqualFold(selected.Type, "btree") {
		return nil, false, nil
	}
	rowIDs := make(map[uint64]struct{})
	matchedFilter := false
	for _, entry := range selected.Entries {
		matches := true
		for index, column := range selected.Columns {
			key, ok := indexKeyPart(entry.Key, index, len(selected.Columns))
			if !ok {
				matches = false
				break
			}
			for _, filter := range request.Filters {
				filterColumn := filter.Column
				if dot := strings.LastIndex(filterColumn, "."); dot >= 0 {
					filterColumn = filterColumn[dot+1:]
				}
				if strings.EqualFold(filterColumn, column) {
					matchedFilter = true
					if !execution.Matches(key, filter.Operator, filter.Value) {
						matches = false
					}
				}
			}
		}
		if matches {
			rowIDs[entry.RowID] = struct{}{}
		}
	}
	if !matchedFilter {
		return nil, false, nil
	}
	return rowIDs, true, nil
}

func indexKeyPart(key interface{}, index, count int) (interface{}, bool) {
	if count == 1 {
		return key, true
	}
	parts, ok := key.([]interface{})
	if !ok || index >= len(parts) {
		return nil, false
	}
	return parts[index], true
}

func applyWindow(rows []map[string]interface{}, offset int, limit *int) []map[string]interface{} {
	if offset < 0 {
		offset = 0
	}
	if offset >= len(rows) {
		return []map[string]interface{}{}
	}
	rows = rows[offset:]
	if limit != nil {
		if *limit <= 0 {
			return []map[string]interface{}{}
		}
		if *limit < len(rows) {
			rows = rows[:*limit]
		}
	}
	return rows
}
