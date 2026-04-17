# Chapter 7: Synchronisation Primitives

*"Shared mutable state is the root of all evil."* --- attributed to various, but universally felt

---

When multiple threads or processes access shared resources, the absence of coordination leads to race conditions --- subtle, intermittent bugs that corrupt data, crash systems, and resist debugging. Synchronisation primitives are the tools we use to impose order on concurrent execution. They range from simple hardware instructions that atomically modify a single word of memory, through software abstractions such as mutexes and semaphores, to high-level constructs like monitors and condition variables.

This chapter builds the theory from the ground up. We begin with the formal statement of the critical section problem and its correctness requirements. We then examine algorithmic solutions (Peterson's algorithm), hardware-level atomic instructions, and the rich hierarchy of synchronisation abstractions that modern operating systems and language runtimes provide.

---

## 7.1 The Critical Section Problem

### 7.1.1 Motivation

Consider two threads, each incrementing a shared counter:

```c
/* Shared variable */
int counter = 0;

/* Thread 1 */
void *increment(void *arg) {
    for (int i = 0; i < 1000000; i++) {
        counter++;  /* NOT atomic */
    }
    return NULL;
}

/* Thread 2 runs the same function */
```

On a typical machine, the increment `counter++` compiles to three instructions: load the value from memory into a register, add one, and store the result back. If two threads execute these instructions concurrently, their operations can interleave:

```text
Thread 1: LOAD counter  (reads 42)
Thread 2: LOAD counter  (reads 42)
Thread 1: ADD 1         (register = 43)
Thread 2: ADD 1         (register = 43)
Thread 1: STORE counter (writes 43)
Thread 2: STORE counter (writes 43)
```

Both threads performed an increment, but the counter advanced by only one. This is a **race condition**: the program's correctness depends on the relative timing of thread execution.

::: definition
**Definition 7.1 (Race Condition).** A race condition occurs when the outcome of a computation depends on the non-deterministic interleaving of operations by concurrent threads or processes, and at least one interleaving produces an incorrect result.
:::

::: definition
**Definition 7.2 (Critical Section).** A critical section is a segment of code that accesses a shared resource (variable, data structure, file, device) and must not be executed concurrently by more than one thread. The structure of a process participating in a critical section protocol is:

```text
Entry section      -- acquire permission to enter
Critical section   -- access shared resource
Exit section       -- release permission
Remainder section  -- code that does not access shared resources
```
:::

### 7.1.2 Correctness Requirements

Any solution to the critical section problem must satisfy three properties:

::: definition
**Definition 7.3 (Critical Section Requirements).**

1. **Mutual exclusion.** If process $P_i$ is executing in its critical section, no other process $P_j$ ($j \neq i$) may be executing in its critical section simultaneously.

2. **Progress.** If no process is executing in its critical section and some processes wish to enter, the selection of which process enters next cannot be postponed indefinitely. Only processes not in their remainder sections may participate in the decision, and the decision must be made in a finite number of steps.

3. **Bounded waiting.** There exists a bound $B$ such that, after a process $P_i$ has requested entry to its critical section, at most $B$ other processes are allowed to enter their critical sections before $P_i$ is granted entry. This prevents starvation.
:::

The progress requirement is subtle. It forbids solutions where all processes are stuck waiting even though the critical section is free. It also prevents solutions that delegate the decision to processes executing in their remainder section --- those processes may never execute again.

### 7.1.3 The Difficulty of the Problem

The critical section problem may seem trivial at first glance, but it is surprisingly hard to solve correctly without hardware support. The fundamental difficulty is that ordinary read and write operations are not atomic at the system level: between the time a thread reads a variable and acts on the value it read, another thread may have changed that variable. This observation --- that checking a condition and acting on it are two separate steps, susceptible to interleaving --- is the essence of the **time-of-check to time-of-use (TOCTOU)** problem.

::: definition
**Definition 7.3b (TOCTOU Vulnerability).** A time-of-check to time-of-use (TOCTOU) vulnerability exists when a program checks a condition and then takes action based on the result of that check, but the condition may have changed between the check and the action due to concurrent modification.
:::

Every naive approach to the critical section problem falls prey to TOCTOU. The challenge is to design protocols where the check and the action are effectively atomic --- either through careful algorithmic design (Peterson's algorithm) or through hardware atomic instructions (CAS, test-and-set).

### 7.1.4 Naive Attempts

**Attempt 1: Alternation.** A simple approach uses a shared turn variable:

```c
int turn = 0;  /* shared */

/* Process 0 */
while (turn != 0) { /* busy wait */ }
/* critical section */
turn = 1;

/* Process 1 */
while (turn != 1) { /* busy wait */ }
/* critical section */
turn = 0;
```

This satisfies mutual exclusion (only the process whose turn it is can enter) but violates **progress**. If process 0 executes its critical section and sets `turn = 1`, then enters a long remainder section, process 1 can enter and exit, but now `turn = 0` and process 1 cannot re-enter even though the critical section is free. Process 1 depends on process 0 to take its turn.

**Attempt 2: Flag array.** Each process sets a flag indicating its desire to enter:

```c
int flag[2] = {0, 0};  /* shared */

/* Process i */
flag[i] = 1;
while (flag[1 - i]) { /* busy wait */ }
/* critical section */
flag[i] = 0;
```

This violates **mutual exclusion** under certain interleavings. If both processes set their flags to 1 before either checks the other's flag, both will wait forever --- a livelock. Alternatively, if we check before setting, both can enter simultaneously.

These failures motivate more careful solutions.

### 7.1.5 The N-Process Generalisation

For $N > 2$ processes, the critical section problem becomes significantly harder. The **filter lock** (also called the **generalised Peterson's algorithm**) uses $N - 1$ levels, where each level eliminates at least one contending process:

```c
#define N 8  /* number of processes */
int level[N];  /* level[i] = current level of process i */
int victim[N]; /* victim[k] = process that yields at level k */

void filter_lock(int i) {
    for (int k = 1; k < N; k++) {
        level[i] = k;
        victim[k] = i;
        /* Wait while there exists another process at level >= k
           and I am the victim at level k */
        while (victim[k] == i) {
            int found = 0;
            for (int j = 0; j < N; j++) {
                if (j != i && level[j] >= k) {
                    found = 1;
                    break;
                }
            }
            if (!found) break;
        }
    }
}

void filter_unlock(int i) {
    level[i] = 0;
}
```

At each level $k$, at most $N - k$ processes can pass through. At level $N - 1$, at most one process remains. The filter lock satisfies mutual exclusion and freedom from starvation, but its space complexity is $O(N)$ shared variables, and a process must traverse $O(N)$ levels --- making it impractical for large $N$.

::: theorem
**Theorem 7.0b (Lower Bound on Shared Variables).** Any solution to the $N$-process mutual exclusion problem using only read-write registers requires at least $N$ shared variables (Burns and Lynch, 1993).
:::

This lower bound explains why practical synchronisation relies on hardware atomic instructions rather than software algorithms: hardware provides the "bigger hammer" needed to solve the problem efficiently.

---

## 7.2 Peterson's Algorithm

### 7.2.1 The Algorithm

Peterson's algorithm (1981) is the simplest correct software-only solution for two processes under the sequential consistency memory model.

```c
int flag[2] = {0, 0};  /* desire to enter */
int turn;               /* whose turn to yield */

/* Process i (i = 0 or 1) */
void enter_critical_section(int i) {
    int j = 1 - i;
    flag[i] = 1;        /* I want to enter */
    turn = j;            /* but I yield to you */
    while (flag[j] && turn == j) {
        /* busy wait */
    }
}

void exit_critical_section(int i) {
    flag[i] = 0;
}
```

The key insight is the `turn` variable: when both processes want to enter, the one that set `turn` last (the more "polite" one) yields. This combines the flag approach with the turn approach, fixing the defects of both.

### 7.2.2 Correctness Proof

::: theorem
**Theorem 7.1 (Peterson's Algorithm is Correct).** Peterson's algorithm satisfies mutual exclusion, progress, and bounded waiting for two processes, assuming sequential consistency.

*Proof.* We prove each property separately.

**Mutual exclusion.** Suppose, for contradiction, that both $P_0$ and $P_1$ are in their critical sections simultaneously. Then both passed their while-loop conditions: `flag[j] && turn == j` evaluated to false for both $i = 0$ and $i = 1$.

For $P_0$: either $\texttt{flag}[1] = 0$ or $\texttt{turn} = 0$.
For $P_1$: either $\texttt{flag}[0] = 0$ or $\texttt{turn} = 1$.

Since both are in the critical section, both set their flags to 1 before entering (and flags are only cleared in the exit section). So $\texttt{flag}[0] = 1$ and $\texttt{flag}[1] = 1$. Therefore:

- $P_0$ entered because $\texttt{turn} = 0$
- $P_1$ entered because $\texttt{turn} = 1$

But $\texttt{turn}$ is a single variable that cannot simultaneously hold both values. Contradiction. $\square$

**Progress.** Suppose the critical section is free and at least one process wishes to enter. If only one process (say $P_i$) has $\texttt{flag}[i] = 1$, then $\texttt{flag}[j] = 0$, and $P_i$'s while condition is immediately false --- it enters. If both processes set their flags, one of them wrote to $\texttt{turn}$ last, and that process yields to the other. The other enters immediately. In either case, the decision is made without involving processes in their remainder sections. $\square$

**Bounded waiting.** After $P_i$ sets $\texttt{flag}[i] = 1$ and $\texttt{turn} = j$, if $P_j$ is in its critical section, $P_j$ will eventually exit and set $\texttt{flag}[j] = 0$, allowing $P_i$ to enter. If $P_j$ then re-enters the entry section, it sets $\texttt{turn} = i$, which allows $P_i$ to proceed. Thus at most one entry by $P_j$ can occur before $P_i$ enters. The bound is $B = 1$. $\square$
:::

### 7.2.3 Limitations

Peterson's algorithm assumes **sequential consistency**: all memory operations appear in some global total order consistent with each thread's program order. Modern processors with store buffers, write-combining buffers, and relaxed memory models may reorder the writes to `flag[i]` and `turn`, breaking the algorithm.

::: example
**Example 7.1 (Reordering Breaks Peterson's).** On an x86 processor, stores to different addresses may become visible in different orders to different cores (the Total Store Order model permits store-load reordering). Consider:

```text
Process 0:                    Process 1:
  flag[0] = 1                   flag[1] = 1
  turn = 1                      turn = 0
  read flag[1], read turn       read flag[0], read turn
```

Under TSO, the store to `flag[0]` may sit in process 0's store buffer while process 0 reads `flag[1]` from main memory (which still holds 0). Similarly for process 1. Both see the other's flag as 0 and both enter. Memory fences are required to prevent this.
:::

> **Programmer:** On modern hardware, Peterson's algorithm requires explicit memory barriers to work correctly. On x86 (TSO), a `mfence` instruction between the writes and the reads suffices. On ARM or RISC-V (weaker memory models), both store-release and load-acquire barriers are needed. In practice, nobody implements Peterson's algorithm on real hardware --- atomic instructions (Section 7.3) are both simpler and faster. Peterson's algorithm remains essential as a teaching tool and as the foundation for understanding why hardware support is necessary.

---

## 7.3 Hardware Support for Synchronisation

Software-only solutions like Peterson's algorithm are fragile under relaxed memory models and do not generalise efficiently to $N$ processes. Modern processors provide atomic read-modify-write instructions that serve as the building blocks for all practical synchronisation primitives.

### 7.3.1 Test-and-Set

::: definition
**Definition 7.4 (Test-and-Set).** The test-and-set instruction atomically reads a memory location, returns its old value, and writes 1 (or true) to that location:

$$\text{TestAndSet}(\texttt{lock}) : \begin{cases} \texttt{old} \leftarrow \texttt{*lock} \\ \texttt{*lock} \leftarrow 1 \\ \text{return } \texttt{old} \end{cases}$$

The entire operation is indivisible: no other processor can observe a state where the read has completed but the write has not.
:::

A simple spinlock using test-and-set:

```c
#include <stdatomic.h>

typedef atomic_int spinlock_t;

void spin_lock(spinlock_t *lock) {
    while (atomic_exchange(lock, 1) == 1) {
        /* spin */
    }
}

void spin_unlock(spinlock_t *lock) {
    atomic_store(lock, 0);
}
```

This satisfies mutual exclusion: only the thread that observes `old = 0` from the exchange enters the critical section. However, it does not guarantee bounded waiting --- a thread could spin indefinitely while other threads repeatedly acquire and release the lock.

### 7.3.1b Test-and-Test-and-Set (TTAS)

The simple test-and-set spinlock has a severe performance problem on multicore systems. Each `atomic_exchange` generates a write to the lock variable, which invalidates the cache line on all other cores. With $N$ cores spinning, every iteration generates $N - 1$ cache invalidations, creating an $O(N^2)$ bus traffic explosion.

The **test-and-test-and-set (TTAS)** optimisation reduces bus traffic by reading the lock (a non-invalidating cache hit) before attempting the expensive atomic exchange:

```c
void ttas_lock(spinlock_t *lock) {
    while (1) {
        /* Test: spin on cached copy (read-only, no bus traffic) */
        while (atomic_load_explicit(lock, memory_order_relaxed) == 1) {
            /* spin locally on cached copy */
        }
        /* Test-and-set: try to acquire */
        if (atomic_exchange(lock, 1) == 0) {
            return;  /* acquired */
        }
        /* Failed: another thread got it first. Back to spinning. */
    }
}
```

The key insight is that while the lock is held, all spinning threads read their local cached copy of the lock variable, generating no bus traffic. Only when the lock is released (and cache lines are invalidated) do the spinners attempt the expensive exchange. This reduces steady-state bus traffic from $O(N)$ per spin iteration to $O(1)$.

::: example
**Example 7.1b (TTAS Cache Behaviour).** Consider 4 cores spinning on a lock held by Core 0:

```text
TAS (simple):
  Every iteration: Core 1 writes lock -> invalidates Core 2, 3 cache
                   Core 2 writes lock -> invalidates Core 1, 3 cache
                   Core 3 writes lock -> invalidates Core 1, 2 cache
  Bus traffic per iteration: O(N)

TTAS:
  While lock held: Cores 1, 2, 3 read local cache -> 0 bus transactions
  On release:      Core 0 writes lock = 0 -> invalidates all caches
                   Cores 1, 2, 3 read lock (cache miss) -> 3 bus reads
                   Cores 1, 2, 3 attempt exchange -> 3 bus writes
  Total bus traffic per acquisition: O(N) instead of O(N * hold_time)
```

TTAS with exponential backoff further reduces the "thundering herd" effect: after a failed exchange, each thread waits a random exponentially increasing delay before retrying.
:::

### 7.3.2 Compare-and-Swap (CAS)

::: definition
**Definition 7.5 (Compare-and-Swap).** The compare-and-swap (CAS) instruction atomically compares the value at a memory location with an expected value and, if they match, replaces it with a new value:

$$\text{CAS}(\texttt{addr}, \texttt{expected}, \texttt{new}) : \begin{cases} \texttt{old} \leftarrow \texttt{*addr} \\ \text{if } \texttt{old} = \texttt{expected}: \texttt{*addr} \leftarrow \texttt{new} \\ \text{return } \texttt{old} \end{cases}$$

The return value (or a boolean success indicator) tells the caller whether the swap occurred.
:::

CAS is strictly more powerful than test-and-set. It is the foundation of lock-free programming (Chapter 9). On x86, it is implemented by the `LOCK CMPXCHG` instruction; on ARM, by the `LDXR`/`STXR` (load-exclusive/store-exclusive) pair.

```c
#include <stdatomic.h>

void cas_lock(atomic_int *lock) {
    int expected = 0;
    while (!atomic_compare_exchange_weak(lock, &expected, 1)) {
        expected = 0;  /* reset expected after failure */
    }
}

void cas_unlock(atomic_int *lock) {
    atomic_store(lock, 0);
}
```

::: theorem
**Theorem 7.2 (CAS Consensus Number).** The compare-and-swap instruction has an infinite consensus number: it can solve the consensus problem for any number of threads. This means CAS can implement any concurrent data structure in a wait-free manner (via Herlihy's universal construction).

*Proof sketch.* Given $n$ threads, each with a proposed value, allocate a shared variable initialised to $\bot$ (null). Each thread attempts $\text{CAS}(\texttt{decision}, \bot, \texttt{my\_value})$. Exactly one thread succeeds (the first to execute CAS), and all threads can read the decided value. Since no thread blocks and the operation completes in a single CAS per thread, this is wait-free. $\square$
:::

### 7.3.2b The Consensus Hierarchy

Herlihy (1991) classified synchronisation primitives by their **consensus number** --- the maximum number of threads for which the primitive can solve the consensus problem. This classification reveals a strict hierarchy of synchronisation power:

::: definition
**Definition 7.5b (Consensus Number).** The consensus number of a synchronisation primitive is the maximum number of threads $n$ for which the primitive can solve the **consensus problem**: given $n$ threads, each with a proposed value, all threads must agree on one of the proposed values (agreement), the decided value must have been proposed by some thread (validity), and every thread must decide in a finite number of steps (termination).
:::

| Primitive | Consensus Number | Examples |
|-----------|-----------------|----------|
| Atomic read/write registers | 1 | Ordinary variables |
| Test-and-set, swap, fetch-and-add | 2 | `XCHG`, `XADD` |
| Compare-and-swap, LL/SC | $\infty$ | `CMPXCHG`, `LDXR`/`STXR` |

::: theorem
**Theorem 7.2b (Consensus Hierarchy Separation).** No synchronisation primitive with consensus number $k$ can solve consensus for $k + 1$ threads. In particular, read-write registers cannot solve consensus for 2 threads (the FLP impossibility result for asynchronous systems), and test-and-set cannot solve consensus for 3 threads.
:::

This hierarchy has profound practical implications. Since CAS has an infinite consensus number, it can implement **any** concurrent object for **any** number of threads. This is why CAS is the fundamental building block of all modern lock-free data structures (Chapter 9). Test-and-set, despite being simpler and cheaper, cannot implement lock-free structures for more than 2 threads.

### 7.3.3 Fetch-and-Add

::: definition
**Definition 7.6 (Fetch-and-Add).** The fetch-and-add instruction atomically reads a memory location, adds a value to it, and returns the old value:

$$\text{FetchAndAdd}(\texttt{addr}, \texttt{val}) : \begin{cases} \texttt{old} \leftarrow \texttt{*addr} \\ \texttt{*addr} \leftarrow \texttt{old} + \texttt{val} \\ \text{return } \texttt{old} \end{cases}$$
:::

Fetch-and-add enables the construction of **ticket locks**, which provide fairness (bounded waiting):

```c
#include <stdatomic.h>

typedef struct {
    atomic_int ticket;
    atomic_int serving;
} ticket_lock_t;

void ticket_lock(ticket_lock_t *lock) {
    int my_ticket = atomic_fetch_add(&lock->ticket, 1);
    while (atomic_load(&lock->serving) != my_ticket) {
        /* spin */
    }
}

void ticket_unlock(ticket_lock_t *lock) {
    atomic_fetch_add(&lock->serving, 1);
}
```

Each arriving thread takes a unique ticket number. The lock holder increments `serving` on release, granting entry to the next ticket holder in FIFO order. This is a direct analogue of the numbering system at a bakery counter.

::: theorem
**Theorem 7.3 (Ticket Lock Bounded Waiting).** The ticket lock satisfies mutual exclusion, progress, and bounded waiting with bound $B = N - 1$, where $N$ is the number of contending threads.

*Proof.* Mutual exclusion: two threads hold the lock simultaneously only if `serving` equals both their ticket numbers, which is impossible since `fetch_add` assigns distinct tickets. Progress: when the lock is released, `serving` is incremented, and the thread holding the next ticket enters. Bounded waiting: a thread with ticket $k$ waits for at most $N - 1$ other threads (those with tickets $k - N + 1, \ldots, k - 1$ modulo wrap-around) to be served. $\square$
:::

> **Programmer:** The Linux kernel uses a variant of the ticket lock called an **MCS lock** (Mellor-Crummey and Scott, 1991) for its spinlock implementation. The problem with basic ticket locks is cache contention: all spinning threads repeatedly read the same `serving` variable, causing a cache-line ping-pong storm on multi-socket systems. MCS locks solve this by having each thread spin on its own local cache line. When you call `spin_lock()` in the Linux kernel (on x86), the implementation uses `LOCK XADD` (fetch-and-add) for the initial ticket acquisition and queued spinning for the wait phase.

### 7.3.4 LL/SC: Load-Linked and Store-Conditional

ARM, RISC-V, MIPS, and PowerPC architectures do not provide CAS directly. Instead, they offer a pair of instructions:

- **Load-Linked (LL)** / **Load-Exclusive (LDXR)**: reads a memory location and sets a hardware reservation on that cache line.
- **Store-Conditional (SC)** / **Store-Exclusive (STXR)**: writes to the location only if the reservation is still valid (no other core has written to the same cache line since the LL). Returns success or failure.

```c
/* ARM64 CAS emulation using LDXR/STXR (pseudocode) */
int cas_arm64(int *addr, int expected, int new_val) {
    int old;
    int success;
    do {
        old = __LDXR(addr);      /* load-exclusive */
        if (old != expected) {
            __CLREX();            /* clear exclusive monitor */
            return 0;             /* CAS failed */
        }
        success = __STXR(addr, new_val);  /* store-exclusive */
    } while (!success);          /* retry if reservation lost */
    return 1;                    /* CAS succeeded */
}
```

The LL/SC pair is immune to the ABA problem (Chapter 9) because the reservation is invalidated by any write to the cache line, not just by a value change. However, spurious failures are possible (the SC may fail even without interference from other threads), which is why the retry loop is necessary.

---

## 7.4 Mutexes

### 7.4.1 Definition and Semantics

::: definition
**Definition 7.7 (Mutex).** A mutex (mutual exclusion lock) is a synchronisation object with two operations:

- $\texttt{lock}(m)$: acquires exclusive ownership of $m$. If $m$ is already held by another thread, the calling thread blocks (is suspended) until $m$ becomes available.
- $\texttt{unlock}(m)$: releases ownership of $m$. If other threads are blocked waiting for $m$, one of them is woken and granted ownership.

A mutex has a single owner at any time. Only the owner may call $\texttt{unlock}$.
:::

The fundamental difference between a mutex and a spinlock is the **blocking** behaviour. When a spinlock is contended, the waiting thread burns CPU cycles in a busy-wait loop. When a mutex is contended, the waiting thread is placed on a queue and descheduled by the operating system, allowing other threads to use the CPU.

### 7.4.2 Implementation

A typical mutex implementation combines an atomic state variable with a wait queue managed by the kernel:

```c
#include <stdatomic.h>
#include <linux/futex.h>  /* Linux-specific */

typedef struct {
    atomic_int state;  /* 0 = unlocked, 1 = locked (no waiters),
                          2 = locked (waiters present) */
} mutex_t;

void mutex_lock(mutex_t *m) {
    int c;
    /* Fast path: try to acquire uncontended lock */
    c = 0;
    if (atomic_compare_exchange_strong(&m->state, &c, 1))
        return;

    /* Slow path: lock is contended */
    do {
        /* If state was already 2, or we successfully set it to 2 */
        if (c == 2 || atomic_compare_exchange_strong(&m->state, &c, 2)) {
            /* Sleep until woken by unlock */
            futex_wait(&m->state, 2);
        }
        c = 0;
    } while (!atomic_compare_exchange_strong(&m->state, &c, 2));
}

void mutex_unlock(mutex_t *m) {
    if (atomic_fetch_sub(&m->state, 1) != 1) {
        /* There were waiters (state was 2) */
        atomic_store(&m->state, 0);
        futex_wake(&m->state, 1);  /* wake one waiter */
    }
}
```

This three-state design (from Ulrich Drepper's "Futexes Are Tricky") ensures that the common uncontended case requires only a single CAS in userspace --- no system call. The kernel is involved only when actual contention exists.

::: example
**Example 7.2 (Mutex Performance).** Consider a lock protecting a counter incremented 10 million times by 4 threads on a 4-core machine. The critical section is a single increment (a few nanoseconds). Measured performance:

| Strategy | Time | Notes |
|----------|------|-------|
| No synchronisation | 8 ms | Incorrect result |
| Spinlock | 350 ms | Heavy cache contention |
| Mutex (futex-based) | 420 ms | Overhead from context switches |
| Atomic increment | 120 ms | No lock needed; hardware atomics |

For tiny critical sections, atomic operations outperform both spinlocks and mutexes. As the critical section grows longer, mutexes become superior because they free the CPU during the wait.
:::

### 7.4.3 Recursive Mutexes

::: definition
**Definition 7.8 (Recursive Mutex).** A recursive (or reentrant) mutex permits the same thread to acquire the lock multiple times without deadlocking. The mutex maintains an ownership count; each `lock` increments the count, and each `unlock` decrements it. The lock is released only when the count reaches zero.
:::

```c
typedef struct {
    mutex_t base;          /* underlying non-recursive mutex */
    atomic_int owner;      /* thread ID of owner, or 0 */
    int recursion_count;   /* number of recursive acquisitions */
} recursive_mutex_t;

void recursive_lock(recursive_mutex_t *m) {
    int self = get_thread_id();
    if (atomic_load(&m->owner) == self) {
        m->recursion_count++;
        return;
    }
    mutex_lock(&m->base);
    atomic_store(&m->owner, self);
    m->recursion_count = 1;
}

void recursive_unlock(recursive_mutex_t *m) {
    m->recursion_count--;
    if (m->recursion_count == 0) {
        atomic_store(&m->owner, 0);
        mutex_unlock(&m->base);
    }
}
```

Recursive mutexes are controversial. Their proponents argue they simplify designs where a function that holds a lock calls another function that also requires the lock. Their detractors argue that they mask poor design: if you need recursive locking, your lock granularity or call graph is wrong.

### 7.4.4 The Futex Mechanism in Detail

The Linux futex (Fast Userspace muTeX) mechanism, introduced in Linux 2.6, is the foundation of all userspace synchronisation in Linux. Understanding its design illuminates the boundary between userspace and kernel synchronisation.

::: definition
**Definition 7.8b (Futex).** A futex is a 32-bit integer in userspace memory, combined with a kernel wait queue indexed by the integer's address. The kernel provides two operations:

- $\texttt{futex\_wait}(\texttt{addr}, \texttt{expected})$: if `*addr == expected`, put the calling thread to sleep on the wait queue for `addr`. Otherwise, return immediately (the condition changed before we could sleep).
- $\texttt{futex\_wake}(\texttt{addr}, n)$: wake up to $n$ threads sleeping on the wait queue for `addr`.

The key invariant is that `futex_wait` atomically checks the value and sleeps. This prevents the **lost wakeup** problem: if the value changes between the check and the sleep, `futex_wait` returns immediately instead of sleeping forever.
:::

The futex design reflects a fundamental principle: the **common case** (uncontended lock acquisition) should be as fast as possible, even if the **uncommon case** (contention) is slightly slower. In the uncontended case, a mutex acquisition is a single CAS in userspace --- no system call, no kernel involvement, no context switch. The cost is approximately 10--20 nanoseconds on modern hardware. Only when contention occurs does the thread enter the kernel via the `futex` system call.

::: example
**Example 7.2b (Futex Performance Breakdown).**

| Path | Operations | Approximate cost |
|------|-----------|-----------------|
| Uncontended lock | 1 CAS | 10--20 ns |
| Contended lock (sleep) | 1 CAS (fail) + `futex_wait` syscall + context switch | 1--10 $\mu$s |
| Unlock with waiters | 1 atomic store + `futex_wake` syscall + context switch | 1--10 $\mu$s |
| Unlock without waiters | 1 atomic store | 5--10 ns |

In a typical server application, 95--99% of lock acquisitions are uncontended, so the amortised cost of locking is very close to the uncontended cost of 10--20 ns. This is why futex-based mutexes are vastly superior to always-kernel approaches (like System V semaphores, which require a system call on every operation).
:::

---

## 7.5 Semaphores

### 7.5.1 Definition

Edsger Dijkstra introduced semaphores in 1965 as a generalisation of the mutex concept.

::: definition
**Definition 7.9 (Semaphore).** A semaphore $S$ is a non-negative integer variable accessed through two atomic operations:

- $\texttt{wait}(S)$ (historically $P(S)$, from the Dutch *probeer*, "try"):

$$\texttt{wait}(S): \text{while } S \leq 0 \text{ do block; } S \leftarrow S - 1$$

- $\texttt{signal}(S)$ (historically $V(S)$, from *verhoog*, "increment"):

$$\texttt{signal}(S): S \leftarrow S + 1; \text{ wake one blocked process if any}$$

A **binary semaphore** has values restricted to $\{0, 1\}$ and behaves similarly to a mutex (but without ownership semantics). A **counting semaphore** may take any non-negative integer value.
:::

::: example
**Example 7.3 (Semaphore as Mutex).** A binary semaphore initialised to 1 provides mutual exclusion:

```c
sem_t mutex;
sem_init(&mutex, 0, 1);  /* initial value = 1 */

/* Thread */
sem_wait(&mutex);     /* P: decrement, block if 0 */
/* critical section */
sem_post(&mutex);     /* V: increment */
```

The key difference from a true mutex is that any thread can call `sem_post`, not just the one that called `sem_wait`. This makes semaphores more flexible but also more error-prone.
:::

### 7.5.1b Semaphore Implementation

A semaphore can be implemented using a mutex and a condition variable, demonstrating how higher-level primitives are built from lower-level ones:

```c
#include <pthread.h>

typedef struct {
    int value;
    pthread_mutex_t lock;
    pthread_cond_t cond;
} sem_impl_t;

void sem_impl_init(sem_impl_t *s, int initial_value) {
    s->value = initial_value;
    pthread_mutex_init(&s->lock, NULL);
    pthread_cond_init(&s->cond, NULL);
}

void sem_impl_wait(sem_impl_t *s) {
    pthread_mutex_lock(&s->lock);
    while (s->value <= 0)
        pthread_cond_wait(&s->cond, &s->lock);
    s->value--;
    pthread_mutex_unlock(&s->lock);
}

void sem_impl_signal(sem_impl_t *s) {
    pthread_mutex_lock(&s->lock);
    s->value++;
    pthread_cond_signal(&s->cond);
    pthread_mutex_unlock(&s->lock);
}
```

The `while` loop in `sem_impl_wait` is necessary because of Mesa semantics: the signalled thread may not run immediately, and another thread could decrement the semaphore before it resumes.

### 7.5.2 Producer-Consumer Problem

The producer-consumer (bounded-buffer) problem is a canonical synchronisation scenario:

::: definition
**Definition 7.10 (Producer-Consumer Problem).** Given a buffer of size $N$ shared between producer threads (which insert items) and consumer threads (which remove items):

1. Producers must block when the buffer is full.
2. Consumers must block when the buffer is empty.
3. Access to the buffer must be mutually exclusive.
:::

The semaphore solution uses three semaphores:

```c
#include <semaphore.h>
#include <pthread.h>

#define BUFFER_SIZE 10

int buffer[BUFFER_SIZE];
int in = 0, out = 0;

sem_t empty;   /* counts empty slots */
sem_t full;    /* counts filled slots */
sem_t mutex;   /* protects buffer access */

void init(void) {
    sem_init(&empty, 0, BUFFER_SIZE);
    sem_init(&full, 0, 0);
    sem_init(&mutex, 0, 1);
}

void *producer(void *arg) {
    while (1) {
        int item = produce_item();
        sem_wait(&empty);       /* wait for empty slot */
        sem_wait(&mutex);       /* enter critical section */
        buffer[in] = item;
        in = (in + 1) % BUFFER_SIZE;
        sem_post(&mutex);       /* exit critical section */
        sem_post(&full);        /* signal that a slot is filled */
    }
    return NULL;
}

void *consumer(void *arg) {
    while (1) {
        sem_wait(&full);        /* wait for filled slot */
        sem_wait(&mutex);       /* enter critical section */
        int item = buffer[out];
        out = (out + 1) % BUFFER_SIZE;
        sem_post(&mutex);       /* exit critical section */
        sem_post(&empty);       /* signal that a slot is freed */
        consume_item(item);
    }
    return NULL;
}
```

::: theorem
**Theorem 7.4 (Correctness of Bounded-Buffer Solution).** The three-semaphore bounded-buffer solution satisfies:

1. **Mutual exclusion**: the `mutex` semaphore ensures only one thread modifies the buffer at a time.
2. **No buffer overflow**: a producer blocks when `empty = 0` (all slots are full).
3. **No buffer underflow**: a consumer blocks when `full = 0` (all slots are empty).
4. **No deadlock**: a process that holds `mutex` never waits on `empty` or `full` (the semaphore order prevents circular waiting).

*Proof.* The invariant $\texttt{empty} + \texttt{full} = N$ is maintained: each `sem_wait(&empty)` / `sem_post(&full)` pair preserves it, as does each `sem_wait(&full)` / `sem_post(&empty)` pair. Since both semaphores are non-negative, $\texttt{full} \leq N$ and $\texttt{empty} \leq N$. The ordering constraint --- always acquire `empty` or `full` before `mutex` --- prevents deadlock because no thread holds `mutex` while waiting for a counting semaphore. $\square$
:::

### 7.5.3 Readers-Writers Problem

::: definition
**Definition 7.11 (Readers-Writers Problem).** A shared database is accessed by two classes of processes:

- **Readers**: only read the database; multiple readers can access it simultaneously.
- **Writers**: modify the database; a writer requires exclusive access (no other readers or writers).
:::

**First readers-writers solution (readers preference):**

```c
sem_t rw_mutex;     /* controls writer access */
sem_t mutex;        /* protects read_count */
int read_count = 0;

void init(void) {
    sem_init(&rw_mutex, 0, 1);
    sem_init(&mutex, 0, 1);
}

void *reader(void *arg) {
    sem_wait(&mutex);
    read_count++;
    if (read_count == 1)
        sem_wait(&rw_mutex);  /* first reader locks out writers */
    sem_post(&mutex);

    /* read the database */

    sem_wait(&mutex);
    read_count--;
    if (read_count == 0)
        sem_post(&rw_mutex);  /* last reader lets writers in */
    sem_post(&mutex);
    return NULL;
}

void *writer(void *arg) {
    sem_wait(&rw_mutex);
    /* write to the database */
    sem_post(&rw_mutex);
    return NULL;
}
```

This solution allows readers to starve writers: as long as at least one reader is active, new readers can enter continuously, and the writer never gets access.

**Second readers-writers solution (writers preference):**

To prevent writer starvation, we add a mechanism that blocks new readers when a writer is waiting:

```c
sem_t rw_mutex;     /* controls writer access */
sem_t mutex;        /* protects read_count and write_count */
sem_t read_try;     /* blocks readers when writer is waiting */
int read_count = 0;
int write_count = 0;

void init(void) {
    sem_init(&rw_mutex, 0, 1);
    sem_init(&mutex, 0, 1);
    sem_init(&read_try, 0, 1);
}

void *reader(void *arg) {
    sem_wait(&read_try);      /* check if readers are allowed */
    sem_wait(&mutex);
    read_count++;
    if (read_count == 1)
        sem_wait(&rw_mutex);  /* first reader locks out writers */
    sem_post(&mutex);
    sem_post(&read_try);

    /* read the database */

    sem_wait(&mutex);
    read_count--;
    if (read_count == 0)
        sem_post(&rw_mutex);  /* last reader lets writers in */
    sem_post(&mutex);
    return NULL;
}

void *writer(void *arg) {
    sem_wait(&read_try);      /* block new readers */
    sem_wait(&rw_mutex);      /* exclusive access */

    /* write to the database */

    sem_post(&rw_mutex);
    sem_post(&read_try);      /* allow readers again */
    return NULL;
}
```

When a writer calls `sem_wait(&read_try)`, it blocks subsequent readers from entering the `read_try` section. Readers already inside the critical section can finish, but no new readers can start. Once all existing readers exit and release `rw_mutex`, the writer proceeds. This gives writers preference at the cost of potentially starving readers.

::: theorem
**Theorem 7.4b (No Fair Readers-Writers Solution with Semaphores Alone).** Neither the readers-preference nor the writers-preference solution is fair: one class of processes can starve the other. A **fair** readers-writers solution requires additional mechanisms such as a FIFO queue or a turnstile that alternates between readers and writers.
:::

### 7.5.4 Dining Philosophers Problem

::: definition
**Definition 7.12 (Dining Philosophers).** Five philosophers sit at a round table. Between each pair of adjacent philosophers lies one chopstick (five total). A philosopher alternates between thinking and eating. To eat, a philosopher must acquire both the left and right chopsticks. The problem is to design a protocol that prevents deadlock and starvation.
:::

**Naive solution (deadlock-prone):**

```c
sem_t chopstick[5];

void *philosopher(void *arg) {
    int i = *(int *)arg;
    while (1) {
        think();
        sem_wait(&chopstick[i]);           /* pick up left */
        sem_wait(&chopstick[(i + 1) % 5]); /* pick up right */
        eat();
        sem_post(&chopstick[(i + 1) % 5]); /* put down right */
        sem_post(&chopstick[i]);           /* put down left */
    }
    return NULL;
}
```

If all five philosophers pick up their left chopstick simultaneously, all will block waiting for the right one. This is a textbook deadlock.

**Solution: Asymmetric ordering.** Philosopher 4 picks up chopsticks in reverse order (right first, then left). This breaks the circular wait condition:

```c
void *philosopher(void *arg) {
    int i = *(int *)arg;
    while (1) {
        think();
        if (i == 4) {
            sem_wait(&chopstick[0]);           /* right first */
            sem_wait(&chopstick[4]);           /* then left */
        } else {
            sem_wait(&chopstick[i]);           /* left first */
            sem_wait(&chopstick[(i + 1) % 5]); /* then right */
        }
        eat();
        sem_post(&chopstick[(i + 1) % 5]);
        sem_post(&chopstick[i]);
    }
    return NULL;
}
```

More generally, one can impose a total order on resource acquisition (always acquire the lower-numbered chopstick first), which is the resource ordering strategy for deadlock prevention (Chapter 8).

**Solution: Limit concurrency.** An alternative approach limits the number of philosophers allowed to eat simultaneously. With a semaphore initialised to $N - 1 = 4$, at most 4 philosophers can attempt to pick up chopsticks at once. Since 5 chopsticks exist and at most 4 philosophers hold one each, at least one chopstick remains free, guaranteeing that at least one philosopher can obtain both chopsticks:

```c
sem_t seats;  /* limits concurrent eaters */
sem_init(&seats, 0, 4);  /* N - 1 */

void *philosopher(void *arg) {
    int i = *(int *)arg;
    while (1) {
        think();
        sem_wait(&seats);                      /* sit at table */
        sem_wait(&chopstick[i]);               /* pick up left */
        sem_wait(&chopstick[(i + 1) % 5]);     /* pick up right */
        eat();
        sem_post(&chopstick[(i + 1) % 5]);
        sem_post(&chopstick[i]);
        sem_post(&seats);                      /* leave table */
    }
    return NULL;
}
```

::: theorem
**Theorem 7.4c (Dining Philosophers with N-1 Seats).** Allowing at most $N - 1$ of $N$ philosophers to attempt eating simultaneously guarantees deadlock freedom with $N$ chopsticks.

*Proof.* With at most $N - 1$ philosophers at the table and $N$ chopsticks, by the pigeonhole principle, at least one philosopher has both adjacent chopsticks available and can eat. That philosopher will eventually finish and release both chopsticks, allowing others to proceed. Since at least one philosopher always makes progress, no deadlock occurs. $\square$
:::

This solution has the drawback of reduced concurrency: even when enough chopsticks are free for all 5 philosophers, only 4 are allowed to try.

---

## 7.6 Monitors and Condition Variables

### 7.6.1 The Problem with Semaphores

Semaphores are powerful but low-level. Common errors include:

- Swapping the order of `wait` operations (e.g., acquiring `mutex` before `empty` in the producer-consumer problem) $\rightarrow$ deadlock.
- Forgetting to call `signal` $\rightarrow$ permanent blocking.
- Calling `signal` instead of `wait` (or vice versa) $\rightarrow$ violation of mutual exclusion.

Monitors, introduced by C.A.R. Hoare (1974) and Per Brinch Hansen (1973), encapsulate synchronisation within an abstract data type, making errors structurally impossible.

### 7.6.2 Monitor Definition

::: definition
**Definition 7.13 (Monitor).** A monitor is a synchronisation construct consisting of:

1. A set of programmer-defined procedures (entry points).
2. Private data variables accessible only through these procedures.
3. An implicit mutual exclusion lock: at most one thread may be executing any monitor procedure at any time.
4. **Condition variables** that allow threads to wait for specific conditions inside the monitor.
:::

### 7.6.3 Condition Variables

::: definition
**Definition 7.14 (Condition Variable).** A condition variable $c$ associated with a monitor supports two operations:

- $\texttt{wait}(c)$: the calling thread releases the monitor lock, blocks on $c$'s wait queue, and re-acquires the monitor lock when signalled.
- $\texttt{signal}(c)$: if any threads are waiting on $c$, one is woken. If no threads are waiting, the signal is lost (it is not queued).

Unlike semaphores, condition variables have no state. A signal with no waiters has no effect.
:::

::: example
**Example 7.4 (Bounded Buffer with Monitor).** The producer-consumer problem expressed as a monitor:

```c
#include <pthread.h>

#define BUFFER_SIZE 10

typedef struct {
    int buffer[BUFFER_SIZE];
    int count, in, out;
    pthread_mutex_t lock;
    pthread_cond_t not_full;
    pthread_cond_t not_empty;
} bounded_buffer_t;

void bb_init(bounded_buffer_t *bb) {
    bb->count = bb->in = bb->out = 0;
    pthread_mutex_init(&bb->lock, NULL);
    pthread_cond_init(&bb->not_full, NULL);
    pthread_cond_init(&bb->not_empty, NULL);
}

void bb_insert(bounded_buffer_t *bb, int item) {
    pthread_mutex_lock(&bb->lock);
    while (bb->count == BUFFER_SIZE)
        pthread_cond_wait(&bb->not_full, &bb->lock);
    bb->buffer[bb->in] = item;
    bb->in = (bb->in + 1) % BUFFER_SIZE;
    bb->count++;
    pthread_cond_signal(&bb->not_empty);
    pthread_mutex_unlock(&bb->lock);
}

int bb_remove(bounded_buffer_t *bb) {
    pthread_mutex_lock(&bb->lock);
    while (bb->count == 0)
        pthread_cond_wait(&bb->not_empty, &bb->lock);
    int item = bb->buffer[bb->out];
    bb->out = (bb->out + 1) % BUFFER_SIZE;
    bb->count--;
    pthread_cond_signal(&bb->not_full);
    pthread_mutex_unlock(&bb->lock);
    return item;
}
```

Note the `while` loop around `pthread_cond_wait` --- this is essential under Mesa semantics (see below).
:::

### 7.6.4 Mesa vs Hoare Semantics

The critical question in monitor design is: when `signal(c)` wakes a waiting thread, which thread runs next?

::: definition
**Definition 7.15 (Hoare Semantics).** When thread $A$ executes $\texttt{signal}(c)$, the signalled thread $B$ runs immediately inside the monitor. Thread $A$ is suspended until $B$ exits the monitor or waits again. The condition that $B$ was waiting for is guaranteed to hold when $B$ resumes.
:::

::: definition
**Definition 7.16 (Mesa Semantics).** When thread $A$ executes $\texttt{signal}(c)$, it merely marks thread $B$ as runnable. Thread $A$ continues executing in the monitor. By the time $B$ actually runs, the condition may no longer hold, so $B$ must recheck it (hence the `while` loop around `wait`).
:::

| Property | Hoare | Mesa |
|----------|-------|------|
| Condition guaranteed on wake | Yes | No --- must recheck |
| Signaller suspended | Yes | No |
| Wait pattern | `if (!condition) wait(c)` | `while (!condition) wait(c)` |
| Implementation complexity | High | Low |
| Used in practice | Rare | Universal (POSIX, Java, Go) |

::: example
**Example 7.4b (Dining Philosophers with Monitor).** The dining philosophers problem can be elegantly solved using a monitor that tracks the state of each philosopher:

```c
#include <pthread.h>

#define N 5
enum state_t { THINKING, HUNGRY, EATING };

typedef struct {
    enum state_t state[N];
    pthread_mutex_t lock;
    pthread_cond_t can_eat[N];  /* one condition per philosopher */
} dining_monitor_t;

void try_eat(dining_monitor_t *m, int i) {
    /* Can eat only if hungry and neither neighbour is eating */
    if (m->state[i] == HUNGRY &&
        m->state[(i + N - 1) % N] != EATING &&
        m->state[(i + 1) % N] != EATING) {
        m->state[i] = EATING;
        pthread_cond_signal(&m->can_eat[i]);
    }
}

void pickup(dining_monitor_t *m, int i) {
    pthread_mutex_lock(&m->lock);
    m->state[i] = HUNGRY;
    try_eat(m, i);
    while (m->state[i] != EATING)
        pthread_cond_wait(&m->can_eat[i], &m->lock);
    pthread_mutex_unlock(&m->lock);
}

void putdown(dining_monitor_t *m, int i) {
    pthread_mutex_lock(&m->lock);
    m->state[i] = THINKING;
    /* Check if neighbours can now eat */
    try_eat(m, (i + N - 1) % N);
    try_eat(m, (i + 1) % N);
    pthread_mutex_unlock(&m->lock);
}
```

This monitor-based solution avoids the individual chopstick locks entirely. A philosopher eats only when both neighbours are not eating, checked atomically inside the monitor. When a philosopher finishes, it signals its neighbours, who may then transition from HUNGRY to EATING. This solution is deadlock-free and starvation-free (under fair scheduling of condition variable waits).
:::

::: theorem
**Theorem 7.5 (Mesa Semantics Sufficiency).** Any correct program under Hoare semantics remains correct under Mesa semantics if every `wait` is enclosed in a `while` loop that rechecks the condition.

*Proof.* Under Hoare semantics, the condition holds immediately upon waking from `wait`. Under Mesa semantics, the condition may not hold, but the `while` loop causes the thread to re-wait. The thread proceeds past the `while` only when the condition is actually true, which is exactly the Hoare guarantee. The only difference is that under Mesa semantics, a thread may wait multiple times, but since each wait releases and re-acquires the lock correctly, correctness is preserved. $\square$
:::

---

## 7.7 Spinlocks vs Sleeping Locks

### 7.7.1 When to Use Which

The choice between spinning and sleeping depends on the expected wait time relative to the cost of a context switch:

::: definition
**Definition 7.17 (Context Switch Cost).** A context switch involves saving the current thread's register state, updating scheduler data structures, flushing and reloading TLB entries, and potentially flushing cache lines. The total cost on modern hardware is typically 1--10 microseconds.
:::

**Use spinlocks when:**

- The critical section is shorter than two context switches (the waiting thread would waste more time sleeping and waking than spinning).
- You are in a context where sleeping is not permitted (e.g., interrupt handlers in the kernel).
- The number of contending threads is small relative to the number of cores.

**Use sleeping locks (mutexes) when:**

- The critical section is long (file I/O, network operations, complex computations).
- There are many more contending threads than available cores.
- You want to free the CPU for other work during the wait.

### 7.7.2 Adaptive Spinning

Modern mutex implementations combine both strategies. The Linux kernel's `mutex_lock()` and Go's `sync.Mutex` use **adaptive spinning**: they spin for a short time hoping the lock will be released quickly, then fall back to sleeping if the lock remains held.

::: example
**Example 7.5 (Adaptive Spinning in Practice).** The Linux kernel's `mutex_optimistic_spin()` function checks whether the lock owner is currently running on a CPU. If so, it spins --- the owner is likely to release the lock soon. If the owner is not running (was preempted or is sleeping), spinning is futile, so the waiter sleeps immediately. This heuristic dramatically reduces unnecessary context switches for short critical sections while avoiding wasted spinning when the lock holder is not making progress.
:::

### 7.7.3 Exponential Backoff

A key optimisation for spinlocks under contention is **exponential backoff**: after failing to acquire the lock, a thread waits for a random delay before retrying, and the delay doubles after each failure:

```c
#include <stdatomic.h>
#include <time.h>

#define MIN_DELAY 100     /* nanoseconds */
#define MAX_DELAY 100000  /* nanoseconds */

void spin_lock_backoff(spinlock_t *lock) {
    int delay = MIN_DELAY;
    while (1) {
        /* TTAS: test first, then try to acquire */
        while (atomic_load_explicit(lock, memory_order_relaxed) == 1)
            ;  /* spin on local cache */
        if (atomic_exchange(lock, 1) == 0)
            return;  /* acquired */
        /* Backoff: wait before retrying */
        struct timespec ts = {0, delay + (rand() % delay)};
        nanosleep(&ts, NULL);
        delay = (delay * 2 < MAX_DELAY) ? delay * 2 : MAX_DELAY;
    }
}
```

Exponential backoff reduces contention (fewer threads hammering the bus simultaneously) at the cost of increased latency when the lock becomes free.

### 7.7.4 Cost Analysis

Let $T_{\text{cs}}$ be the critical section duration and $T_{\text{ctx}}$ be the context switch cost. For a sleeping lock, the waiting thread incurs $2 \cdot T_{\text{ctx}}$ (sleep + wake). For a spinlock, the waiting thread burns CPU for $T_{\text{cs}}$ on average.

Spinning is cheaper when $T_{\text{cs}} < 2 \cdot T_{\text{ctx}}$. On modern hardware with $T_{\text{ctx}} \approx 5\,\mu\text{s}$, this threshold is approximately $10\,\mu\text{s}$.

::: example
**Example 7.5b (Lock Strategy Decision Tree).**

```text
Is the critical section < 10 us?
├── Yes: Is it in an interrupt handler?
│   ├── Yes: Use raw spinlock (cannot sleep in interrupt context)
│   └── No: Use spinlock with TTAS + backoff
└── No: Is it > 100 us?
    ├── Yes: Use sleeping mutex (futex-based)
    └── No: Use adaptive spinning mutex
            (spin briefly, then sleep)
```

This decision tree captures the practical heuristics used by kernel developers and language runtime designers. The Linux kernel uses raw spinlocks for interrupt handlers, MCS-style spinlocks for short critical sections, and sleeping mutexes for longer ones. The Go runtime's `sync.Mutex` uses adaptive spinning (spin for up to 4 iterations before sleeping).
:::

---

## 7.8 Read-Write Locks

### 7.8.1 Definition

::: definition
**Definition 7.18 (Read-Write Lock).** A read-write lock (RWLock) permits concurrent access by multiple readers or exclusive access by a single writer:

- $\texttt{read\_lock}(rw)$: acquires shared access. Blocks only if a writer holds the lock.
- $\texttt{read\_unlock}(rw)$: releases shared access.
- $\texttt{write\_lock}(rw)$: acquires exclusive access. Blocks if any reader or writer holds the lock.
- $\texttt{write\_unlock}(rw)$: releases exclusive access.
:::

Read-write locks improve throughput for workloads dominated by reads. If $r$ readers and $w$ writers access a resource, and the read-to-write ratio is $r : w$, the maximum concurrency with a regular mutex is 1, while with an RWLock it is $r$ (when no writers are active).

### 7.8.2 Implementation

```c
#include <pthread.h>

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t readers_ok;
    pthread_cond_t writer_ok;
    int active_readers;
    int active_writers;
    int waiting_writers;
} rwlock_t;

void rwlock_init(rwlock_t *rw) {
    pthread_mutex_init(&rw->lock, NULL);
    pthread_cond_init(&rw->readers_ok, NULL);
    pthread_cond_init(&rw->writer_ok, NULL);
    rw->active_readers = 0;
    rw->active_writers = 0;
    rw->waiting_writers = 0;
}

void rwlock_read_lock(rwlock_t *rw) {
    pthread_mutex_lock(&rw->lock);
    /* Writers-preference: block if writers are waiting */
    while (rw->active_writers > 0 || rw->waiting_writers > 0)
        pthread_cond_wait(&rw->readers_ok, &rw->lock);
    rw->active_readers++;
    pthread_mutex_unlock(&rw->lock);
}

void rwlock_read_unlock(rwlock_t *rw) {
    pthread_mutex_lock(&rw->lock);
    rw->active_readers--;
    if (rw->active_readers == 0)
        pthread_cond_signal(&rw->writer_ok);
    pthread_mutex_unlock(&rw->lock);
}

void rwlock_write_lock(rwlock_t *rw) {
    pthread_mutex_lock(&rw->lock);
    rw->waiting_writers++;
    while (rw->active_readers > 0 || rw->active_writers > 0)
        pthread_cond_wait(&rw->writer_ok, &rw->lock);
    rw->waiting_writers--;
    rw->active_writers = 1;
    pthread_mutex_unlock(&rw->lock);
}

void rwlock_write_unlock(rwlock_t *rw) {
    pthread_mutex_lock(&rw->lock);
    rw->active_writers = 0;
    /* Wake one writer or all readers */
    pthread_cond_signal(&rw->writer_ok);
    pthread_cond_broadcast(&rw->readers_ok);
    pthread_mutex_unlock(&rw->lock);
}
```

This implementation gives **writers preference**: when a writer is waiting, new readers are blocked. This prevents writer starvation at the cost of potentially starving readers under heavy write contention.

### 7.8.3 Sequence Locks (Seqlocks)

::: definition
**Definition 7.19 (Sequence Lock).** A sequence lock uses a sequence counter to allow readers to proceed without acquiring any lock. Writers increment the counter before and after writing. Readers check the counter before and after reading: if the counter changed or is odd (indicating a write in progress), the read is retried.
:::

```c
#include <stdatomic.h>

typedef struct {
    atomic_int sequence;
    pthread_mutex_t write_lock;
} seqlock_t;

void seqlock_write_lock(seqlock_t *sl) {
    pthread_mutex_lock(&sl->write_lock);
    atomic_fetch_add(&sl->sequence, 1);  /* odd = write in progress */
    atomic_thread_fence(memory_order_release);
}

void seqlock_write_unlock(seqlock_t *sl) {
    atomic_thread_fence(memory_order_release);
    atomic_fetch_add(&sl->sequence, 1);  /* even = write complete */
    pthread_mutex_unlock(&sl->write_lock);
}

int seqlock_read_begin(seqlock_t *sl) {
    int seq;
    do {
        seq = atomic_load(&sl->sequence);
    } while (seq & 1);  /* wait if write in progress */
    atomic_thread_fence(memory_order_acquire);
    return seq;
}

int seqlock_read_retry(seqlock_t *sl, int old_seq) {
    atomic_thread_fence(memory_order_acquire);
    return atomic_load(&sl->sequence) != old_seq;
}
```

Usage pattern for readers:

```c
/* Reader: optimistic, lock-free read */
int seq;
struct data local_copy;
do {
    seq = seqlock_read_begin(&lock);
    local_copy = shared_data;  /* may read torn data */
} while (seqlock_read_retry(&lock, seq));
/* local_copy is now consistent */
```

Seqlocks are ideal when:

- Reads are far more frequent than writes.
- The shared data is small (fits in a few cache lines).
- Readers can tolerate occasionally reading inconsistent data (since they will retry).

The Linux kernel uses seqlocks extensively, notably for reading the system time (`jiffies`, `xtime`), where reads happen billions of times per second but writes happen only at timer-tick frequency.

### 7.8.4 Choosing Between Lock Types

The following table summarises the synchronisation landscape and helps practitioners select the right primitive for each scenario:

| Scenario | Best primitive | Reason |
|----------|---------------|--------|
| Single writer, rare writes, many readers | Seqlock | Readers never block; near-zero overhead |
| Many readers, occasional writers | Read-write lock (writer preference) | Concurrent reads; writers not starved |
| Equal reads and writes | Mutex | RWLock overhead not justified |
| Single shared counter | `atomic_fetch_add` | No lock needed |
| Complex multi-variable update | Mutex + condition variable | Atomicity across variables |
| Real-time, must not block | Spinlock + disable preemption | Bounded worst-case latency |

::: example
**Example 7.6 (Seqlock for System Time).** The Linux kernel stores the current time in a `timekeeper` structure protected by a seqlock. Every timer interrupt (typically every 1--10 ms), the kernel writes the new time using `write_seqlock`. Every call to `gettimeofday()` reads the time using the seqlock's optimistic read pattern. Since timer interrupts are rare compared to time queries, the reader almost never needs to retry, achieving near-zero synchronisation overhead for the common case.
:::

### 7.8.5 Barriers

::: definition
**Definition 7.20 (Barrier).** A barrier is a synchronisation construct where $N$ threads must all arrive at the barrier point before any of them is allowed to proceed past it. The barrier enforces a global synchronisation point in a parallel computation.
:::

Barriers are essential in parallel algorithms that operate in phases: all threads complete phase $k$ before any thread begins phase $k + 1$. Examples include parallel matrix operations, iterative solvers, and parallel sorting.

```c
#include <pthread.h>

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t all_arrived;
    int count;       /* number of threads currently waiting */
    int threshold;   /* total number of threads */
    int generation;  /* prevents premature release on reuse */
} barrier_t;

void barrier_init(barrier_t *b, int num_threads) {
    pthread_mutex_init(&b->lock, NULL);
    pthread_cond_init(&b->all_arrived, NULL);
    b->count = 0;
    b->threshold = num_threads;
    b->generation = 0;
}

void barrier_wait(barrier_t *b) {
    pthread_mutex_lock(&b->lock);
    int gen = b->generation;
    b->count++;
    if (b->count == b->threshold) {
        /* Last thread to arrive: reset and wake all */
        b->count = 0;
        b->generation++;
        pthread_cond_broadcast(&b->all_arrived);
    } else {
        /* Wait for all threads to arrive */
        while (gen == b->generation)
            pthread_cond_wait(&b->all_arrived, &b->lock);
    }
    pthread_mutex_unlock(&b->lock);
}
```

The `generation` counter is critical for reusable barriers: without it, a fast thread that passes through the barrier and loops back could see the old `count` value and proceed prematurely. The generation counter ensures that threads from different phases do not interfere.

::: example
**Example 7.6b (Parallel Matrix Computation with Barrier).** A parallel iterative solver (e.g., Jacobi iteration) updates each cell of a matrix based on its neighbours' values from the previous iteration:

```c
/* Each thread handles a portion of the matrix */
void *worker(void *arg) {
    int my_id = *(int *)arg;
    for (int iter = 0; iter < MAX_ITER; iter++) {
        /* Phase 1: compute new values from old values */
        for (int i = my_start; i < my_end; i++)
            for (int j = 1; j < N - 1; j++)
                new_matrix[i][j] = 0.25 * (old_matrix[i-1][j] +
                    old_matrix[i+1][j] + old_matrix[i][j-1] +
                    old_matrix[i][j+1]);

        barrier_wait(&phase_barrier);  /* all threads finish computing */

        /* Phase 2: swap old and new matrices */
        if (my_id == 0)
            swap_pointers(&old_matrix, &new_matrix);

        barrier_wait(&swap_barrier);   /* all threads see swapped pointers */
    }
    return NULL;
}
```

Without the barriers, Thread A might start reading `old_matrix` values that Thread B has already overwritten with new values, producing incorrect results. The barrier ensures phase separation.
:::

---

## 7.9 Programmer's Perspective: Go's Synchronisation Primitives

> **Programmer:** Go provides a rich set of synchronisation primitives in the `sync` and `sync/atomic` packages, designed around the principle that synchronisation should be explicit and composable. Understanding their implementation reveals how the concepts from this chapter map to a modern language runtime.
>
> **sync.Mutex** is a sleeping lock with adaptive spinning. Its internal structure uses a 32-bit state word encoding whether the lock is held, whether a goroutine is woken, whether the lock is in starvation mode, and the number of waiters. The fast path is a single `atomic.CompareAndSwapInt32`. If that fails, the goroutine spins briefly (up to 4 iterations on a multicore machine) before parking itself on a semaphore queue managed by the Go runtime. After 1 ms of waiting, the lock enters **starvation mode**, where ownership is handed directly to the longest-waiting goroutine (FIFO), preventing tail-latency problems:
>
> ```go
> package main
>
> import (
>     "fmt"
>     "sync"
> )
>
> func main() {
>     var mu sync.Mutex
>     counter := 0
>
>     var wg sync.WaitGroup
>     for i := 0; i < 1000; i++ {
>         wg.Add(1)
>         go func() {
>             defer wg.Done()
>             mu.Lock()
>             counter++
>             mu.Unlock()
>         }()
>     }
>
>     wg.Wait()
>     fmt.Println("Counter:", counter) // always 1000
> }
> ```
>
> **sync.RWMutex** implements a read-write lock. Internally, it uses a `sync.Mutex` for write serialisation plus atomic counters for reader tracking. When a writer calls `Lock()`, it sets a flag (by subtracting a large constant from the reader count) that blocks new readers, then waits for existing readers to finish. This is a writers-preference design that avoids writer starvation:
>
> ```go
> package main
>
> import (
>     "fmt"
>     "sync"
> )
>
> type SafeMap struct {
>     mu   sync.RWMutex
>     data map[string]int
> }
>
> func (m *SafeMap) Get(key string) (int, bool) {
>     m.mu.RLock()
>     defer m.mu.RUnlock()
>     v, ok := m.data[key]
>     return v, ok
> }
>
> func (m *SafeMap) Set(key string, value int) {
>     m.mu.Lock()
>     defer m.mu.Unlock()
>     m.data[key] = value
> }
>
> func main() {
>     m := &SafeMap{data: make(map[string]int)}
>     m.Set("x", 42)
>     v, _ := m.Get("x")
>     fmt.Println(v) // 42
> }
> ```
>
> **sync.WaitGroup** provides a barrier synchronisation mechanism. Its internal state packs the counter and the waiter count into a single 64-bit atomic word (for alignment reasons on 32-bit platforms). `Add(n)` increments the counter atomically. `Done()` is equivalent to `Add(-1)`. `Wait()` blocks until the counter reaches zero, using the same runtime semaphore infrastructure as `sync.Mutex`. The 64-bit atomic state allows checking both the counter and waiter count in a single `atomic.LoadUint64`, avoiding the need for a mutex in the fast path.
>
> The critical design principle in Go's sync package is **zero-value usability**: `var mu sync.Mutex` is ready to use without initialisation. This eliminates an entire class of bugs (forgetting to call `init`) that plague C/C++ synchronisation code. However, Go mutexes must not be copied after first use, which the `go vet` tool detects statically.

> **Programmer:** When choosing between Go's synchronisation primitives, consider these guidelines:
>
> - Use **channels** for communication between goroutines (passing ownership of data).
> - Use **sync.Mutex** when protecting a shared data structure that multiple goroutines read and write.
> - Use **sync.RWMutex** when reads dominate writes (at least 10:1 ratio; otherwise the reader-tracking overhead negates the benefit).
> - Use **sync/atomic** for single-variable updates where you need maximum performance and can reason about memory ordering.
> - Use **sync.WaitGroup** for fork-join parallelism (launch N goroutines, wait for all to complete).
> - Use **sync.Once** for lazy initialisation that must happen exactly once across all goroutines.
>
> The `go test -race` flag enables the Go race detector, which instruments all memory accesses and reports data races at runtime. It is implemented using ThreadSanitizer (TSan) from the LLVM project. Running your test suite with `-race` is non-negotiable for any concurrent Go code.

---

## 7.10 Summary

This chapter developed the theory and practice of synchronisation primitives, from the formal requirements of the critical section problem through hardware atomic instructions to high-level abstractions.

**Key results:**

- The critical section problem requires three properties: mutual exclusion, progress, and bounded waiting. Any correct solution must satisfy all three.

- Peterson's algorithm is the simplest correct two-process solution under sequential consistency, but fails under relaxed memory models. The filter lock generalises to $N$ processes but requires $O(N)$ shared variables.

- Hardware provides test-and-set, compare-and-swap (with infinite consensus number), and fetch-and-add as building blocks. The consensus hierarchy classifies primitives by their synchronisation power: CAS is universal (infinite consensus number), while test-and-set is limited to 2 threads.

- Mutexes provide sleeping mutual exclusion. The Linux futex mechanism avoids system calls in the uncontended case, achieving 10--20 ns lock acquisition. The three-state design (unlocked, locked-no-waiters, locked-with-waiters) ensures that the kernel is involved only when contention actually occurs.

- Semaphores generalise mutexes to counting and signalling. They solve the canonical problems: producer-consumer (bounded buffer), readers-writers (shared database), and dining philosophers (resource contention).

- Monitors encapsulate synchronisation within abstract data types. Mesa semantics (used universally in practice) requires `while`-loop condition checking around every `wait`. Hoare semantics is theoretically cleaner but impractical to implement.

- The spinlock vs sleeping lock decision depends on critical section duration relative to context switch cost. TTAS with exponential backoff optimises spinlocks; adaptive spinning combines spinning and sleeping.

- Read-write locks optimise for read-dominated workloads. Sequence locks provide lock-free reads at the cost of occasional retries. Barriers synchronise phases of parallel computations.

The next chapter examines what happens when synchronisation goes wrong: the theory of deadlock, its detection, prevention, avoidance, and recovery.

---

## Exercises

**Exercise 7.1.** Prove that any solution to the two-process critical section problem using only shared read-write registers requires at least two registers. (*Hint*: consider an execution where one process crashes in its remainder section --- the other process must still be able to enter its critical section, so the crashed process's state must be recorded somewhere.)

**Exercise 7.2.** The **bakery algorithm** (Lamport, 1974) solves the critical section problem for $N$ processes. Each process $P_i$ selects a ticket number $\texttt{number}[i] = 1 + \max(\texttt{number}[0], \ldots, \texttt{number}[N-1])$ and waits until its ticket is the smallest among all interested processes (with ties broken by process ID). Prove that the bakery algorithm satisfies mutual exclusion, progress, and bounded waiting. What assumption about the atomicity of reading and writing `number[i]` is required?

**Exercise 7.3.** Consider a system with three processes $P_0, P_1, P_2$ and three resources $R_0, R_1, R_2$ (one instance each). The access pattern is:

- $P_0$: acquires $R_0$, then $R_1$
- $P_1$: acquires $R_1$, then $R_2$
- $P_2$: acquires $R_2$, then $R_0$

(a) Draw the resource allocation graph when all three processes hold their first resource and are waiting for their second. (b) Is this system deadlocked? (c) Propose a resource ordering that prevents deadlock.

**Exercise 7.4.** Implement a **readers-writers lock** with **fair scheduling**: neither readers nor writers can starve. Your solution should use POSIX mutexes and condition variables. Prove that your implementation satisfies the fairness property by showing that the maximum number of consecutive same-type accesses is bounded.

**Exercise 7.5.** A semaphore can be implemented using a mutex and a condition variable. Write the implementation in C using `pthread_mutex_t` and `pthread_cond_t`. Prove that your implementation is correct: `wait` decrements the count and blocks when zero, `signal` increments and wakes exactly one waiter.

**Exercise 7.6.** The **sleeping barber problem** is a classic synchronisation puzzle. A barber shop has one barber, one barber chair, and $N$ waiting chairs. If there are no customers, the barber sleeps. When a customer arrives, they wake the barber (if sleeping) or sit in a waiting chair (if the barber is busy). If all waiting chairs are full, the customer leaves. Solve this problem using semaphores. Prove your solution is free of deadlock and starvation.

**Exercise 7.7.** A **seqlock** allows readers to proceed without blocking, at the cost of occasionally retrying. Analyse the expected number of reader retries as a function of the write frequency $f_w$ (writes per second), the write duration $T_w$ (seconds), and the read duration $T_r$ (seconds). Under what conditions does a seqlock outperform a readers-writers lock? Assume Poisson-distributed write arrivals and derive the expected retry probability per read attempt.

