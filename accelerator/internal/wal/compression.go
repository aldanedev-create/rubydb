package wal

import (
	"bytes"
	"compress/gzip"
	"io"
)

func Gzip(data []byte, level int) ([]byte, error) {
	var output bytes.Buffer
	writer, err := gzip.NewWriterLevel(&output, level)
	if err != nil {
		return nil, err
	}
	if _, err = writer.Write(data); err == nil {
		err = writer.Close()
	}
	if err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

func Gunzip(data []byte, maxOutput int) ([]byte, error) {
	reader, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	output, readErr := io.ReadAll(io.LimitReader(reader, int64(maxOutput)+1))
	closeErr := reader.Close()
	if readErr != nil {
		return nil, readErr
	}
	if len(output) > maxOutput {
		return nil, io.ErrShortBuffer
	}
	if closeErr != nil {
		return nil, closeErr
	}
	return output, nil
}
