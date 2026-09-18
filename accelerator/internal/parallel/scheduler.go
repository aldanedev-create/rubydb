package parallel

import (
	"runtime"
	"sync"
)

func ChunkCount(items int) int {
	if items <= 0 {
		return 0
	}
	workers := runtime.GOMAXPROCS(0)
	if workers < 2 {
		workers = 2
	}
	if workers > items {
		workers = items
	}
	return workers
}

// ForEachChunk preserves result order by giving each callback a stable index.
// The caller owns result storage; callbacks must only write their own index.
func ForEachChunk(items int, callback func(index, start, end int)) {
	workers := ChunkCount(items)
	if workers == 0 {
		return
	}
	chunkSize := (items + workers - 1) / workers
	var wait sync.WaitGroup
	for index := 0; index < workers; index++ {
		start := index * chunkSize
		end := start + chunkSize
		if end > items {
			end = items
		}
		if start >= end {
			continue
		}
		wait.Add(1)
		go func(index, start, end int) {
			defer wait.Done()
			callback(index, start, end)
		}(index, start, end)
	}
	wait.Wait()
}
