package sourcehistory

import "context"

// Only non-secret identifiers are stored, scoped to a local network and node.
type Entry struct{ Network, Source, Node string }
type History []Entry

func (h History) Last(network string) Entry {
	for _, e := range h {
		if network != "" && e.Network == network {
			return e
		}
	}
	return Entry{}
}
func (h History) With(e Entry) History {
	if e.Network == "" || e.Source == "" || e.Node == "" || h.Last(e.Network) == e {
		return h
	}
	out := History{e}
	for _, v := range h {
		if v.Network != e.Network && len(out) < 12 {
			out = append(out, v)
		}
	}
	return out
}

// Visit each completed probe immediately on the caller goroutine. Dispatch and
// result collection stay bounded even when a slow source heads the saved list.
func Race[T, R any](ctx context.Context, candidates []T, workers int, probe func(context.Context, T) R, visit func(T, R)) {
	type result struct {
		candidate T
		value     R
	}
	jobs := make(chan T, len(candidates))
	for _, c := range candidates {
		jobs <- c
	}
	close(jobs)
	results := make(chan result, workers)
	done := make(chan struct{}, workers)
	count := min(workers, len(candidates))
	for i := 0; i < count; i++ {
		go func() {
			defer func() { done <- struct{}{} }()
			for c := range jobs {
				if ctx.Err() != nil {
					return
				}
				r := probe(ctx, c)
				select {
				case results <- result{c, r}:
				case <-ctx.Done():
					return
				}
			}
		}()
	}
	// A worker can only finish after sending every result. Drain all buffered
	// results once the last worker is done.
	for count > 0 {
		select {
		case r := <-results:
			if ctx.Err() == nil {
				visit(r.candidate, r.value)
			}
		case <-done:
			count--
		}
	}
	close(results)
	for r := range results {
		if ctx.Err() == nil {
			visit(r.candidate, r.value)
		}
	}
}
