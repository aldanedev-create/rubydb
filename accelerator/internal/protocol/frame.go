package protocol

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

const (
	Version       = 1
	BinaryVersion = 1
	MaxFrameSize  = 16 * 1024 * 1024

	BinaryRequestKind      byte = 1
	BinaryResponseKind     byte = 2
	BinaryRowsType         byte = 1
	BinaryJoinType         byte = 2
	BinarySnapshotScanType byte = 3
)

var BinaryMagic = []byte("RDBB")

var ErrFrameTooLarge = errors.New("frame too large")

type BinaryFrame struct {
	Kind    byte
	TypeID  byte
	Status  byte
	ID      string
	Payload []byte
}

func ReadMessage(reader *bufio.Reader) (*BinaryFrame, []byte, error) {
	prefix, err := reader.Peek(len(BinaryMagic))
	if err != nil {
		return nil, nil, err
	}
	if bytes.Equal(prefix, BinaryMagic) {
		frame, err := ReadBinaryFrame(reader)
		return frame, nil, err
	}
	frame, err := ReadFrame(reader)
	return nil, frame, err
}

func ReadBinaryFrame(reader *bufio.Reader) (*BinaryFrame, error) {
	header := make([]byte, 14)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil, err
	}
	if !bytes.Equal(header[:4], BinaryMagic) || header[4] != BinaryVersion {
		return nil, errors.New("invalid binary frame")
	}
	idLength := int(binaryLittleEndian16(header[8:10]))
	payloadLength := int(binaryLittleEndian32(header[10:14]))
	if payloadLength > MaxFrameSize || idLength > 1024 || payloadLength+idLength > MaxFrameSize {
		return nil, ErrFrameTooLarge
	}
	body := make([]byte, idLength+payloadLength)
	if _, err := io.ReadFull(reader, body); err != nil {
		return nil, err
	}
	return &BinaryFrame{
		Kind:    header[5],
		TypeID:  header[6],
		Status:  header[7],
		ID:      string(body[:idLength]),
		Payload: body[idLength:],
	}, nil
}

func WriteBinaryResponse(writer *bufio.Writer, requestFrame BinaryFrame, payload []byte, message, code string) error {
	status := byte(0)
	if message != "" {
		status = 1
		payload = MustJSON(map[string]string{"error": message, "code": code})
	}
	if len(requestFrame.ID) > 1024 || len(payload)+len(requestFrame.ID) > MaxFrameSize {
		return ErrFrameTooLarge
	}
	header := make([]byte, 14)
	copy(header[:4], BinaryMagic)
	header[4] = BinaryVersion
	header[5] = BinaryResponseKind
	header[6] = requestFrame.TypeID
	header[7] = status
	putBinaryLittleEndian16(header[8:10], uint16(len(requestFrame.ID)))
	putBinaryLittleEndian32(header[10:14], uint32(len(payload)))
	if _, err := writer.Write(header); err != nil {
		return err
	}
	if _, err := writer.WriteString(requestFrame.ID); err != nil {
		return err
	}
	if _, err := writer.Write(payload); err != nil {
		return err
	}
	return writer.Flush()
}

func ReadFrame(reader *bufio.Reader) ([]byte, error) {
	frame := make([]byte, 0, 1024)
	for {
		chunk, err := reader.ReadSlice('\n')
		if len(frame)+len(chunk) > MaxFrameSize {
			return nil, ErrFrameTooLarge
		}
		frame = append(frame, chunk...)
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil {
			return nil, err
		}
		return frame, nil
	}
}

func WriteJSONResponse(writer *bufio.Writer, value interface{}) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(data)+1 > MaxFrameSize {
		return fmt.Errorf("response exceeds maximum frame size")
	}
	if _, err = writer.Write(append(data, '\n')); err != nil {
		return err
	}
	return writer.Flush()
}

func MustJSON(value interface{}) []byte {
	data, _ := json.Marshal(value)
	return data
}

type Reader struct {
	data   []byte
	offset int
}

func NewReader(data []byte) *Reader { return &Reader{data: data} }

func (reader *Reader) Remaining() int { return len(reader.data) - reader.offset }

func (reader *Reader) Bytes() []byte { return reader.data[reader.offset:] }

func (reader *Reader) Take(length int) ([]byte, error) {
	if length < 0 || reader.Remaining() < length {
		return nil, errors.New("binary value is truncated")
	}
	value := reader.data[reader.offset : reader.offset+length]
	reader.offset += length
	return value, nil
}

func (reader *Reader) Uint32() (uint32, error) {
	value, err := reader.Take(4)
	if err != nil {
		return 0, err
	}
	return binaryLittleEndian32(value), nil
}

func binaryLittleEndian16(data []byte) uint16 {
	return uint16(data[0]) | uint16(data[1])<<8
}

func binaryLittleEndian32(data []byte) uint32 {
	return uint32(data[0]) | uint32(data[1])<<8 | uint32(data[2])<<16 | uint32(data[3])<<24
}

func putBinaryLittleEndian16(data []byte, value uint16) {
	data[0] = byte(value)
	data[1] = byte(value >> 8)
}

func putBinaryLittleEndian32(data []byte, value uint32) {
	data[0] = byte(value)
	data[1] = byte(value >> 8)
	data[2] = byte(value >> 16)
	data[3] = byte(value >> 24)
}
