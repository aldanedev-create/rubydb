package wal

import (
	"encoding/binary"
	"hash/crc32"
)

// EncodeRecord provides a versioned physical record format for future WAL
// batching. Ruby remains responsible for LSN allocation and commit ordering.
// Layout: magic(4), version(1), kind(1), LSN(8), transaction(8), length(4),
// payload, CRC32(4).
var recordMagic = [4]byte{'R', 'D', 'W', 'L'}

func EncodeRecord(kind byte, lsn, transaction uint64, payload []byte) []byte {
	const headerSize = 26
	output := make([]byte, headerSize+len(payload)+4)
	copy(output[:4], recordMagic[:])
	output[4] = 1
	output[5] = kind
	binary.LittleEndian.PutUint64(output[6:14], lsn)
	binary.LittleEndian.PutUint64(output[14:22], transaction)
	binary.LittleEndian.PutUint32(output[22:26], uint32(len(payload)))
	copy(output[26:], payload)
	checksum := crc32.ChecksumIEEE(output[:26+len(payload)])
	binary.LittleEndian.PutUint32(output[26+len(payload):], checksum)
	return output
}

func VerifyRecord(record []byte) bool {
	if len(record) < 30 || string(record[:4]) != string(recordMagic[:]) || record[4] != 1 {
		return false
	}
	length := int(binary.LittleEndian.Uint32(record[22:26]))
	if length < 0 || len(record) != 30+length {
		return false
	}
	want := binary.LittleEndian.Uint32(record[len(record)-4:])
	got := crc32.ChecksumIEEE(record[:len(record)-4])
	return got == want
}
