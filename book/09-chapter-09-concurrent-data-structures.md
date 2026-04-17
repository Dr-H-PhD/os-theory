# Chapter 9: Concurrent Data Structures

*"A lock-free algorithm guarantees system-wide progress; a wait-free algorithm guarantees per-thread progress. The gap between these two guarantees is where most of the difficulty lies."* --- Maurice Herlihy

---

The synchronisation primitives of Chapter 7 and the deadlock theory of Chapter 8 give us the tools and understanding to build concurrent programs. But tools alone are not enough: the way we compose them into data structures determines the performance, scalability, and correctness of concurrent systems. A naively locked hash table that serialises every operation is correct but may be slower than a single-threaded version due to lock contention and cache-line bouncing.

This chapter develops the theory and practice of concurrent data structures. We begin with lock-based designs that improve on coarse-grained locking, then advance to lock-free and wait-free algorithms that eliminate locks entirely. We formalise correctness through linearisability, examine the memory ordering guarantees that underpin these algorithms, and study the memory reclamation problem that arises when pointers are accessed concurrently.

---

## 9.1 Lock-Based Data Structures

### 9.1.1 Coarse-Grained Locking

The simplest approach to making a data structure thread-safe is to protect it with a single lock:

```c
#include <pthread.h>
#include <stdlib.h>

typedef struct node {
    int key;
    struct node *next;
} node_t;

typedef struct {
    node_t *head;
    pthread_mutex_t lock;
} list_t;

void list_init(list_t *l) {
    l->head = NULL;
    pthread_mutex_init(&l->lock, NULL);
}

int list_insert(list_t *l, int key) {
    pthread_mutex_lock(&l->lock);
    node_t *new_node = malloc(sizeof(node_t));
    if (!new_node) {
        pthread_mutex_unlock(&l->lock);
        return -1;
    }
    new_node->key = key;
    new_node->next = l->head;
    l->head = new_node;
    pthread_mutex_unlock(&l->lock);
    return 0;
}

int list_contains(list_t *l, int key) {
    pthread_mutex_lock(&l->lock);
    node_t *curr = l->head;
    while (curr) {
        if (curr->key == key) {
            pthread_mutex_unlock(&l->lock);
            return 1;
        }
        curr = curr->next;
    }
    pthread_mutex_unlock(&l->lock);
    return 0;
}
```

This is correct and simple, but all operations are serialised. If 32 threads perform lookups on a 10,000-element list, only one thread traverses the list at any time. The throughput is no better than single-threaded --- and worse, due to lock acquisition overhead.

::: definition
**Definition 9.0b (Throughput and Scalability).** The **throughput** of a concurrent data structure is the number of completed operations per unit time. **Scalability** measures how throughput changes as the number of threads increases. A perfectly scalable structure achieves linear speedup: $p$ threads provide $p$ times the throughput of one thread. In practice, contention, cache effects, and synchronisation overhead cause throughput to plateau or even decrease beyond a certain number of threads.
:::

### 9.1.2 Fine-Grained Locking

Fine-grained locking assigns a separate lock to each node (or to each region of the data structure), allowing multiple threads to operate on different parts simultaneously.

::: definition
**Definition 9.1 (Fine-Grained Locking).** A fine-grained locking strategy associates a lock with each independently accessible portion of a data structure. Threads acquire only the locks protecting the portions they access, allowing disjoint operations to proceed in parallel.
:::

For a linked list, the natural granularity is per-node locking:

```c
typedef struct node {
    int key;
    struct node *next;
    pthread_mutex_t lock;
} node_t;

typedef struct {
    node_t *head;  /* sentinel node, always present */
} list_t;

void list_init(list_t *l) {
    l->head = malloc(sizeof(node_t));
    l->head->key = -1;  /* sentinel */
    l->head->next = NULL;
    pthread_mutex_init(&l->head->lock, NULL);
}
```

### 9.1.3 Hand-Over-Hand Locking (Lock Coupling)

::: definition
**Definition 9.2 (Hand-Over-Hand Locking).** Hand-over-hand locking (also called lock coupling) is a traversal strategy for linked structures where a thread holds the lock on the current node while acquiring the lock on the next node, then releases the current node's lock. At any point, the thread holds at most two locks.
:::

```c
int list_contains_hoh(list_t *l, int key) {
    node_t *prev = l->head;
    pthread_mutex_lock(&prev->lock);
    node_t *curr = prev->next;

    while (curr != NULL) {
        pthread_mutex_lock(&curr->lock);
        if (curr->key == key) {
            pthread_mutex_unlock(&curr->lock);
            pthread_mutex_unlock(&prev->lock);
            return 1;
        }
        if (curr->key > key) {
            /* list is sorted: key not present */
            pthread_mutex_unlock(&curr->lock);
            pthread_mutex_unlock(&prev->lock);
            return 0;
        }
        pthread_mutex_unlock(&prev->lock);
        prev = curr;
        curr = curr->next;
    }

    pthread_mutex_unlock(&prev->lock);
    return 0;
}

int list_insert_hoh(list_t *l, int key) {
    node_t *prev = l->head;
    pthread_mutex_lock(&prev->lock);
    node_t *curr = prev->next;

    while (curr != NULL) {
        pthread_mutex_lock(&curr->lock);
        if (curr->key == key) {
            /* already present */
            pthread_mutex_unlock(&curr->lock);
            pthread_mutex_unlock(&prev->lock);
            return 0;
        }
        if (curr->key > key)
            break;  /* insert between prev and curr */
        pthread_mutex_unlock(&prev->lock);
        prev = curr;
        curr = curr->next;
    }

    node_t *new_node = malloc(sizeof(node_t));
    new_node->key = key;
    new_node->next = curr;
    pthread_mutex_init(&new_node->lock, NULL);
    prev->next = new_node;

    if (curr) pthread_mutex_unlock(&curr->lock);
    pthread_mutex_unlock(&prev->lock);
    return 1;
}
```

Hand-over-hand locking allows multiple threads to traverse the list simultaneously, provided they are at different positions. Thread A can be at node 5 while Thread B is at node 50.

::: example
**Example 9.1 (Concurrency in Hand-Over-Hand Locking).** Consider a sorted linked list with nodes $[1, 5, 10, 20, 50, 100]$. Thread A searches for 50 and Thread B inserts 15:

```text
Time 1: A locks sentinel, B locks sentinel          (conflict!)
Time 2: A locks node(1), unlocks sentinel
         B locks node(1), unlocks sentinel           (A has moved on)
Time 3: A locks node(5), unlocks node(1)
         B locks node(5), unlocks node(1)
Time 4: A locks node(10), unlocks node(5)
         B locks node(10), unlocks node(5)
Time 5: A locks node(20), unlocks node(10)
         B inserts 15 between node(10) and node(20)   (B is done)
Time 6: A locks node(50), unlocks node(20)
         A finds 50. Done.
```

The two threads operate concurrently once they separate in the list. The key invariant is that a thread always holds the lock on its current position, preventing another thread from modifying that node.
:::

**Performance trade-off**: fine-grained locking adds overhead (one lock per node) and complexity (lock ordering to prevent deadlock). For short lists, the overhead exceeds the benefit. For long lists with many concurrent operations on different regions, fine-grained locking provides significant speedups.

::: theorem
**Theorem 9.0b (Amdahl's Law for Concurrent Data Structures).** If a fraction $f$ of operations on a data structure can proceed concurrently and the remaining fraction $1 - f$ must be serialised, the maximum speedup with $p$ threads is:

$$S(p) = \frac{1}{(1 - f) + f/p}$$

For a coarse-grained locked list, $f = 0$ (all operations serialised), so $S(p) = 1$ regardless of $p$. For a hand-over-hand locked list with uniform access patterns, $f \approx 1 - 1/L$ where $L$ is the list length (the serialised fraction is the probability that two threads access the same node simultaneously).
:::

::: example
**Example 9.1b (Scalability Comparison).** Measured throughput for a sorted linked list with 10,000 elements, 80% lookups, 10% inserts, 10% deletes:

| Threads | Coarse-grained | Hand-over-hand | Optimistic | Lock-free |
|---------|---------------|----------------|-----------|-----------|
| 1 | 1.0x | 0.8x | 0.7x | 0.9x |
| 2 | 0.9x | 1.4x | 1.5x | 1.7x |
| 4 | 0.8x | 2.1x | 2.8x | 3.2x |
| 8 | 0.7x | 2.5x | 4.1x | 5.8x |
| 16 | 0.6x | 2.3x | 5.2x | 8.1x |

(Throughput relative to single-threaded coarse-grained baseline.)

Key observations: coarse-grained locking degrades beyond 1 thread due to lock contention. Hand-over-hand locking improves but plateaus at 8 threads (lock coupling overhead limits scalability). Optimistic and lock-free approaches scale better because they minimise the time locks are held (or eliminate locks entirely).
:::

### 9.1.4 Optimistic Locking

::: definition
**Definition 9.3 (Optimistic Locking).** In optimistic locking, a thread traverses the data structure without holding any locks, then acquires locks on the relevant nodes and validates that the structure has not changed during the traversal. If validation fails, the thread retries.
:::

This reduces lock hold times: locks are held only during the (short) modification phase, not during the (potentially long) traversal phase. The trade-off is the cost of validation and the possibility of retries under contention.

```c
int list_contains_optimistic(list_t *l, int key) {
    while (1) {
        /* Phase 1: lock-free traversal */
        node_t *prev = l->head;
        node_t *curr = prev->next;
        while (curr != NULL && curr->key < key) {
            prev = curr;
            curr = curr->next;
        }

        /* Phase 2: lock and validate */
        pthread_mutex_lock(&prev->lock);
        if (curr) pthread_mutex_lock(&curr->lock);

        if (validate(l, prev, curr)) {
            int found = (curr != NULL && curr->key == key);
            if (curr) pthread_mutex_unlock(&curr->lock);
            pthread_mutex_unlock(&prev->lock);
            return found;
        }

        /* Validation failed: retry */
        if (curr) pthread_mutex_unlock(&curr->lock);
        pthread_mutex_unlock(&prev->lock);
    }
}
```

The validation function checks that `prev` is still reachable from the head and that `prev->next` still points to `curr`.

---

## 9.2 Lock-Free Programming

### 9.2.1 Progress Guarantees

::: definition
**Definition 9.4 (Progress Guarantees).** Concurrent algorithms are classified by the progress guarantees they provide:

- **Blocking (lock-based)**: if a thread holding a lock is suspended (by the OS scheduler, a page fault, or a crash), other threads waiting for the lock cannot progress.

- **Obstruction-free**: a thread makes progress if it eventually executes in isolation (no other thread takes steps). This is the weakest non-blocking guarantee.

- **Lock-free**: at least one thread in the system makes progress in a finite number of steps, regardless of the execution speeds or failures of other threads. Individual threads may starve, but the system as a whole always advances.

- **Wait-free**: every thread makes progress in a bounded number of steps, regardless of other threads. No thread can starve.
:::

The hierarchy is: wait-free $\subset$ lock-free $\subset$ obstruction-free $\subset$ blocking-free.

::: theorem
**Theorem 9.1 (Lock-Free via CAS Loops).** Any sequential data structure operation can be made lock-free using a compare-and-swap loop: read the current state, compute the new state, and attempt to install it with CAS. If CAS fails (another thread modified the state), retry.

*Proof sketch.* Each CAS failure implies another thread's CAS succeeded (made progress). Therefore, if thread $T$ fails $k$ times, at least $k$ other operations completed. The system makes progress at a rate of at least one operation per step across all threads. $\square$
:::

### 9.2.2 CAS Loops

The fundamental pattern of lock-free programming is the **CAS loop** (also called the **retry loop** or **optimistic update**):

```c
#include <stdatomic.h>

/* Lock-free counter increment */
void atomic_increment(atomic_int *counter) {
    int old_val, new_val;
    do {
        old_val = atomic_load(counter);
        new_val = old_val + 1;
    } while (!atomic_compare_exchange_weak(counter, &old_val, new_val));
}
```

This pattern generalises to arbitrary transformations:

```c
/* Lock-free stack push */
typedef struct stack_node {
    int value;
    struct stack_node *next;
} stack_node_t;

typedef struct {
    _Atomic(stack_node_t *) top;
} lock_free_stack_t;

void stack_push(lock_free_stack_t *s, int value) {
    stack_node_t *new_node = malloc(sizeof(stack_node_t));
    new_node->value = value;
    stack_node_t *old_top;
    do {
        old_top = atomic_load(&s->top);
        new_node->next = old_top;
    } while (!atomic_compare_exchange_weak(&s->top, &old_top, new_node));
}

int stack_pop(lock_free_stack_t *s, int *value) {
    stack_node_t *old_top;
    stack_node_t *new_top;
    do {
        old_top = atomic_load(&s->top);
        if (old_top == NULL) return 0;  /* empty */
        new_top = old_top->next;
    } while (!atomic_compare_exchange_weak(&s->top, &old_top, new_top));
    *value = old_top->value;
    /* Cannot free old_top here! See Section 9.5 */
    return 1;
}
```

### 9.2.2b Correctness of the Lock-Free Stack

::: theorem
**Theorem 9.1b (Treiber Stack Correctness).** The lock-free stack (Treiber, 1986) satisfies:

1. **Linearisability**: each push operation is linearised at its successful CAS on `top`; each pop is linearised at its successful CAS on `top`.
2. **Lock-freedom**: in any execution where some thread is attempting a push or pop, at least one thread completes its operation in a finite number of steps.

*Proof of lock-freedom.* Consider a thread $T$ that fails its CAS during push or pop. The CAS fails because another thread successfully modified `top` --- that other thread made progress (either completed a push or a pop). Therefore, every CAS failure implies another thread's success. In any finite execution with $k$ CAS failures across all threads, at least $k$ operations completed. The system is never stuck. $\square$
:::

Note that the lock-free stack is **not** wait-free: a single thread's push can be delayed indefinitely if other threads keep modifying `top` between the thread's load and CAS. In practice, sustained starvation of a single thread is extremely unlikely due to the non-determinism of thread scheduling, but it is theoretically possible.

### 9.2.3 The ABA Problem

::: definition
**Definition 9.5 (ABA Problem).** The ABA problem occurs when a CAS operation succeeds spuriously because the target location's value changed from $A$ to $B$ and back to $A$ between the load and the CAS. The CAS sees value $A$ and assumes nothing has changed, but the underlying state may have been modified.
:::

::: example
**Example 9.2 (ABA in a Lock-Free Stack).** Consider a lock-free stack with elements $[A \rightarrow B \rightarrow C]$ (top is $A$):

```text
Thread 1: old_top = A, new_top = B          (prepares to pop A)
          [suspended before CAS]

Thread 2: pops A (stack becomes [B -> C])
Thread 2: pops B (stack becomes [C])
Thread 2: pushes A back (stack becomes [A -> C])

Thread 1: [resumes] CAS(&top, A, B)
          Succeeds! (top is indeed A)
          Stack becomes [B -> ...]
          But B was already freed by Thread 2!
```

Thread 1's CAS succeeds because `top` is `A`, but the stack's structure has changed: `A->next` no longer points to $B$. The result is a corrupted stack with a dangling pointer.
:::

**Solutions to the ABA problem:**

1. **Tagged pointers (version counters)**: pair each pointer with a monotonically increasing counter. CAS operates on the (pointer, counter) pair. Even if the pointer returns to $A$, the counter will have changed. On 64-bit systems, the upper 16 bits of a pointer (unused in current architectures with 48-bit virtual addresses) can store the counter.

2. **Hazard pointers**: protect nodes from being freed while any thread holds a reference (Section 9.5).

3. **Epoch-based reclamation**: defer freeing nodes until all threads have passed through a quiescent point (Section 9.5).

```c
/* Tagged pointer: pack pointer and counter into 64 bits */
typedef struct {
    stack_node_t *ptr;
    unsigned int tag;
} tagged_ptr_t;

/* On x86-64, use CMPXCHG16B for 128-bit CAS (double-width CAS) */
/* Or use the upper bits of the pointer as the tag */
typedef union {
    struct {
        stack_node_t *ptr;
        uint64_t tag;
    };
    __int128 combined;  /* for atomic 128-bit CAS */
} tagged_ptr_u;
```

> **Programmer:** Go's `sync/atomic` package provides `atomic.CompareAndSwapPointer` but does not support double-width CAS directly. However, Go's garbage collector eliminates the ABA problem for most use cases: a pointer to an object $A$ remains valid as long as any goroutine holds a reference to it. The GC will not free (and therefore will not reallocate) the memory at address $A$ while references exist. This is a significant advantage of garbage-collected languages for lock-free programming --- an entire class of bugs (ABA, use-after-free, dangling pointers) is eliminated by the runtime. The trade-off is GC pause latency and reduced control over memory layout.

---

## 9.3 Wait-Free Data Structures

### 9.3.1 Herlihy's Universal Construction

::: theorem
**Theorem 9.2 (Herlihy's Universality Result, 1991).** Any sequential data structure can be transformed into a wait-free concurrent data structure using compare-and-swap (or any object with consensus number $\geq n$ for $n$ threads). The construction guarantees that every operation completes in $O(n)$ steps, where $n$ is the number of threads.
:::

The construction works by maintaining the data structure as an immutable log of operations. Each thread:

1. Creates a node describing its operation.
2. Appends it to a shared linked list using CAS.
3. Replays the log from the last known state to compute the result.
4. If the CAS fails (another thread appended first), it helps the other thread complete its operation before retrying its own.

::: definition
**Definition 9.6 (Helping).** In a wait-free algorithm, a thread that detects another thread's pending operation may **help** it complete. Helping ensures that no thread can be blocked indefinitely: even if a thread is suspended, other threads will complete its operation on its behalf.
:::

```c
/* Simplified universal construction (pseudocode) */
typedef struct op_node {
    int (*operation)(void *state, void *arg);
    void *arg;
    _Atomic(int) result;
    _Atomic(int) done;
    _Atomic(struct op_node *) next;
} op_node_t;

typedef struct {
    _Atomic(op_node_t *) tail;
    void *state;  /* the sequential data structure */
} universal_t;

int apply(universal_t *u, op_node_t *my_op) {
    my_op->done = 0;
    my_op->next = NULL;

    /* Append to log */
    while (1) {
        op_node_t *last = atomic_load(&u->tail);
        op_node_t *expected = NULL;
        if (atomic_compare_exchange_strong(&last->next, &expected, my_op)) {
            atomic_compare_exchange_strong(&u->tail, &last, my_op);
            break;
        } else {
            /* Help the other thread advance the tail */
            atomic_compare_exchange_strong(&u->tail, &last, expected);
        }
    }

    /* Execute all pending operations in log order */
    /* (details omitted for brevity) */

    return my_op->result;
}
```

::: example
**Example 9.3 (Wait-Free Counter).** A wait-free counter for $n$ threads can be implemented by giving each thread its own counter cell. The `increment` operation atomically increments the local cell (a single atomic write, always $O(1)$). The `read` operation sums all cells (an $O(n)$ operation, but wait-free since it reads each cell exactly once):

```c
#include <stdatomic.h>

#define MAX_THREADS 64

typedef struct {
    _Alignas(64) atomic_long count;  /* one cache line per thread */
} counter_cell_t;

typedef struct {
    counter_cell_t cells[MAX_THREADS];
    int num_threads;
} wf_counter_t;

void wf_increment(wf_counter_t *c, int thread_id) {
    atomic_fetch_add(&c->cells[thread_id].count, 1);
    /* Wait-free: exactly one atomic operation, no retry */
}

long wf_read(wf_counter_t *c) {
    long total = 0;
    for (int i = 0; i < c->num_threads; i++)
        total += atomic_load(&c->cells[i].count);
    return total;
    /* Wait-free: exactly n atomic loads, no retry */
}
```

Note the `_Alignas(64)` to place each cell on its own cache line, avoiding false sharing (where atomic operations on different cells invalidate each other's cache lines because they happen to share a 64-byte cache line).

::: definition
**Definition 9.6b (False Sharing).** False sharing occurs when two or more threads access different variables that reside on the same cache line. Even though the variables are logically independent, atomic operations on one variable invalidate the cache line for all threads accessing other variables on the same line, causing unnecessary cache coherence traffic. Padding variables to cache-line boundaries (typically 64 bytes) eliminates false sharing.
:::
:::

### 9.3.2 Practical Considerations

Herlihy's universal construction proves that wait-free implementations exist for any data structure, but the resulting algorithms are typically impractical: the overhead of logging, helping, and replaying operations dominates the actual work. In practice, most concurrent data structures use **lock-free** algorithms (which allow individual starvation but guarantee system-wide progress) because they are simpler and faster.

Wait-free algorithms are used in specialised domains:

- **Real-time systems**: where worst-case bounds on operation latency are required.
- **Hard real-time embedded systems**: where no operation may take more than a fixed number of steps.
- **Read-heavy workloads**: where wait-free reads (as in the counter example) are the common case.

### 9.3.3 The Price of Wait-Freedom

::: theorem
**Theorem 9.2b (Wait-Free Overhead).** Any wait-free implementation of a concurrent object from CAS has worst-case step complexity $\Omega(n)$ per operation, where $n$ is the number of threads. This is because the helping mechanism requires each thread to examine the state of all other threads to ensure no thread is left behind.
:::

This $\Omega(n)$ lower bound explains why wait-free algorithms are typically slower than lock-free alternatives for small numbers of threads. The overhead of helping is worthwhile only when absolute worst-case guarantees are required, or when the number of threads is small enough that the helping overhead is acceptable.

In practice, the progression of concurrent algorithm design is:

1. **Coarse-grained locking** (simplest, lowest concurrency)
2. **Fine-grained locking** (more complex, better concurrency)
3. **Lock-free** (CAS-based, system-wide progress guarantee)
4. **Wait-free** (per-thread progress guarantee, highest complexity and overhead)

Most production systems stop at step 3 (lock-free). Lock-free algorithms provide excellent practical performance and system-wide progress, and the theoretical possibility of individual starvation almost never occurs in practice because OS schedulers ensure fair CPU time distribution.

---

## 9.4 The Michael-Scott Lock-Free Queue

The Michael-Scott queue (1996) is the most widely used lock-free queue algorithm. It is used in the Java `ConcurrentLinkedQueue`, the .NET `ConcurrentQueue`, and forms the basis of many message-passing systems.

### 9.4.1 Structure

```c
#include <stdatomic.h>
#include <stdlib.h>

typedef struct queue_node {
    int value;
    _Atomic(struct queue_node *) next;
} queue_node_t;

typedef struct {
    _Atomic(queue_node_t *) head;
    _Atomic(queue_node_t *) tail;
} ms_queue_t;

void ms_queue_init(ms_queue_t *q) {
    queue_node_t *sentinel = malloc(sizeof(queue_node_t));
    sentinel->next = NULL;
    q->head = sentinel;
    q->tail = sentinel;
}
```

The queue uses a sentinel (dummy) node: the head always points to the sentinel, and the first real element is `head->next`. This eliminates special cases for empty queues.

### 9.4.2 Enqueue

```c
void ms_enqueue(ms_queue_t *q, int value) {
    queue_node_t *new_node = malloc(sizeof(queue_node_t));
    new_node->value = value;
    atomic_store(&new_node->next, NULL);

    while (1) {
        queue_node_t *tail = atomic_load(&q->tail);
        queue_node_t *next = atomic_load(&tail->next);

        if (tail == atomic_load(&q->tail)) {  /* consistency check */
            if (next == NULL) {
                /* Tail is pointing to the last node */
                if (atomic_compare_exchange_weak(&tail->next,
                                                  &next, new_node)) {
                    /* Enqueue succeeded; try to advance tail */
                    atomic_compare_exchange_weak(&q->tail, &tail, new_node);
                    return;
                }
            } else {
                /* Tail is lagging; help advance it */
                atomic_compare_exchange_weak(&q->tail, &tail, next);
            }
        }
    }
}
```

::: definition
**Definition 9.7 (Helping in the Michael-Scott Queue).** The enqueue operation exhibits cooperative helping: if a thread observes that `tail->next` is not null (meaning another thread has appended a node but has not yet updated `tail`), it helps advance `tail` before attempting its own enqueue. This ensures that `tail` never falls more than one node behind the actual end of the queue, and it guarantees lock-freedom.
:::

### 9.4.3 Dequeue

```c
int ms_dequeue(ms_queue_t *q, int *value) {
    while (1) {
        queue_node_t *head = atomic_load(&q->head);
        queue_node_t *tail = atomic_load(&q->tail);
        queue_node_t *next = atomic_load(&head->next);

        if (head == atomic_load(&q->head)) {  /* consistency check */
            if (head == tail) {
                if (next == NULL) {
                    return 0;  /* queue is empty */
                }
                /* Tail lagging; advance it */
                atomic_compare_exchange_weak(&q->tail, &tail, next);
            } else {
                /* Read value before CAS, in case another
                   dequeue frees the node */
                *value = next->value;
                if (atomic_compare_exchange_weak(&q->head,
                                                  &head, next)) {
                    /* Dequeue succeeded */
                    /* free(head); -- NOT SAFE! See Section 9.5 */
                    return 1;
                }
            }
        }
    }
}
```

::: theorem
**Theorem 9.3 (Michael-Scott Queue is Lock-Free).** The Michael-Scott queue's enqueue and dequeue operations are lock-free.

*Proof.* Consider any execution where some thread $T$ is attempting an enqueue or dequeue. If $T$'s CAS fails, it means another thread's CAS on the same location succeeded, which means that other thread made progress (either advanced `tail`, appended a node, or dequeued a node). In any finite interval where threads take steps, at least one CAS succeeds, so at least one operation completes. Therefore, the algorithm is lock-free. $\square$
:::

::: example
**Example 9.4 (Michael-Scott Queue Interleaving).** Consider two threads simultaneously enqueuing values 10 and 20 into a queue containing $[\text{sentinel}]$:

```text
Initial: sentinel.next = NULL, tail = sentinel

Thread A: new_node(10), reads tail = sentinel, next = NULL
Thread B: new_node(20), reads tail = sentinel, next = NULL

Thread A: CAS(sentinel.next, NULL, node(10))  -- SUCCESS
          Queue: sentinel -> 10
          CAS(tail, sentinel, node(10))        -- SUCCESS
          tail = node(10)

Thread B: CAS(sentinel.next, NULL, node(20))  -- FAILS (next is now node(10))
          Reads next = node(10)
          next != NULL, so helps: CAS(tail, sentinel, node(10))
          (may fail: tail already advanced by Thread A)
          Retries: reads tail = node(10), next = NULL
          CAS(node(10).next, NULL, node(20))   -- SUCCESS
          Queue: sentinel -> 10 -> 20
          CAS(tail, node(10), node(20))        -- SUCCESS
```

Both operations complete. The queue is linearisable: the operations appear to take effect in the order $10, 20$.
:::

---

## 9.5 Memory Reclamation

### 9.5.1 The Problem

In lock-free data structures, a fundamental challenge arises: when a node is removed from the structure, it cannot be immediately freed because other threads may still hold references to it. In the Michael-Scott queue, after a dequeue advances `head` past a node, another thread in the middle of a dequeue may still be reading that node's `next` pointer.

::: definition
**Definition 9.8 (Safe Memory Reclamation).** The memory reclamation problem for lock-free data structures asks: when is it safe to free (or reuse) a node that has been removed from a concurrent data structure? The node can be freed only when no thread holds a reference to it and no thread will access it in the future.
:::

### 9.5.2 Hazard Pointers

::: definition
**Definition 9.9 (Hazard Pointers, Michael 2004).** Each thread maintains a small set of **hazard pointers** --- shared variables that advertise which nodes the thread is currently accessing. Before accessing a node, a thread publishes the node's address in its hazard pointer. Before freeing a node, a thread checks all hazard pointers across all threads; if any hazard pointer references the node, the free is deferred.
:::

```c
#include <stdatomic.h>

#define MAX_THREADS 64
#define HP_PER_THREAD 2
#define RETIRE_THRESHOLD 64

typedef struct {
    _Atomic(void *) hp[HP_PER_THREAD];
} hp_record_t;

hp_record_t hp_records[MAX_THREADS];

/* Thread-local retired list */
typedef struct {
    void *nodes[RETIRE_THRESHOLD * 2];
    int count;
} retired_list_t;

__thread retired_list_t retired = {.count = 0};

void hp_protect(int thread_id, int slot, void *ptr) {
    atomic_store(&hp_records[thread_id].hp[slot], ptr);
}

void hp_clear(int thread_id, int slot) {
    atomic_store(&hp_records[thread_id].hp[slot], NULL);
}

void hp_retire(int thread_id, void *ptr, int num_threads) {
    retired.nodes[retired.count++] = ptr;

    if (retired.count >= RETIRE_THRESHOLD) {
        /* Scan all hazard pointers */
        void *protected_ptrs[MAX_THREADS * HP_PER_THREAD];
        int pcount = 0;
        for (int t = 0; t < num_threads; t++) {
            for (int s = 0; s < HP_PER_THREAD; s++) {
                void *p = atomic_load(&hp_records[t].hp[s]);
                if (p) protected_ptrs[pcount++] = p;
            }
        }

        /* Try to free retired nodes not in the protected set */
        int new_count = 0;
        for (int i = 0; i < retired.count; i++) {
            int is_protected = 0;
            for (int j = 0; j < pcount; j++) {
                if (retired.nodes[i] == protected_ptrs[j]) {
                    is_protected = 1;
                    break;
                }
            }
            if (is_protected) {
                retired.nodes[new_count++] = retired.nodes[i];
            } else {
                free(retired.nodes[i]);
            }
        }
        retired.count = new_count;
    }
}
```

Using hazard pointers in the Michael-Scott dequeue:

```c
int ms_dequeue_hp(ms_queue_t *q, int *value, int tid) {
    while (1) {
        queue_node_t *head = atomic_load(&q->head);
        hp_protect(tid, 0, head);  /* protect head */
        if (head != atomic_load(&q->head)) continue;  /* validate */

        queue_node_t *tail = atomic_load(&q->tail);
        queue_node_t *next = atomic_load(&head->next);
        hp_protect(tid, 1, next);  /* protect next */
        if (head != atomic_load(&q->head)) continue;  /* validate */

        if (head == tail) {
            if (next == NULL) {
                hp_clear(tid, 0);
                hp_clear(tid, 1);
                return 0;  /* empty */
            }
            atomic_compare_exchange_weak(&q->tail, &tail, next);
        } else {
            *value = next->value;
            if (atomic_compare_exchange_weak(&q->head, &head, next)) {
                hp_clear(tid, 0);
                hp_clear(tid, 1);
                hp_retire(tid, head, MAX_THREADS);
                return 1;
            }
        }
    }
}
```

### 9.5.3 Epoch-Based Reclamation

::: definition
**Definition 9.10 (Epoch-Based Reclamation, Fraser 2004).** The system maintains a global epoch counter. Each thread records the epoch it observed when it last entered a critical region. Retired nodes are tagged with the epoch in which they were retired. A retired node from epoch $e$ can be freed when all threads have observed an epoch greater than $e$ --- meaning no thread can hold a reference from epoch $e$ or earlier.
:::

```c
#include <stdatomic.h>
#include <stdlib.h>

#define MAX_THREADS 64
#define NUM_EPOCHS 3

typedef struct retire_node {
    void *ptr;
    struct retire_node *next;
} retire_node_t;

typedef struct {
    atomic_int global_epoch;
    _Atomic(int) thread_epochs[MAX_THREADS];
    _Atomic(int) thread_active[MAX_THREADS];
    retire_node_t *retire_lists[MAX_THREADS][NUM_EPOCHS];
} epoch_t;

void epoch_enter(epoch_t *e, int tid) {
    int ge = atomic_load(&e->global_epoch);
    atomic_store(&e->thread_epochs[tid], ge);
    atomic_store(&e->thread_active[tid], 1);
    atomic_thread_fence(memory_order_seq_cst);
}

void epoch_exit(epoch_t *e, int tid) {
    atomic_store(&e->thread_active[tid], 0);
}

void epoch_retire(epoch_t *e, int tid, void *ptr) {
    int ge = atomic_load(&e->global_epoch);
    retire_node_t *node = malloc(sizeof(retire_node_t));
    node->ptr = ptr;
    node->next = e->retire_lists[tid][ge % NUM_EPOCHS];
    e->retire_lists[tid][ge % NUM_EPOCHS] = node;

    /* Try to advance the global epoch */
    int can_advance = 1;
    for (int t = 0; t < MAX_THREADS; t++) {
        if (atomic_load(&e->thread_active[t]) &&
            atomic_load(&e->thread_epochs[t]) != ge) {
            can_advance = 0;
            break;
        }
    }

    if (can_advance) {
        int new_epoch = ge + 1;
        if (atomic_compare_exchange_strong(&e->global_epoch,
                                            &ge, new_epoch)) {
            /* Free all nodes from two epochs ago */
            int old_epoch = (new_epoch - 2 + NUM_EPOCHS) % NUM_EPOCHS;
            for (int t = 0; t < MAX_THREADS; t++) {
                retire_node_t *list = e->retire_lists[t][old_epoch];
                while (list) {
                    retire_node_t *tmp = list;
                    list = list->next;
                    free(tmp->ptr);
                    free(tmp);
                }
                e->retire_lists[t][old_epoch] = NULL;
            }
        }
    }
}
```

::: example
**Example 9.5 (Epoch Advancement).** With 3 threads and global epoch at 5:

```text
Time 1: Thread 0 enters (epoch 5), Thread 1 enters (epoch 5)
Time 2: Thread 0 retires node X (tagged epoch 5)
Time 3: Thread 1 exits, Thread 2 enters (epoch 5)
Time 4: Thread 0 exits, Thread 1 enters (epoch 5)
Time 5: All threads have seen epoch 5 -> advance to epoch 6
Time 6: Thread 2 exits, enters (epoch 6)
Time 7: All threads have seen epoch 6 -> advance to epoch 7
         Now safe to free nodes retired in epoch 5 (node X)
```

The two-epoch grace period ensures that no thread can hold a reference to a node from two or more epochs ago.
:::

**Comparison:**

| Property | Hazard Pointers | Epoch-Based |
|----------|----------------|-------------|
| Memory overhead | $O(T \cdot K)$ pointers ($T$ threads, $K$ hazard pointers per thread) | $O(T \cdot R)$ retired nodes ($R$ = max retire rate between epochs) |
| Reclamation latency | Per-scan (bounded by $T \cdot K$) | Per-epoch (may accumulate if a thread stalls) |
| Stalled thread | Does not delay reclamation of unprotected nodes | Delays all reclamation (epoch cannot advance) |
| Implementation complexity | Moderate | Lower |

### 9.5.4 Choosing a Reclamation Strategy

The choice between hazard pointers and epoch-based reclamation depends on the application's requirements:

- **Use hazard pointers** when threads may be preempted for long periods (e.g., in a system with oversubscription, where more threads than cores exist). A stalled thread's hazard pointers protect only the specific nodes it references, so reclamation of other nodes proceeds normally.

- **Use epoch-based reclamation** when threads are cooperative and make frequent progress (e.g., in a database engine where worker threads are never preempted mid-operation). The simpler implementation and lower per-operation overhead outweigh the risk of delayed reclamation.

- **Use garbage collection** (as in Go, Java, C#) when the language provides it. GC eliminates the entire reclamation problem at the cost of pause latency and reduced memory control. For most applications, this is the right trade-off.

::: example
**Example 9.5b (Reclamation in Practice).** Major systems and their reclamation strategies:

| System | Language | Reclamation | Reason |
|--------|---------|-------------|--------|
| Linux kernel RCU | C | Epoch-based (read-copy-update) | Threads are kernel threads; quiescent detection is natural |
| Java ConcurrentHashMap | Java | Garbage collection | JVM provides GC |
| Go sync.Map | Go | Garbage collection | Go GC handles it |
| Folly ConcurrentHashMap | C++ | Hazard pointers | Long-lived threads may be preempted |
| crossbeam (Rust) | Rust | Epoch-based | Cooperative threads in async runtime |
:::

---

## 9.6 Memory Ordering

### 9.6.1 The Need for Memory Ordering

Modern processors and compilers reorder memory operations for performance. A store followed by a load to a different address may execute in the reverse order (the store sits in a write buffer while the load proceeds from cache). Without explicit ordering constraints, concurrent algorithms that depend on the order of memory accesses may break.

::: definition
**Definition 9.11 (Memory Model).** A memory model specifies the set of allowable orderings of memory operations as observed by different threads. It defines which reorderings the hardware and compiler are permitted to perform, and which guarantees the programmer can rely on.
:::

### 9.6.2 Sequential Consistency

::: definition
**Definition 9.12 (Sequential Consistency, Lamport 1979).** A multiprocessor system is sequentially consistent if the result of any execution is the same as if the operations of all processors were executed in some sequential order, and the operations of each individual processor appear in this sequence in the order specified by its program.
:::

Sequential consistency (SC) is the most intuitive model: it behaves as if there is a single shared memory and threads take turns executing one operation at a time. However, SC is expensive to implement because it forbids most hardware and compiler optimisations.

::: example
**Example 9.6 (Sequential Consistency Violation).** Consider two threads:

```c
/* Initially: x = 0, y = 0 */

/* Thread 1 */          /* Thread 2 */
x = 1;                  y = 1;
r1 = y;                 r2 = x;
```

Under sequential consistency, the possible outcomes are:

| Interleaving | r1 | r2 |
|-------------|----|----|
| T1, T1, T2, T2 | 0 | 1 |
| T1, T2, T1, T2 | 1 | 1 |
| T1, T2, T2, T1 | 1 | 1 |
| T2, T2, T1, T1 | 1 | 0 |
| T2, T1, T2, T1 | 1 | 1 |
| T2, T1, T1, T2 | 1 | 1 |

The outcome $r_1 = 0, r_2 = 0$ is **impossible** under SC: it would require both stores to occur after both loads, which contradicts program order.

However, on x86 (TSO), this outcome **is** possible: both stores may sit in write buffers while both loads read from cache (which still holds 0). This is the store-buffer reordering allowed by TSO.
:::

### 9.6.3 Acquire-Release Semantics

::: definition
**Definition 9.13 (Acquire and Release).** In the acquire-release memory model:

- An **acquire** operation (e.g., a load with acquire semantics) ensures that no subsequent memory operation (in program order) can be reordered before it. It acts as a one-way barrier: operations can move down past it, but not up.

- A **release** operation (e.g., a store with release semantics) ensures that no preceding memory operation (in program order) can be reordered after it. It acts as a one-way barrier: operations can move up past it, but not down.

When a release store in thread $A$ is observed by an acquire load in thread $B$ (they read the same value), a **synchronises-with** relationship is established: all memory operations before $A$'s release are visible to all memory operations after $B$'s acquire.
:::

```c
#include <stdatomic.h>

int data = 0;
atomic_int flag = 0;

/* Thread 1 (producer) */
void producer(void) {
    data = 42;                                         /* ordinary store */
    atomic_store_explicit(&flag, 1, memory_order_release);  /* release */
}

/* Thread 2 (consumer) */
void consumer(void) {
    while (atomic_load_explicit(&flag, memory_order_acquire) == 0)
        ;  /* spin with acquire */
    /* data is guaranteed to be 42 here */
    printf("%d\n", data);
}
```

The release store of `flag = 1` by Thread 1 synchronises with the acquire load that reads `flag == 1` by Thread 2. This guarantees that Thread 2 sees `data = 42` --- the store to `data` cannot be reordered past the release store.

### 9.6.3b Hardware Memory Models

Different processor architectures provide different memory ordering guarantees:

::: definition
**Definition 9.13b (Total Store Order, TSO).** x86 processors implement Total Store Order (TSO): stores from a single core are seen by all other cores in program order. The only reordering permitted is a store followed by a load to a different address: the load may execute before the store becomes globally visible (due to the store buffer). All other orderings (store-store, load-load, load-store) are preserved.
:::

::: definition
**Definition 9.13c (Weak Ordering).** ARM and RISC-V processors implement weak ordering: both loads and stores may be reordered with respect to each other, subject to data dependencies. Explicit barrier instructions (`DMB`, `DSB` on ARM; `FENCE` on RISC-V) are required to enforce specific orderings. This provides maximum optimisation freedom for the hardware at the cost of requiring explicit programmer annotation.
:::

The practical consequence is that lock-free algorithms that work correctly on x86 (TSO) may fail on ARM (weak ordering) because ARM permits more reorderings. The C11/C++11 memory model abstracts over these hardware differences: the programmer specifies the required ordering (acquire, release, seq_cst), and the compiler inserts the appropriate barriers for each target architecture.

::: example
**Example 9.6b (Platform-Specific Barrier Costs).**

| Memory order | x86 (TSO) | ARM | RISC-V |
|-------------|-----------|-----|--------|
| Relaxed load | `MOV` (free) | `LDR` (free) | `LW` (free) |
| Acquire load | `MOV` (free, TSO provides it) | `LDAR` or `LDR + DMB` | `LW + FENCE` |
| Release store | `MOV` (free, TSO provides it) | `STLR` or `DMB + STR` | `FENCE + SW` |
| Seq\_cst store | `MOV + MFENCE` or `LOCK XCHG` | `STLR + DMB ISH` | `FENCE + SW + FENCE` |

On x86, acquire and release are free (TSO already provides them). Seq\_cst is the only ordering that requires an explicit fence. On ARM, every ordering above relaxed requires explicit barrier instructions. This is why weakening memory orderings from seq\_cst to acquire-release provides significant performance improvements on ARM but negligible improvement on x86.
:::

### 9.6.4 Relaxed Ordering

::: definition
**Definition 9.14 (Relaxed Memory Order).** A relaxed atomic operation guarantees only atomicity (no torn reads/writes) but provides no ordering constraints with respect to other memory operations. Relaxed operations are useful for statistics counters and other cases where the exact ordering of updates is irrelevant.
:::

```c
/* Relaxed counter: counts are eventually consistent but always accurate */
atomic_int total_requests = 0;

void handle_request(void) {
    /* Relaxed: we only care about the final count, not ordering */
    atomic_fetch_add_explicit(&total_requests, 1, memory_order_relaxed);
}
```

### 9.6.5 Memory Order Hierarchy

The C11/C++11 standard defines six memory orderings, forming a hierarchy from weakest to strongest:

| Ordering | Guarantees | Cost |
|----------|-----------|------|
| `memory_order_relaxed` | Atomicity only | Cheapest (no fences) |
| `memory_order_consume` | Data-dependent ordering (deprecated in practice) | |
| `memory_order_acquire` | No reordering of subsequent ops before this load | Load fence |
| `memory_order_release` | No reordering of preceding ops after this store | Store fence |
| `memory_order_acq_rel` | Both acquire and release (for read-modify-write) | Both fences |
| `memory_order_seq_cst` | Total order across all seq\_cst operations | Full fence |

::: theorem
**Theorem 9.4 (Sequential Consistency of Default Atomics).** All C11/C++11 atomic operations default to `memory_order_seq_cst`. A program that uses only default atomic operations on all shared variables is sequentially consistent.

*Proof.* The C11 standard defines that `memory_order_seq_cst` operations participate in a single total order $S$ consistent with the modification order of each atomic object and consistent with the "happens-before" relation. Since all operations are `seq_cst`, the total order $S$ is a valid sequential execution. $\square$
:::

> **Programmer:** Go's `sync/atomic` package provides sequentially consistent operations only --- there is no way to specify relaxed or acquire-release ordering. Every `atomic.LoadInt64`, `atomic.StoreInt64`, and `atomic.CompareAndSwapInt64` provides full sequential consistency. This is a deliberate design choice: the Go team prioritises correctness over the marginal performance gains of weaker orderings. The Go memory model (documented at `go.dev/ref/mem`) states that atomic operations behave as `sync.Mutex` acquire/release pairs, creating happens-before edges.
>
> For performance-critical code that needs weaker ordering, Go programmers can use `unsafe.Pointer` with careful reasoning, but this is strongly discouraged. In practice, the overhead of seq\_cst atomics on x86 (which has a naturally strong memory model) is negligible --- the difference matters mainly on ARM and POWER architectures, where explicit barriers are needed for seq\_cst but not for acquire-release.
>
> ```go
> package main
>
> import (
>     "fmt"
>     "sync/atomic"
> )
>
> func main() {
>     var counter int64
>
>     // All atomic operations are sequentially consistent in Go
>     atomic.StoreInt64(&counter, 0)
>     atomic.AddInt64(&counter, 1)
>     val := atomic.LoadInt64(&counter)
>     fmt.Println(val) // 1
>
>     // CompareAndSwap: the foundation of lock-free programming
>     swapped := atomic.CompareAndSwapInt64(&counter, 1, 42)
>     fmt.Println(swapped, atomic.LoadInt64(&counter)) // true 42
> }
> ```

---

## 9.7 The C11/C++11 Memory Model

### 9.7.1 Formalisation

::: definition
**Definition 9.15 (Happens-Before Relation).** The happens-before relation $\xrightarrow{hb}$ is a partial order on memory operations defined as the transitive closure of:

1. **Sequenced-before** ($\xrightarrow{sb}$): if $A$ appears before $B$ in the same thread's program, then $A \xrightarrow{sb} B$.
2. **Synchronises-with** ($\xrightarrow{sw}$): if $A$ is a release operation on atomic variable $x$ and $B$ is an acquire operation on $x$ that reads the value written by $A$, then $A \xrightarrow{sw} B$.

If $A \xrightarrow{hb} B$, then $A$'s effects are visible to $B$.
:::

::: definition
**Definition 9.16 (Data Race).** A data race occurs when two memory operations access the same non-atomic memory location, at least one is a write, and there is no happens-before relation between them. The C11/C++11 standards declare that programs with data races have **undefined behaviour**.
:::

::: theorem
**Theorem 9.5 (DRF-SC Guarantee).** The C11/C++11 memory model provides the DRF-SC (Data-Race-Free implies Sequential Consistency) guarantee: if a program is free of data races (all conflicting accesses are ordered by happens-before), then its behaviour is sequentially consistent.

*Proof sketch.* In a data-race-free program, every pair of conflicting accesses is ordered by $\xrightarrow{hb}$. The happens-before relation is consistent with program order and with the synchronisation order. Any sequentially consistent execution respects these orderings. Since every pair of conflicting accesses is ordered, the interleaving of operations across threads cannot produce results that differ from some sequential interleaving. $\square$
:::

### 9.7.2 Modification Order and Coherence

::: definition
**Definition 9.16b (Modification Order).** For each atomic variable $x$, the C11 memory model defines a **modification order** $M_x$: a total order on all stores to $x$. All threads agree on this order. This ensures **coherence**: if thread $A$ sees store $S_1$ to $x$ before store $S_2$, then no thread can see $S_2$ before $S_1$.
:::

Coherence is weaker than sequential consistency: it applies per-variable, not globally. Two threads may see stores to different variables in different orders, as long as they agree on the order of stores to each individual variable.

::: example
**Example 9.7b (Coherence vs Sequential Consistency).** Consider:

```c
atomic_int x = 0, y = 0;

/* Thread 1 */              /* Thread 2 */
x = 1;                      y = 1;

/* Thread 3 */              /* Thread 4 */
r1 = x; /* sees 1 */       r3 = y; /* sees 1 */
r2 = y; /* sees 0 */       r4 = x; /* sees 0 */
```

Under sequential consistency, if Thread 3 sees $x = 1$ before $y = 1$, then Thread 4 must also see $x = 1$ before $y = 1$ (there is a single global order). The outcome $r_1 = 1, r_2 = 0, r_3 = 1, r_4 = 0$ is impossible.

Under coherence (with relaxed atomics), each variable has its own order, but there is no global order across variables. Thread 3 may see $x$ updated before $y$, while Thread 4 sees $y$ updated before $x$. The outcome above is permitted.

This is why `memory_order_seq_cst` is the default: it provides the intuitive global ordering that programmers expect. Weakening to acquire-release sacrifices cross-variable ordering but preserves the happens-before relationship needed for correct synchronisation patterns.
:::

### 9.7.3 Practical Implications

The DRF-SC guarantee is the foundation of correct concurrent programming in C and C++:

1. **Use atomic types for shared variables** (`atomic_int`, `_Atomic(int)`, `std::atomic<int>`).
2. **Use mutexes for compound operations** that involve multiple variables.
3. **Default to `memory_order_seq_cst`** (the default) and weaken only with careful reasoning and testing.
4. **Use tools**: ThreadSanitizer (TSan) detects data races dynamically.

::: example
**Example 9.7 (Compiler Reordering).** Without atomics, the compiler may reorder stores:

```c
/* Thread 1 */
data = 42;    /* may be reordered after flag = 1 by the compiler */
flag = 1;

/* Thread 2 */
while (flag == 0) ;
printf("%d\n", data);  /* may print 0! */
```

With atomics:

```c
#include <stdatomic.h>

int data = 0;
atomic_int flag = 0;

/* Thread 1 */
data = 42;
atomic_store(&flag, 1);  /* seq_cst: cannot be reordered before data = 42 */

/* Thread 2 */
while (atomic_load(&flag) == 0) ;
printf("%d\n", data);  /* always prints 42 */
```

The atomic store acts as a compiler and hardware barrier, ensuring the store to `data` is visible before the store to `flag`.
:::

---

## 9.8 Linearisability

### 9.8.1 Definition

::: definition
**Definition 9.17 (Linearisability, Herlihy and Wing 1990).** A concurrent execution is **linearisable** if each operation appears to take effect instantaneously at some point (the **linearisation point**) between its invocation and its response, and the resulting sequential history is consistent with the sequential specification of the data structure.

Formally: an execution history $H$ is linearisable with respect to a sequential specification $S$ if $H$ can be extended (by completing pending operations or removing them) to a history $H'$ such that:

1. $H'$ is equivalent to a legal sequential history $\sigma$.
2. If operation $o_1$ completes before operation $o_2$ begins in $H$, then $o_1$ appears before $o_2$ in $\sigma$.
:::

::: example
**Example 9.8 (Linearisable vs Non-Linearisable).** Consider a concurrent queue with enqueue (E) and dequeue (D) operations:

**Linearisable execution:**

```text
Thread A: |--- E(1) ---|
Thread B:        |--- E(2) ---|
Thread C:                          |--- D() -> 1 ---|
Thread D:                                               |--- D() -> 2 ---|
```

Linearisation points: $E(1)$ before $E(2)$ before $D() \to 1$ before $D() \to 2$. Sequential history: $E(1), E(2), D() \to 1, D() \to 2$. Valid FIFO queue behaviour.

**Non-linearisable execution:**

```text
Thread A: |--- E(1) ---|
Thread B:                    |--- E(2) ---|
Thread C:                                       |--- D() -> 2 ---|
```

$E(1)$ completes before $E(2)$ begins, so $E(1)$ must precede $E(2)$ in any linearisation. But $D() \to 2$ dequeues 2 before 1, violating FIFO order. This is not linearisable.
:::

### 9.8.2 Linearisation Points

::: definition
**Definition 9.18 (Linearisation Point).** The linearisation point of an operation is the atomic step at which the operation appears to take effect. For lock-based data structures, the linearisation point is typically within the critical section. For lock-free data structures, it is typically a successful CAS.
:::

In the Michael-Scott queue:

- **Enqueue**: the linearisation point is the successful CAS that links the new node to the tail of the queue (`CAS(tail->next, NULL, new_node)`).
- **Dequeue**: the linearisation point is the successful CAS that advances the head pointer (`CAS(head, old_head, next)`).

### 9.8.3 Composability

::: theorem
**Theorem 9.6 (Linearisability is Compositional).** If objects $O_1$ and $O_2$ are each linearisable in isolation, then the system composed of both $O_1$ and $O_2$ is linearisable.

*Proof sketch.* The linearisation point of each operation on $O_1$ and $O_2$ is independent. A global linearisation order can be constructed by merging the individual linearisation orders, respecting the real-time ordering constraint (if an operation on $O_1$ completes before an operation on $O_2$ begins, the first precedes the second in the global order). Since each object's operations are individually consistent with their sequential specifications, the merged order is consistent with the combined specification. $\square$
:::

This composability property is unique to linearisability among common consistency conditions. It means that systems can be built from linearisable components with the guarantee that the whole system is linearisable.

### 9.8.4 Verifying Linearisability

Determining whether a concurrent execution history is linearisable is NP-complete in general (Gibbons and Korach, 1997). However, practical verification strategies exist:

1. **Linearisation point analysis**: for each operation in the algorithm, identify the single atomic step where the operation "takes effect". If every operation has a fixed linearisation point, linearisability follows directly.

2. **Testing with a linearisability checker**: tools like **Lowe's linearisability tester** or **Knossos** (used by Jepsen) record all invocations and responses in a concurrent execution and check whether there exists a valid linearisation.

3. **Proof by simulation**: construct a simulation relation between the concurrent implementation and the sequential specification. Show that every concurrent step maps to at most one step in the sequential specification.

::: example
**Example 9.8b (Linearisability Verification of a Counter).** Consider a concurrent counter with `increment` (returns void) and `read` (returns the count):

```text
Thread A: |--- inc() ---|           |--- read() -> 2 ---|
Thread B:      |--- inc() ---|
Thread C:                      |--- inc() ---|
```

Possible linearisation: `inc_A` at some point in $[t_0, t_1]$, `inc_B` at some point in $[t_2, t_3]$, `inc_C` at some point in $[t_4, t_5]$, `read_A` at some point in $[t_6, t_7]$.

For `read -> 2` to be correct, exactly 2 of the 3 increments must have taken effect before the read's linearisation point. This means `inc_C`'s linearisation point must be after `read_A`'s. Is this consistent with the real-time constraint? `inc_C` starts before `read_A` starts, but overlaps with it, so their linearisation points can be in either order. If `inc_C` is linearised after `read_A`, this is valid. The execution is linearisable.
:::

### 9.8.5 Alternatives to Linearisability

Linearisability provides strong guarantees but comes at a performance cost. Weaker consistency conditions are used when full linearisability is unnecessary:

- **Sequential consistency**: operations from each thread appear in program order, but there is no real-time ordering requirement between threads. A counter might show a stale value that was valid at some earlier point.

- **Quiescent consistency**: operations separated by a period of quiescence (no pending operations) appear in their real-time order. Between quiescent points, operations may be reordered.

- **Eventual consistency**: all replicas eventually converge to the same state, with no ordering guarantees for concurrent updates. Used in distributed key-value stores like Cassandra and DynamoDB.

The choice between consistency conditions depends on the application's requirements:

| Application | Typical consistency | Reason |
|------------|-------------------|--------|
| Bank account balance | Linearisable | Must reflect all completed transactions |
| Web page hit counter | Quiescent consistent | Approximate counts are acceptable |
| Social media feed | Eventually consistent | Stale reads are tolerable |
| Lock-free queue | Linearisable | FIFO ordering is the specification |
| Distributed cache | Eventually consistent | Performance over precision |

### 9.8.6 Practical Correctness Testing

In practice, proving linearisability formally is difficult for complex data structures. Engineers rely on a combination of techniques:

1. **Stress testing**: run many threads performing random operations simultaneously, checking invariants after each operation (e.g., a queue should return elements in FIFO order).

2. **Linearisability checkers**: record operation start/end timestamps and results, then check whether a valid linearisation exists. The tool Lowe's LinTester and Knossos (used by the Jepsen test suite for distributed databases) implement this.

3. **Model checking**: tools like SPIN or TLA+ can exhaustively explore all possible interleavings for small instances, finding bugs that random testing would miss.

4. **ThreadSanitizer (TSan)**: built into Clang and GCC, TSan detects data races at runtime by instrumenting every memory access. While it does not check linearisability directly, it finds the most common source of correctness bugs in concurrent code: missing synchronisation.

```c
/* Compile with TSan enabled */
/* gcc -fsanitize=thread -g -O1 myprogram.c -o myprogram */

/* TSan output for a data race: */
/*
WARNING: ThreadSanitizer: data race (pid=12345)
  Write of size 4 at 0x7f...abc by thread T1:
    #0 push queue.c:42
  Previous read of size 4 at 0x7f...abc by thread T2:
    #0 pop queue.c:67
*/
```

::: theorem
**Theorem 9.7 (Linearisability Verification is NP-Complete).** Given a concurrent execution history $H$ and a sequential specification $S$, determining whether $H$ is linearisable with respect to $S$ is NP-complete in general (Gibbons and Korach, 1997).

*Proof sketch.* Membership in NP is clear: a valid linearisation order is a polynomial-size certificate that can be verified in polynomial time (check that the sequential specification is satisfied and that the real-time ordering constraint holds). NP-hardness is proved by reduction from the set partitioning problem. The key difficulty is that overlapping operations can be linearised in any order, and the number of possible orderings is exponential in the number of overlapping operations. $\square$
:::

Despite NP-completeness in the worst case, practical linearisability checking works well because most realistic histories have limited overlap (few operations are truly concurrent), and heuristics prune the search space effectively. Tools like Knossos handle millions of operations in minutes for typical workloads.

::: example
**Example 9.8c (Testing Strategy for a Lock-Free Queue).** A comprehensive test suite for a Michael-Scott queue should include:

1. **Sequential correctness**: single-threaded enqueue/dequeue in various orders, verifying FIFO property.
2. **Concurrent stress test**: $P$ producer threads each enqueue $N$ unique values; $C$ consumer threads dequeue all values. Verify that every enqueued value is dequeued exactly once, with no duplicates or losses.
3. **Memory safety**: run under AddressSanitizer (ASan) to detect use-after-free in the memory reclamation scheme.
4. **Linearisability check**: record timestamps of all operations, feed to a linearisability checker, verify no violations.
5. **Performance regression**: measure throughput and latency at various thread counts; compare against the previous version.
:::

---

## 9.9 Programmer's Perspective: Go's Lock-Free Channels

> **Programmer:** Go channels are the language's primary concurrency communication primitive. Internally, Go channels are implemented as a combination of lock-based and lock-free techniques, depending on the channel state.
>
> A channel is represented by the `hchan` struct in the Go runtime:
>
> ```go
> // Simplified from runtime/chan.go
> type hchan struct {
>     qcount   uint     // number of elements in buffer
>     dataqsiz uint     // buffer capacity
>     buf      unsafe.Pointer // circular buffer
>     elemsize uint16
>     closed   uint32
>     sendx    uint     // send index into buf
>     recvx    uint     // receive index into buf
>     recvq    waitq    // list of blocked receivers
>     sendq    waitq    // list of blocked senders
>     lock     mutex    // protects all fields
> }
> ```
>
> The channel uses a mutex (not `sync.Mutex` but a lighter runtime mutex) to protect its state. However, several fast paths avoid locking entirely:
>
> 1. **Direct send**: if a receiver is already waiting (`recvq` is non-empty), the sender copies data directly into the receiver's stack frame using `memmove` and wakes the receiver. This avoids touching the buffer entirely.
>
> 2. **Empty channel fast path**: a non-blocking receive on an empty channel (`select` with `default`) checks `qcount == 0` with an atomic load and returns immediately without acquiring the lock.
>
> 3. **Closed channel detection**: receiving from a closed, empty channel is detected with atomic loads on the `closed` and `qcount` fields.
>
> For truly lock-free communication between goroutines, the `sync/atomic.Value` type provides a lock-free box for storing and loading arbitrary values:
>
> ```go
> package main
>
> import (
>     "fmt"
>     "sync"
>     "sync/atomic"
> )
>
> func main() {
>     var config atomic.Value
>
>     // Writer (infrequent)
>     type Config struct {
>         MaxConns int
>         Timeout  int
>     }
>     config.Store(Config{MaxConns: 100, Timeout: 30})
>
>     // Readers (frequent, lock-free)
>     var wg sync.WaitGroup
>     for i := 0; i < 10; i++ {
>         wg.Add(1)
>         go func() {
>             defer wg.Done()
>             cfg := config.Load().(Config)
>             fmt.Println(cfg.MaxConns)
>         }()
>     }
>     wg.Wait()
> }
> ```
>
> `atomic.Value` uses a single atomic pointer swap (on `Store`) and a single atomic pointer load (on `Load`), providing linearisable reads and writes without any locks. This is the recommended pattern for read-heavy configuration data in Go servers --- far more efficient than protecting the config with an `RWMutex`.
>
> The Go 1.19+ `atomic.Int64`, `atomic.Uint64`, `atomic.Bool`, and `atomic.Pointer[T]` types provide ergonomic wrappers around the raw `sync/atomic` functions with proper type safety:
>
> ```go
> package main
>
> import (
>     "fmt"
>     "sync"
>     "sync/atomic"
> )
>
> func main() {
>     var ops atomic.Int64
>     var wg sync.WaitGroup
>
>     for i := 0; i < 50; i++ {
>         wg.Add(1)
>         go func() {
>             defer wg.Done()
>             for j := 0; j < 1000; j++ {
>                 ops.Add(1)
>             }
>         }()
>     }
>
>     wg.Wait()
>     fmt.Println("Total ops:", ops.Load()) // always 50000
> }
> ```

---

## 9.10 Summary

This chapter developed the theory and practice of concurrent data structures, moving from simple lock-based designs through lock-free algorithms to formal correctness criteria.

**Key results:**

- **Lock-based designs** range from coarse-grained (one lock for the entire structure) to fine-grained (per-node locking) to hand-over-hand locking (lock coupling for traversals). Finer granularity increases concurrency but also complexity and overhead.

- **Lock-free programming** uses CAS loops to ensure system-wide progress without locks. The ABA problem is a fundamental challenge, solved by tagged pointers, hazard pointers, or epoch-based reclamation.

- **Wait-free data structures** guarantee per-thread progress. Herlihy's universal construction proves they exist for any sequential data type, but practical wait-free algorithms are complex and rarely necessary.

- **The Michael-Scott queue** is the canonical lock-free FIFO queue, using CAS on head and tail pointers with cooperative helping to maintain lock-freedom.

- **Memory reclamation** (hazard pointers and epoch-based reclamation) solves the problem of safely freeing nodes in lock-free structures.

- **Memory ordering** (sequential consistency, acquire-release, relaxed) governs how memory operations become visible across threads. The C11/C++11 memory model formalises these guarantees with the DRF-SC property.

- **Linearisability** is the gold standard for concurrent data structure correctness: each operation appears to take effect atomically at its linearisation point. It is the only common consistency condition that is compositional.

**Design principles:**

- Choose the simplest locking strategy that meets your performance requirements. Start with coarse-grained locking and optimise only when profiling demonstrates contention.

- Prefer well-known, proven algorithms (Michael-Scott queue, Treiber stack) over custom designs. Lock-free algorithms are subtle and easy to get wrong.

- Use the language's standard library when available. Go's `sync.Mutex`, Java's `ConcurrentHashMap`, and C++'s `std::atomic` are battle-tested and optimised for their respective platforms.

- Memory ordering is a leaky abstraction: default to the strongest ordering (seq_cst) and weaken only with profiling evidence and careful reasoning. The performance difference between seq_cst and acquire-release is negligible on x86 and moderate on ARM.

- Test concurrent code aggressively: stress tests, race detectors, linearisability checkers, and model checkers each catch different classes of bugs. No single technique is sufficient.

The concurrent data structures developed in this chapter build directly on the synchronisation primitives of Chapter 7 and the deadlock avoidance strategies of Chapter 8. Together, these three chapters form the foundation of concurrent systems programming.

---

## Exercises

**Exercise 9.1.** Implement a lock-free stack in C using `atomic_compare_exchange_weak` for both `push` and `pop`. Your implementation must handle the ABA problem using tagged pointers (pack a version counter into the upper 16 bits of the pointer). Write a multi-threaded test that runs 4 threads, each pushing and popping 100,000 elements, and verify that no elements are lost or duplicated.

**Exercise 9.2.** Prove that the Michael-Scott queue is linearisable. Identify the linearisation point of each operation (enqueue and dequeue, including the empty-queue case). Show that the resulting sequential history satisfies the FIFO queue specification for any possible interleaving of concurrent operations.

**Exercise 9.3.** A **Treiber stack** uses a single CAS on the top pointer for both push and pop. (a) Prove it is lock-free. (b) Prove it is not wait-free by constructing an execution where one thread's pop is delayed indefinitely by other threads' pushes. (c) What is the maximum number of CAS retries a pop operation can experience if $n$ concurrent push operations occur?

**Exercise 9.4.** Consider the following C11 program:

```c
atomic_int x = 0, y = 0;

/* Thread 1 */
atomic_store_explicit(&x, 1, memory_order_relaxed);
atomic_store_explicit(&y, 1, memory_order_release);

/* Thread 2 */
int r1 = atomic_load_explicit(&y, memory_order_acquire);
int r2 = atomic_load_explicit(&x, memory_order_relaxed);
```

(a) Can the outcome $r_1 = 1, r_2 = 0$ occur? Justify your answer using the C11 memory model's happens-before relation. (b) What if both operations in Thread 1 use `memory_order_relaxed`? (c) What if all operations use `memory_order_seq_cst`?

**Exercise 9.5.** Implement an epoch-based memory reclamation scheme in C for a lock-free linked list. Your implementation must: (a) support `enter_epoch`, `exit_epoch`, and `retire_node` operations; (b) advance the global epoch when all threads have been observed in the current epoch; (c) free retired nodes that are two or more epochs old. Demonstrate correctness with a test using 4 threads performing concurrent insertions and deletions.

**Exercise 9.6.** A **wait-free bounded queue** for a single producer and a single consumer (SPSC) can be implemented using two atomic indices and a shared array, with no CAS operations required. (a) Design such a queue using only `atomic_load` and `atomic_store` with appropriate memory orderings. (b) Prove it is wait-free for both the producer and consumer. (c) Explain why this construction does not generalise to multiple producers or multiple consumers.

**Exercise 9.7.** Linearisability is compositional but sequential consistency is not. Construct a concrete counterexample: two objects $O_1$ and $O_2$, each sequentially consistent in isolation, but whose composition violates sequential consistency. (*Hint*: consider two registers and exploit the lack of real-time ordering in sequential consistency.)

\vspace{2em}

The study of concurrent data structures sits at the intersection of algorithm design, hardware architecture, and programming language semantics. Getting these structures right requires understanding all three: the algorithmic logic (CAS loops, helping), the hardware reality (cache coherence, memory ordering, store buffers), and the language-level guarantees (the C11 memory model, the Go memory model). Errors in any dimension produce subtle bugs that manifest only under specific timing conditions, making concurrent programming one of the most demanding areas of systems engineering.

