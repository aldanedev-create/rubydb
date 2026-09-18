package parallel

import (
	"context"
	"testing"
)

func TestForEachChunkCoversEveryItem(t *testing.T) {
	seen := make([]bool, 37)
	ForEachChunk(len(seen), func(_, start, end int) {
		for index := start; index < end; index++ {
			seen[index] = true
		}
	})
	for index, value := range seen {
		if !value {
			t.Fatalf("item %d was not visited", index)
		}
	}
}

func TestBoundedQueueHonorsCancellation(t *testing.T) {
	queue := NewBoundedQueue[int](1)
	defer queue.Close()
	if err := queue.Push(context.Background(), 1); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := queue.Push(ctx, 2); err == nil {
		t.Fatal("expected canceled push")
	}
}
