package parallel

import (
	"context"
	"errors"
)

var ErrQueueClosed = errors.New("bounded queue is closed")

type BoundedQueue[T any] struct {
	items  chan T
	closed chan struct{}
}

func NewBoundedQueue[T any](capacity int) *BoundedQueue[T] {
	if capacity < 1 {
		capacity = 1
	}
	return &BoundedQueue[T]{items: make(chan T, capacity), closed: make(chan struct{})}
}

func (queue *BoundedQueue[T]) Push(ctx context.Context, item T) error {
	select {
	case <-queue.closed:
		return ErrQueueClosed
	case <-ctx.Done():
		return ctx.Err()
	case queue.items <- item:
		return nil
	}
}

func (queue *BoundedQueue[T]) Pop(ctx context.Context) (T, error) {
	var zero T
	select {
	case item := <-queue.items:
		return item, nil
	case <-queue.closed:
		select {
		case item := <-queue.items:
			return item, nil
		default:
			return zero, ErrQueueClosed
		}
	case <-ctx.Done():
		return zero, ctx.Err()
	}
}

func (queue *BoundedQueue[T]) Close() {
	select {
	case <-queue.closed:
	default:
		close(queue.closed)
	}
}
