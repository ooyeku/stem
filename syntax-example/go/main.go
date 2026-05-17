// Goroutine producer/consumer. Run with: go run main.go
package main

import (
	"fmt"
	"sync"
	"time"
)

type Job struct {
	ID   int
	Data string
}

func producer(ch chan<- Job, n int) {
	defer close(ch)
	for i := 1; i <= n; i++ {
		ch <- Job{ID: i, Data: fmt.Sprintf("payload-%d", i)}
		time.Sleep(5 * time.Millisecond)
	}
}

func consumer(id int, ch <-chan Job, wg *sync.WaitGroup) {
	defer wg.Done()
	for job := range ch {
		fmt.Printf("[worker %d] processed job %d (%s)\n", id, job.ID, job.Data)
	}
}

func main() {
	const workers = 3
	jobs := make(chan Job, 4)
	var wg sync.WaitGroup

	for w := 1; w <= workers; w++ {
		wg.Add(1)
		go consumer(w, jobs, &wg)
	}

	producer(jobs, 8)
	wg.Wait()
	fmt.Println("done")
}
