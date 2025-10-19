package valkyrie

import "core:sync"
import "core:thread"
import linux "core:sys/linux"

// Processor_Work_Item represents a unit of work for the thread pool and responses from workers
Processor_Work_Item :: struct {
	fd:   linux.Fd,
	data: []u8,
	len:  int,
}

// Work_Result tells the processor what to do with the result of processing
Work_Result :: struct {
	response_data:    []u8,
	close_connection: bool,
}

// Lockless SPMC Queue (Single Producer, Multiple Consumers)
Processor_Lockless_Queue :: struct($T: typeid, $N: int) {
	items: [N]T,
	head:  u32, // Consumer index
	tail:  u32, // Producer index
}

// Processor struct holds the state for the work processor
// Generic over handler type for zero-overhead abstraction
Processor :: struct($Handler: typeid, $QueueSize: int = 4096) {
	io_to_worker_queue: Processor_Lockless_Queue(Processor_Work_Item, QueueSize),
	worker_to_io_queue: Processor_Lockless_Queue(Processor_Work_Item, QueueSize),
	workers:            [dynamic]^thread.Thread,
	handler:            Handler,
	shutdown:           bool,
}

// processor_lockless_queue_init initializes a lockless SPMC queue
processor_lockless_queue_init :: proc($T: typeid, $N: int) -> Processor_Lockless_Queue(T, N) {
	return Processor_Lockless_Queue(T, N){}
}

// processor_lockless_queue_is_full checks if the queue is full
processor_lockless_queue_is_full :: proc(queue: ^Processor_Lockless_Queue($T, $N)) -> bool {
	head := sync.atomic_load(&queue.head)
	tail := sync.atomic_load(&queue.tail)
	return (tail + 1) % u32(N) == head
}

// processor_lockless_queue_is_empty checks if the queue is empty
processor_lockless_queue_is_empty :: proc(queue: ^Processor_Lockless_Queue($T, $N)) -> bool {
	head := sync.atomic_load(&queue.head)
	tail := sync.atomic_load(&queue.tail)
	return head == tail
}

// processor_lockless_queue_push adds an item to the queue (producer side, single producer)
processor_lockless_queue_push :: proc(queue: ^Processor_Lockless_Queue($T, $N), item: T) -> bool {
	tail := sync.atomic_load(&queue.tail)
	head := sync.atomic_load(&queue.head)

	if (tail + 1) % u32(N) == head {
		return false // Full
	}

	queue.items[tail] = item
	sync.atomic_thread_fence(.Release) // Ensure item write is visible before tail update
	sync.atomic_store(&queue.tail, (tail + 1) % u32(N))
	return true
}

// processor_lockless_queue_try_pop removes an item from the queue (consumer side, multiple consumers)
processor_lockless_queue_try_pop :: proc(queue: ^Processor_Lockless_Queue($T, $N)) -> (item: T, ok: bool) {
	for {
		head := sync.atomic_load(&queue.head)
		tail := sync.atomic_load(&queue.tail)

		if head == tail {
			return {}, false
		}

		new_head := (head + 1) % u32(N)

		_, swapped := sync.atomic_compare_exchange_weak(&queue.head, head, new_head)
		if swapped {
			sync.atomic_thread_fence(.Acquire) // Ensure we see the latest item data
			item = queue.items[head]
			return item, true
		}
	}
}

// Processor_Worker_Context holds the processor pointer for worker threads
Processor_Worker_Context :: struct($P: typeid, $QueueSize: int) {
	processor: ^Processor(P, QueueSize),
}

// processor_worker_thread_proc is the worker thread procedure
processor_worker_thread_proc :: proc($P: typeid, $QueueSize: int) -> proc(^Processor_Worker_Context(P, QueueSize)) {
	worker_proc :: proc(ctx: ^Processor_Worker_Context(P, QueueSize)) {
		p := ctx.processor
		for !sync.atomic_load(&p.shutdown) {
			work_item, ok := processor_lockless_queue_try_pop(&p.io_to_worker_queue)
			if !ok {
				sync.cpu_relax()
				continue
			}

			result := p.handler.process(&p.handler, work_item)

			if result.close_connection {
				close_item := Processor_Work_Item {
					fd   = work_item.fd,
					data = nil,
					len  = -1,
				}
				processor_lockless_queue_push(&p.worker_to_io_queue, close_item)
			} else if result.response_data != nil && len(result.response_data) > 0 {
				response_item := Processor_Work_Item {
					fd   = work_item.fd,
					data = result.response_data,
					len  = len(result.response_data),
				}
				processor_lockless_queue_push(&p.worker_to_io_queue, response_item)
			}
		}
	}
	return worker_proc
}

// processor_init initializes the processor with the given number of workers and handler
processor_init :: proc(p: ^Processor($P, $QueueSize), num_workers: int, handler: P) {
	p.io_to_worker_queue = processor_lockless_queue_init(Processor_Work_Item, QueueSize)
	p.worker_to_io_queue = processor_lockless_queue_init(Processor_Work_Item, QueueSize)
	p.handler = handler
	sync.atomic_store(&p.shutdown, false)
	p.workers = make([dynamic]^thread.Thread, num_workers)

	worker_fn := processor_worker_thread_proc(P, QueueSize)
	for i in 0..<num_workers {
		ctx := new(Processor_Worker_Context(P, QueueSize))
		ctx.processor = p
		p.workers[i] = thread.create_and_start_with_poly_data(ctx, worker_fn)
	}
}

// processor_enqueue_work sends data to worker threads for processing
processor_enqueue_work :: proc(p: ^Processor($P, $QueueSize), client_fd: linux.Fd, data: []u8, len: int) {
	work_item := Processor_Work_Item {
		fd   = client_fd,
		data = data,
		len  = len,
	}
	if !processor_lockless_queue_push(&p.io_to_worker_queue, work_item) {
		delete(data)
	}
}

// Drain_Response_Handler is called for each response item drained from the queue
// User provides this to handle connection cleanup, writing, etc.
Drain_Response_Handler :: proc(work_item: Processor_Work_Item, user_data: rawptr)

// processor_drain_responses drains all pending responses from worker threads
// Calls handler for each response item (close signal or data to write)
processor_drain_responses :: proc(p: ^Processor($P, $QueueSize), handler: Drain_Response_Handler, user_data: rawptr) {
	for {
		work_item, ok := processor_lockless_queue_try_pop(&p.worker_to_io_queue)
		if !ok {
			break
		}
		handler(work_item, user_data)
	}
}

// processor_shutdown cleans up the processor resources
processor_shutdown :: proc(p: ^Processor($P, $QueueSize)) {
	sync.atomic_store(&p.shutdown, true)
	for worker in p.workers {
		thread.join(worker)
	}
	delete(p.workers)
}