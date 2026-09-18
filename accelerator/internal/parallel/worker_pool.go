package parallel

import (
	"context"
	"sync"
)

type WorkerPool struct {
	queue  *BoundedQueue[func()]
	wait   sync.WaitGroup
	closed chan struct{}
}

func NewWorkerPool(workers, queueSize int) *WorkerPool {
	if workers < 1 {
		workers = 1
	}
	pool := &WorkerPool{queue: NewBoundedQueue[func()](queueSize), closed: make(chan struct{})}
	for index := 0; index < workers; index++ {
		pool.wait.Add(1)
		go func() {
			defer pool.wait.Done()
			for {
				job, err := pool.queue.Pop(context.Background())
				if err != nil {
					return
				}
				job()
			}
		}()
	}
	return pool
}

func (pool *WorkerPool) Submit(ctx context.Context, job func()) error {
	select {
	case <-pool.closed:
		return ErrQueueClosed
	default:
	}
	return pool.queue.Push(ctx, job)
}

func (pool *WorkerPool) Close() {
	select {
	case <-pool.closed:
		return
	default:
		close(pool.closed)
		pool.queue.Close()
		pool.wait.Wait()
	}
}
