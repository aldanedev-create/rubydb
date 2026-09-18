package memory

import "testing"

func TestArenaReusesInitialBlockAfterReset(t *testing.T) {
	arena := NewArena(1024)
	first := arena.Bytes(32)
	first[0] = 7
	arena.Bytes(64)
	arena.Reset()
	if arena.Capacity() != 1024 {
		t.Fatalf("capacity grew after reset: %d", arena.Capacity())
	}
	buffer := arena.Bytes(1)
	buffer[0] = 0
}
