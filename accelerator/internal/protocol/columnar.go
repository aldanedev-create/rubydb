package protocol

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"math"
)

func EncodeRows(rows []map[string]interface{}) ([]byte, error) {
	columns := make([]string, 0)
	known := make(map[string]bool)
	for _, row := range rows {
		for key := range row {
			if !known[key] {
				known[key] = true
				columns = append(columns, key)
			}
		}
	}
	if len(columns) > math.MaxUint16 || uint64(len(rows)) > math.MaxUint32 {
		return nil, errors.New("binary rows batch is too large")
	}
	output := bytes.NewBuffer(make([]byte, 0, 6+len(columns)*16))
	writeUint16(output, uint16(len(columns)))
	writeUint32(output, uint32(len(rows)))
	for _, column := range columns {
		if len(column) > math.MaxUint16 {
			return nil, errors.New("binary row column name is too long")
		}
		writeUint16(output, uint16(len(column)))
		output.WriteString(column)
	}
	for _, column := range columns {
		for _, row := range rows {
			if err := encodeValue(output, row[column]); err != nil {
				return nil, err
			}
		}
	}
	return output.Bytes(), nil
}

func DecodeRows(data []byte) ([]map[string]interface{}, error) {
	reader := newValueReader(data)
	columnCount, err := reader.uint16()
	if err != nil {
		return nil, errors.New("binary rows batch is truncated")
	}
	rowCount, err := reader.uint32()
	if err != nil {
		return nil, errors.New("binary rows batch is truncated")
	}
	columns := make([]string, columnCount)
	for index := range columns {
		name, err := reader.string16()
		if err != nil {
			return nil, errors.New("binary row column metadata is invalid")
		}
		columns[index] = name
	}
	rows := make([]map[string]interface{}, rowCount)
	for index := range rows {
		rows[index] = make(map[string]interface{}, columnCount)
	}
	for _, column := range columns {
		for rowIndex := range rows {
			value, err := reader.value()
			if err != nil {
				return nil, errors.New("binary row value is invalid")
			}
			rows[rowIndex][column] = value
		}
	}
	if reader.remaining() != 0 {
		return nil, errors.New("binary rows batch has trailing bytes")
	}
	return rows, nil
}

func encodeValue(output *bytes.Buffer, value interface{}) error {
	switch typed := value.(type) {
	case nil:
		output.WriteByte(0)
	case bool:
		output.WriteByte(1)
		if typed {
			output.WriteByte(1)
		} else {
			output.WriteByte(0)
		}
	case json.Number:
		if integer, err := typed.Int64(); err == nil {
			output.WriteByte(2)
			writeInt64(output, integer)
		} else if number, err := typed.Float64(); err == nil {
			output.WriteByte(3)
			writeFloat64(output, number)
		} else {
			return errors.New("invalid numeric value")
		}
	case int:
		output.WriteByte(2)
		writeInt64(output, int64(typed))
	case int8:
		output.WriteByte(2)
		writeInt64(output, int64(typed))
	case int16:
		output.WriteByte(2)
		writeInt64(output, int64(typed))
	case int32:
		output.WriteByte(2)
		writeInt64(output, int64(typed))
	case int64:
		output.WriteByte(2)
		writeInt64(output, typed)
	case uint:
		output.WriteByte(2)
		writeInt64(output, int64(typed))
	case uint8:
		output.WriteByte(2)
		writeInt64(output, int64(typed))
	case uint16:
		output.WriteByte(2)
		writeInt64(output, int64(typed))
	case uint32:
		output.WriteByte(2)
		writeInt64(output, int64(typed))
	case uint64:
		if typed > math.MaxInt64 {
			return errors.New("unsigned numeric value is too large")
		}
		output.WriteByte(2)
		writeInt64(output, int64(typed))
	case float32:
		output.WriteByte(3)
		writeFloat64(output, float64(typed))
	case float64:
		output.WriteByte(3)
		writeFloat64(output, typed)
	case []byte:
		output.WriteByte(5)
		writeBytes(output, typed)
	case string:
		output.WriteByte(4)
		writeString(output, typed)
	default:
		encoded, err := json.Marshal(value)
		if err != nil {
			return errors.New("value is not serializable")
		}
		output.WriteByte(6)
		writeBytes(output, encoded)
	}
	return nil
}

type valueReader struct {
	data   []byte
	offset int
}

func newValueReader(data []byte) *valueReader { return &valueReader{data: data} }
func (reader *valueReader) remaining() int    { return len(reader.data) - reader.offset }

func (reader *valueReader) take(length int) ([]byte, error) {
	if length < 0 || reader.remaining() < length {
		return nil, errors.New("binary value is truncated")
	}
	value := reader.data[reader.offset : reader.offset+length]
	reader.offset += length
	return value, nil
}

func (reader *valueReader) uint16() (uint16, error) {
	value, err := reader.take(2)
	if err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint16(value), nil
}

func (reader *valueReader) uint32() (uint32, error) {
	value, err := reader.take(4)
	if err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint32(value), nil
}

func (reader *valueReader) string16() (string, error) {
	length, err := reader.uint16()
	if err != nil {
		return "", err
	}
	value, err := reader.take(int(length))
	return string(value), err
}

func (reader *valueReader) value() (interface{}, error) {
	tag, err := reader.take(1)
	if err != nil {
		return nil, err
	}
	switch tag[0] {
	case 0:
		return nil, nil
	case 1:
		value, err := reader.take(1)
		return value[0] == 1, err
	case 2:
		value, err := reader.take(8)
		if err != nil {
			return nil, err
		}
		return int64(binary.LittleEndian.Uint64(value)), nil
	case 3:
		value, err := reader.take(8)
		if err != nil {
			return nil, err
		}
		return math.Float64frombits(binary.LittleEndian.Uint64(value)), nil
	case 4, 5, 6:
		length, err := reader.uint32()
		if err != nil {
			return nil, err
		}
		value, err := reader.take(int(length))
		if err != nil {
			return nil, err
		}
		if tag[0] == 4 {
			return string(value), nil
		}
		if tag[0] == 5 {
			return append([]byte(nil), value...), nil
		}
		var decoded interface{}
		if err := json.Unmarshal(value, &decoded); err != nil {
			return nil, err
		}
		return decoded, nil
	default:
		return nil, errors.New("unknown binary value tag")
	}
}

func writeUint16(output *bytes.Buffer, value uint16) {
	var encoded [2]byte
	binary.LittleEndian.PutUint16(encoded[:], value)
	_, _ = output.Write(encoded[:])
}
func writeUint32(output *bytes.Buffer, value uint32) {
	var encoded [4]byte
	binary.LittleEndian.PutUint32(encoded[:], value)
	_, _ = output.Write(encoded[:])
}
func writeBytes(output *bytes.Buffer, value []byte) {
	writeUint32(output, uint32(len(value)))
	_, _ = output.Write(value)
}
func writeString(output *bytes.Buffer, value string) {
	writeUint32(output, uint32(len(value)))
	_, _ = output.WriteString(value)
}
func writeInt64(output *bytes.Buffer, value int64)     { writeUint64(output, uint64(value)) }
func writeFloat64(output *bytes.Buffer, value float64) { writeUint64(output, math.Float64bits(value)) }
func writeUint64(output *bytes.Buffer, value uint64) {
	var encoded [8]byte
	binary.LittleEndian.PutUint64(encoded[:], value)
	_, _ = output.Write(encoded[:])
}
