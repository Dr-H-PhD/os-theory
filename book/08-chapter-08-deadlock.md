# Chapter 8: Deadlock

*"The dining philosophers problem illustrates that even well-intentioned processes, following individually reasonable protocols, can collectively reach a state from which no progress is possible."* --- adapted from Dijkstra (1971)

---

Synchronisation primitives solve the problem of concurrent access to shared resources. But they introduce a new hazard: **deadlock**, a condition where a set of processes are each waiting for a resource held by another process in the set, forming a cycle of dependencies from which none can escape. Deadlock is not merely a theoretical curiosity --- it brings production systems to a halt, and its diagnosis often requires understanding the global state of a system from local observations.

This chapter develops the theory of deadlock systematically. We formalise the system model, state the four necessary conditions for deadlock (Coffman's conditions), and then explore four strategies: prevention (making deadlock structurally impossible), avoidance (making safe decisions at runtime), detection (identifying deadlock after it occurs), and recovery (breaking the deadlock). We also examine the related phenomena of livelock and starvation.

---

## 8.1 System Model

### 8.1.1 Resources and Processes

::: definition
**Definition 8.1 (Resource).** A resource is any entity that a process requires to make progress: CPU time, memory pages, disk blocks, file locks, semaphores, mutexes, database records, network sockets, or physical devices such as printers and tape drives.

Resources are classified as:

- **Reusable**: can be used repeatedly without being consumed (CPU, memory, locks, I/O channels).
- **Consumable**: are created (produced) and destroyed (consumed) during use (messages, signals, interrupts).

Each resource type $R_j$ has $W_j$ instances (e.g., a system might have 3 printers, 4 tape drives, or 16 GB of memory allocated in 4 KB pages).
:::

The distinction between reusable and consumable resources is important because deadlock theory primarily addresses reusable resources. Consumable resources introduce additional complexity: a process waiting for a message that has not yet been produced is not holding a resource in the classical sense, and the message may never exist. Deadlocks involving consumable resources are generally harder to detect and prevent.

::: definition
**Definition 8.2 (Resource Usage Protocol).** Each process uses a resource in three steps:

1. **Request**: the process asks the operating system for the resource. If the resource is unavailable, the process waits.
2. **Use**: the process operates on the resource (prints, reads, writes, computes).
3. **Release**: the process returns the resource to the operating system.

Request and release are system calls (e.g., `open()`/`close()`, `malloc()`/`free()`, `lock()`/`unlock()`).
:::

::: example
**Example 8.0 (Resource Usage in Practice).** A database transaction illustrates all three phases:

```c
/* Request: acquire locks on rows */
BEGIN TRANSACTION;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;  /* lock row 1 */

/* Use: modify the resource */
UPDATE accounts SET balance = balance - 100 WHERE id = 1;

/* Release: commit releases all locks */
COMMIT;
```

Between the `SELECT FOR UPDATE` and `COMMIT`, the transaction holds an exclusive lock on row 1. Any other transaction attempting to modify or exclusively lock the same row must wait. If two transactions lock different rows and then request each other's rows, deadlock results.
:::

### 8.1.2 Formal State Description

At any instant, the state of a resource allocation system can be described by:

- A set of processes $P = \{P_1, P_2, \ldots, P_n\}$.
- A set of resource types $R = \{R_1, R_2, \ldots, R_m\}$ with instance counts $W = (W_1, W_2, \ldots, W_m)$.
- An **allocation matrix** $A$ where $A_{ij}$ is the number of instances of resource $R_j$ currently allocated to process $P_i$.
- A **request matrix** $Q$ where $Q_{ij}$ is the number of additional instances of $R_j$ that process $P_i$ needs.
- An **available vector** $V$ where $V_j$ is the number of free instances of $R_j$.

The conservation law holds: for each resource type $j$,

$$\sum_{i=1}^{n} A_{ij} + V_j = W_j$$

This equation states that every instance of every resource is either allocated to some process or available. Resources do not appear or disappear (we assume a static set of resources for the core theory).

### 8.1.3 State Transitions

The system transitions between states through three operations:

1. **Request** by $P_i$ for $k$ instances of $R_j$: if $k \leq V_j$, the request may be granted immediately. Otherwise, $P_i$ blocks and $Q_{ij}$ is updated.

2. **Acquisition** of previously requested resources: $A_{ij} \leftarrow A_{ij} + k$, $V_j \leftarrow V_j - k$, $Q_{ij} \leftarrow Q_{ij} - k$.

3. **Release** by $P_i$ of $k$ instances of $R_j$: $A_{ij} \leftarrow A_{ij} - k$, $V_j \leftarrow V_j + k$.

A deadlock is a state from which no sequence of acquisitions and releases can allow all processes to complete. The theory we develop in this chapter characterises precisely when such states arise and how to handle them.

::: example
**Example 8.0b (State Space Size).** For a system with $n = 10$ processes and $m = 5$ resource types, each with $W_j = 4$ instances, the number of possible allocation states is the number of ways to distribute instances among processes and the free pool. This is:

$$\prod_{j=1}^{m} \binom{n + W_j}{n} = \binom{14}{10}^5 = 1001^5 \approx 10^{15}$$

Even for this modest system, exhaustive analysis of all states is infeasible. This motivates efficient algorithms (Banker's Algorithm, wait-for graph analysis) that work on the current state rather than exploring the entire state space.
:::


---

## 8.2 Deadlock Characterisation

### 8.2.1 Coffman's Four Conditions

::: theorem
**Theorem 8.1 (Coffman Conditions, 1971).** A deadlock can arise if and only if all four of the following conditions hold simultaneously:

1. **Mutual exclusion**: at least one resource must be held in a non-sharable mode. Only one process at a time can use the resource.

2. **Hold and wait**: a process holds at least one resource and is waiting to acquire additional resources held by other processes.

3. **No preemption**: resources cannot be forcibly removed from a process; they must be released voluntarily by the holding process.

4. **Circular wait**: there exists a set $\{P_0, P_1, \ldots, P_k\}$ of waiting processes such that $P_0$ is waiting for a resource held by $P_1$, $P_1$ is waiting for a resource held by $P_2$, $\ldots$, and $P_k$ is waiting for a resource held by $P_0$.

These conditions are **necessary**: if any one is absent, deadlock cannot occur. For the case of single-instance resource types, they are also **sufficient**.
:::

The circular wait condition is the most operational: it directly corresponds to a cycle in the resource allocation graph. The first three conditions are structural properties of the system and its protocols.

Let us prove that each condition is indeed necessary:

- **Without mutual exclusion**: if all resources are sharable, no process ever blocks waiting for a resource, so no waiting cycle can form.

- **Without hold and wait**: if a process must release all resources before requesting new ones, it never holds resources while waiting, so the chain $P_0 \text{ holds } R_a \text{ and waits for } R_b$ cannot occur.

- **Without no preemption**: if resources can be preempted, a process in the circular wait can have its resources forcibly taken and given to another, breaking the cycle.

- **Without circular wait**: if no cycle exists in the wait-for relationship, the dependency graph is a DAG, and at least one process can proceed (the one with no outgoing wait edges).

::: example
**Example 8.1 (Deadlock in File Locking).** Consider two processes that need to update two files, $F_A$ and $F_B$:

```c
/* Process 1 */
lock(F_A);
lock(F_B);    /* blocks: F_B held by Process 2 */
/* update both files */
unlock(F_B);
unlock(F_A);

/* Process 2 */
lock(F_B);
lock(F_A);    /* blocks: F_A held by Process 1 */
/* update both files */
unlock(F_A);
unlock(F_B);
```

All four Coffman conditions hold: (1) file locks are exclusive, (2) each process holds one lock while waiting for the other, (3) locks cannot be preempted, (4) Process 1 $\rightarrow$ Process 2 $\rightarrow$ Process 1 forms a cycle.
:::

::: example
**Example 8.1b (Deadlock with Three Processes).** The two-process case above generalises. Consider three threads in a web server:

```c
/* Thread A: transfer between accounts */
lock(account_1);
lock(account_2);   /* blocks: held by Thread B */

/* Thread B: transfer between accounts */
lock(account_2);
lock(account_3);   /* blocks: held by Thread C */

/* Thread C: calculate interest across accounts */
lock(account_3);
lock(account_1);   /* blocks: held by Thread A */
```

The circular wait is $A \rightarrow B \rightarrow C \rightarrow A$. With two processes, deadlock requires only two resources; with $k$ processes, it requires at least $k$ resources. In general, the minimum number of resources for a deadlock involving $k$ processes is $k$ (one per process in the cycle).
:::

### 8.2.2 Resource Allocation Graph

::: definition
**Definition 8.3 (Resource Allocation Graph).** A resource allocation graph $G = (V, E)$ is a directed graph where:

- $V = P \cup R$ where $P$ is the set of processes and $R$ is the set of resource types.
- $E$ consists of two kinds of edges:
  - **Request edge** $P_i \rightarrow R_j$: process $P_i$ is waiting for an instance of resource $R_j$.
  - **Assignment edge** $R_j \rightarrow P_i$: an instance of resource $R_j$ is allocated to process $P_i$.

Each resource type $R_j$ is drawn as a box containing $W_j$ dots (one per instance). Each process $P_i$ is drawn as a circle.
:::

The resource allocation graph provides both a visual tool for understanding deadlocks and a computational tool for detecting them.

::: theorem
**Theorem 8.2 (Deadlock Detection via RAG).** In a resource allocation graph:

- If the graph contains **no cycle**, no deadlock exists.
- If each resource type has exactly **one instance** and the graph contains a cycle, then deadlock exists.
- If resource types have **multiple instances**, a cycle is necessary but not sufficient for deadlock.

*Proof of the single-instance case.* Suppose each resource type has one instance and the RAG contains a cycle $P_0 \rightarrow R_{j_0} \rightarrow P_1 \rightarrow R_{j_1} \rightarrow \cdots \rightarrow P_k \rightarrow R_{j_k} \rightarrow P_0$.

Each edge $P_i \rightarrow R_{j_i}$ means $P_i$ is requesting $R_{j_i}$. Each edge $R_{j_i} \rightarrow P_{i+1}$ means $R_{j_i}$ is allocated to $P_{i+1}$. So $P_i$ is waiting for a resource held by $P_{i+1}$ (indices modulo $k+1$). All four Coffman conditions are satisfied (mutual exclusion by the single-instance assumption, hold and wait because each $P_i$ holds $R_{j_{i-1}}$ and waits for $R_{j_i}$, no preemption by assumption, and circular wait by the cycle). Therefore, deadlock exists. $\square$
:::

::: example
**Example 8.2 (Cycle Without Deadlock).** Consider:

- $R_1$ has 2 instances, $R_2$ has 1 instance.
- $P_1$ holds one instance of $R_1$, requests $R_2$.
- $P_2$ holds $R_2$, requests $R_1$.
- $P_3$ holds one instance of $R_1$.

The graph contains a cycle: $P_1 \rightarrow R_2 \rightarrow P_2 \rightarrow R_1 \rightarrow P_1$. But this is not a deadlock: $P_3$ can finish and release its instance of $R_1$, satisfying $P_2$'s request, which then releases $R_2$, satisfying $P_1$. The cycle exists, but an alternative execution path resolves it.
:::

### 8.2.3 Graph Reduction

::: definition
**Definition 8.3b (Graph Reduction).** A resource allocation graph can be **reduced** by the following operation: if a process $P_i$ has all its requests satisfiable (for each resource $R_j$ that $P_i$ requests, enough free instances exist), then remove all edges to and from $P_i$ and return its allocated resources to the available pool.

A state is deadlock-free if and only if the graph can be completely reduced (all process nodes removed). The set of processes remaining after no further reductions are possible is the deadlocked set.
:::

Graph reduction is the graphical equivalent of the detection algorithm presented in Section 8.5.

::: example
**Example 8.2b (Graph Reduction).** Consider a system with three processes and two resource types:

- $R_1$: 3 instances. $P_1$ holds 1, $P_2$ holds 1, $P_3$ holds 1. Available: 0.
- $R_2$: 2 instances. $P_1$ holds 1, $P_3$ holds 1. Available: 0.
- Requests: $P_1$ requests 1 of $R_2$, $P_2$ requests 1 of $R_1$, $P_3$ has no outstanding requests.

Step 1: $P_3$ has no requests. Reduce $P_3$: release its resources. Available becomes $R_1: 1, R_2: 1$.

Step 2: $P_2$ requests 1 of $R_1$, and 1 is available. Reduce $P_2$: release its resources. Available becomes $R_1: 2, R_2: 1$.

Step 3: $P_1$ requests 1 of $R_2$, and 1 is available. Reduce $P_1$: complete.

All processes reduced: no deadlock.
:::

---

## 8.3 Deadlock Prevention

Deadlock prevention works by ensuring that at least one of the four Coffman conditions can never hold. Each strategy has trade-offs in terms of resource utilisation, programming convenience, and system throughput.

### 8.3.1 Breaking Mutual Exclusion

If resources can be shared, there is no need for exclusive access, and deadlock cannot arise. However, many resources are inherently non-sharable: a printer cannot interleave pages from two documents, and a mutex is exclusive by definition.

**Approach**: use spooling and virtualisation. Instead of granting direct access to a printer, the OS accepts print jobs into a spool queue. Only the spooler daemon accesses the printer exclusively; user processes never hold the printer resource directly. Similarly, virtual memory eliminates deadlocks over physical memory by giving each process the illusion of its own address space.

**Limitation**: not all resources can be virtualised or spooled. Mutexes protecting data structures must be exclusive. Database row locks must be exclusive for writes. The mutual exclusion condition is inherent to the resource, not a design choice that can be eliminated.

**Read-write locks** partially address this: by allowing concurrent readers, they reduce the scope of mutual exclusion. However, write operations still require exclusive access, so deadlocks involving writers remain possible.

### 8.3.2 Breaking Hold and Wait

**Approach 1: All-or-nothing.** A process must request all resources it will ever need before beginning execution. The system either grants all of them or none.

```c
/* Request all resources atomically */
if (request(R1, R2, R3) == SUCCESS) {
    /* use R1, R2, R3 */
    release(R1, R2, R3);
} else {
    /* wait and retry */
}
```

**Approach 2: Release before requesting.** A process must release all currently held resources before requesting new ones.

```c
/* Phase 1: use R1 */
request(R1);
/* work with R1 */
release(R1);

/* Phase 2: use R1 and R2 together */
request(R1);   /* must re-request R1 */
request(R2);
/* work with R1 and R2 */
release(R1);
release(R2);
```

**Drawbacks of all-or-nothing:**

1. **Low resource utilisation**: resources are held long before they are needed. A process that needs a printer only in its final phase holds the printer throughout its entire execution.

2. **Potential starvation**: a process that needs many popular resources may never find them all free simultaneously. Each time it tries, at least one is held by another process.

3. **Requires advance knowledge**: the process must know all resources it will need before starting. Many programs discover their resource needs dynamically (e.g., a database query whose execution plan depends on data statistics).

**Drawbacks of release-before-request:**

1. **State loss**: releasing a resource may require discarding work in progress. A database transaction that releases a row lock loses its isolation guarantee.

2. **Increased overhead**: re-acquiring resources wastes time, especially if no other process used the resource in the interim.

::: example
**Example 8.2c (Hold-and-Wait in Two-Phase Locking).** Database systems use **two-phase locking** (2PL), which divides a transaction into a growing phase (only acquire locks) and a shrinking phase (only release locks). This ensures serialisability but permits hold-and-wait: during the growing phase, a transaction holds some locks while requesting others. 2PL therefore does not prevent deadlock; databases rely on deadlock detection and transaction rollback instead.
:::

### 8.3.3 Breaking No Preemption

**Approach**: if a process holding some resources requests additional resources that cannot be immediately allocated, all resources the process currently holds are preempted (released implicitly), and the process is restarted when all needed resources become available.

This is practical only for resources whose state can be saved and restored:

- **CPU registers**: yes (context switch saves and restores register state)
- **Memory pages**: yes (swap to disk, reload later)
- **Locks**: no (the protected data structure may be in an inconsistent state)
- **Printer mid-page**: no (half-printed output is useless)
- **Network connections**: partially (TCP can recover from brief interruptions, but application state may be lost)

::: example
**Example 8.3a (Preemption in Memory Management).** Virtual memory is the most successful application of resource preemption. When physical memory is scarce, the OS preempts pages from processes by swapping them to disk. The process is not aware that its page was taken away; when it accesses the swapped page, a page fault occurs, and the OS transparently reloads the page. This preemption prevents deadlocks over physical memory frames, at the cost of performance degradation (disk I/O is 1000x slower than memory access).
:::

**Variant: priority-based preemption.** In some systems, a higher-priority process can preempt resources from a lower-priority process. This breaks the no-preemption condition for the lower-priority process but introduces the **priority inversion** problem (Chapter 7): a low-priority process holding a resource needed by a high-priority process can block the high-priority process. Priority inheritance protocols address this by temporarily boosting the low-priority process's priority.

### 8.3.4 Breaking Circular Wait

::: definition
**Definition 8.4 (Resource Ordering).** Assign a total ordering $f : R \rightarrow \mathbb{N}$ to all resource types. Require that each process requests resources in increasing order of $f$: if a process holds $R_j$, it may only request $R_k$ where $f(R_k) > f(R_j)$.
:::

::: theorem
**Theorem 8.3 (Resource Ordering Prevents Deadlock).** If all processes request resources in a fixed total order $f$, circular wait cannot occur.

*Proof.* Suppose, for contradiction, that a circular wait exists: $P_0$ waits for $R_{j_0}$ held by $P_1$, $P_1$ waits for $R_{j_1}$ held by $P_2$, ..., $P_k$ waits for $R_{j_k}$ held by $P_0$.

Since $P_i$ holds $R_{j_{i-1}}$ and requests $R_{j_i}$, the ordering constraint requires $f(R_{j_{i-1}}) < f(R_{j_i})$ for each $i$ (a process holding a lower-numbered resource requests a higher-numbered one). Following the chain:

$$f(R_{j_0}) < f(R_{j_1}) < \cdots < f(R_{j_k}) < f(R_{j_0})$$

This is a contradiction: $f(R_{j_0})$ cannot be strictly less than itself. Therefore, no circular wait can exist under the ordering constraint. $\square$
:::

Resource ordering is the most widely used deadlock prevention strategy in practice. The Linux kernel enforces a lock ordering discipline, and tools like **lockdep** detect violations at runtime.

::: example
**Example 8.3b (Lock Ordering in Practice).** The Linux kernel's lockdep subsystem maintains a directed graph of lock acquisition orders observed at runtime. When a thread acquires lock $B$ while holding lock $A$, lockdep records the edge $A \rightarrow B$. If a later execution acquires $A$ while holding $B$, lockdep detects the cycle $A \rightarrow B \rightarrow A$ and reports a potential deadlock, even if the deadlock has not actually occurred yet. This is a dynamic variant of resource ordering verification.

The output includes the full lock dependency chain:

```text
======================================================
WARNING: possible circular locking dependency detected
------------------------------------------------------
swapper/0/1 is trying to acquire lock:
 (&mm->mmap_lock){+.+.}-{3:3}, at: lock_mm_and_find_vma
but task is already holding lock:
 (&rq->__lock){-.-.}-{2:2}, at: __schedule
which lock already depends on the new lock.
```
:::

::: example
**Example 8.3c (Resource Ordering for Dining Philosophers).** Recall the dining philosophers problem (Chapter 7): five philosophers, five chopsticks. Assign $f(\text{chopstick}_i) = i$ for $i = 0, 1, 2, 3, 4$. Each philosopher must pick up the lower-numbered chopstick first:

| Philosopher | Left chopstick | Right chopstick | Acquisition order |
|-------------|---------------|-----------------|-------------------|
| 0 | 0 | 1 | 0, then 1 |
| 1 | 1 | 2 | 1, then 2 |
| 2 | 2 | 3 | 2, then 3 |
| 3 | 3 | 4 | 3, then 4 |
| 4 | 4 | 0 | **0, then 4** (reversed!) |

Philosopher 4 must pick up chopstick 0 (lower number) before chopstick 4 (higher number), which is the opposite of their "natural" left-then-right order. This breaks the circular wait: philosopher 4 and philosopher 0 both compete for chopstick 0 first, and only one succeeds. The other waits, preventing the simultaneous "everyone holds left, waits for right" scenario.
:::

### 8.3.5 Comparison of Prevention Strategies

| Strategy | Condition broken | Practicality | Resource utilisation | Starvation risk |
|----------|-----------------|-------------|---------------------|-----------------|
| Spooling/virtualisation | Mutual exclusion | Limited to specific resources | High | Low |
| All-or-nothing | Hold and wait | Low (requires advance knowledge) | Low (resources held too long) | High |
| Preemption | No preemption | Limited to saveable resources | Moderate | Low |
| Resource ordering | Circular wait | High (widely used) | High | Low |

::: example
**Example 8.3d (Prevention Strategy in a Web Application).** Consider a web application that handles bank transfers. Each transfer requires locks on two accounts:

```c
/* Deadlock-prone: lock order depends on transfer direction */
void transfer(account_t *from, account_t *to, int amount) {
    lock(from);
    lock(to);
    from->balance -= amount;
    to->balance += amount;
    unlock(to);
    unlock(from);
}
```

If Thread A calls `transfer(acct_1, acct_2, 100)` and Thread B calls `transfer(acct_2, acct_1, 50)` simultaneously, deadlock can occur.

**Fix using resource ordering:**

```c
void transfer(account_t *from, account_t *to, int amount) {
    /* Always lock the account with the lower ID first */
    account_t *first = (from->id < to->id) ? from : to;
    account_t *second = (from->id < to->id) ? to : from;
    lock(first);
    lock(second);
    from->balance -= amount;
    to->balance += amount;
    unlock(second);
    unlock(first);
}
```

Now both threads acquire locks in the same order (by account ID), regardless of the transfer direction. This is a clean application of Theorem 8.3.
:::

> **Programmer:** In Go, there is no built-in lock ordering enforcement, but the convention is the same: document the ordering and adhere to it. A common pattern in Go servers is to define a hierarchy: `globalMu > sessionMu > connMu`. Every goroutine that needs multiple locks acquires them in this order. The `go vet` tool does not check lock ordering, but the race detector (`go test -race`) will catch many resulting data races. For critical systems, external tools such as `go-deadlock` (a drop-in replacement for `sync.Mutex`) detect lock ordering violations at runtime with a mechanism similar to Linux's lockdep:
>
> ```go
> package main
>
> import (
>     "fmt"
>     "sync"
> )
>
> // Convention: always lock mu1 before mu2
> var mu1 sync.Mutex
> var mu2 sync.Mutex
>
> func transferAtoB() {
>     mu1.Lock()
>     defer mu1.Unlock()
>     mu2.Lock()
>     defer mu2.Unlock()
>     fmt.Println("A -> B transfer")
> }
>
> func transferBtoA() {
>     mu1.Lock()         // same order as transferAtoB!
>     defer mu1.Unlock()
>     mu2.Lock()
>     defer mu2.Unlock()
>     fmt.Println("B -> A transfer")
> }
> ```
>
> Both functions acquire `mu1` before `mu2`, regardless of the logical direction of the transfer. This is the resource ordering principle applied to Go mutexes.

---

## 8.4 Deadlock Avoidance: The Banker's Algorithm

Deadlock prevention is conservative: it restricts how processes use resources, potentially reducing concurrency. Deadlock avoidance takes a different approach: it allows all four Coffman conditions to potentially hold, but makes each allocation decision carefully to ensure the system never enters an unsafe state.

### 8.4.1 Safe and Unsafe States

::: definition
**Definition 8.5 (Safe State).** A state is **safe** if there exists a sequence $\langle P_{i_1}, P_{i_2}, \ldots, P_{i_n} \rangle$ of all processes such that, for each $P_{i_k}$, the resources that $P_{i_k}$ can still request can be satisfied by the currently available resources plus the resources held by all $P_{i_j}$ with $j < k$ (i.e., processes that finish before $P_{i_k}$ in the sequence).

Such a sequence is called a **safe sequence**.
:::

::: definition
**Definition 8.6 (Unsafe State).** A state is **unsafe** if no safe sequence exists. An unsafe state does not necessarily mean deadlock has occurred --- it means that deadlock **may** occur depending on future requests.
:::

The relationship is:

```text
┌──────────────────────────────────────────────────────────────────┐
│                        All states                                 │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              Safe states                                     │ │
│  │    (guaranteed deadlock-free)                                │ │
│  └─────────────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              Unsafe states                                   │ │
│  │  ┌───────────────────────────────────────────────────────┐  │ │
│  │  │          Deadlocked states                             │  │ │
│  │  └───────────────────────────────────────────────────────┘  │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

Every deadlocked state is unsafe, but not every unsafe state is deadlocked. An unsafe state is one from which a particular sequence of future requests *could* lead to deadlock; whether it actually does depends on the processes' behaviour.

::: example
**Example 8.3d (Safe vs Unsafe).** Consider a system with 12 instances of a single resource type and three processes:

| Process | Allocation | Max | Need |
|---------|-----------|-----|------|
| $P_0$ | 5 | 10 | 5 |
| $P_1$ | 2 | 4 | 2 |
| $P_2$ | 2 | 9 | 7 |

Available $= 12 - 5 - 2 - 2 = 3$.

**Safe sequence**: $\langle P_1, P_0, P_2 \rangle$:

1. $P_1$ needs 2, available is 3. Grant. $P_1$ finishes, releases 4. Available $= 5$.
2. $P_0$ needs 5, available is 5. Grant. $P_0$ finishes, releases 10. Available $= 10$.
3. $P_2$ needs 7, available is 10. Grant. $P_2$ finishes. Done.

Now suppose we grant $P_0$ one more unit (Allocation becomes 6, Available becomes 2):

| Process | Allocation | Max | Need |
|---------|-----------|-----|------|
| $P_0$ | 6 | 10 | 4 |
| $P_1$ | 2 | 4 | 2 |
| $P_2$ | 2 | 9 | 7 |

Available $= 2$.

$P_1$ can still finish (needs 2, available 2), releasing 4 units. Available becomes 4. But then neither $P_0$ (needs 4, available 4 --- this works!) nor $P_2$ (needs 7, available 4 --- this fails). So the safe sequence is $\langle P_1, P_0, P_2 \rangle$: after $P_0$ finishes, Available $= 10$, and $P_2$ can proceed. The state is still safe.

If instead we had granted $P_2$ one more unit (Allocation becomes 3, Available becomes 1):

Available $= 1$. Only $P_1$ needs $\leq 1$... but $P_1$ needs 2. No process can proceed. **Unsafe state.** If $P_0$ and $P_2$ both request their remaining needs, deadlock is inevitable.
:::

### 8.4.2 The Banker's Algorithm

Dijkstra's Banker's Algorithm (1965) implements deadlock avoidance. The name comes from an analogy: a banker decides whether to grant a loan (allocate resources) based on whether, after the loan, they can still guarantee that all customers (processes) can eventually be satisfied.

**Data structures:**

- $n$ = number of processes, $m$ = number of resource types
- $\texttt{Available}[j]$ = number of available instances of resource type $R_j$
- $\texttt{Max}[i][j]$ = maximum demand of process $P_i$ for resource $R_j$
- $\texttt{Allocation}[i][j]$ = number of instances of $R_j$ currently allocated to $P_i$
- $\texttt{Need}[i][j] = \texttt{Max}[i][j] - \texttt{Allocation}[i][j]$ = remaining demand

**Safety algorithm** (determines whether a state is safe):

```c
#include <stdbool.h>
#include <string.h>

#define MAX_P 64
#define MAX_R 16

int Available[MAX_R];
int Max[MAX_P][MAX_R];
int Allocation[MAX_P][MAX_R];
int Need[MAX_P][MAX_R];
int n, m;  /* number of processes and resource types */

bool is_safe(void) {
    int Work[MAX_R];
    bool Finish[MAX_P];
    memcpy(Work, Available, m * sizeof(int));
    memset(Finish, false, n * sizeof(bool));

    int count = 0;
    while (count < n) {
        bool found = false;
        for (int i = 0; i < n; i++) {
            if (Finish[i]) continue;

            /* Check if P_i's remaining needs can be satisfied */
            bool can_finish = true;
            for (int j = 0; j < m; j++) {
                if (Need[i][j] > Work[j]) {
                    can_finish = false;
                    break;
                }
            }

            if (can_finish) {
                /* P_i can finish: reclaim its resources */
                for (int j = 0; j < m; j++)
                    Work[j] += Allocation[i][j];
                Finish[i] = true;
                found = true;
                count++;
            }
        }
        if (!found) return false;  /* no process can proceed */
    }
    return true;  /* all processes can finish */
}
```

**Resource request algorithm** (called when process $P_i$ requests resources):

```c
bool request_resources(int i, int Request[]) {
    /* Step 1: Validate request against maximum claim */
    for (int j = 0; j < m; j++) {
        if (Request[j] > Need[i][j])
            return false;  /* exceeds declared maximum */
    }

    /* Step 2: Check resource availability */
    for (int j = 0; j < m; j++) {
        if (Request[j] > Available[j])
            return false;  /* not enough resources: must wait */
    }

    /* Step 3: Tentatively allocate */
    for (int j = 0; j < m; j++) {
        Available[j] -= Request[j];
        Allocation[i][j] += Request[j];
        Need[i][j] -= Request[j];
    }

    /* Step 4: Check safety of resulting state */
    if (is_safe()) {
        return true;  /* grant the request */
    } else {
        /* Rollback: restore old state */
        for (int j = 0; j < m; j++) {
            Available[j] += Request[j];
            Allocation[i][j] -= Request[j];
            Need[i][j] += Request[j];
        }
        return false;  /* deny: would lead to unsafe state */
    }
}
```

### 8.4.3 Worked Example 1

::: example
**Example 8.4 (Banker's Algorithm Execution).** Consider a system with 5 processes and 3 resource types with total instances $(10, 5, 7)$.

Current state:

| Process | Allocation | Max | Need |
|---------|-----------|-----|------|
| $P_0$ | $(0, 1, 0)$ | $(7, 5, 3)$ | $(7, 4, 3)$ |
| $P_1$ | $(2, 0, 0)$ | $(3, 2, 2)$ | $(1, 2, 2)$ |
| $P_2$ | $(3, 0, 2)$ | $(9, 0, 2)$ | $(6, 0, 0)$ |
| $P_3$ | $(2, 1, 1)$ | $(2, 2, 2)$ | $(0, 1, 1)$ |
| $P_4$ | $(0, 0, 2)$ | $(4, 3, 3)$ | $(4, 3, 1)$ |

Available $= (10 - 7, 5 - 2, 7 - 5) = (3, 3, 2)$.

**Safety check:**

1. $\texttt{Work} = (3, 3, 2)$. Find a process whose Need $\leq$ Work.
   - $P_1$: Need $= (1, 2, 2) \leq (3, 3, 2)$. Run $P_1$: $\texttt{Work} = (3 + 2, 3 + 0, 2 + 0) = (5, 3, 2)$.

2. $\texttt{Work} = (5, 3, 2)$.
   - $P_3$: Need $= (0, 1, 1) \leq (5, 3, 2)$. Run $P_3$: $\texttt{Work} = (5 + 2, 3 + 1, 2 + 1) = (7, 4, 3)$.

3. $\texttt{Work} = (7, 4, 3)$.
   - $P_0$: Need $= (7, 4, 3) \leq (7, 4, 3)$. Run $P_0$: $\texttt{Work} = (7 + 0, 4 + 1, 3 + 0) = (7, 5, 3)$.

4. $\texttt{Work} = (7, 5, 3)$.
   - $P_2$: Need $= (6, 0, 0) \leq (7, 5, 3)$. Run $P_2$: $\texttt{Work} = (7 + 3, 5 + 0, 3 + 2) = (10, 5, 5)$.

5. $\texttt{Work} = (10, 5, 5)$.
   - $P_4$: Need $= (4, 3, 1) \leq (10, 5, 5)$. Run $P_4$: $\texttt{Work} = (10, 5, 7)$.

Safe sequence: $\langle P_1, P_3, P_0, P_2, P_4 \rangle$. The state is safe.

**Now $P_1$ requests $(1, 0, 2)$:**

- Check: $(1, 0, 2) \leq \text{Need}[1] = (1, 2, 2)$. OK.
- Check: $(1, 0, 2) \leq \text{Available} = (3, 3, 2)$. OK.
- Tentative allocation: Available $= (2, 3, 0)$, Allocation$[1] = (3, 0, 2)$, Need$[1] = (0, 2, 0)$.
- Safety check with new state: find sequence $\langle P_1, P_3, P_0, P_2, P_4 \rangle$. Safe. Grant the request.

**Now $P_4$ requests $(3, 3, 0)$:**

- Check: $(3, 3, 0) \leq \text{Need}[4] = (4, 3, 1)$. OK.
- Check: $(3, 3, 0) \leq \text{Available} = (2, 3, 0)$. FAIL: $3 > 2$ for the first resource. $P_4$ must wait.
:::

### 8.4.4 Worked Example 2: Unsafe State

::: example
**Example 8.5 (Banker's Algorithm --- Denied Request).** Starting from the state after $P_1$'s request was granted:

Available $= (2, 3, 0)$.

**$P_0$ requests $(0, 2, 0)$:**

- Check: $(0, 2, 0) \leq \text{Need}[0] = (7, 4, 3)$. OK.
- Check: $(0, 2, 0) \leq \text{Available} = (2, 3, 0)$. OK.
- Tentative: Available $= (2, 1, 0)$, Allocation$[0] = (0, 3, 0)$, Need$[0] = (7, 2, 3)$.

Safety check:

- $\texttt{Work} = (2, 1, 0)$.
- $P_0$: Need $(7, 2, 3)$. $7 > 2$: cannot finish.
- $P_1$: Need $(0, 2, 0)$. $2 > 1$: cannot finish.
- $P_2$: Need $(6, 0, 0)$. $6 > 2$: cannot finish.
- $P_3$: Need $(0, 1, 1)$. $1 > 0$ for resource $C$: cannot finish.
- $P_4$: Need $(4, 3, 1)$. $4 > 2$: cannot finish.

No process can be selected. The state is **unsafe**. The Banker's Algorithm denies $P_0$'s request. $P_0$ must wait until more resources become available (e.g., after another process completes and releases resources).
:::

### 8.4.5 Proof of Safety

::: theorem
**Theorem 8.4 (Banker's Algorithm Correctness).** If the Banker's Algorithm reports that a state is safe, then from that state, all processes can complete without deadlock, regardless of the order and timing of future requests (provided each process's total requests do not exceed its declared maximum).

*Proof.* The safety algorithm constructs a safe sequence $\langle P_{i_1}, \ldots, P_{i_n} \rangle$ by induction.

**Base case**: $P_{i_1}$'s need can be satisfied by $\texttt{Available}$, so $P_{i_1}$ can acquire all resources it needs, complete, and release all its resources. After $P_{i_1}$ completes, $\texttt{Available}$ increases by $\texttt{Allocation}[i_1]$.

**Inductive step**: assume $P_{i_1}, \ldots, P_{i_{k-1}}$ have completed, releasing their resources. Then $\texttt{Work} = \texttt{Available} + \sum_{j=1}^{k-1} \texttt{Allocation}[i_j]$. The algorithm found $P_{i_k}$ such that $\texttt{Need}[i_k] \leq \texttt{Work}$, so $P_{i_k}$ can complete.

After all $n$ processes complete, all resources are returned. Since the algorithm only grants a request if the resulting state is safe, the system can always find a completion ordering. Deadlock is a state from which no process can complete, which contradicts the existence of a safe sequence. $\square$
:::

::: theorem
**Theorem 8.4b (Safe State Invariant).** If the system starts in a safe state and the Banker's Algorithm is used for all allocation decisions, the system remains in a safe state at all times.

*Proof.* By induction on the sequence of allocation decisions. The initial state is safe (given). Each decision either grants the request (only if the resulting state is safe, as verified by the safety algorithm) or denies it (the state remains unchanged, and hence safe). Process completions can only improve safety: when a process finishes and releases resources, $\texttt{Available}$ increases, which can only make it easier (not harder) to find a safe sequence. Therefore, the system is always in a safe state, and deadlock can never occur. $\square$
:::

### 8.4.6 Complexity and Limitations

The safety algorithm has time complexity $O(n^2 \cdot m)$: the outer while-loop runs at most $n$ times (each iteration marks at least one process as finished), and each iteration scans up to $n$ processes, comparing $m$ resource types.

The resource request algorithm calls the safety algorithm once, preceded by $O(m)$ work for validation and tentative allocation. Therefore, each resource request costs $O(n^2 \cdot m)$.

**Limitations of the Banker's Algorithm:**

1. **Maximum demand must be declared in advance.** Many real systems cannot predict their maximum resource usage before execution. A web server cannot predict how many database connections a request handler will need.

2. **Fixed number of processes and resources.** The algorithm does not handle dynamic process creation (fork) or resource addition (hot-plugging memory or disks).

3. **Conservative.** It may deny requests that would not actually lead to deadlock, reducing concurrency. The algorithm assumes the worst case: every process may request its full remaining need simultaneously.

4. **Assumes processes eventually release resources.** If a process crashes while holding resources, the system may deadlock despite the Banker's guarantee.

5. **Centralised.** The algorithm requires a single decision point with global knowledge of all allocations and demands. This is impractical in distributed systems.

For these reasons, the Banker's Algorithm is rarely used in general-purpose operating systems. It finds application in specialised real-time and embedded systems where resource usage is predictable, the set of tasks is fixed, and deadlock is unacceptable.

### 8.4.7 The Single-Resource Banker's Algorithm

For systems with a single resource type, the Banker's Algorithm simplifies considerably. The safety check reduces to sorting processes by remaining need:

::: theorem
**Theorem 8.4c (Single-Resource Safety).** A system with one resource type, $n$ processes, $W$ total instances, and allocations $a_i$ with maximum claims $m_i$ is safe if and only if the processes can be ordered $P_{i_1}, P_{i_2}, \ldots, P_{i_n}$ such that for each $k$:

$$m_{i_k} - a_{i_k} \leq V + \sum_{j=1}^{k-1} a_{i_j}$$

where $V = W - \sum_{i=1}^{n} a_i$ is the number of available instances. The optimal ordering is to sort by remaining need $m_i - a_i$ in ascending order.

*Proof.* The greedy strategy of finishing the process with the smallest remaining need first maximises the resources returned at each step, making it possible to satisfy subsequent processes. If the greedy ordering fails, no ordering can succeed (since the greedy choice maximises available resources at every step). $\square$
:::

This simplification reduces the complexity from $O(n^2 m)$ to $O(n \log n)$ (dominated by the sorting step) for a single resource type.

::: example
**Example 8.5d (Single-Resource Banker's).** System with 12 units, 4 processes:

| Process | Allocation | Max | Need |
|---------|-----------|-----|------|
| $P_0$ | 3 | 9 | 6 |
| $P_1$ | 2 | 4 | 2 |
| $P_2$ | 2 | 7 | 5 |
| $P_3$ | 1 | 3 | 2 |

Available $= 12 - 3 - 2 - 2 - 1 = 4$.

Sort by need: $P_1$ (2), $P_3$ (2), $P_2$ (5), $P_0$ (6).

1. $P_1$: need $2 \leq 4$. Finish. Available $= 4 + 2 = 6$.
2. $P_3$: need $2 \leq 6$. Finish. Available $= 6 + 1 = 7$.
3. $P_2$: need $5 \leq 7$. Finish. Available $= 7 + 2 = 9$.
4. $P_0$: need $6 \leq 9$. Finish.

Safe. Now suppose $P_0$ requests 2 more (allocation becomes 5, available becomes 2):
Sort by need: $P_1$ (2), $P_3$ (2), $P_0$ (4), $P_2$ (5).
$P_1$: need $2 \leq 2$. Available $= 4$. $P_3$: need $2 \leq 4$. Available $= 5$. $P_0$: need $4 \leq 5$. Available $= 10$. $P_2$: need $5 \leq 10$. Safe. Grant.
:::

---

## 8.5 Deadlock Detection

If deadlock prevention and avoidance are too restrictive or impractical, the alternative is to allow deadlocks to occur and then detect and resolve them. This is the approach taken by most database systems and some operating systems.

### 8.5.1 Wait-For Graph

::: definition
**Definition 8.7 (Wait-For Graph).** For a system where each resource type has exactly one instance, the wait-for graph $G_W = (V, E)$ is a directed graph where:

- $V = P$ (the set of processes).
- There is an edge $P_i \rightarrow P_j$ if and only if $P_i$ is waiting for a resource held by $P_j$.

Deadlock exists if and only if $G_W$ contains a cycle.
:::

The wait-for graph is obtained from the resource allocation graph by collapsing resource nodes: the pair of edges $P_i \rightarrow R_k \rightarrow P_j$ (process $P_i$ requests resource $R_k$, which is held by $P_j$) becomes the single edge $P_i \rightarrow P_j$.

Cycle detection in the wait-for graph can be performed in $O(|V| + |E|)$ time using depth-first search. For $n$ processes, each waiting for at most one resource, the graph has at most $n$ edges, so detection is $O(n)$.

The DFS-based cycle detection algorithm proceeds as follows:

```c
/* Wait-for graph cycle detection via DFS */
#define MAX_P 256

int adj[MAX_P];       /* adj[i] = j means P_i waits for P_j, -1 if none */
int visited[MAX_P];   /* 0 = unvisited, 1 = in progress, 2 = done */
int deadlocked[MAX_P]; /* 1 if process is in a deadlock cycle */

int dfs(int node) {
    visited[node] = 1;  /* mark as in progress */
    int next = adj[node];
    if (next >= 0) {
        if (visited[next] == 1) {
            /* Back edge: cycle detected */
            deadlocked[next] = 1;
            return next;  /* return start of cycle */
        }
        if (visited[next] == 0) {
            int cycle_start = dfs(next);
            if (cycle_start >= 0) {
                deadlocked[node] = 1;
                if (cycle_start == node)
                    return -1;  /* full cycle marked */
                return cycle_start;
            }
        }
    }
    visited[node] = 2;  /* mark as done */
    return -1;
}

void detect_deadlocks(int n) {
    for (int i = 0; i < n; i++) {
        visited[i] = 0;
        deadlocked[i] = 0;
    }
    for (int i = 0; i < n; i++) {
        if (visited[i] == 0)
            dfs(i);
    }
}
```

This algorithm visits each node and each edge exactly once, giving $O(n)$ time complexity for single-instance resource types (where each node has at most one outgoing edge).

::: example
**Example 8.5b (Wait-For Graph Construction).** Five processes with single-instance resources:

- $P_1$ holds $R_1$, requests $R_2$ (held by $P_2$)
- $P_2$ holds $R_2$, requests $R_3$ (held by $P_3$)
- $P_3$ holds $R_3$, requests $R_1$ (held by $P_1$)
- $P_4$ holds $R_4$, requests $R_5$ (held by $P_5$)
- $P_5$ holds $R_5$, no pending requests

Wait-for graph edges: $P_1 \rightarrow P_2$, $P_2 \rightarrow P_3$, $P_3 \rightarrow P_1$, $P_4 \rightarrow P_5$.

DFS from $P_1$ discovers the cycle $P_1 \rightarrow P_2 \rightarrow P_3 \rightarrow P_1$. Processes $P_1, P_2, P_3$ are deadlocked. $P_4$ and $P_5$ are not involved.
:::

### 8.5.2 Detection Algorithm for Multiple-Instance Resources

When resource types have multiple instances, cycle detection in the wait-for graph is insufficient (as shown in Example 8.2). We use a generalisation of the safety algorithm:

```c
bool detect_deadlock(void) {
    int Work[MAX_R];
    bool Finish[MAX_P];
    memcpy(Work, Available, m * sizeof(int));

    /* Mark processes with no outstanding requests as finished */
    for (int i = 0; i < n; i++) {
        Finish[i] = true;
        for (int j = 0; j < m; j++) {
            if (Request[i][j] > 0) {
                Finish[i] = false;
                break;
            }
        }
    }

    /* Iteratively find processes that can have requests satisfied */
    bool changed = true;
    while (changed) {
        changed = false;
        for (int i = 0; i < n; i++) {
            if (Finish[i]) continue;

            bool can_proceed = true;
            for (int j = 0; j < m; j++) {
                if (Request[i][j] > Work[j]) {
                    can_proceed = false;
                    break;
                }
            }

            if (can_proceed) {
                for (int j = 0; j < m; j++)
                    Work[j] += Allocation[i][j];
                Finish[i] = true;
                changed = true;
            }
        }
    }

    /* Any unfinished process is in deadlock */
    for (int i = 0; i < n; i++) {
        if (!Finish[i]) return true;
    }
    return false;
}
```

The key difference from the Banker's safety algorithm is that this algorithm uses the **current request** matrix (what each process is waiting for right now) rather than the **maximum need** matrix (what each process might ever request). This makes it more precise: it identifies actual deadlocks rather than potential ones.

::: theorem
**Theorem 8.5 (Detection Algorithm Correctness).** The detection algorithm correctly identifies all deadlocked processes. A process $P_i$ is in deadlock if and only if $\texttt{Finish}[i] = \texttt{false}$ after the algorithm terminates.

*Proof.* The algorithm simulates an optimistic execution: it assumes that any process whose current requests can be satisfied will eventually complete and release all its resources. If a process cannot proceed even under this optimistic assumption, it is truly blocked.

More formally: the set $D = \{P_i \mid \texttt{Finish}[i] = \texttt{false}\}$ has the property that for each $P_i \in D$, $P_i$'s request cannot be satisfied by $\texttt{Work}$ (the resources available plus those released by all processes not in $D$). Since no process outside $D$ holds resources needed by processes in $D$ (if it did, those resources would have been added to $\texttt{Work}$ when that process was marked finished), the processes in $D$ are waiting only for resources held by other processes in $D$. This is precisely the deadlock condition. $\square$
:::

::: example
**Example 8.5c (Detection Algorithm Execution).** Consider:

| Process | Allocation $(A, B, C)$ | Request $(A, B, C)$ |
|---------|----------------------|---------------------|
| $P_0$ | $(0, 1, 0)$ | $(0, 0, 0)$ |
| $P_1$ | $(2, 0, 0)$ | $(2, 0, 2)$ |
| $P_2$ | $(3, 0, 3)$ | $(0, 0, 0)$ |
| $P_3$ | $(2, 1, 1)$ | $(1, 0, 0)$ |
| $P_4$ | $(0, 0, 2)$ | $(0, 0, 2)$ |

Available $= (0, 0, 0)$.

1. $P_0$ has no requests: $\texttt{Finish}[0] = \texttt{true}$. Work $= (0 + 0, 0 + 1, 0 + 0) = (0, 1, 0)$.

2. $P_2$ has no requests: $\texttt{Finish}[2] = \texttt{true}$. Work $= (0 + 3, 1 + 0, 0 + 3) = (3, 1, 3)$.

3. $P_3$: Request $(1, 0, 0) \leq (3, 1, 3)$. $\texttt{Finish}[3] = \texttt{true}$. Work $= (3 + 2, 1 + 1, 3 + 1) = (5, 2, 4)$.

4. $P_1$: Request $(2, 0, 2) \leq (5, 2, 4)$. $\texttt{Finish}[1] = \texttt{true}$. Work $= (5 + 2, 2 + 0, 4 + 0) = (7, 2, 4)$.

5. $P_4$: Request $(0, 0, 2) \leq (7, 2, 4)$. $\texttt{Finish}[4] = \texttt{true}$.

All processes finished. No deadlock.

Now change $P_2$'s request to $(0, 0, 1)$:

1. $P_0$: no requests. Finish. Work $= (0, 1, 0)$.
2. No other process can proceed: $P_1$ needs $(2, 0, 2)$, but Work has only $(0, 1, 0)$. $P_2$ needs $(0, 0, 1)$, but Work has $(0, 1, 0)$; $0 < 1$? No, $0 \geq 0$ for $A$ and $B$, but $0 < 1$ for $C$. Cannot proceed. $P_3$ needs $(1, 0, 0)$; $1 > 0$. Cannot proceed. $P_4$ needs $(0, 0, 2)$; $2 > 0$. Cannot proceed.

$D = \{P_1, P_2, P_3, P_4\}$. These processes are deadlocked.
:::

### 8.5.3 When to Run Detection

The frequency of deadlock detection involves a trade-off between detection latency and computational overhead:

- **On every resource request**: catches deadlocks immediately but has $O(n^2 \cdot m)$ overhead per request. Suitable only for small systems.

- **Periodically** (e.g., every 5 minutes or when CPU utilisation drops below a threshold): lower overhead but delayed detection. Deadlocked processes waste resources during the detection interval.

- **On specific triggers**: when a process has waited longer than a timeout, or when the system detects low throughput (high CPU idle time despite runnable processes).

::: example
**Example 8.5d (Detection Frequency Trade-off).** A database system with 100 concurrent transactions and 50 lock types would execute the detection algorithm with complexity $O(100^2 \times 50) = O(500{,}000)$ operations per run. Running this on every lock request (potentially thousands per second) adds significant overhead. Running it every 5 seconds is usually sufficient: the cost of 5 seconds of wasted resources is far less than the cost of continuous detection.

InnoDB (MySQL's storage engine) uses an aggressive approach: it runs deadlock detection on every lock wait. To bound the cost, it limits the search depth (the number of edges traversed in the wait-for graph) to 200. If the graph is too deep to analyse within this limit, InnoDB falls back to a timeout-based approach (`innodb_lock_wait_timeout`, default 50 seconds).
:::

---

## 8.6 Deadlock Recovery

Once a deadlock is detected, the system must break it. There are two main approaches, each with significant trade-offs.

### 8.6.1 Process Termination

**Abort all deadlocked processes.** This is the simplest approach but the most expensive: all work done by the terminated processes is lost. It is guaranteed to break the deadlock.

**Abort processes one at a time** until the deadlock cycle is broken. After each termination, re-run the detection algorithm to check whether the deadlock is resolved. The order of termination matters; common criteria include:

1. **Priority**: terminate low-priority processes first. Preserves important work.

2. **Elapsed time**: terminate the process that has run for the shortest time. Minimises lost work.

3. **Resources held**: terminate the process holding the most resources. Maximises the resources freed.

4. **Resources needed**: terminate the process that needs the most additional resources. It was furthest from completion.

5. **Type**: terminate batch processes before interactive ones. Users are more sensitive to lost interactive sessions.

6. **Rollback cost**: terminate the process for which rollback is cheapest. Some processes can be easily restarted (idempotent batch jobs); others cannot (processes that have performed irrevocable actions like sending emails or dispensing cash).

### 8.6.2 Resource Preemption

Instead of terminating processes, preempt resources from some processes and give them to others. This requires:

1. **Selecting a victim**: which process will have its resources preempted? The same criteria as above apply, with an emphasis on minimising total cost.

2. **Rollback**: the victim process must be rolled back to a safe state from which it can restart. This requires **checkpointing**: periodically saving the process's state so that it can be restored.

3. **Starvation prevention**: the same process must not always be selected as the victim. A common solution is to include the number of times a process has been preempted in the cost function, increasing its priority over time.

::: definition
**Definition 8.7b (Checkpoint).** A checkpoint is a saved snapshot of a process's state at a particular point in execution. The state includes register values, memory contents, open file descriptors, and any other information needed to resume execution from that point. Checkpoints enable rollback: if a process must be preempted, it is rolled back to its most recent checkpoint, and the resources it acquired after the checkpoint are released.
:::

::: example
**Example 8.6 (Deadlock Recovery in Databases).** Database systems are the most common users of deadlock detection and recovery. When a deadlock is detected among transactions, the DBMS selects a **victim transaction** (typically the one that has done the least work, measured by the number of log records or the number of locks held) and **rolls it back** to its last savepoint or to the beginning of the transaction. The rollback releases all locks held by the victim, breaking the cycle. The victim transaction is then restarted automatically.

PostgreSQL detects deadlocks by running a wait-for graph cycle detection algorithm whenever a transaction has waited for a lock for more than `deadlock_timeout` (default: 1 second). When a cycle is found, it terminates one of the involved transactions:

```text
ERROR:  deadlock detected
DETAIL: Process 12345 waits for ShareLock on transaction 67890;
        blocked by process 67891.
        Process 67891 waits for ShareLock on transaction 12345;
        blocked by process 12345.
HINT:   See server log for query details.
```

MySQL's InnoDB engine uses a different approach: it runs detection immediately on every lock wait and selects the victim based on transaction weight (number of rows modified). The victim's transaction is rolled back, and the application receives an error code that it should handle by retrying the transaction.
:::

### 8.6.3 Checkpointing for Rollback

Effective resource preemption requires the ability to roll a process back to a previous consistent state. **Checkpointing** saves the process's state at regular intervals so that recovery involves replaying from the last checkpoint rather than from the beginning.

```c
/* Simplified checkpoint mechanism */
typedef struct {
    void *memory_snapshot;
    size_t snapshot_size;
    int file_positions[MAX_FD];
    int checkpoint_id;
} checkpoint_t;

void save_checkpoint(process_t *p, checkpoint_t *cp) {
    cp->snapshot_size = p->memory_size;
    cp->memory_snapshot = malloc(cp->snapshot_size);
    memcpy(cp->memory_snapshot, p->memory_base, cp->snapshot_size);
    for (int fd = 0; fd < p->num_open_files; fd++)
        cp->file_positions[fd] = lseek(fd, 0, SEEK_CUR);
    cp->checkpoint_id++;
}

void restore_checkpoint(process_t *p, checkpoint_t *cp) {
    memcpy(p->memory_base, cp->memory_snapshot, cp->snapshot_size);
    for (int fd = 0; fd < p->num_open_files; fd++)
        lseek(fd, cp->file_positions[fd], SEEK_SET);
    /* Resume execution from checkpoint */
}
```

The cost of checkpointing involves a trade-off:

- **Frequent checkpoints**: low rollback cost (less work to redo) but high overhead during normal execution (each checkpoint copies memory state).
- **Infrequent checkpoints**: low normal overhead but high rollback cost (more work is lost on preemption).

The optimal checkpoint interval $T_c$ minimises total expected cost:

$$T_c^* = \sqrt{2 \cdot T_{\text{save}} \cdot T_{\text{mean}}}$$

where $T_{\text{save}}$ is the time to save a checkpoint and $T_{\text{mean}}$ is the mean time between failures requiring rollback.

::: example
**Example 8.6b (Recovery Cost Analysis).** Consider a deadlock involving three processes:

| Process | CPU time consumed | Resources held | Rollback cost |
|---------|------------------|----------------|---------------|
| $P_1$ | 45 minutes | 3 locks, 2 files | High (data written to disk) |
| $P_2$ | 2 minutes | 1 lock | Low (in-memory only) |
| $P_3$ | 30 minutes | 4 locks, 1 file | Medium (partial disk writes) |

The optimal victim is $P_2$: it has consumed the least CPU time, holds the fewest resources, and has the lowest rollback cost. Terminating $P_2$ is likely to break the cycle and waste the least work.

However, if $P_2$ has been selected as a victim three times already, fairness considerations may dictate choosing $P_1$ or $P_3$ instead, even at higher cost.
:::

---

## 8.7 Livelock and Starvation

### 8.7.1 Livelock

::: definition
**Definition 8.8 (Livelock).** A livelock is a condition where processes continuously change state in response to each other but make no progress. Unlike deadlock (where processes are blocked and consume no CPU), livelocked processes are active and consuming resources, but their actions are futile.
:::

Livelock is in some ways worse than deadlock: deadlocked processes at least do not waste CPU cycles. Livelocked processes consume CPU, memory bandwidth, and energy while accomplishing nothing. They are also harder to detect because the processes appear to be running normally.

::: example
**Example 8.7 (Corridor Livelock).** Two people approach each other in a narrow corridor. Both step left to avoid each other, then both step right, then left again, indefinitely. They are both active and responsive, but neither makes progress.

In computing, livelock occurs when processes repeatedly try and fail to acquire resources. Consider two processes using a "polite" lock acquisition strategy:

```c
/* Process 1 */
while (1) {
    lock(A);
    if (trylock(B) == FAIL) {
        unlock(A);   /* be polite: release A and retry */
        continue;
    }
    /* critical section */
    unlock(B);
    unlock(A);
    break;
}

/* Process 2 */
while (1) {
    lock(B);
    if (trylock(A) == FAIL) {
        unlock(B);   /* be polite: release B and retry */
        continue;
    }
    /* critical section */
    unlock(A);
    unlock(B);
    break;
}
```

If both processes execute in lockstep, Process 1 always holds $A$ when Process 2 tries it, and vice versa. Both repeatedly acquire one lock, fail to get the other, release, and retry. Neither thread blocks, but neither makes progress.
:::

::: example
**Example 8.7b (Livelock in Network Protocols).** The Ethernet CSMA/CD protocol can livelock if two stations transmit simultaneously, detect the collision, wait the same backoff time, and retransmit simultaneously again. Without randomisation, this cycle repeats indefinitely. The protocol prevents livelock using **exponential random backoff**: after the $k$-th collision, a station waits a random time in $[0, 2^k - 1]$ slot times. The probability of sustained lockstep drops exponentially with each collision.
:::

**Solutions to livelock:**

1. **Randomised backoff**: each process waits a random duration before retrying, making sustained lockstep extremely unlikely:

```c
while (1) {
    lock(A);
    if (trylock(B) == FAIL) {
        unlock(A);
        usleep(rand() % 1000);  /* random backoff: 0-999 microseconds */
        continue;
    }
    /* critical section */
    unlock(B);
    unlock(A);
    break;
}
```

2. **Priority-based resolution**: assign each process a priority (e.g., based on process ID or timestamp). When two processes conflict, the lower-priority one backs off. Since priorities are distinct, only one process backs off, breaking the symmetry.

3. **Resource ordering**: if both processes acquire locks in the same order, livelock cannot occur (they never hold different subsets of locks simultaneously).

::: theorem
**Theorem 8.6 (Randomised Backoff Terminates in Expected O(1) Rounds).** If two processes use randomised backoff with delay chosen uniformly from $[0, D]$, the probability that they conflict in round $k$ is at most $T_{\text{try}} / D$ (where $T_{\text{try}}$ is the time to perform a lock attempt). After $k$ independent rounds, the probability of continued conflict is at most $(T_{\text{try}} / D)^k$, which converges to 0 exponentially.

*Proof sketch.* In each round, both processes choose a random delay independently. They conflict only if their retry times overlap within a window of $T_{\text{try}}$. For sufficiently large $D$, this probability is small. The expected number of rounds before one process proceeds without conflict is $D / T_{\text{try}}$, which is $O(1)$ for constant $D$. $\square$
:::

::: example
**Example 8.7c (Livelock in Optimistic Concurrency Control).** Database systems using optimistic concurrency control (OCC) can experience livelock. In OCC, transactions execute without acquiring locks, then validate at commit time. If validation fails (another transaction modified the same data), the transaction is rolled back and retried. If two transactions repeatedly modify the same rows, they can repeatedly invalidate each other:

```text
Round 1: T1 modifies row A, T2 modifies row A.
         T1 commits first, T2's validation fails. T2 retries.
Round 2: T2 retries, modifies row A again. T1 starts new transaction
         on row A. T2 commits, T1's validation fails. T1 retries.
Round 3: Repeat...
```

The solution is again randomised backoff: a failed transaction waits a random exponentially increasing delay before retrying. PostgreSQL's serialisable snapshot isolation (SSI) includes this mechanism.
:::

### 8.7.2 Starvation

::: definition
**Definition 8.9 (Starvation).** Starvation occurs when a process is indefinitely denied access to a resource it needs, not because of deadlock, but because other processes are continuously favoured by the scheduling or allocation policy.
:::

Starvation differs from deadlock in that the system as a whole is making progress --- some processes are completing their work --- but one or more specific processes are perpetually bypassed.

::: example
**Example 8.8 (Starvation in Readers-Writers).** In the first readers-writers solution (Chapter 7), a continuous stream of readers can prevent any writer from ever accessing the database. The writer is not deadlocked (it is waiting on a semaphore that could potentially be released), but it may wait forever if readers keep arriving. This is starvation.

The fix (discussed in Chapter 7) is to give writers preference: when a writer is waiting, new readers are blocked until the writer completes. This prevents writer starvation at the cost of potentially starving readers under heavy write contention. A fair solution alternates between readers and writers.
:::

::: example
**Example 8.8b (Starvation in Priority Scheduling).** Consider a CPU scheduler that always runs the highest-priority process. If high-priority processes continuously arrive, a low-priority process may never receive CPU time. This is CPU starvation.

The solution is **ageing**: periodically increase the priority of waiting processes. After waiting long enough, even the lowest-priority process will become the highest priority and get scheduled. The rate of ageing determines the maximum wait time.
:::

**Starvation prevention mechanisms:**

- **FIFO ordering**: serve requests in the order they arrive. Used in ticket locks (Chapter 7) and fair scheduling algorithms.

- **Ageing**: increase a process's priority the longer it waits. Guarantees that every process eventually reaches the highest priority.

- **Bounded bypass**: guarantee that at most $B$ other processes can be served before any waiting process. The bounded waiting property of the critical section problem (Chapter 7) is a form of bounded bypass.

- **Fair locks**: Go's `sync.Mutex` enters starvation mode after 1 ms of waiting, switching from competitive (spinning) to FIFO (direct handoff) mode. This ensures bounded waiting in practice.

### 8.7.3 Formal Relationships

::: definition
**Definition 8.10 (Relationship Between Deadlock, Livelock, and Starvation).**

- **Deadlock** $\implies$ no progress for any process in the deadlocked set. All deadlocked processes are blocked.

- **Livelock** $\implies$ no progress for any process in the livelocked set, despite all being active. The set collectively makes no progress.

- **Starvation** $\implies$ no progress for specific process(es), but the system overall makes progress.

- A starved process is not deadlocked (other processes are completing).
- A livelocked process is not deadlocked (it is not blocked).
- Deadlock is detectable (blocked processes are visible to the scheduler); livelock is harder to detect (active processes look normal); starvation depends on the fairness analysis of the scheduling policy.
:::

---

## 8.8 Deadlock in Distributed Systems

### 8.8.1 The Distributed Deadlock Problem

In a distributed system, processes on different nodes may hold resources and request resources on other nodes. No single node has a complete view of the global wait-for graph. Detecting deadlocks requires coordination among nodes.

::: definition
**Definition 8.11 (Distributed Deadlock).** A distributed deadlock occurs when a cycle exists in the global wait-for graph that spans multiple nodes. Each node's local wait-for graph shows only the edges corresponding to local resources; the global graph is the union of all local graphs plus inter-node wait edges.
:::

::: example
**Example 8.9 (Distributed Deadlock).** Three database nodes:

```text
Node 1: Transaction T1 holds lock L_A, requests L_B (on Node 2)
Node 2: Transaction T2 holds lock L_B, requests L_C (on Node 3)
Node 3: Transaction T3 holds lock L_C, requests L_A (on Node 1)
```

Each node sees only one edge of the cycle. Node 1 sees $T_1 \rightarrow T_2$ (an inter-node edge). Node 2 sees $T_2 \rightarrow T_3$. Node 3 sees $T_3 \rightarrow T_1$. No single node can detect the cycle.
:::

### 8.8.2 Distributed Detection Algorithms

**Centralised detection**: one node (the coordinator) periodically collects all local wait-for graphs and constructs the global graph. Simple but creates a single point of failure and a communication bottleneck.

```c
/* Pseudocode: centralised deadlock detection */
void coordinator_detect(void) {
    graph_t global_wfg;
    for (int node = 0; node < num_nodes; node++) {
        graph_t local = request_wait_for_graph(node);
        merge_graph(&global_wfg, &local);
    }
    if (has_cycle(&global_wfg)) {
        process_t victim = select_victim(&global_wfg);
        send_abort(victim);
    }
}
```

**Distributed detection (probe-based, Chandy-Misra-Haas 1983)**: when a process $P_i$ on node $A$ is blocked waiting for a process $P_j$ on node $B$, node $A$ sends a **probe message** $(P_i, P_j, P_i)$ to node $B$. If $P_j$ is also blocked, the probe is forwarded along the wait-for chain, appending each blocked process. If the probe returns to its initiator ($P_i$ appears as both the first and last element), a cycle (deadlock) is detected.

::: example
**Example 8.9b (Chandy-Misra-Haas Probe Execution).** Using the three-node scenario from Example 8.9:

```text
Step 1: T1 (Node 1) is blocked. Sends probe (T1, T1, T2) to Node 2.
Step 2: Node 2 receives probe. T2 is blocked waiting for T3.
        Forwards probe (T1, T2, T3) to Node 3.
Step 3: Node 3 receives probe. T3 is blocked waiting for T1.
        Forwards probe (T1, T3, T1) to Node 1.
Step 4: Node 1 receives probe. The initiator (T1) matches the
        last element. Deadlock detected!
        Node 1 selects a victim (e.g., T1, the initiator) and aborts it.
```

The message complexity is $O(k)$ where $k$ is the length of the cycle: one probe message per edge in the cycle. For cycles of length 2 (the most common case), only 2 messages are needed.
:::

**Edge-chasing algorithms** generalise the probe approach. Each node maintains a partial wait-for graph. When a dependency crosses node boundaries, an edge-chasing message follows the dependency chain. The algorithm terminates when either a cycle is detected or the chain ends at a non-blocked process.

### 8.8.3 The Phantom Deadlock Problem

::: definition
**Definition 8.12 (Phantom Deadlock).** A phantom deadlock is a false positive in distributed deadlock detection: the algorithm reports a deadlock that does not actually exist, because the wait-for information collected from different nodes reflects different points in time. Between the time the probe was sent and the time it arrives, a process may have released its resources, breaking the cycle.
:::

::: example
**Example 8.10 (Phantom Deadlock).** Consider three nodes:

```text
Time 0: T1 (Node 1) holds L_A, waits for L_B (Node 2).
        T2 (Node 2) holds L_B, waits for L_C (Node 3).
        T3 (Node 3) holds L_C, waits for L_A (Node 1).
        -> True deadlock exists.

Time 1: Node 1 starts probe: sends (T1, T1, T2) to Node 2.

Time 2: T3 times out and releases L_C.
        T2 acquires L_C and proceeds. Deadlock is broken.

Time 3: Probe arrives at Node 2. T2 is no longer blocked.
        In theory, the probe should stop here.
        But if Node 2 processes the probe using stale state
        (before learning T3 released L_C), it forwards the probe.

Time 4: Probe reaches Node 3. T3 is still listed as waiting for L_A.
        Probe returns to Node 1: phantom deadlock detected!
        Node 1 aborts T1 unnecessarily.
```

The probe traversed edges that existed at different moments in time, detecting a cycle that was already broken. This is a phantom deadlock.
:::

Phantom deadlocks arise because distributed snapshots are not instantaneous. They are a fundamental challenge in distributed deadlock detection and are one reason why many distributed systems prefer **timeout-based** deadlock handling: if a transaction waits longer than a threshold, it is aborted. This may occasionally abort non-deadlocked transactions (false positives), but it avoids the complexity and phantom-deadlock risk of distributed detection algorithms.

The trade-off between detection and timeout approaches can be quantified:

| Approach | False positives | Detection latency | Message overhead |
|----------|----------------|-------------------|-----------------|
| Probe-based detection | Possible (phantom deadlocks) | $O(k \cdot d)$ where $k$ = cycle length, $d$ = network delay | $O(k)$ messages per detection |
| Timeout-based | Common (any slow transaction appears deadlocked) | Fixed ($= \text{timeout value}$) | Zero (purely local) |
| Centralised detection | Rare (global snapshot) | $O(n \cdot d)$ where $n$ = nodes | $O(n)$ per detection round |

In practice, most production distributed databases (Google Spanner, CockroachDB, TiDB) use a combination: short timeouts for fast resolution of obvious deadlocks, plus periodic wait-for graph analysis for long-running transactions.

---

## 8.9 Practical Strategies in Real Systems

### 8.9.1 The Ostrich Algorithm

Many general-purpose operating systems (Linux, Windows, macOS) use the **ostrich algorithm**: they ignore deadlocks entirely. The reasoning is pragmatic:

1. Deadlocks are rare in practice (well-written applications use lock ordering).
2. Prevention and avoidance impose unacceptable overhead and restrict programming models.
3. When a deadlock does occur, the user notices (the system becomes unresponsive) and reboots or kills the offending processes manually.

This is a legitimate engineering trade-off: the cost of handling deadlocks exceeds the cost of occasional manual intervention. The name comes from the (apocryphal) belief that ostriches bury their heads in the sand to avoid danger.

The mathematical justification for the ostrich algorithm rests on a cost-benefit analysis. Let $p$ be the probability of deadlock per unit time, $C_d$ be the cost of a deadlock occurrence (including detection, recovery, and lost work), and $C_p$ be the continuous cost of deadlock prevention or avoidance. The ostrich algorithm is optimal when:

$$p \cdot C_d < C_p$$

For a well-engineered system with lock ordering, $p$ is extremely small (perhaps $10^{-6}$ per hour), $C_d$ is moderate (a process restart), and $C_p$ is substantial (the complexity and performance overhead of running the Banker's Algorithm on every resource request). The inequality is easily satisfied.

::: example
**Example 8.10b (Cost of the Ostrich Algorithm).** A web server handles 10,000 requests per second. With proper lock ordering, the probability of a deadlock is approximately $10^{-9}$ per request (one in a billion). Expected time between deadlocks: $10^{9} / 10{,}000 = 100{,}000$ seconds $\approx 27$ hours. The cost of a deadlock is a single process restart (10 seconds of downtime). The alternative --- running deadlock detection on every lock acquisition --- would add 1 microsecond per request, totalling 10,000 microseconds/second = 10 ms of CPU per second, or 0.86 seconds per day. Over 27 hours, this amounts to 24 seconds of CPU time to prevent 10 seconds of downtime --- the ostrich algorithm is more efficient.
:::


### 8.9.2 Combined Approaches

Real systems use different strategies for different resource types:

| Resource | Strategy |
|----------|----------|
| Internal kernel locks | Prevention (lock ordering, enforced by lockdep) |
| Memory allocation | Prevention (allocation ordering) + detection (OOM killer) |
| File locks | Detection (timeout-based) + recovery (process termination) |
| Database locks | Detection (wait-for graph) + recovery (transaction rollback) |
| Printer/device access | Prevention (spooling eliminates mutual exclusion) |
| Network connections | Timeout-based (TCP keepalive, application-level timeouts) |
| Distributed transactions | Timeout-based + two-phase commit protocol |

This heterogeneous approach reflects a fundamental principle: no single deadlock strategy is optimal for all resources. The right strategy depends on the resource's characteristics (can it be preempted? shared? virtualised?), the cost of deadlock (is it catastrophic or merely inconvenient?), and the overhead of the strategy relative to normal operation.

> **Programmer:** In Go applications, the practical approach to deadlock management combines prevention and detection. Prevention comes from disciplined channel usage and lock ordering. Detection comes from three mechanisms:
>
> 1. **Runtime deadlock detection**: the Go runtime detects when all goroutines are asleep (blocked on channels, locks, or I/O) and no goroutine can make progress. It prints `fatal error: all goroutines are asleep - deadlock!` and dumps all goroutine stacks. This is a global deadlock detector --- it catches the case where the entire program is stuck, but not partial deadlocks where some goroutines are still running.
>
> 2. **Goroutine dump analysis**: sending `SIGQUIT` (or `Ctrl-\`) to a Go process prints a full goroutine dump showing every goroutine's stack trace and blocking reason. This is invaluable for diagnosing partial deadlocks:
>
> ```text
> goroutine 1 [semacquire]:
> sync.runtime_SemacquireMutex(0xc00001a0a8, 0x0, 0x1)
>     /usr/local/go/src/runtime/sema.go:77 +0x25
> sync.(*Mutex).lockSlow(0xc00001a0a0)
>     /usr/local/go/src/sync/mutex.go:171 +0x152
> sync.(*Mutex).Lock(...)
>     /usr/local/go/src/sync/mutex.go:90
> main.worker(0xc00001a0a0, 0xc00001a0c0)
>     /home/user/deadlock.go:15 +0x45
> ```
>
> 3. **Context-based timeouts**: for production systems, the standard approach is to use `context.WithTimeout` to bound how long any operation can wait for a lock or resource:
>
> ```go
> ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
> defer cancel()
>
> select {
> case resource <- request:
>     // acquired
> case <-ctx.Done():
>     log.Printf("timeout waiting for resource: possible deadlock")
>     // handle timeout: retry, abort, or alert
> }
> ```
>
> This transforms potential deadlocks into timeouts, which are easier to detect, log, and recover from in a distributed system.

> **Programmer:** The Go race detector (`go test -race`) and deadlock detection address complementary problems. The race detector finds **data races** (unsynchronised concurrent access to shared memory), while deadlock detection finds **blocking cycles** (processes waiting for each other). A program can be race-free but deadlocked, or deadlock-free but racy. Production Go code should run both `-race` in testing and `GOTRACEBACK=all` in production (to get full goroutine dumps on crashes) to catch both classes of concurrency bugs.
>
> For distributed Go services communicating over gRPC or HTTP, the deadlock model shifts from lock-based to resource-based: goroutine A is waiting for a response from service B, which is waiting for service C, which is waiting for service A. The detection strategy is context timeouts and distributed tracing (OpenTelemetry), not lock analysis. Every outgoing RPC call should carry a context with a deadline, and the system should be designed so that timeouts propagate: if A's context expires, it cancels its call to B, which cancels its call to C.

---

## 8.10 Summary

Deadlock is an inherent risk in any system where processes compete for resources. This chapter provided the theoretical framework for understanding and managing deadlocks:

**Key results:**

- Deadlock requires all four Coffman conditions: mutual exclusion, hold and wait, no preemption, and circular wait. Removing any one condition prevents deadlock.

- The resource allocation graph provides a visual and algorithmic tool for deadlock analysis. For single-instance resources, a cycle implies deadlock. For multiple-instance resources, graph reduction or the detection algorithm is needed.

- **Prevention** eliminates one Coffman condition statically. Resource ordering (breaking circular wait) is the most practical and widely used strategy, enforced by tools like Linux's lockdep.

- **Avoidance** (Banker's Algorithm) dynamically ensures the system stays in a safe state, at the cost of requiring advance knowledge of maximum resource demands. It has $O(n^2 m)$ time complexity per decision.

- **Detection** finds deadlocks after they occur using wait-for graphs ($O(n)$ for single-instance resources) or the generalised detection algorithm ($O(n^2 m)$ for multiple-instance resources).

- **Recovery** involves process termination or resource preemption, guided by cost minimisation and fairness constraints.

- Livelock (active but futile processes) is solved by randomised backoff. Starvation (indefinite bypass) is solved by fairness mechanisms such as ageing and FIFO ordering.

- **Distributed deadlocks** require coordination across nodes and are subject to phantom deadlock false positives. Most distributed systems prefer timeout-based approaches. The Chandy-Misra-Haas algorithm detects distributed deadlocks with $O(k)$ messages per cycle of length $k$.

- Real systems use combined strategies tailored to each resource type, often including the ostrich algorithm for non-critical resources. The cost-benefit analysis $p \cdot C_d < C_p$ provides a principled framework for deciding when to invest in deadlock handling.

- The four strategies form a spectrum from most conservative (prevention) to most permissive (ostrich), with avoidance and detection-recovery as intermediate positions. No single strategy dominates all others; the optimal choice depends on the application domain, resource characteristics, and acceptable failure modes.

- **Checkpointing** enables resource preemption by saving process state at regular intervals. The optimal checkpoint interval balances the cost of saving state against the expected cost of lost work on rollback.

The next chapter moves from the correctness of individual synchronisation primitives to the design of complete concurrent data structures --- structures that provide thread-safe operations through careful use of the primitives developed in Chapters 7 and 8.

---

## Exercises

**Exercise 8.1.** A system has four processes $P_1, P_2, P_3, P_4$ and three resource types $A$ (3 instances), $B$ (2 instances), $C$ (2 instances). The current state is:

| Process | Allocation $(A, B, C)$ | Max $(A, B, C)$ | Need $(A, B, C)$ |
|---------|----------------------|----------------|-----------------|
| $P_1$ | $(0, 1, 0)$ | $(0, 1, 1)$ | $(0, 0, 1)$ |
| $P_2$ | $(2, 0, 0)$ | $(2, 1, 1)$ | $(0, 1, 1)$ |
| $P_3$ | $(0, 0, 1)$ | $(1, 0, 1)$ | $(1, 0, 0)$ |
| $P_4$ | $(1, 0, 0)$ | $(1, 1, 0)$ | $(0, 1, 0)$ |

Available $= (0, 1, 1)$.

(a) Show that the system is in a safe state by finding a safe sequence.
(b) Process $P_2$ requests $(0, 0, 1)$. Should the request be granted? Use the Banker's Algorithm to justify your answer.
(c) If $P_2$'s request is granted, can $P_1$ then request $(0, 0, 1)$? Justify.

**Exercise 8.2.** Prove that the Banker's Algorithm, when used to determine whether to grant each request, is sufficient to prevent deadlock. Specifically, show that if the system starts in a safe state and the Banker's Algorithm grants only requests that leave the system in a safe state, then no deadlock can ever occur.

**Exercise 8.3.** Consider a system with 5 processes and 3 resource types. The processes' maximum demands are:

| Process | Max $(R_1, R_2, R_3)$ |
|---------|----------------------|
| $P_0$ | $(4, 1, 1)$ |
| $P_1$ | $(0, 2, 1)$ |
| $P_2$ | $(4, 2, 1)$ |
| $P_3$ | $(1, 1, 1)$ |
| $P_4$ | $(2, 1, 3)$ |

The total resources are $(6, 3, 4)$. (a) What is the minimum value of Available for each resource type that guarantees a safe initial state (before any allocations)? (b) Give an allocation that results in an unsafe state. (c) Give an allocation that results in deadlock.

**Exercise 8.4.** The time complexity of the Banker's safety algorithm is $O(n^2 \cdot m)$ where $n$ is the number of processes and $m$ is the number of resource types. Prove this bound. Is a more efficient algorithm possible? (*Hint*: consider maintaining a sorted list of processes by remaining need and analyse the resulting complexity.)

**Exercise 8.5.** A distributed system has three nodes, each running a transaction manager. Node 1 holds lock $L_A$ and requests $L_B$ (held by Node 2). Node 2 holds $L_B$ and requests $L_C$ (held by Node 3). Node 3 holds $L_C$ and requests $L_A$ (held by Node 1). No single node can see the complete wait-for graph. (a) Describe a distributed deadlock detection algorithm based on probe messages (Chandy-Misra-Haas). (b) Analyse the message complexity of your algorithm as a function of the cycle length $k$. (c) Discuss the phantom deadlock problem: construct a scenario where the probe algorithm reports a deadlock that was already resolved by the time the probe completes.

**Exercise 8.6.** Write a program in C that deliberately creates a deadlock between two POSIX threads using `pthread_mutex_t`. Then modify the program to prevent the deadlock using resource ordering. Verify that the original program hangs and the modified program completes. Provide the complete source code for both versions.

**Exercise 8.7.** Prove that for a system with $n$ processes and $m$ resource types, each with a single instance, the problem of determining whether a state is deadlocked can be solved in $O(n + m)$ time by constructing the wait-for graph and running DFS for cycle detection. Contrast this with the $O(n^2 \cdot m)$ complexity of the general detection algorithm for multiple-instance resources. Under what conditions is the general algorithm necessary?

\vspace{2em}

The study of deadlock connects fundamental theoretical concepts (graph theory, state-space analysis, resource allocation) with practical engineering concerns (lock ordering, timeout configuration, recovery strategies). The gap between theory and practice is narrower here than in most areas of operating systems: the Coffman conditions provide a precise characterisation, and the prevention, avoidance, and detection algorithms are directly implementable.

