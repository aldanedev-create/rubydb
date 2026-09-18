package wal

import "sync"

// Batch collects approved WAL payloads before Ruby assigns the durable LSN.
// It does not perform fsync or publish commits; those remain RubyDB rules.
type Batch struct {
	mu      sync.Mutex
	payload [][]byte
}

func (batch *Batch) Add(payload []byte) {
	batch.mu.Lock()
	defer batch.mu.Unlock()
	batch.payload = append(batch.payload, append([]byte(nil), payload...))
}

func (batch *Batch) Drain() [][]byte {
	batch.mu.Lock()
	defer batch.mu.Unlock()
	payload := batch.payload
	batch.payload = nil
	return payload
}
