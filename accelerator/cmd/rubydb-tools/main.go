package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/csv"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/aldanedev-create/rubydb/accelerator/internal/execution"
	"github.com/aldanedev-create/rubydb/accelerator/internal/storage"
)

type whereFlags []string

func (flags *whereFlags) String() string { return strings.Join(*flags, ", ") }
func (flags *whereFlags) Set(value string) error {
	*flags = append(*flags, value)
	return nil
}

func main() {
	code := run(os.Args[1:], os.Stderr)
	os.Exit(code)
}

func run(args []string, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "export" {
		fmt.Fprintln(stderr, "usage: rubydb-tools export --manifest FILE --table NAME --format jsonl|csv --out FILE [--columns a,b] [--where 'column op value'] [--workers N] [--max-rows N] [--json-stats]")
		return 2
	}
	flags := flag.NewFlagSet("export", flag.ContinueOnError)
	flags.SetOutput(stderr)
	manifestPath := flags.String("manifest", "", "immutable snapshot manifest")
	table := flags.String("table", "", "table name")
	format := flags.String("format", "jsonl", "jsonl or csv")
	out := flags.String("out", "", "output file")
	columnList := flags.String("columns", "", "comma-separated columns")
	workers := flags.Int("workers", 0, "parallel page workers (max 8)")
	maxRows := flags.Int("max-rows", 0, "fail if more than N rows would be exported (0 is unlimited)")
	jsonStats := flags.Bool("json-stats", false, "write one JSON stats line to stderr")
	var where whereFlags
	flags.Var(&where, "where", "column operator value; repeatable")
	if err := flags.Parse(args[1:]); err != nil || *manifestPath == "" || *table == "" || *out == "" || flags.NArg() != 0 || (*format != "jsonl" && *format != "csv") || *workers < 0 || *maxRows < 0 {
		fmt.Fprintln(stderr, "invalid export options")
		return 2
	}
	filters := make([]execution.Filter, 0, len(where))
	for _, clause := range where {
		filter, err := parseFilter(clause)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 2
		}
		filters = append(filters, filter)
	}
	contents, err := os.ReadFile(*manifestPath)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	var manifest storage.SnapshotManifest
	if err := json.Unmarshal(contents, &manifest); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	selected, err := selectedNames(manifest, *table, *columnList)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if _, err := os.Stat(*out); err == nil {
		fmt.Fprintln(stderr, "output file already exists")
		return 1
	} else if !errors.Is(err, os.ErrNotExist) {
		fmt.Fprintln(stderr, err)
		return 1
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	started := time.Now()
	// Rows need the requested output columns plus any filter columns. The
	// streaming reader may discard unselected fields, so filtering a hidden
	// field would otherwise compare nil and silently return no rows.
	scanColumns := append([]string(nil), selected...)
	for _, filter := range filters {
		column := filter.Column
		if dot := strings.LastIndex(column, "."); dot >= 0 {
			column = column[dot+1:]
		}
		if !containsFold(scanColumns, column) {
			scanColumns = append(scanColumns, column)
		}
	}
	rows, bytes, err := export(ctx, storage.SnapshotScanRequest{Snapshot: manifest, Table: *table,
		Columns: scanColumns, Filters: filters, Workers: *workers, MaxRows: *maxRows}, *format, *out, selected)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if *jsonStats {
		stats, _ := json.Marshal(map[string]interface{}{"rows": rows, "bytes": bytes,
			"elapsed_ms": time.Since(started).Milliseconds(), "workers": effectiveWorkers(*workers)})
		fmt.Fprintln(stderr, string(stats))
	}
	return 0
}

func containsFold(values []string, wanted string) bool {
	for _, value := range values {
		if strings.EqualFold(value, wanted) {
			return true
		}
	}
	return false
}

func selectedNames(manifest storage.SnapshotManifest, tableName, csvNames string) ([]string, error) {
	var table storage.SnapshotTable
	found := false
	for name, value := range manifest.Tables {
		if strings.EqualFold(name, tableName) {
			table, found = value, true
			break
		}
	}
	if !found || len(table.Columns) == 0 {
		return nil, fmt.Errorf("unknown table %q", tableName)
	}
	requested := []string{}
	if csvNames != "" {
		requested = strings.Split(csvNames, ",")
	} else {
		for _, column := range table.Columns {
			requested = append(requested, column.Name)
		}
	}
	selected := make([]string, 0, len(requested))
	for _, name := range requested {
		name = strings.TrimSpace(name)
		matched := false
		for _, column := range table.Columns {
			if strings.EqualFold(column.Name, name) {
				selected = append(selected, column.Name)
				matched = true
				break
			}
		}
		if !matched {
			return nil, fmt.Errorf("unknown column %q", name)
		}
	}
	return selected, nil
}

func parseFilter(clause string) (execution.Filter, error) {
	parts := strings.SplitN(strings.TrimSpace(clause), " ", 3)
	if len(parts) < 2 || parts[0] == "" {
		return execution.Filter{}, fmt.Errorf("invalid --where %q", clause)
	}
	operator := strings.ToLower(parts[1])
	valid := map[string]bool{"eq": true, "ne": true, "lt": true, "lte": true,
		"gt": true, "gte": true, "like": true, "is_null": true, "is_not_null": true}
	if !valid[operator] || (len(parts) != 3 && operator != "is_null" && operator != "is_not_null") {
		return execution.Filter{}, fmt.Errorf("invalid --where operator %q", operator)
	}
	var value interface{}
	if len(parts) == 3 {
		if err := json.Unmarshal([]byte(parts[2]), &value); err != nil {
			value = parts[2]
		}
	}
	return execution.Filter{Column: parts[0], Operator: operator, Value: value}, nil
}

func export(ctx context.Context, request storage.SnapshotScanRequest, format, out string, columns []string) (int, int64, error) {
	partial := out + ".partial"
	file, err := os.OpenFile(partial, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return 0, 0, err
	}
	defer os.Remove(partial)
	defer file.Close()
	buffer := bufio.NewWriterSize(file, 128*1024)
	var csvWriter *csv.Writer
	if format == "csv" {
		csvWriter = csv.NewWriter(buffer)
		if err := csvWriter.Write(columns); err != nil {
			return 0, 0, err
		}
	}
	rows := 0
	err = storage.StreamSnapshotScan(ctx, request, func(batch []map[string]interface{}) error {
		for _, row := range batch {
			if format == "csv" {
				values := make([]string, len(columns))
				for index, column := range columns {
					values[index] = csvValue(row[column])
				}
				if err := csvWriter.Write(values); err != nil {
					return err
				}
			} else {
				line, err := jsonLine(columns, row)
				if err != nil {
					return err
				}
				if _, err := buffer.Write(line); err != nil {
					return err
				}
			}
			rows++
		}
		return nil
	})
	if err != nil {
		return 0, 0, err
	}
	if csvWriter != nil {
		csvWriter.Flush()
		if err := csvWriter.Error(); err != nil {
			return 0, 0, err
		}
	}
	if err := buffer.Flush(); err != nil {
		return 0, 0, err
	}
	if err := file.Sync(); err != nil {
		return 0, 0, err
	}
	info, err := file.Stat()
	if err != nil {
		return 0, 0, err
	}
	if err := file.Close(); err != nil {
		return 0, 0, err
	}
	if err := os.Rename(partial, out); err != nil {
		return 0, 0, err
	}
	if directory, err := os.Open(filepath.Dir(out)); err == nil {
		_ = directory.Sync()
		_ = directory.Close()
	}
	return rows, info.Size(), nil
}

func jsonLine(columns []string, row map[string]interface{}) ([]byte, error) {
	line := []byte{'{'}
	for index, column := range columns {
		if index > 0 {
			line = append(line, ',')
		}
		key, _ := json.Marshal(column)
		value, err := json.Marshal(normalizeValue(row[column]))
		if err != nil {
			return nil, err
		}
		line = append(line, key...)
		line = append(line, ':')
		line = append(line, value...)
	}
	return append(line, '}', '\n'), nil
}

func normalizeValue(value interface{}) interface{} {
	switch value := value.(type) {
	case float64:
		if math.IsNaN(value) {
			return "NaN"
		}
		if math.IsInf(value, 1) {
			return "Infinity"
		}
		if math.IsInf(value, -1) {
			return "-Infinity"
		}
		if value == 0 && math.Signbit(value) {
			return "-0"
		}
	case []byte:
		return base64.StdEncoding.EncodeToString(value)
	}
	return value
}

func csvValue(value interface{}) string {
	if value == nil {
		return ""
	}
	value = normalizeValue(value)
	switch value := value.(type) {
	case string:
		return value
	case bool:
		if value {
			return "true"
		}
		return "false"
	case map[string]interface{}, []interface{}:
		encoded, _ := json.Marshal(value)
		return string(encoded)
	default:
		return fmt.Sprint(value)
	}
}

func effectiveWorkers(configured int) int {
	if configured < 1 {
		configured = runtime.GOMAXPROCS(0)
	}
	if configured > 8 {
		return 8
	}
	return configured
}
