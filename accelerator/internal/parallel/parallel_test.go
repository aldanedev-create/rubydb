package parallel

import "testing"

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
