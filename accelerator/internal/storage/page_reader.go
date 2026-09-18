package storage

import (
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"sync"
)

var ErrInvalidPage = errors.New("invalid storage page")

type Snapshot struct {
	ID       uint64
	PageSize int
	MaxPages uint64
}

type Page struct {
	Number uint64
	Data   []byte
	Digest [32]byte
}

type Reader struct {
	input io.ReaderAt
	cache sync.Map
}

func NewReader(input io.ReaderAt) *Reader { return &Reader{input: input} }

// ReadBatch reads immutable pages for a snapshot. The caller must provide a
// snapshot validated by RubyDB; this package never reads catalog or WAL state.
func (reader *Reader) ReadBatch(ctx context.Context, snapshot Snapshot, pageNumbers []uint64) ([]Page, error) {
	if snapshot.PageSize <= 0 || snapshot.MaxPages == 0 || uint64(snapshot.PageSize) > 64*1024*1024 {
		return nil, ErrInvalidPage
	}
	result := make([]Page, len(pageNumbers))
	var wait sync.WaitGroup
	var firstErr error
	var errMu sync.Mutex
	for index, number := range pageNumbers {
		if number >= snapshot.MaxPages {
			return nil, ErrInvalidPage
		}
		wait.Add(1)
		go func(index int, number uint64) {
			defer wait.Done()
			select {
			case <-ctx.Done():
				errMu.Lock()
				if firstErr == nil {
					firstErr = ctx.Err()
				}
				errMu.Unlock()
				return
			default:
			}
			data := make([]byte, snapshot.PageSize)
			read, err := reader.input.ReadAt(data, int64(number)*int64(snapshot.PageSize))
			if read != snapshot.PageSize || (err != nil && err != io.EOF) {
				errMu.Lock()
				if firstErr == nil {
					if err != nil {
						firstErr = err
					} else {
						firstErr = ErrInvalidPage
					}
				}
				errMu.Unlock()
				return
			}
			result[index] = Page{Number: number, Data: data, Digest: sha256.Sum256(data)}
		}(index, number)
	}
	wait.Wait()
	if firstErr != nil {
		return nil, firstErr
	}
	return result, nil
}
