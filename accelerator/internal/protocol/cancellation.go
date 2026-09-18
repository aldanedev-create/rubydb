package protocol

import (
	"context"
	"sync"
)

// CancellationRegistry gives the runtime a bounded, request-scoped context
// registry. A future multiplexed transport can cancel a running request by
// ID without changing the physical execution APIs.
type CancellationRegistry struct {
	mu      sync.Mutex
	entries map[string]context.CancelFunc
}

func NewCancellationRegistry() *CancellationRegistry {
	return &CancellationRegistry{entries: make(map[string]context.CancelFunc)}
}

func (registry *CancellationRegistry) Begin(parent context.Context, id string) context.Context {
	ctx, cancel := context.WithCancel(parent)
	registry.mu.Lock()
	if previous, exists := registry.entries[id]; exists {
		previous()
	}
	registry.entries[id] = cancel
	registry.mu.Unlock()
	return ctx
}

func (registry *CancellationRegistry) Cancel(id string) bool {
	registry.mu.Lock()
	cancel, exists := registry.entries[id]
	if exists {
		delete(registry.entries, id)
	}
	registry.mu.Unlock()
	if exists {
		cancel()
	}
	return exists
}

func (registry *CancellationRegistry) Finish(id string) {
	registry.mu.Lock()
	delete(registry.entries, id)
	registry.mu.Unlock()
}
