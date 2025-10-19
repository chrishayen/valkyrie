package valkyrie

import "core:sync"
import "core:thread"
import linux "core:sys/linux"

// WP_Work_Item represents a unit of work for the thread pool and responses from workers
WP_Work_Item :: struct {
	fd:   linux.Fd,
	data: []u8,
	len:  int,
}

// Mutex_Queue is a thread-safe queue protected by a mutex
Mutex_Queue :: struct($T: typeid) {
	items:  [dynamic]T,
	mutex:  sync.Mutex,
}

// Work_Pool struct holds the state for the work pool (mutex-based)
// Generic over handler type for zero-overhead abstraction
Work_Pool :: struct($Handler: typeid) {
	io_to_worker_queue: Mutex_Queue(WP_Work_Item),
	worker_to_io_queue: Mutex_Queue(WP_Work_Item),
	workers:            [dynamic]^thread.Thread,
	handler:            Handler,
	shutdown:           bool,
}

// WP_Worker_Context holds the work pool pointer for worker threads
WP_Worker_Context :: struct($P: typeid) {
	pool: ^Work_Pool(P),
}

// mutex_queue_init initializes a mutex-protected queue
mutex_queue_init :: proc($T: typeid) -> Mutex_Queue(T) {
	q := Mutex_Queue(T){}
	q.items = make([dynamic]T)
	return q
}

// mutex_queue_push adds an item to the queue
mutex_queue_push :: proc(queue: ^Mutex_Queue($T), item: T) {
	sync.mutex_lock(&queue.mutex)
	append(&queue.items, item)
	sync.mutex_unlock(&queue.mutex)
}

// mutex_queue_try_pop removes an item from the queue (non-blocking)
mutex_queue_try_pop :: proc(queue: ^Mutex_Queue($T)) -> (item: T, ok: bool) {
	sync.mutex_lock(&queue.mutex)
	defer sync.mutex_unlock(&queue.mutex)
	
	if len(queue.items) == 0 {
		return {}, false
	}
	
	item = pop(&queue.items)
	return item, true
}

// mutex_queue_is_empty checks if the queue is empty
mutex_queue_is_empty :: proc(queue: ^Mutex_Queue($T)) -> bool {
	sync.mutex_lock(&queue.mutex)
	defer sync.mutex_unlock(&queue.mutex)
	return len(queue.items) == 0
}

// Worker_Context holds the work pool pointer for worker threads
Worker_Context :: struct($P: typeid) {
	pool: ^Work_Pool(P),
}

// work_pool_worker_thread_proc is the worker thread procedure
work_pool_worker_thread_proc :: proc($P: typeid) -> proc(^WP_Worker_Context(P)) {
	worker_proc :: proc(ctx: ^WP_Worker_Context(P)) {
		pool := ctx.pool
		for !pool.shutdown {
			work_item, ok := mutex_queue_try_pop(&pool.io_to_worker_queue)
			if !ok {
				sync.cpu_relax()
				continue
			}

			result := pool.handler.process(&pool.handler, work_item)

			if result.close_connection {
				close_item := WP_Work_Item {
					fd   = work_item.fd,
					data = nil,
					len  = -1,
				}
				mutex_queue_push(&pool.worker_to_io_queue, close_item)
			} else if result.response_data != nil && len(result.response_data) > 0 {
				response_item := WP_Work_Item {
					fd   = work_item.fd,
					data = result.response_data,
					len  = len(result.response_data),
				}
				mutex_queue_push(&pool.worker_to_io_queue, response_item)
			}
		}
	}
	return worker_proc
}

// work_pool_init initializes the work pool with the given number of workers and handler
work_pool_init :: proc(pool: ^Work_Pool($P), num_workers: int, handler: P) {
	pool.io_to_worker_queue = mutex_queue_init(WP_Work_Item)
	pool.worker_to_io_queue = mutex_queue_init(WP_Work_Item)
	pool.handler = handler
	pool.shutdown = false
	pool.workers = make([dynamic]^thread.Thread, num_workers)
	
	worker_fn := work_pool_worker_thread_proc(P)
	for i in 0..<num_workers {
		ctx := new(WP_Worker_Context(P))
		ctx.pool = pool
		pool.workers[i] = thread.create_and_start_with_poly_data(ctx, worker_fn)
	}
}

// work_pool_enqueue_work sends data to worker threads for processing
work_pool_enqueue :: proc(pool: ^Work_Pool($P), client_fd: linux.Fd, data: []u8, len: int) {
	work_item := WP_Work_Item {
		fd   = client_fd,
		data = data,
		len  = len,
	}
	mutex_queue_push(&pool.io_to_worker_queue, work_item)
}

// WP_Drain_Response_Handler is called for each response item drained from the queue
WP_Drain_Response_Handler :: proc(work_item: WP_Work_Item, user_data: rawptr)

// work_pool_drain_responses drains all pending responses from worker threads
work_pool_drain_responses :: proc(pool: ^Work_Pool($P), handler: WP_Drain_Response_Handler, user_data: rawptr) {
	for {
		work_item, ok := mutex_queue_try_pop(&pool.worker_to_io_queue)
		if !ok {
			break
		}
		handler(work_item, user_data)
	}
}

// work_pool_shutdown cleans up the work pool resources
work_pool_shutdown :: proc(pool: ^Work_Pool($P)) {
	pool.shutdown = true
	delete(pool.workers)
	delete(pool.io_to_worker_queue.items)
	delete(pool.worker_to_io_queue.items)
}
