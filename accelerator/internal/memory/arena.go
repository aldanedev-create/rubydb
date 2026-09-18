package memory

type Arena struct {
	blocks [][]byte
	used   int
}

func NewArena(capacity int) *Arena {
	if capacity < 1024 {
		capacity = 1024
	}
	return &Arena{blocks: [][]byte{make([]byte, capacity)}}
}

func (arena *Arena) Bytes(size int) []byte {
	if size < 0 {
		size = 0
	}
	block := arena.blocks[len(arena.blocks)-1]
	if arena.used+size > len(block) {
		capacity := len(block) * 2
		if capacity < size {
			capacity = size
		}
		block = make([]byte, capacity)
		arena.blocks = append(arena.blocks, block)
		arena.used = 0
	}
	start := arena.used
	arena.used += size
	return block[start:arena.used]
}

func (arena *Arena) Reset() {
	if len(arena.blocks) > 1 {
		arena.blocks = arena.blocks[:1]
	}
	arena.used = 0
}

func (arena *Arena) Capacity() int {
	total := 0
	for _, block := range arena.blocks {
		total += len(block)
	}
	return total
}
