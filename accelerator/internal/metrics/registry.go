package metrics

import (
	"sync"
	"time"
)

type Sample struct {
	Count int64   `json:"count"`
	Total float64 `json:"total_ms"`
	P50   float64 `json:"p50_ms"`
	P95   float64 `json:"p95_ms"`
	P99   float64 `json:"p99_ms"`
}

type Registry struct {
	mu      sync.Mutex
	counts  map[string]int64
	totals  map[string]float64
	samples map[string][]float64
}

func NewRegistry() *Registry {
	return &Registry{counts: map[string]int64{}, totals: map[string]float64{}, samples: map[string][]float64{}}
}

func (registry *Registry) Observe(operation string, duration time.Duration) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	ms := float64(duration) / float64(time.Millisecond)
	registry.counts[operation]++
	registry.totals[operation] += ms
	values := registry.samples[operation]
	if len(values) >= 1024 {
		copy(values, values[1:])
		values = values[:1023]
	}
	registry.samples[operation] = append(values, ms)
}

func (registry *Registry) Snapshot() map[string]Sample {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	result := make(map[string]Sample, len(registry.counts))
	for operation, count := range registry.counts {
		values := append([]float64(nil), registry.samples[operation]...)
		for index := 1; index < len(values); index++ {
			value := values[index]
			position := index - 1
			for position >= 0 && values[position] > value {
				values[position+1] = values[position]
				position--
			}
			values[position+1] = value
		}
		p50, p95, p99 := float64(0), float64(0), float64(0)
		if len(values) > 0 {
			p50 = values[int(float64(len(values)-1)*0.50)]
			position := int(float64(len(values)-1) * 0.95)
			p95 = values[position]
			position = int(float64(len(values)-1) * 0.99)
			p99 = values[position]
		}
		result[operation] = Sample{Count: count, Total: registry.totals[operation], P50: p50, P95: p95, P99: p99}
	}
	return result
}
