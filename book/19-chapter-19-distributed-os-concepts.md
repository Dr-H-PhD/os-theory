# Chapter 19: Distributed Operating System Concepts

*"A distributed system is one in which the failure of a computer you didn't even know existed can render your own computer unusable."*
--- Leslie Lamport

---

A distributed operating system extends the abstractions of a traditional OS --- processes, files, memory, communication --- across multiple machines connected by a network. The machines may fail independently, the network may lose or reorder messages, and there is no shared clock. These constraints make distributed systems fundamentally harder to reason about than single-machine systems, and the theoretical results that govern their behaviour --- the FLP impossibility theorem, the CAP theorem, the bounds on clock synchronisation --- are among the deepest in computer science.

This chapter examines the core problems of distributed computing from an OS perspective: how to order events without a global clock, how to achieve mutual exclusion across machines, how to reach agreement (consensus) despite failures, how to build distributed file systems, how to reason about the consistency of shared state, and how to detect failures in a world where silence is ambiguous.

## 19.1 Motivation and Design Goals

### 19.1.1 Why Distribute?

Single machines have limits: finite CPU cores, finite memory, finite storage bandwidth, and a single point of failure. When any of these limits is reached, the only option is to spread the workload across multiple machines. But distribution introduces new problems that do not exist on a single machine:

- **Partial failure**: some machines fail while others continue. The system must continue operating (or gracefully degrade) despite failures.
- **No global state**: no single machine knows the complete state of the system. Decisions must be made with incomplete information.
- **Unbounded delay**: messages can be delayed arbitrarily by the network. A slow machine is indistinguishable from a crashed one.
- **Clock skew**: each machine has its own clock, and clocks drift at different rates.
- **Concurrency**: operations on different machines happen truly in parallel, not just interleaved.

### 19.1.2 Transparency

::: definition
**Transparency.** A distributed system provides transparency when it hides the distribution from users and applications. The ISO Reference Model for Open Distributed Processing (RM-ODP, ISO/IEC 10746) identifies eight forms:

1. **Access transparency**: local and remote resources are accessed using identical operations.
2. **Location transparency**: resources are accessed without knowledge of their physical location.
3. **Migration transparency**: resources can move between machines without affecting access.
4. **Replication transparency**: multiple copies of a resource exist without the user's knowledge.
5. **Concurrency transparency**: multiple users can share resources without interference.
6. **Failure transparency**: failures of components are hidden from the user.
7. **Performance transparency**: the system can be reconfigured for performance without user impact.
8. **Scaling transparency**: the system can scale without structural changes.
:::

In practice, perfect transparency is impossible --- Deutsch's eight fallacies of distributed computing remind us that the network is not reliable, latency is not zero, bandwidth is not infinite, and topology does change. The art of distributed system design is choosing which transparencies to sacrifice and how to expose the remaining non-transparency to applications gracefully.

### 19.1.3 System Models

::: definition
**System Model.** A distributed system model specifies assumptions about three dimensions:

1. **Process behaviour**:
   - *Crash-stop*: a process either runs correctly or halts permanently. Once crashed, it never recovers.
   - *Crash-recovery*: a process may crash and later restart, potentially with persistent state (e.g., from a write-ahead log).
   - *Byzantine*: a process may behave arbitrarily, including sending contradictory messages to different recipients, lying, or colluding with other Byzantine processes.

2. **Communication**:
   - *Reliable links*: every message sent is eventually delivered, with no duplication. (Typically built on top of TCP.)
   - *Fair-loss links*: messages may be lost, but a message sent infinitely often is eventually delivered.
   - *Arbitrary links*: messages may be lost, duplicated, corrupted, or delivered out of order.

3. **Timing**:
   - *Synchronous*: known upper bounds on message delay and processing time. An algorithm can use timeouts to detect failures reliably.
   - *Partially synchronous*: bounds exist but are unknown, or hold only after some (unknown) point in time (Global Stabilisation Time).
   - *Asynchronous*: no timing bounds at all. An algorithm cannot distinguish a slow process from a crashed one.
:::

Most practical systems assume crash-recovery processes, reliable communication (built on TCP), and partial synchrony. The theoretical results we study in this chapter often consider the asynchronous model, which gives the strongest impossibility results --- if something is impossible in the asynchronous model, no algorithm can guarantee it without timing assumptions.

## 19.2 Distributed Clocks

In a single-machine OS, all events can be ordered by a single hardware clock. In a distributed system, each machine has its own clock, and these clocks drift at different rates (typically 10--100 ppm, or 1--10 ms/day). The fundamental question is: how do we assign meaningful timestamps to events in the absence of a shared clock?

### 19.2.1 Happened-Before and Lamport Timestamps

Leslie Lamport's seminal 1978 paper "Time, Clocks, and the Ordering of Events in a Distributed System" introduced the **happened-before** relation and logical clocks. The key insight is that we do not need a global clock --- we only need to capture **causal ordering**: if event $a$ could have influenced event $b$, then $a$ must be ordered before $b$.

::: definition
**Happened-Before Relation.** For events in a distributed system, the happened-before relation $\rightarrow$ is the smallest transitive relation satisfying:

1. If $a$ and $b$ are events in the same process and $a$ occurs before $b$ in that process's local order, then $a \rightarrow b$.
2. If $a$ is the sending of a message by one process and $b$ is the receipt of that message by another process, then $a \rightarrow b$.
3. If $a \rightarrow b$ and $b \rightarrow c$, then $a \rightarrow c$ (transitivity).

If neither $a \rightarrow b$ nor $b \rightarrow a$, the events are **concurrent**, written $a \| b$. Concurrency does not mean the events happened at the same real-world time --- it means neither could have causally influenced the other.
:::

::: definition
**Lamport Timestamp.** Each process $P_i$ maintains a monotonically increasing counter $C_i$. The timestamp rules are:

1. Before each local event, increment: $C_i \leftarrow C_i + 1$.
2. When sending a message $m$, attach the current timestamp: $\text{send}(m, C_i)$.
3. When receiving a message $m$ with timestamp $t$: $C_i \leftarrow \max(C_i, t) + 1$.

The Lamport timestamp $L(e)$ of event $e$ is the value of the counter when $e$ occurs.
:::

::: theorem
**Theorem 19.1 (Lamport Clock Consistency).** If $a \rightarrow b$, then $L(a) < L(b)$.

*Proof.* By structural induction on the happened-before relation.

*Base case (same process):* If $a$ and $b$ are in the same process and $a$ occurs before $b$, then $C_i$ was incremented at least once between $a$ and $b$ (once for each intervening event). Therefore $L(a) < L(b)$.

*Base case (message):* If $a$ is the send of message $m$ with timestamp $L(a) = C_i$, and $b$ is the receipt of $m$ at process $P_j$, then $C_j \leftarrow \max(C_j, L(a)) + 1 \geq L(a) + 1$. Therefore $L(b) \geq L(a) + 1 > L(a)$.

*Inductive step:* If $a \rightarrow b$ and $b \rightarrow c$, then by induction $L(a) < L(b)$ and $L(b) < L(c)$, so $L(a) < L(c)$ by transitivity of $<$. $\square$
:::

Crucially, the **converse does not hold**: $L(a) < L(b)$ does not imply $a \rightarrow b$. Two concurrent events may happen to have different Lamport timestamps. This means Lamport timestamps can provide a **total order** (by breaking ties with process IDs: $(L(a), i) < (L(b), j)$ iff $L(a) < L(b)$ or ($L(a) = L(b)$ and $i < j$)), but they cannot detect concurrency.

::: example
**Example 19.1 (Lamport Timestamps).** Three processes $P_1$, $P_2$, $P_3$:

```text
Time -->

P1:  a(1) ──send m1──>           c(5)
                        \
P2:       d(1)  e(2)    b(3)  ──send m2──>  f(6)
                                              \
P3:            g(1)  h(2)                      i(7)
```

- Event $a$ at $P_1$: $C_1 = 1$, sends $m_1$ to $P_2$.
- Event $d$ at $P_2$: $C_2 = 1$ (local event).
- Event $e$ at $P_2$: $C_2 = 2$ (local event).
- Event $b$ at $P_2$: receives $m_1$ with timestamp 1. $C_2 = \max(2, 1) + 1 = 3$.
- Events $g(1), h(2)$ at $P_3$ proceed locally.
- Event $c$ at $P_1$: $C_1 = 5$ (local events between $a$ and $c$).
- Event $f$ at $P_2$: $C_2 = 6$, sends $m_2$ to $P_3$.
- Event $i$ at $P_3$: receives $m_2$ with timestamp 6. $C_3 = \max(2, 6) + 1 = 7$.

Observations: $a \rightarrow b$ (via message $m_1$), and indeed $L(a) = 1 < 3 = L(b)$. Events $a$ and $d$ are concurrent ($a \| d$): neither happened before the other, even though $L(a) = L(d) = 1$.
:::

### 19.2.2 Vector Clocks

**Vector clocks** extend Lamport timestamps to capture **causality precisely**: they can distinguish "happened before" from "concurrent."

::: definition
**Vector Clock.** In a system of $n$ processes, each process $P_i$ maintains a vector $V_i[1..n]$ of $n$ counters, initialised to all zeros. The rules are:

1. Before each local event at $P_i$: increment own entry: $V_i[i] \leftarrow V_i[i] + 1$.
2. When sending a message, attach the entire vector $V_i$ (after incrementing).
3. When receiving a message with vector $V_m$: for each $j \in \{1, \ldots, n\}$, set $V_i[j] \leftarrow \max(V_i[j], V_m[j])$; then increment own entry: $V_i[i] \leftarrow V_i[i] + 1$.
:::

The partial order on vectors is defined componentwise:

$$V(a) \leq V(b) \iff \forall j : V(a)[j] \leq V(b)[j]$$
$$V(a) < V(b) \iff V(a) \leq V(b) \text{ and } V(a) \neq V(b)$$

Two vectors are **incomparable** (concurrent) if neither $V(a) \leq V(b)$ nor $V(b) \leq V(a)$.

::: theorem
**Theorem 19.2 (Vector Clock Characterisation).** For events $a$ and $b$ in a distributed system with vector clocks:

$$a \rightarrow b \iff V(a) < V(b)$$

Events $a$ and $b$ are concurrent ($a \| b$) if and only if neither $V(a) < V(b)$ nor $V(b) < V(a)$.

*Proof.* The forward direction ($a \rightarrow b \Rightarrow V(a) < V(b)$) follows from the same structural induction as Theorem 19.1, extended to vectors. Each component can only increase, and at least one component (the sender's) strictly increases across a message.

The reverse direction ($V(a) < V(b) \Rightarrow a \rightarrow b$) uses the fact that $V_i[i]$ is a faithful count of events at $P_i$: if $V(a)[i] \leq V(b)[i]$ and $V(a) \neq V(b)$, then there exists a causal chain from $a$ to $b$ through the message sends that propagated process $i$'s counter to the process where $b$ occurred. The formal proof appears in Fidge (1988) and Mattern (1989). $\square$
:::

::: example
**Example 19.2 (Vector Clocks Detecting Concurrency).** Two processes $P_1$ and $P_2$:

```text
P1:  a[1,0] ──send──>        c[1,2]
                      \
P2:       b[0,1]      d[1,2]
                       (received msg from P1)
```

- After event $a$: $V_1 = [1, 0]$. $P_1$ sends message to $P_2$.
- After event $b$: $V_2 = [0, 1]$ (local event before receiving $P_1$'s message).

Compare $V(a) = [1, 0]$ and $V(b) = [0, 1]$:
$V(a)[1] = 1 > 0 = V(b)[1]$, but $V(a)[2] = 0 < 1 = V(b)[2]$.
Neither $V(a) \leq V(b)$ nor $V(b) \leq V(a)$, so $a \| b$ --- correctly identified as concurrent.

After event $d$ (receiving $P_1$'s message): $V_2 = [\max(0,1), \max(1,0) + 1] = [1, 2]$.
Compare $V(a) = [1, 0]$ and $V(d) = [1, 2]$: $V(a) \leq V(d)$ and $V(a) \neq V(d)$, so $V(a) < V(d)$, confirming $a \rightarrow d$ (as expected, since $d$ received $a$'s message).
:::

The disadvantage of vector clocks is their $O(n)$ space per timestamp, where $n$ is the number of processes. In systems with millions of processes, this is prohibitive. Practical alternatives include:

- **Bounded vector clocks**: truncate to the $k$ most recently updated entries.
- **Dotted version vectors**: compact representation for replicated data stores.
- **Hybrid logical clocks**: combine physical and logical timestamps (see below).

### 19.2.3 Physical Clock Synchronisation: NTP and PTP

Logical clocks order events causally but do not provide wall-clock time. For timestamps that correspond to real-world time (log correlation, certificate validity, financial transactions, lease expiry), physical clock synchronisation is necessary.

**NTP (Network Time Protocol)** synchronises clocks over unreliable networks. NTP uses a hierarchical system of **stratum** levels: stratum-0 devices are atomic clocks or GPS receivers; stratum-1 servers connect directly to stratum-0; stratum-2 synchronise from stratum-1; and so on.

NTP achieves accuracy of 1--10 ms over the internet and sub-millisecond on a LAN. The algorithm estimates the clock offset $\theta$ as:

$$\theta = \frac{(t_2 - t_1) + (t_3 - t_4)}{2}$$

where $t_1$ is the client send time (client clock), $t_2$ the server receive time (server clock), $t_3$ the server send time (server clock), and $t_4$ the client receive time (client clock). This formula assumes **symmetric network delay**: the one-way delay from client to server equals the one-way delay from server to client. When this assumption is violated (e.g., asymmetric routing), NTP's accuracy degrades.

::: theorem
**Theorem 19.3 (Lundelius-Lynch Clock Synchronisation Bound, 1984).** In a system of $n$ processes where message delay is bounded by $[d - u, d]$ (uncertainty $u$), no deterministic algorithm can synchronise clocks to better than:

$$\epsilon \geq \frac{u}{2}\left(1 - \frac{1}{n}\right)$$

*Proof sketch.* The proof constructs two executions of the synchronisation protocol that are indistinguishable to $n-1$ of the $n$ processes but result in different clock values. The adversary shifts message delays within the uncertainty window to create these indistinguishable executions. Since no process can tell which execution it is in, it must set its clock to the same value in both executions, leading to a synchronisation error of at least $u(1-1/n)/2$. $\square$
:::

**PTP (Precision Time Protocol, IEEE 1588)** achieves sub-microsecond synchronisation using **hardware timestamping**: network interface cards timestamp packets at the physical layer, eliminating the jitter introduced by operating system scheduling, interrupt handling, and network stack processing. PTP is used in financial trading (where nanosecond precision is valuable), telecommunications (5G synchronisation), and industrial control (motion control, power grid synchronisation).

::: programmer
**Programmer's Perspective: Hybrid Logical Clocks in Go.**
Go's `time.Now()` returns the local wall clock, which is subject to NTP adjustments (including backwards jumps when NTP corrects a fast clock). For measuring elapsed time, always use `time.Since()` with a monotonic clock reading (Go automatically tracks monotonic time for `Time` values created by `time.Now()`).

For distributed systems, **hybrid logical clocks** (HLCs) combine physical and logical timestamps, giving the best of both worlds: timestamps that are close to real time and that capture causal ordering.

```go
package hlc

import (
    "sync"
    "time"
)

// Timestamp is a hybrid logical clock value.
type Timestamp struct {
    WallTime int64  // physical time (nanoseconds since epoch)
    Logical  uint32 // logical counter for events at same wall time
}

// Less reports whether ts < other.
func (ts Timestamp) Less(other Timestamp) bool {
    if ts.WallTime != other.WallTime {
        return ts.WallTime < other.WallTime
    }
    return ts.Logical < other.Logical
}

// Clock implements a hybrid logical clock.
type Clock struct {
    mu  sync.Mutex
    now func() time.Time // injectable time source for testing
    ts  Timestamp
}

// NewClock creates a new HLC using the given time source.
func NewClock(now func() time.Time) *Clock {
    return &Clock{now: now}
}

// Now returns a new timestamp for a local event.
func (c *Clock) Now() Timestamp {
    c.mu.Lock()
    defer c.mu.Unlock()

    pt := c.now().UnixNano()
    if pt > c.ts.WallTime {
        // Physical clock advanced: reset logical counter
        c.ts.WallTime = pt
        c.ts.Logical = 0
    } else {
        // Physical clock did not advance (same nanosecond
        // or NTP jumped backwards): increment logical counter
        c.ts.Logical++
    }
    return c.ts
}

// Update merges a received timestamp with the local clock.
// Called when a message with timestamp 'received' arrives.
func (c *Clock) Update(received Timestamp) Timestamp {
    c.mu.Lock()
    defer c.mu.Unlock()

    pt := c.now().UnixNano()

    if pt > c.ts.WallTime && pt > received.WallTime {
        // Physical clock is ahead of both: use it
        c.ts.WallTime = pt
        c.ts.Logical = 0
    } else if c.ts.WallTime == received.WallTime {
        // Local and received have same wall time: advance logical
        if c.ts.Logical > received.Logical {
            c.ts.Logical++
        } else {
            c.ts.Logical = received.Logical + 1
        }
    } else if c.ts.WallTime > received.WallTime {
        // Local is ahead: just advance local logical
        c.ts.Logical++
    } else {
        // Received is ahead: adopt received wall time
        c.ts.WallTime = received.WallTime
        c.ts.Logical = received.Logical + 1
    }
    return c.ts
}
```

HLCs are used by CockroachDB, YugabyteDB, and other distributed databases. The wall-time component provides rough real-time ordering (useful for TTL, lease expiry, and human-readable timestamps). The logical component ensures causal consistency: if event $a$ caused event $b$, then $\text{HLC}(a) < \text{HLC}(b)$.
:::

## 19.3 Distributed Mutual Exclusion

In a single OS, mutual exclusion is achieved through locks, semaphores, or atomic instructions backed by cache coherence protocols. In a distributed system, there is no shared memory and no atomic test-and-set. Distributed mutual exclusion algorithms must use only message passing.

::: definition
**Distributed Mutual Exclusion.** An algorithm that ensures at most one process in a distributed system can be in the critical section at any time, using only message passing. The algorithm must satisfy:

1. **Safety (Mutual Exclusion)**: at most one process is in the critical section at any time.
2. **Liveness (Progress)**: every request to enter the critical section is eventually granted.
3. **Ordering (Fairness)**: requests are granted in happened-before order. If process $P_i$ requests entry before process $P_j$ (in the happened-before sense), then $P_i$ enters before $P_j$.
:::

### 19.3.1 Centralised Algorithm

The simplest approach: a designated coordinator grants permission to enter the critical section.

1. To enter the CS, process $P_i$ sends a REQUEST to the coordinator.
2. The coordinator maintains a queue of pending requests. If no process is in the CS, it sends a GRANT to the requester. Otherwise, it queues the request.
3. When a process exits the CS, it sends a RELEASE to the coordinator, which grants the CS to the next queued process.

This requires 3 messages per CS entry (REQUEST, GRANT, RELEASE), but the coordinator is a single point of failure and a potential bottleneck.

### 19.3.2 Ricart-Agrawala Algorithm

The Ricart-Agrawala algorithm (1981) is a fully distributed, permission-based algorithm that requires $2(n-1)$ messages per critical section entry.

::: definition
**Ricart-Agrawala Algorithm.** When process $P_i$ wants to enter the critical section:

1. $P_i$ broadcasts a REQUEST message with its Lamport timestamp $(T_i, i)$ to all $n-1$ other processes.
2. When $P_j$ receives REQUEST$(T_i, i)$:
   - If $P_j$ is not requesting and not in the CS: immediately send REPLY to $P_i$.
   - If $P_j$ is in the CS: defer (queue) the REPLY.
   - If $P_j$ is also requesting the CS: compare timestamps. If $(T_i, i) < (T_j, j)$ (i.e., $P_i$'s request has priority): send REPLY to $P_i$. Otherwise: defer.
3. $P_i$ enters the CS after receiving REPLY from all $n-1$ processes.
4. When $P_i$ exits the CS: send REPLY to all deferred requests.
:::

::: theorem
**Theorem 19.4 (Ricart-Agrawala Mutual Exclusion).** The Ricart-Agrawala algorithm guarantees mutual exclusion.

*Proof.* Suppose, for contradiction, that $P_i$ and $P_j$ are both in the critical section simultaneously. Without loss of generality, assume $P_i$'s request has the smaller Lamport timestamp: $(T_i, i) < (T_j, j)$. For $P_j$ to be in the CS, it must have received REPLY from all $n-1$ processes, including $P_i$.

When $P_i$ received $P_j$'s REQUEST with timestamp $(T_j, j)$, $P_i$ was either: (a) requesting with $(T_i, i) < (T_j, j)$, in which case $P_i$ defers $P_j$'s request (no REPLY sent), or (b) already in the CS, in which case $P_i$ also defers. In neither case does $P_i$ send REPLY to $P_j$.

Therefore $P_j$ cannot have received REPLY from $P_i$ and cannot be in the CS --- contradiction. $\square$
:::

::: example
**Example 19.3 (Ricart-Agrawala Execution).** Three processes $P_1$, $P_2$, $P_3$, where $P_1$ and $P_2$ simultaneously request the critical section with timestamps $(5, 1)$ and $(3, 2)$ respectively:

```text
P1: REQUEST(5,1) ──> P2, P3    | Receives REQUEST(3,2): (3,2)<(5,1), send REPLY to P2
P2: REQUEST(3,2) ──> P1, P3    | Receives REQUEST(5,1): (3,2)<(5,1), defer P1's request
P3: Not requesting              | Receives both: send REPLY to both

Timeline:
  P2 has REPLYs from P1 and P3: enters CS
  P2 exits CS: sends deferred REPLY to P1
  P1 has REPLYs from P2 and P3: enters CS
```

The algorithm correctly serialises access: $P_2$ (with the earlier timestamp) enters first.
:::

### 19.3.3 Token Ring

An alternative approach: a logical token circulates among processes. Only the token holder may enter the critical section.

::: definition
**Token Ring Mutual Exclusion.** Processes are arranged in a logical ring $P_1 \rightarrow P_2 \rightarrow \cdots \rightarrow P_n \rightarrow P_1$. A special TOKEN message circulates continuously. When a process receives the token: if it wants the CS, it enters and holds the token; otherwise, it forwards the token to the next process.
:::

Token ring requires between 0 messages (if the process already holds the token) and $n$ messages (the token must traverse the entire ring) per CS entry. The average is $n/2$ under uniform load. The algorithm is simple and fair, but it has two issues: a lost token (due to process crash or message loss) requires a token regeneration protocol, and the token circulates even when no process needs the CS (wasting bandwidth).

## 19.4 Consensus

**Consensus** is the fundamental problem of distributed computing: getting a group of processes to agree on a single value, even when some processes may fail. Consensus underlies state machine replication, atomic commit, leader election, and configuration management.

::: definition
**Consensus.** A set of $n$ processes, each proposing a value, must reach agreement satisfying:

1. **Agreement**: all non-faulty processes decide the same value.
2. **Validity**: the decided value was proposed by some process. (This prevents trivial solutions like "always decide 0.")
3. **Termination**: every non-faulty process eventually decides.
:::

### 19.4.1 The FLP Impossibility Result

::: theorem
**Theorem 19.5 (Fischer, Lynch, Paterson, 1985).** In an asynchronous distributed system with reliable message delivery, there is no deterministic algorithm that solves consensus if even one process may crash.

*Proof sketch.* The proof proceeds in three steps:

**Step 1: Bivalent initial configurations exist.** An initial configuration is *bivalent* if both 0 and 1 are reachable as decision values from that configuration (depending on the schedule of events). By a valence argument on the boundary between 0-valent and 1-valent configurations (varying one process's initial value at a time), at least one bivalent initial configuration must exist.

**Step 2: From any bivalent configuration, the adversary can maintain bivalence.** Consider a bivalent configuration $C$ and a pending event $e$ (a message delivery). The set of configurations reachable from $C$ by applying $e$ either contains a bivalent configuration (the adversary applies $e$ and remains bivalent) or all configurations reachable are univalent but with different valences. In the latter case, the adversary can show a contradiction by constructing two executions that are indistinguishable to all but one process.

**Step 3: The adversary constructs an infinite non-deciding execution.** Starting from the bivalent initial configuration, the adversary repeatedly applies Step 2 to keep the system bivalent. Each process's pending messages are eventually delivered (ensuring fairness), but the adversary delays the "critical" message just enough to prevent the system from reaching a univalent (decided) state.

The key insight is that in an asynchronous system, there is no way to distinguish a slow process from a crashed one. Any timeout-based decision risks violating agreement (if the "slow" process is actually alive and decides differently). $\square$
:::

The FLP result does not mean consensus is impossible in practice --- it means there is no algorithm that is guaranteed to terminate in **all** asynchronous executions. Practical consensus algorithms work around FLP by:

- **Partial synchrony**: assuming that the system eventually becomes synchronous (unknown GST), which allows liveness after GST while maintaining safety always.
- **Randomisation**: Las Vegas algorithms that terminate with probability 1 (Ben-Or, 1983).
- **Failure detectors**: oracles that provide hints about which processes have crashed ($\diamond \mathcal{S}$, the eventually perfect failure detector, is sufficient for consensus).

### 19.4.2 Paxos

**Paxos**, proposed by Leslie Lamport in 1989 (published in 1998 as "The Part-Time Parliament"), is the canonical consensus algorithm for partially synchronous systems.

::: definition
**Paxos Roles.** A Paxos system has three roles (a single node may play multiple roles):

1. **Proposer**: proposes values for the consensus decision.
2. **Acceptor**: votes on proposed values. A quorum of acceptors (a majority: $\lfloor n/2 \rfloor + 1$ out of $n$) must agree for a value to be chosen.
3. **Learner**: learns the decided value (for applying to the state machine).
:::

The single-decree (single-value) Paxos algorithm proceeds in two phases:

**Phase 1 --- Prepare:**

1. A proposer selects a globally unique, monotonically increasing proposal number $n$ (typically using a pair $(round, proposer\_id)$) and sends PREPARE$(n)$ to a quorum of acceptors.

2. An acceptor receiving PREPARE$(n)$: if $n$ is greater than any PREPARE it has previously responded to, it replies with PROMISE$(n, v_a, n_a)$, where $(v_a, n_a)$ is the highest-numbered proposal it has previously accepted (or $(\bot, 0)$ if none). The acceptor **promises** not to accept any proposal with number less than $n$.

**Phase 2 --- Accept:**

1. If the proposer receives PROMISE from a quorum, it selects a value $v$:
   - If any acceptor reported a previously accepted value, the proposer **must** use the value with the highest proposal number (this is what prevents conflicting decisions).
   - If no acceptor has accepted anything ($v_a = \bot$ for all), the proposer may choose any value.
   
   The proposer sends ACCEPT$(n, v)$ to the quorum.

2. An acceptor receiving ACCEPT$(n, v)$: if $n \geq$ the highest-numbered PREPARE it has promised, it accepts the proposal and sends ACCEPTED$(n, v)$ to the learners. Otherwise, it ignores the request.

::: theorem
**Theorem 19.6 (Paxos Safety).** If a value $v$ is chosen (accepted by a quorum), then no other value $v' \neq v$ can ever be chosen.

*Proof sketch.* Suppose $v$ is chosen with proposal number $n$. We prove by strong induction that every proposal with number $n' > n$ also proposes $v$.

Consider any proposal with number $n' > n$. In Phase 1, the proposer of $n'$ receives PROMISE from a quorum $Q'$. Because any two quorums overlap ($|Q| + |Q'| > n_{\text{acceptors}}$, since both are majorities), at least one acceptor $a$ is in both the quorum that accepted $(n, v)$ and the quorum $Q'$ that responded to the PREPARE$(n')$.

Acceptor $a$ has accepted $(n, v)$ (or something with an even higher number, which by induction also proposes $v$). Acceptor $a$ reports this in its PROMISE response. The proposer of $n'$, following the protocol, must use the value from the highest-numbered accepted proposal, which is $v$ (or a value proposed at $\geq n$, which by induction is also $v$).

Therefore, proposal $n'$ proposes $v$, and the only value that can be chosen is $v$. $\square$
:::

::: example
**Example 19.4 (Paxos Execution).** Three acceptors $A_1, A_2, A_3$. Proposer $P_1$ proposes value "x", proposer $P_2$ proposes value "y".

```text
P1: PREPARE(1)  ──> A1, A2, A3
  A1: PROMISE(1, null, 0)
  A2: PROMISE(1, null, 0)
  (A3 is slow)

P1: received quorum (A1, A2). No accepted values. Chooses "x".
P1: ACCEPT(1, "x") ──> A1, A2
  A1: accepts (1, "x")
  A2: accepts (1, "x")
  Value "x" is CHOSEN (majority accepted).

P2: PREPARE(2) ──> A1, A2, A3  (higher proposal number)
  A1: PROMISE(2, "x", 1)      (reports previously accepted value)
  A3: PROMISE(2, null, 0)

P2: received quorum (A1, A3). A1 reports ("x", 1).
P2: MUST propose "x" (the value from the highest accepted proposal).
P2: ACCEPT(2, "x") ──> A1, A3

Result: "x" is the consensus value, even though P2 originally wanted "y".
```
:::

### 19.4.3 Raft: A Detailed Walkthrough

**Raft** (Ongaro and Ousterhout, 2014) was designed as an understandable alternative to Paxos. Where Paxos decomposes consensus into roles (proposer, acceptor, learner), Raft decomposes it into sub-problems: leader election, log replication, and safety.

::: definition
**Raft.** A consensus algorithm for replicated state machines. Key concepts:

1. **Term**: a logical time period, monotonically increasing. Each term has at most one leader. Terms serve the role of Paxos proposal numbers.
2. **Log**: an ordered sequence of entries, each containing a client command and the term when it was received.
3. **Commit index**: the index of the highest log entry known to be replicated on a majority. Committed entries are safe to apply to the state machine.
4. **State machine**: the application logic (e.g., a key-value store) that applies committed log entries in order.
:::

**Leader Election:**

1. All nodes start as **followers**. Each follower has a randomised **election timeout** (e.g., 150--300 ms). If a follower does not hear from a leader (via AppendEntries RPC or heartbeat) within its timeout, it becomes a **candidate**.

2. The candidate increments its current term, votes for itself, and sends RequestVote RPCs to all other nodes.

3. A node votes for at most one candidate per term (first-come-first-served), and only if the candidate's log is at least as up-to-date as the voter's (compared by last entry's term, then log length). This is the **election restriction** that ensures safety.

4. A candidate that receives votes from a majority becomes the **leader** for that term. It immediately sends heartbeats (empty AppendEntries) to all followers to establish authority and prevent new elections.

5. If no candidate wins (split vote --- two candidates each get some votes but not a majority), all candidates time out and start a new election with a higher term. The randomised timeout makes split votes unlikely.

**Log Replication:**

::: example
**Example 19.5 (Raft Log Replication).** A 5-node Raft cluster with $S_1$ as leader in term 3:

```text
Client request: SET x=5
   │
   ▼
S1 (Leader, Term 3):
  Log: [T1:SET a=1] [T2:SET b=2] [T3:SET x=5]
                                    │ (index 3, new entry)
                          AppendEntries RPC
                    (term=3, prevLogIndex=2, prevLogTerm=2,
                     entries=[{T3,SET x=5}], leaderCommit=2)
                                    │
          ┌──────────────┬──────────┼──────────┬──────────────┐
          ▼              ▼          ▼          ▼              ▼
   S2: match OK    S3: match OK   S4: slow   S5: match OK
   append entry    append entry              append entry
   reply success   reply success             reply success

S1 receives 3 successes (S2, S3, S5) + itself = 4/5 = majority
  => Entry at index 3 is COMMITTED
  => S1 applies SET x=5 to state machine, replies to client: OK
  => Next AppendEntries will carry leaderCommit=3
  => S4 eventually catches up and applies the entry
```

Even though $S_4$ is slow, the entry is committed because 4 out of 5 nodes have it. $S_4$ will receive the entry in a later AppendEntries and catch up. The state machine is consistent: all nodes that apply the entry will apply the same command in the same order.
:::

**Safety --- Leader Completeness:**

Raft's key safety invariant: if a log entry is committed in a given term, that entry is present in the logs of all leaders for all higher terms.

::: theorem
**Theorem 19.7 (Raft Leader Completeness).** If a log entry $e$ at index $i$ is committed in term $t$, then every leader elected in any term $t' > t$ has $e$ at index $i$ in its log.

*Proof sketch.* Entry $e$ is committed, so it is stored on a majority $M$ of nodes. For a candidate to win election in term $t'$, it must receive votes from a majority $V$ of nodes. Since $|M| + |V| > n$, $M \cap V \neq \emptyset$: at least one node in $V$ has entry $e$.

The election restriction ensures that a voter only votes for a candidate whose log is at least as up-to-date. A node with entry $e$ (committed at term $t$, index $i$) will reject any candidate whose last log entry has a term $< t$, or the same term but a shorter log. Therefore, only candidates that already have entry $e$ can win the election. $\square$
:::

::: example
**Example 19.6 (Log Divergence and Repair).** After a leader crash, logs may diverge. Consider a 5-node cluster where leader $S_1$ crashes after replicating an entry (index 4, term 3) to only $S_2$:

```text
S1: [T1][T2][T3][T3]  <-- crashed, had index 4 in term 3
S2: [T1][T2][T3][T3]  <-- has the unreplicated entry
S3: [T1][T2][T3]      <-- does not have index 4
S4: [T1][T2][T3]
S5: [T1][T2][T3]
```

$S_3$ wins election in term 4 (receives votes from $S_4$ and $S_5$, plus itself = 3/5 majority). $S_3$'s log ends at (term 3, index 3), which is at least as up-to-date as $S_4$ and $S_5$'s logs.

$S_3$ receives a new client request and appends it at index 4, term 4:

```text
S3 (new leader): [T1][T2][T3][T4]  <-- index 4 now has term 4 entry
```

When $S_3$ sends AppendEntries to $S_2$, $S_2$'s log has a conflicting entry at index 4 (term 3 vs term 4). The Raft protocol requires $S_2$ to **delete** the conflicting entry and replace it with the leader's entry. This is safe because the term 3 entry at index 4 was never committed (it was only on $S_1$ and $S_2$, not a majority).
:::

## 19.5 Distributed File Systems

A distributed file system provides the abstraction of a single, shared filesystem across multiple machines.

### 19.5.1 NFS (Network File System)

NFS, originally developed by Sun Microsystems (1984), is the most widely deployed distributed file system. NFS v3 uses a **stateless** server design:

::: definition
**Stateless NFS Server.** The NFS server does not maintain per-client state about open files. Each request (READ, WRITE, LOOKUP, GETATTR) is self-contained, carrying a **file handle** (an opaque reference to the inode), the byte offset, and the data. If the server crashes and restarts, it can continue serving requests without a recovery protocol --- clients simply retry.
:::

The stateless design simplifies crash recovery but limits performance and semantics:

- **No read-ahead or write-behind per client**: the server does not know which files a client has open.
- **No close-to-open consistency guarantee**: clients cache file data aggressively and may serve stale reads.
- **No locking protocol in the core protocol**: a separate NLM (Network Lock Manager) provides advisory locking, adding complexity.

NFS v4 (2003) adds statefulness: clients open files and acquire **leases** (time-limited locks). This enables better caching semantics (delegations), atomic open-with-create, and mandatory locking. NFSv4.1 (2010) adds session semantics and pNFS (parallel NFS) for distributed data access.

### 19.5.2 GFS and HDFS

**Google File System** (GFS, 2003) and its open-source descendant **Hadoop Distributed File System** (HDFS) are designed for a different workload: very large files (gigabytes to terabytes), sequential reads, and append-heavy writes, running on commodity hardware that fails frequently.

::: definition
**GFS/HDFS Architecture.** The system has three components:

1. **Master/NameNode**: a single node that manages metadata --- the directory tree, file-to-chunk mapping, and chunk locations. The master does not store file data.

2. **Chunkservers/DataNodes**: store file data in fixed-size chunks (64 MB in GFS, 128 MB default in HDFS). Each chunk is replicated on 3 nodes by default for fault tolerance.

3. **Client library**: contacts the master for metadata (which chunkserver has chunk $k$ of file $f$?), then reads/writes directly from/to chunkservers (data never flows through the master).
:::

The single-master design simplifies consistency and enables fast metadata operations (the entire directory tree fits in RAM), but it is a bottleneck and single point of failure. HDFS NameNode HA uses a **standby NameNode** with a shared edit journal (via JournalNodes implementing a consensus protocol) for automatic failover.

::: example
**Example 19.7 (HDFS Read Path).**

```text
Client                    NameNode               DataNode1    DataNode2    DataNode3
  │                         │                        │            │            │
  │ open("/data/log.gz")    │                        │            │            │
  │────────────────────────>│                        │            │            │
  │ block locations:        │                        │            │            │
  │ blk_0: DN1, DN2, DN3   │                        │            │            │
  │ blk_1: DN2, DN3, DN1   │                        │            │            │
  │<────────────────────────│                        │            │            │
  │                         │                        │            │            │
  │ read blk_0 from DN1    │                        │            │            │
  │ (closest replica)       │                        │            │            │
  │──────────────────────────────────────────────────>│            │            │
  │ data                    │                        │            │            │
  │<──────────────────────────────────────────────────│            │            │
  │                         │                        │            │            │
  │ read blk_1 from DN2    │                        │            │            │
  │ (closest replica)       │                        │            │            │
  │───────────────────────────────────────────────────────────────>│            │
  │ data                    │                        │            │            │
  │<───────────────────────────────────────────────────────────────│            │
```

The client reads each block from the closest replica (rack-aware placement). The NameNode is contacted only once for block locations, not on every read. Data flows directly between client and DataNodes.
:::

### 19.5.3 Ceph

**Ceph** eliminates the single-metadata-server bottleneck with **CRUSH** (Controlled Replication Under Scalable Hashing), an algorithmic data placement strategy.

::: definition
**CRUSH Algorithm.** Instead of looking up data locations in a metadata table, CRUSH computes the location of any object deterministically from the object's name, a cluster map (describing the topology of storage nodes), and placement rules. Both clients and storage nodes can independently compute where data should be stored, without consulting a central authority.
:::

The CRUSH algorithm takes as input: the object's ID (a hash), the cluster map (a hierarchy of racks, hosts, and disks), and a placement rule (e.g., "place 3 replicas, each on a different rack"). It outputs a list of storage targets. Because the computation is deterministic, any node that has the cluster map can compute the same result.

Ceph provides three interfaces: **RBD** (block storage for VMs), **CephFS** (POSIX file system with distributed metadata servers), and **RADOS Gateway** (S3/Swift-compatible object storage). The underlying **RADOS** layer handles replication, recovery, and rebalancing automatically.

## 19.6 Distributed Shared Memory

**Distributed Shared Memory** (DSM) provides the abstraction of a single shared address space across multiple machines, allowing processes to read and write shared variables using normal memory operations. The DSM system transparently handles the communication necessary to keep the shared state consistent.

### 19.6.1 Consistency Models

::: definition
**Consistency Model.** A contract between the memory system and the programmer that defines which orderings of reads and writes are legal. Stronger models restrict the set of possible orderings (easier to reason about) but require more communication (harder to implement efficiently).
:::

The hierarchy from strongest to weakest:

**Strict Consistency:** Every read returns the value of the most recent write, globally. This requires instantaneous propagation of writes --- physically impossible when machines are separated by network latency.

**Linearisability (Herlihy and Wing, 1990):**

::: definition
**Linearisability.** An execution is linearisable if each operation appears to take effect instantaneously at some point between its invocation and its response, and the resulting sequence of operations is consistent with the object's sequential specification.
:::

Linearisability is the strongest achievable consistency model in a distributed system. It is the "C" in the CAP theorem (see Section 19.7).

**Sequential Consistency (Lamport, 1979):**

::: definition
**Sequential Consistency.** A system is sequentially consistent if the result of any execution is the same as if the operations of all processes were executed in some sequential order, and the operations of each individual process appear in this sequence in the order issued by that process.
:::

::: example
**Example 19.8 (Sequential vs Linearisable).** Two processes:

```text
P1: W(x, 1)  W(x, 3)
P2: W(x, 2)  R(x) -> ?
```

Under **sequential consistency**, any total order preserving each process's program order is valid. $R(x) = 3$ (order: $W_2(x,2), W_1(x,1), W_1(x,3), R_2(x)$) is valid even though $W_1(x,3)$ finished (in real time) before $R_2(x)$ started.

Under **linearisability**, the total order must also be consistent with real-time ordering: if $W_1(x,3)$ completed before $R_2(x)$ started, then $R_2(x)$ must return 3 or a later value. Linearisability is strictly stronger.
:::

**Causal Consistency:** Writes that are causally related (one happened before the other) are seen in the same order by all processes. Concurrent writes may be seen in different orders by different processes.

**Eventual Consistency:** If no new writes are made, all replicas will eventually converge to the same value. This is the weakest useful model and is used by many internet-scale systems (DNS, Cassandra, DynamoDB in its default mode, web caches).

### 19.6.2 Trade-offs

| Model | Programmability | Latency | Availability |
|---|---|---|---|
| Linearisable | Easiest | High (requires quorum) | Low during partitions |
| Sequential | Easy | Medium | Low during partitions |
| Causal | Moderate | Low-medium | Moderate |
| Eventual | Hardest (application resolves conflicts) | Low | High |

## 19.7 The CAP Theorem

The **CAP theorem** (Brewer's conjecture, 2000; proved by Gilbert and Lynch, 2002) formalises the fundamental trade-off in distributed data stores.

::: theorem
**Theorem 19.8 (CAP Theorem).** A distributed data store can provide at most two of the following three guarantees simultaneously:

1. **Consistency (C)**: every read receives the most recent write (linearisability).
2. **Availability (A)**: every request to a non-failing node receives a response (possibly stale).
3. **Partition tolerance (P)**: the system continues to operate despite arbitrary message loss between nodes.

*Proof.* Consider a system with two nodes $N_1$ and $N_2$ that replicate a variable $x$, initially $x = 0$. Suppose a network partition separates $N_1$ and $N_2$ (they cannot communicate).

A client writes $x = 1$ to $N_1$. Another client reads $x$ from $N_2$.

**Case 1 --- Consistency + Availability:** $N_2$ must return $x = 1$ (consistency) and must respond (availability). But $N_2$ has not received the write (partition). Therefore $N_2$ cannot return 1 without communicating with $N_1$, which is impossible. Contradiction: C + A + P cannot all hold.

**Case 2 --- Consistency + Partition tolerance (CP):** $N_2$ refuses to respond until the partition heals (sacrificing availability). After the partition heals, $N_2$ receives the write and can respond correctly.

**Case 3 --- Availability + Partition tolerance (AP):** $N_2$ responds immediately with the stale value $x = 0$ (sacrificing consistency). After the partition heals, a reconciliation mechanism updates $N_2$.

Since network partitions are inevitable in any real distributed system, the practical choice is between CP and AP. $\square$
:::

::: example
**Example 19.9 (CP vs AP Systems in Practice).**

**CP system (etcd, ZooKeeper):** During a network partition, the **minority** partition becomes unavailable --- it cannot elect a leader (requires a majority) and cannot process writes or linearisable reads. The majority partition continues operating normally. After the partition heals, the minority nodes rejoin and catch up.

This is appropriate for: coordination services, distributed locks, configuration stores, and leader election --- systems where stale data is worse than unavailability.

**AP system (Cassandra with CL=ONE, DynamoDB default):** During a partition, **both** sides continue serving reads and writes. After the partition heals, a conflict resolution mechanism reconciles the divergent values. Common strategies:

- **Last-writer-wins (LWW):** the write with the highest timestamp wins. Simple but can lose concurrent writes.
- **CRDTs (Conflict-free Replicated Data Types):** data structures designed to merge automatically without conflicts (e.g., G-counter, OR-set).
- **Application-level resolution:** the application is notified of conflicts and decides (e.g., Amazon's shopping cart merges items from both versions).

This is appropriate for: social media feeds, shopping carts, DNS, caching, and any system where temporary staleness is acceptable.
:::

::: programmer
**Programmer's Perspective: etcd and Raft in Go.**
etcd is a distributed key-value store built on Raft, written in Go. It is the coordination backbone of Kubernetes (storing all cluster state). etcd is a CP system: during a partition, the minority partition cannot process writes.

```go
package main

import (
    "context"
    "fmt"
    "log"
    "time"

    clientv3 "go.etcd.io/etcd/client/v3"
    "go.etcd.io/etcd/client/v3/concurrency"
)

func main() {
    // Connect to etcd cluster
    cli, err := clientv3.New(clientv3.Config{
        Endpoints:   []string{"localhost:2379", "localhost:2380", "localhost:2381"},
        DialTimeout: 5 * time.Second,
    })
    if err != nil {
        log.Fatal(err)
    }
    defer cli.Close()

    ctx := context.Background()

    // Linearisable write (goes through Raft consensus)
    _, err = cli.Put(ctx, "service/leader", "node-3")
    if err != nil {
        log.Fatal(err)
    }

    // Linearisable read (reads go through the leader)
    resp, err := cli.Get(ctx, "service/leader")
    if err != nil {
        log.Fatal(err)
    }
    for _, kv := range resp.Kvs {
        fmt.Printf("%s = %s (mod revision %d)\n",
            kv.Key, kv.Value, kv.ModRevision)
    }

    // Distributed lock using etcd (built on Raft consensus)
    session, err := concurrency.NewSession(cli)
    if err != nil {
        log.Fatal(err)
    }
    defer session.Close()

    mutex := concurrency.NewMutex(session, "/locks/myresource")

    if err := mutex.Lock(ctx); err != nil {
        log.Fatal(err)
    }
    fmt.Println("Acquired distributed lock")

    // Critical section: safe across all nodes in the cluster
    // ... do work ...

    if err := mutex.Unlock(ctx); err != nil {
        log.Fatal(err)
    }
    fmt.Println("Released distributed lock")
}
```

Every `Put` in etcd goes through Raft consensus: the leader replicates the write to a majority before acknowledging. The distributed lock is implemented using etcd's lease mechanism: the lock holder creates a key with a lease, and if the holder crashes, the lease expires and the lock is released automatically.
:::

## 19.8 Failure Detection

Detecting whether a remote process has failed is a prerequisite for many distributed protocols (consensus, group membership, leader election). In an asynchronous system, perfect failure detection is impossible (FLP). Practical failure detectors use timeouts and heuristics, accepting that they will occasionally make mistakes (suspecting alive processes or failing to suspect crashed ones).

### 19.8.1 Heartbeats

The simplest approach: each process periodically sends "I am alive" messages to a monitor (or to all other processes). If the monitor does not receive a heartbeat within a timeout period $T$, it suspects the process has failed.

The challenge is choosing $T$:

- **$T$ too short**: the detector suspects alive-but-slow processes (**false positive**). This can trigger unnecessary leader elections, failovers, and data rebalancing.
- **$T$ too long**: a truly crashed process is not detected for a long time, leaving the system in a degraded state.

### 19.8.2 The Phi Accrual Failure Detector

::: definition
**Phi Accrual Failure Detector (Hayashibara et al., 2004).** Instead of producing a binary "alive/dead" output, the phi accrual detector computes a continuous **suspicion level** $\phi$ based on the statistical distribution of heartbeat inter-arrival times.

Let $\Delta t$ be the time since the last heartbeat, and let $F$ be the CDF of the estimated heartbeat inter-arrival distribution (typically normal, fitted to the most recent $W$ observations). The suspicion level is:

$$\phi(\Delta t) = -\log_{10}\left(1 - F(\Delta t)\right)$$

Interpretation:
- $\phi = 1$: $P(\text{alive node has such a long gap}) = 10^{-1} = 10\%$
- $\phi = 3$: $P = 10^{-3} = 0.1\%$
- $\phi = 8$: $P = 10^{-8} \approx 0$ --- almost certainly failed

The application chooses a threshold based on its tolerance for false positives.
:::

The advantage of the phi accrual detector is **adaptivity**: it learns the network's characteristics (jitter, latency distribution) from observed heartbeat times and adjusts automatically. A noisy network with high variance produces a wider distribution, requiring a larger $\Delta t$ before $\phi$ exceeds the threshold. Apache Cassandra uses this detector with a default threshold of $\phi = 8$.

### 19.8.3 SWIM (Scalable Weakly-consistent Infection-style Membership)

::: definition
**SWIM Protocol (Das et al., 2002).** A membership protocol that detects failures and disseminates membership information in $O(\log n)$ time with $O(1)$ bandwidth per member per protocol period. Each period:

1. A process $P_i$ selects a random member $P_j$ and sends a PING.
2. If $P_j$ replies with an ACK within a timeout, $P_j$ is alive.
3. If $P_j$ does not reply, $P_i$ selects $k$ other members (the **indirect probe group**) and asks them to PING $P_j$ on its behalf. If any of the $k$ members receives an ACK from $P_j$, they relay it to $P_i$.
4. If none of the $k$ indirect probes succeed, $P_i$ marks $P_j$ as **suspected** and disseminates this suspicion via **piggyback gossip**: membership updates are attached to the regular PING/ACK messages, spreading through the cluster like an epidemic.
5. After a configurable grace period, if $P_j$ does not refute the suspicion, it is declared **confirmed dead** and removed from the membership.
:::

SWIM's genius is combining failure detection with information dissemination: membership changes (joins, failures, suspicions) are piggybacked on the PING/ACK messages that are already being exchanged, achieving $O(n)$ total bandwidth across the cluster with $O(\log n)$ convergence time (each message carries updates that spread exponentially, like a rumour).

HashiCorp's **Serf** and **Consul** use SWIM (with extensions: Lifeguard, which reduces false positive rates by allowing suspected nodes to refute before being evicted).

::: programmer
**Programmer's Perspective: gRPC for Distributed Communication.**
gRPC (Google Remote Procedure Call) is the dominant RPC framework for distributed systems. Built on Protocol Buffers (efficient binary serialisation) and HTTP/2 (multiplexed streams, flow control, header compression), gRPC provides features critical for distributed systems:

- **Deadlines**: a client sets a deadline, and it propagates through the entire RPC chain. If a downstream service cannot complete before the deadline, it cancels and returns early.
- **Cancellation**: cancelling a parent context cancels all in-flight RPCs.
- **Streaming**: unary (request-response), server streaming, client streaming, and bidirectional streaming.
- **Health checking**: a standard `grpc.health.v1.Health` service that load balancers use for failure detection.
- **Interceptors**: middleware for logging, authentication, retry, and circuit breaking.

```go
package main

import (
    "context"
    "log"
    "net"
    "sync"

    "google.golang.org/grpc"
    "google.golang.org/grpc/health"
    healthpb "google.golang.org/grpc/health/grpc_health_v1"
    pb "example.com/kvstore" // generated from .proto
)

type server struct {
    pb.UnimplementedKVStoreServer
    mu    sync.RWMutex
    store map[string]string
}

func (s *server) Get(ctx context.Context, req *pb.GetRequest) (*pb.GetResponse, error) {
    s.mu.RLock()
    defer s.mu.RUnlock()
    val, ok := s.store[req.Key]
    return &pb.GetResponse{Value: val, Found: ok}, nil
}

func (s *server) Put(ctx context.Context, req *pb.PutRequest) (*pb.PutResponse, error) {
    s.mu.Lock()
    defer s.mu.Unlock()
    s.store[req.Key] = req.Value
    return &pb.PutResponse{}, nil
}

func main() {
    lis, err := net.Listen("tcp", ":50051")
    if err != nil {
        log.Fatalf("listen: %v", err)
    }

    s := grpc.NewServer()

    // Register application service
    kvServer := &server{store: make(map[string]string)}
    pb.RegisterKVStoreServer(s, kvServer)

    // Register health service (used by load balancers and SWIM-like detectors)
    healthServer := health.NewServer()
    healthpb.RegisterHealthServer(s, healthServer)
    healthServer.SetServingStatus("kvstore", healthpb.HealthCheckResponse_SERVING)

    log.Println("KVStore gRPC server on :50051")
    if err := s.Serve(lis); err != nil {
        log.Fatalf("serve: %v", err)
    }
}
```

In a Raft-based system like etcd, gRPC is used for both client communication and inter-node communication: the leader sends AppendEntries as gRPC streams, and candidates send RequestVote as unary RPCs. The deadline mechanism ensures that a slow follower does not block the leader indefinitely.
:::

## 19.9 Theoretical Boundaries

The results in this chapter establish fundamental limits on what is achievable in distributed systems:

::: theorem
**Theorem 19.9 (Summary of Impossibility and Lower Bound Results).**

1. **FLP (1985)**: no deterministic consensus algorithm terminates in all asynchronous executions with even one crash failure. Implication: practical consensus requires partial synchrony or randomisation.

2. **CAP (2002)**: no distributed system can simultaneously guarantee linearisability, availability, and partition tolerance. Implication: during a partition, choose CP or AP.

3. **Lundelius-Lynch (1984)**: in a system of $n$ processes where message delay uncertainty is $u$, clocks cannot be synchronised to better than $u(1 - 1/n)/2$. Implication: clock synchronisation has a fundamental precision limit.

4. **Two Generals (1975)**: two processes communicating over an unreliable channel cannot reach agreement in a finite number of messages. Implication: TCP's three-way handshake is a practical workaround (not a theoretical solution).

5. **Byzantine Generals (Lamport, Shostak, Pease, 1982)**: consensus tolerating $f$ Byzantine failures requires $n \geq 3f + 1$ processes. Implication: tolerating one lying node requires at least 4 nodes.

These are not engineering limitations --- they are mathematical theorems. No amount of clever design, faster hardware, or better networks can circumvent them. The art of distributed systems is choosing which guarantees to relax and how to build useful systems within these constraints.
:::

---

::: exercises
1. **Vector Clock Comparison.** Three processes $P_1$, $P_2$, $P_3$ produce the following events with vector clocks: $a$ at $P_1$ with $V(a) = [2, 0, 0]$, $b$ at $P_2$ with $V(b) = [1, 3, 1]$, $c$ at $P_3$ with $V(c) = [1, 2, 4]$, $d$ at $P_1$ with $V(d) = [3, 3, 1]$. For each of the six pairs of events, determine whether one happened before the other or they are concurrent. Show your reasoning by comparing vectors componentwise. Draw a space-time diagram consistent with these vector clocks.

2. **Ricart-Agrawala Message Count.** (a) In a system of $n$ processes, prove that the Ricart-Agrawala algorithm requires exactly $2(n-1)$ messages per critical section entry in the absence of failures. (b) Describe the Roucairol-Carvalho optimisation that reduces the average message count. Explain how it works, prove that it maintains correctness, and characterise the workloads where it provides the greatest improvement.

3. **Paxos Liveness.** Paxos guarantees safety (no two different values are chosen) but not liveness (the algorithm may not terminate). (a) Describe a "duelling proposers" scenario in which two proposers prevent each other from ever completing Phase 2. (b) How does **Multi-Paxos** (with a stable leader) address this? (c) Prove that Multi-Paxos requires only one round trip per consensus decision (after leader election), compared to two round trips for basic Paxos.

4. **Raft Log Divergence.** Consider a 5-node Raft cluster where the leader ($S_1$, term 3) crashes after replicating an entry at index 4 to only $S_2$. (a) Draw the logs of all five nodes immediately after the crash. (b) Show how a new leader is elected (which nodes can win, and why). (c) Draw the logs after the new leader receives and commits one new client request. (d) What happens to the unreplicated entry on $S_2$, and at what point is it safe for the new leader to overwrite it?

5. **CAP Classification.** For each of the following systems, classify it as CP or AP and justify with a specific partition scenario: (a) a single-node PostgreSQL database, (b) a 3-node ZooKeeper ensemble, (c) a Cassandra cluster with replication factor 3 and consistency level ONE, (d) a Cassandra cluster with replication factor 3 and consistency level QUORUM. For system (c), describe a concrete scenario in which a client reads stale data.

6. **Eventual Consistency Anomaly.** Two users, Alice and Bob, share a collaborative document stored with eventual consistency and three replicas. Alice deletes paragraph 3; Bob concurrently edits paragraph 3 (adding a sentence). Describe what each user sees immediately after their operation, and what all users see after the system converges, under: (a) last-writer-wins conflict resolution with wall-clock timestamps, (b) operational transformation, and (c) a CRDT-based approach (suggest which CRDT type would be appropriate). Which approach best preserves user intent?

7. **SWIM Protocol Analysis.** (a) Prove that if a node $P_j$ permanently fails, every non-faulty node detects $P_j$'s failure within $O(\log n)$ protocol periods with high probability, given that gossip dissemination achieves $O(\log n)$ rounds for full propagation. (b) Derive an expression for the false positive rate as a function of the timeout parameter and the network's RTT distribution. (c) Describe the trade-off between detection speed and false positive rate, and explain how the Lifeguard protocol extension reduces false positives.
:::
