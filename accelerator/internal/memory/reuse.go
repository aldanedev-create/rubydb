package memory

type BytesPool struct {
	pool [][]byte
}

func (pool *BytesPool) Get(size int) []byte {
	for index, candidate := range pool.pool {
		if cap(candidate) >= size {
			pool.pool = append(pool.pool[:index], pool.pool[index+1:]...)
			return candidate[:size]
		}
	}
	return make([]byte, size)
}

func (pool *BytesPool) Put(buffer []byte) {
	if buffer == nil {
		return
	}
	pool.pool = append(pool.pool, buffer[:0])
}
