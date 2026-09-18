package runtime

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"runtime"
	"sync"
	"time"

	"github.com/aldanedev-create/rubydb/accelerator/internal/execution"
	"github.com/aldanedev-create/rubydb/accelerator/internal/metrics"
	"github.com/aldanedev-create/rubydb/accelerator/internal/protocol"
	"github.com/aldanedev-create/rubydb/accelerator/internal/storage"
	"github.com/aldanedev-create/rubydb/accelerator/internal/wal"
)

type request struct {
	ID      string          `json:"id"`
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

type response struct {
	ID      string      `json:"id"`
	Type    string      `json:"type"`
	Success bool        `json:"success"`
	More    bool        `json:"more,omitempty"`
	Payload interface{} `json:"payload,omitempty"`
	Error   string      `json:"error,omitempty"`
	Code    string      `json:"code,omitempty"`
}

var operationMetrics = metrics.NewRegistry()

func Run(input io.Reader, output io.Writer) {
	reader := bufio.NewReaderSize(input, 64*1024)
	writer := bufio.NewWriterSize(output, 64*1024)
	var writeMu sync.Mutex
	registry := protocol.NewCancellationRegistry()
	workerLimit := runtime.GOMAXPROCS(0) * 2
	// Keep a small amount of parallelism available even on development
	// machines where Go reports only one or two logical processors. The Ruby
	// client multiplexes requests over one worker, so rejecting every request
	// above GOMAXPROCS*2 would turn normal connection-pool bursts into false
	// accelerator failures. The limit is still bounded and remains a safety
	// valve for large requests.
	if workerLimit < 8 {
		workerLimit = 8
	}
	active := make(chan struct{}, workerLimit)
	defer writer.Flush()
	for {
		binaryFrame, frame, err := protocol.ReadMessage(reader)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return
			}
			if errors.Is(err, protocol.ErrFrameTooLarge) {
				_ = protocol.WriteJSONResponse(writer, response{Success: false, Type: "error", Error: "request exceeds maximum frame size", Code: "frame_too_large"})
				return
			}
			_ = protocol.WriteJSONResponse(writer, response{Success: false, Type: "error", Error: "invalid request frame", Code: "invalid_frame"})
			return
		}
		if binaryFrame != nil {
			frame := *binaryFrame
			select {
			case active <- struct{}{}:
			default:
				writeMu.Lock()
				_ = protocol.WriteBinaryResponse(writer, frame, nil, "accelerator worker capacity is exhausted", "resource_limit")
				writeMu.Unlock()
				continue
			}
			ctx := registry.Begin(context.Background(), frame.ID)
			go func() {
				defer func() { <-active }()
				defer registry.Finish(frame.ID)
				payload, message, code := handleBinaryContext(ctx, frame)
				writeMu.Lock()
				defer writeMu.Unlock()
				_ = protocol.WriteBinaryResponse(writer, frame, payload, message, code)
			}()
			continue
		}
		var req request
		decoder := json.NewDecoder(bytes.NewReader(bytes.TrimSpace(frame)))
		decoder.UseNumber()
		if err := decoder.Decode(&req); err != nil || req.ID == "" || req.Type == "" {
			_ = protocol.WriteJSONResponse(writer, response{Success: false, Type: "error", Error: "invalid request frame", Code: "invalid_frame"})
			return
		}
		if req.Type == "cancel" {
			var payload struct {
				TargetID string `json:"target_id"`
			}
			if err := json.Unmarshal(req.Payload, &payload); err != nil || payload.TargetID == "" {
				writeMu.Lock()
				_ = protocol.WriteJSONResponse(writer, response{ID: req.ID, Success: false, Type: "error", Error: "invalid cancellation payload", Code: "invalid_payload"})
				writeMu.Unlock()
				continue
			}
			cancelled := registry.Cancel(payload.TargetID)
			writeMu.Lock()
			_ = protocol.WriteJSONResponse(writer, response{ID: req.ID, Type: "cancel_response", Success: true, Payload: map[string]interface{}{"target_id": payload.TargetID, "cancelled": cancelled}})
			writeMu.Unlock()
			continue
		}
		if req.Type == "terminate" {
			res := handleContext(context.Background(), req)
			res.ID = req.ID
			writeMu.Lock()
			err := protocol.WriteJSONResponse(writer, res)
			writeMu.Unlock()
			if err != nil {
				return
			}
			return
		}
		select {
		case active <- struct{}{}:
		default:
			writeMu.Lock()
			_ = protocol.WriteJSONResponse(writer, response{ID: req.ID, Type: "error", Success: false, Error: "accelerator worker capacity is exhausted", Code: "resource_limit"})
			writeMu.Unlock()
			continue
		}
		ctx := registry.Begin(context.Background(), req.ID)
		go func(req request, ctx context.Context) {
			defer func() { <-active }()
			defer registry.Finish(req.ID)
			started := time.Now()
			if req.Type == "rows_pipeline_stream" {
				streamRowsPipeline(ctx, req, writer, &writeMu)
				operationMetrics.Observe(req.Type, time.Since(started))
				return
			}
			res := handleContext(ctx, req)
			operationMetrics.Observe(req.Type, time.Since(started))
			res.ID = req.ID
			writeMu.Lock()
			defer writeMu.Unlock()
			_ = protocol.WriteJSONResponse(writer, res)
		}(req, ctx)
	}
}

func handle(req request) response {
	return handleContext(context.Background(), req)
}

func handleContext(ctx context.Context, req request) response {
	select {
	case <-ctx.Done():
		return failure(ctx.Err().Error(), "cancelled")
	default:
	}
	switch req.Type {
	case "handshake":
		return response{Success: true, Type: "handshake_response", Payload: map[string]interface{}{
			"protocol_version":    protocolVersion,
			"accelerator_version": "0.1.0",
			"runtime":             "go",
			"capabilities":        capabilities(),
		}}
	case "ping":
		return response{Success: true, Type: "pong", Payload: map[string]interface{}{
			"protocol_version": protocolVersion,
			"capabilities":     capabilities(),
		}}
	case "stats":
		return response{Success: true, Type: "stats_response", Payload: operationMetrics.Snapshot()}
	case "sha256":
		return handleSHA256(req.Payload)
	case "gzip":
		return handleGzip(req.Payload, true)
	case "gunzip":
		return handleGzip(req.Payload, false)
	case "rows_pipeline":
		return handleRowsPipelineContext(ctx, req.Payload)
	case "wal_batch":
		return handleWALBatch(req.Payload)
	case "terminate":
		return response{Success: true, Type: "terminate_response"}
	default:
		return failure("unsupported accelerator operation", "unsupported_operation")
	}
}

func capabilities() []string {
	return []string{"sha256", "gzip", "wal_batch", "rows_pipeline", "rows_pipeline_stream", "rows_pipeline_binary", "hash_join", "merge_join", "snapshot_scan", "snapshot_index_scan", "columnar_batches", "projection", "distinct", "window_functions", "cancellation", "multiplexed_requests", "bounded_concurrency", "resource_limits", "metrics"}
}

func handleBinary(frame protocol.BinaryFrame) ([]byte, string, string) {
	return handleBinaryContext(context.Background(), frame)
}

func handleBinaryContext(ctx context.Context, frame protocol.BinaryFrame) ([]byte, string, string) {
	if frame.Kind != protocol.BinaryRequestKind || (frame.TypeID != protocol.BinaryRowsType && frame.TypeID != protocol.BinaryJoinType && frame.TypeID != protocol.BinarySnapshotScanType) {
		return nil, "unsupported binary accelerator operation", "unsupported_operation"
	}
	if frame.TypeID == protocol.BinarySnapshotScanType {
		var request storage.SnapshotScanRequest
		decoder := json.NewDecoder(bytes.NewReader(frame.Payload))
		decoder.UseNumber()
		if err := decoder.Decode(&request); err != nil {
			return nil, "snapshot scan request is invalid", "invalid_payload"
		}
		result, err := storage.ExecuteSnapshotScanContext(ctx, request)
		if err != nil {
			return nil, err.Error(), "snapshot_scan_failed"
		}
		return encodeBinaryResultWithTypes(result.Rows, nil, result.ColumnTypes)
	}
	if frame.TypeID == protocol.BinaryJoinType {
		return handleBinaryJoin(frame.Payload)
	}
	payload, err := decodeBinaryRowsRequest(frame.Payload)
	if err != nil {
		return nil, err.Error(), "invalid_payload"
	}
	result, err := execution.ExecuteRowsPipelineContext(ctx, payload)
	if err != nil {
		return nil, err.Error(), "execution_error"
	}
	return encodeBinaryResult(result.Rows, result.Aggregates)
}

func encodeBinaryResult(rows, aggregates []map[string]interface{}) ([]byte, string, string) {
	return encodeBinaryResultWithTypes(rows, aggregates, nil)
}

func encodeBinaryResultWithTypes(rows, aggregates []map[string]interface{}, columnTypes map[string]string) ([]byte, string, string) {
	rowBatch, err := protocol.EncodeRows(rows)
	if err != nil {
		return nil, err.Error(), "encoding_error"
	}
	aggregateBatch, err := protocol.EncodeRows(aggregates)
	if err != nil {
		return nil, err.Error(), "encoding_error"
	}
	metadata, _ := json.Marshal(map[string]interface{}{"row_count": len(rows), "has_aggregates": len(aggregates) > 0, "row_batch_bytes": len(rowBatch), "aggregate_batch_bytes": len(aggregateBatch), "column_types": columnTypes})
	var payload bytes.Buffer
	writeUint32(&payload, uint32(len(metadata)))
	payload.Write(metadata)
	writeUint32(&payload, uint32(len(rowBatch)))
	payload.Write(rowBatch)
	writeUint32(&payload, uint32(len(aggregateBatch)))
	payload.Write(aggregateBatch)
	return payload.Bytes(), "", ""
}

func decodeBinaryRowsRequest(payload []byte) (execution.RowsRequest, error) {
	reader := protocol.NewReader(payload)
	metadataLength, err := reader.Uint32()
	if err != nil {
		return execution.RowsRequest{}, errors.New("binary rows request is truncated")
	}
	metadata, err := reader.Take(int(metadataLength))
	if err != nil {
		return execution.RowsRequest{}, errors.New("binary rows request metadata is invalid")
	}
	var request execution.RowsRequest
	decoder := json.NewDecoder(bytes.NewReader(metadata))
	decoder.UseNumber()
	if err := decoder.Decode(&request); err != nil {
		return execution.RowsRequest{}, errors.New("binary rows request metadata is invalid")
	}
	rows, err := protocol.DecodeRows(reader.Bytes())
	if err != nil {
		return execution.RowsRequest{}, err
	}
	request.Rows = rows
	return request, nil
}

func handleBinaryJoin(payload []byte) ([]byte, string, string) {
	reader := protocol.NewReader(payload)
	metadataLength, err := reader.Uint32()
	if err != nil {
		return nil, "binary join request is truncated", "invalid_payload"
	}
	metadata, err := reader.Take(int(metadataLength))
	if err != nil {
		return nil, "binary join metadata is invalid", "invalid_payload"
	}
	var specification struct {
		LeftKey   string `json:"left_key"`
		RightKey  string `json:"right_key"`
		JoinType  string `json:"join_type"`
		Algorithm string `json:"algorithm"`
	}
	if err := json.Unmarshal(metadata, &specification); err != nil || specification.LeftKey == "" || specification.RightKey == "" {
		return nil, "binary join metadata is invalid", "invalid_payload"
	}
	leftLength, err := reader.Uint32()
	if err != nil {
		return nil, "binary join request is truncated", "invalid_payload"
	}
	left, err := reader.Take(int(leftLength))
	if err != nil {
		return nil, "binary join left batch is invalid", "invalid_payload"
	}
	rightLength, err := reader.Uint32()
	if err != nil {
		return nil, "binary join request is truncated", "invalid_payload"
	}
	right, err := reader.Take(int(rightLength))
	if err != nil || reader.Remaining() != 0 {
		return nil, "binary join right batch is invalid", "invalid_payload"
	}
	if specification.JoinType != "" && !equalFold(specification.JoinType, "inner") {
		return nil, "only inner joins are supported by the accelerator", "unsupported_operation"
	}
	leftRows, err := protocol.DecodeRows(left)
	if err != nil {
		return nil, err.Error(), "invalid_payload"
	}
	rightRows, err := protocol.DecodeRows(right)
	if err != nil {
		return nil, err.Error(), "invalid_payload"
	}
	joined := execution.HashJoinRows(leftRows, rightRows, specification.LeftKey, specification.RightKey)
	if equalFold(specification.Algorithm, "merge") {
		joined = execution.MergeJoinRows(leftRows, rightRows, specification.LeftKey, specification.RightKey)
	}
	return encodeBinaryResult(joined, nil)
}

func handleSHA256(raw json.RawMessage) response {
	var payload struct {
		DataBase64 string `json:"data_base64"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return failure("invalid sha256 payload", "invalid_payload")
	}
	data, err := base64.StdEncoding.DecodeString(payload.DataBase64)
	if err != nil {
		return failure("data_base64 is invalid", "invalid_payload")
	}
	return response{Success: true, Type: "sha256_response", Payload: map[string]string{"digest": wal.SHA256Hex(data)}}
}

func handleGzip(raw json.RawMessage, compress bool) response {
	var payload struct {
		DataBase64 string `json:"data_base64"`
		Level      int    `json:"level,omitempty"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return failure("invalid compression payload", "invalid_payload")
	}
	data, err := base64.StdEncoding.DecodeString(payload.DataBase64)
	if err != nil {
		return failure("data_base64 is invalid", "invalid_payload")
	}
	if compress {
		level := payload.Level
		if level == 0 {
			level = gzip.DefaultCompression
		}
		compressed, err := wal.Gzip(data, level)
		if err != nil {
			return failure("gzip operation failed", "compression_error")
		}
		return response{Success: true, Type: "gzip_response", Payload: map[string]interface{}{"data_base64": base64.StdEncoding.EncodeToString(compressed), "input_bytes": len(data), "output_bytes": len(compressed)}}
	}
	output, err := wal.Gunzip(data, protocol.MaxFrameSize)
	if err != nil {
		return failure("gunzip operation failed", "compression_error")
	}
	return response{Success: true, Type: "gunzip_response", Payload: map[string]interface{}{"data_base64": base64.StdEncoding.EncodeToString(output), "output_bytes": len(output)}}
}

func handleRowsPipeline(raw json.RawMessage) response {
	return handleRowsPipelineContext(context.Background(), raw)
}

func handleRowsPipelineContext(ctx context.Context, raw json.RawMessage) response {
	var payload execution.RowsRequest
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&payload); err != nil {
		return failure("invalid rows pipeline payload", "invalid_payload")
	}
	result, err := execution.ExecuteRowsPipelineContext(ctx, payload)
	if err != nil {
		code := "execution_error"
		if errors.Is(err, context.Canceled) {
			code = "cancelled"
		}
		return failure(err.Error(), code)
	}
	return response{Success: true, Type: "rows_pipeline_response", Payload: result.AsMap()}
}

func streamRowsPipeline(ctx context.Context, req request, writer *bufio.Writer, writeMu *sync.Mutex) {
	var payload execution.RowsRequest
	decoder := json.NewDecoder(bytes.NewReader(req.Payload))
	decoder.UseNumber()
	if err := decoder.Decode(&payload); err != nil {
		writeStreamResponse(writer, writeMu, response{ID: req.ID, Type: "rows_pipeline_batch", Success: false, Error: "invalid rows pipeline payload", Code: "invalid_payload"})
		return
	}
	result, err := execution.ExecuteRowsPipelineContext(ctx, payload)
	if err != nil {
		code := "execution_error"
		if errors.Is(err, context.Canceled) {
			code = "cancelled"
		}
		writeStreamResponse(writer, writeMu, response{ID: req.ID, Type: "rows_pipeline_batch", Success: false, Error: err.Error(), Code: code})
		return
	}
	batchSize := payload.BatchSize
	if batchSize < 1 {
		batchSize = 1024
	}
	if len(result.Rows) == 0 {
		writeStreamResponse(writer, writeMu, response{ID: req.ID, Type: "rows_pipeline_batch", Success: true, Payload: map[string]interface{}{"rows": []map[string]interface{}{}, "row_count": 0}, More: false})
		return
	}
	for start := 0; start < len(result.Rows); start += batchSize {
		select {
		case <-ctx.Done():
			writeStreamResponse(writer, writeMu, response{ID: req.ID, Type: "rows_pipeline_batch", Success: false, Error: ctx.Err().Error(), Code: "cancelled"})
			return
		default:
		}
		end := start + batchSize
		if end > len(result.Rows) {
			end = len(result.Rows)
		}
		payload := map[string]interface{}{"rows": result.Rows[start:end], "row_count": end - start}
		if end == len(result.Rows) && len(result.Aggregates) > 0 {
			payload["aggregates"] = result.Aggregates
		}
		writeStreamResponse(writer, writeMu, response{ID: req.ID, Type: "rows_pipeline_batch", Success: true, Payload: payload, More: end < len(result.Rows)})
	}
}

func writeStreamResponse(writer *bufio.Writer, writeMu *sync.Mutex, result response) {
	writeMu.Lock()
	defer writeMu.Unlock()
	_ = protocol.WriteJSONResponse(writer, result)
}

func handleWALBatch(raw json.RawMessage) response {
	var payload struct {
		Records []struct {
			Kind          uint8  `json:"kind"`
			LSN           uint64 `json:"lsn"`
			Transaction   uint64 `json:"transaction"`
			PayloadBase64 string `json:"payload_base64"`
		} `json:"records"`
		Compress bool `json:"compress,omitempty"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil || len(payload.Records) == 0 {
		return failure("invalid WAL batch payload", "invalid_payload")
	}
	encoded := make([][]byte, 0, len(payload.Records))
	for _, record := range payload.Records {
		data, err := base64.StdEncoding.DecodeString(record.PayloadBase64)
		if err != nil {
			return failure("WAL payload is not valid base64", "invalid_payload")
		}
		encoded = append(encoded, wal.EncodeRecord(record.Kind, record.LSN, record.Transaction, data))
	}
	joined := bytes.Join(encoded, nil)
	result := map[string]interface{}{
		"record_count":   len(encoded),
		"bytes":          len(joined),
		"checksum":       wal.SHA256Hex(joined),
		"records_base64": base64.StdEncoding.EncodeToString(joined),
	}
	if payload.Compress {
		compressed, err := wal.Gzip(joined, gzip.DefaultCompression)
		if err != nil {
			return failure("WAL compression failed", "compression_error")
		}
		result["compressed_base64"] = base64.StdEncoding.EncodeToString(compressed)
		result["compressed_bytes"] = len(compressed)
	}
	return response{Success: true, Type: "wal_batch_response", Payload: result}
}

func writeUint32(output *bytes.Buffer, value uint32) {
	output.WriteByte(byte(value))
	output.WriteByte(byte(value >> 8))
	output.WriteByte(byte(value >> 16))
	output.WriteByte(byte(value >> 24))
}

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

func failure(message, code string) response {
	return response{Success: false, Type: "error", Error: message, Code: code}
}

const protocolVersion = protocol.Version
