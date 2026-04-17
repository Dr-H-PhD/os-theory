# Chapter 12: Page Replacement and Thrashing

Demand paging creates an illusion of abundant memory, but the illusion has a hard limit: physical frames are finite. Sooner or later, a page fault occurs when every frame is occupied. The operating system must then choose a *victim* --- a page currently in memory to evict, making room for the incoming page. The choice of victim is the *page replacement* problem, and it has a profound effect on system performance. A bad choice evicts a page that will be needed again immediately, causing another page fault, then another, in a cascading failure known as *thrashing*. A good choice evicts a page that will not be needed for a long time, minimising future faults.

This chapter develops the classical page replacement algorithms, analyses their properties with mathematical rigour, proves Belady's anomaly and the immunity of stack algorithms, and then addresses the systemic failure mode of thrashing and the mechanisms that prevent it.

---

## 12.1 The Page Replacement Problem

### 12.1.1 Formulation

::: definition
**Definition 12.1 (Page Replacement Problem).** Given a sequence of page references $\omega = r_1, r_2, \ldots, r_n$ (the *reference string*) and $m$ physical frames, determine which page to evict upon each page fault so as to minimise the total number of page faults.
:::

The reference string is an abstraction of the program's memory access pattern: each $r_i$ is the page number accessed at time $i$. Consecutive references to the same page are often collapsed, since they do not cause additional faults.

::: example
**Example 12.1 (Reference String).** A program accesses the following addresses (with 4 KB pages): 0x1004, 0x1200, 0x5000, 0x5100, 0x1004, 0x3000, 0x5200, 0x3004.

Page numbers (dividing by 4096): 1, 1, 5, 5, 1, 3, 5, 3.

Collapsing consecutive duplicates: $\omega = 1, 5, 1, 3, 5, 3$.
:::

### 12.1.2 Evaluation Metric

For a given replacement algorithm $A$, reference string $\omega$, and $m$ frames, let $f_A(\omega, m)$ denote the number of page faults. The goal is to minimise $f_A(\omega, m)$.

::: theorem
**Theorem 12.1 (Monotonicity --- General Case Fails).** For an arbitrary page replacement algorithm, it is *not* necessarily true that $f_A(\omega, m+1) \leq f_A(\omega, m)$. That is, adding a frame can increase the number of page faults.

This counter-intuitive phenomenon is called *Belady's anomaly* and is discussed in Section 12.4.
:::

---

## 12.2 Belady's Optimal Algorithm (OPT)

### 12.2.1 Definition

::: definition
**Definition 12.2 (OPT / Belady's Optimal Algorithm).** Upon a page fault, OPT evicts the page that will not be used for the longest time in the future. If a page will never be used again, it is the ideal victim. Among pages that will be used again, the one whose next reference is furthest away is evicted.
:::

::: example
**Example 12.2 (OPT Execution).** Reference string: $\omega = 7, 0, 1, 2, 0, 3, 0, 4, 2, 3, 0, 3, 2, 1, 2, 0, 1, 7, 0, 1$. Frames: $m = 3$.

| Step | Ref | Frame 0 | Frame 1 | Frame 2 | Fault? | Victim | Reason |
|------|-----|---------|---------|---------|--------|--------|--------|
| 1 | 7 | 7 | -- | -- | Yes | -- | Cold start |
| 2 | 0 | 7 | 0 | -- | Yes | -- | Cold start |
| 3 | 1 | 7 | 0 | 1 | Yes | -- | Cold start |
| 4 | 2 | 2 | 0 | 1 | Yes | 7 | 7 next used at step 18 (furthest) |
| 5 | 0 | 2 | 0 | 1 | No | -- | -- |
| 6 | 3 | 2 | 0 | 3 | Yes | 1 | 1 next used at step 14 (furthest) |
| 7 | 0 | 2 | 0 | 3 | No | -- | -- |
| 8 | 4 | 2 | 4 | 3 | Yes | 0 | 0 next used at step 11 (furthest) |
| 9 | 2 | 2 | 4 | 3 | No | -- | -- |
| 10 | 3 | 2 | 4 | 3 | No | -- | -- |
| 11 | 0 | 2 | 0 | 3 | Yes | 4 | 4 never used again |
| 12 | 3 | 2 | 0 | 3 | No | -- | -- |
| 13 | 2 | 2 | 0 | 3 | No | -- | -- |
| 14 | 1 | 2 | 0 | 1 | Yes | 3 | 3 not used again |
| 15 | 2 | 2 | 0 | 1 | No | -- | -- |
| 16 | 0 | 2 | 0 | 1 | No | -- | -- |
| 17 | 1 | 2 | 0 | 1 | No | -- | -- |
| 18 | 7 | 7 | 0 | 1 | Yes | 2 | 2 not used again |
| 19 | 0 | 7 | 0 | 1 | No | -- | -- |
| 20 | 1 | 7 | 0 | 1 | No | -- | -- |

Total page faults: 9.
:::

### 12.2.2 Proof of Optimality

::: theorem
**Theorem 12.2 (Optimality of OPT).** For any reference string $\omega$ and frame count $m$, OPT achieves the minimum possible number of page faults. That is, for any replacement algorithm $A$:

$$f_{\text{OPT}}(\omega, m) \leq f_A(\omega, m)$$

*Proof.* We prove this by an exchange argument. Let $A$ be any algorithm. We show that OPT's decisions can replace $A$'s decisions without increasing the fault count.

Consider the first time $A$ and OPT make different replacement decisions. At time $t$, both have the same set of pages in memory (since they have made identical decisions up to this point). Both experience a page fault on page $p$. OPT evicts page $q_{\text{OPT}}$ (the one with the furthest next use); $A$ evicts page $q_A \neq q_{\text{OPT}}$.

After the replacement:
- OPT has pages: $(S \setminus \{q_{\text{OPT}}\}) \cup \{p\}$
- $A$ has pages: $(S \setminus \{q_A\}) \cup \{p\}$

Since $q_{\text{OPT}}$'s next use is at time $t' \geq t_A'$ (where $t_A'$ is $q_A$'s next use), every reference between $t$ and $t'$ that $A$ handles without a fault can also be handled by OPT without a fault (since OPT has all the pages $A$ has, except it has $q_A$ instead of $q_{\text{OPT}}$, and $q_A$ is not referenced before $q_{\text{OPT}}$).

When $q_A$ is eventually referenced (at time $t_A' \leq t'$), $A$ does not fault (it still has $q_A$), but OPT might. However, at time $t_A'$, OPT can evict any page, and by choosing optimally at each subsequent fault, OPT accumulates at most as many faults as $A$ from time $t$ onward.

A formal inductive argument on the number of faults shows that $f_{\text{OPT}} \leq f_A$ for the entire string. $\square$
:::

### 12.2.3 Why OPT is Impractical

OPT requires knowledge of the entire future reference string, which is unavailable in an online system. Its value is as a benchmark: we can compare any practical algorithm's fault rate against OPT to measure how close to optimal the algorithm is. When evaluating a new replacement algorithm $A$, we compute the *competitiveness ratio*:

$$\rho_A(\omega, m) = \frac{f_A(\omega, m)}{f_{\text{OPT}}(\omega, m)}$$

For the example above, FIFO achieves $\rho_{\text{FIFO}} = 15/9 = 1.67$, meaning FIFO causes 67% more faults than optimal. LRU achieves $\rho_{\text{LRU}} = 12/9 = 1.33$, or 33% more faults.

### 12.2.4 OPT as an Offline Algorithm

::: definition
**Definition 12.2a (Online vs Offline Algorithm).** An *online algorithm* makes decisions based only on past and present information (the reference string up to the current time). An *offline algorithm* has access to the entire input (the complete reference string) before making any decision. OPT is an offline algorithm; all practical replacement policies are online.
:::

The study of online vs offline algorithms is a rich area of theoretical computer science. The *competitive ratio* of an online algorithm $A$ is:

$$c_A = \sup_{\omega} \frac{f_A(\omega, m)}{f_{\text{OPT}}(\omega, m)}$$

::: theorem
**Theorem 12.2a (Competitive Ratio of LRU and FIFO).** For a system with $m$ frames:

- LRU has competitive ratio $m$: $f_{\text{LRU}}(\omega, m) \leq m \cdot f_{\text{OPT}}(\omega, m)$.
- FIFO has competitive ratio $m$: $f_{\text{FIFO}}(\omega, m) \leq m \cdot f_{\text{OPT}}(\omega, m)$.
- No deterministic online algorithm can achieve a competitive ratio better than $m$.

*Proof sketch (lower bound).* Consider an adversary that always requests the page not currently in the online algorithm's cache. With $m$ frames and $m+1$ distinct pages, the online algorithm faults on every access. OPT, knowing the future, can evict the page that will be requested furthest in the future, faulting much less frequently. The ratio is $m$. $\square$
:::

This bound seems pessimistic, but it is tight in the worst case. In practice, locality of reference ensures that real workloads behave much better than the adversarial worst case.

---

## 12.3 FIFO (First-In, First-Out)

::: definition
**Definition 12.3 (FIFO Replacement).** *FIFO* evicts the page that has been in memory the longest --- the page that was loaded first. Pages are maintained in a queue; on a page fault, the page at the head of the queue is evicted, and the new page is added to the tail.
:::

::: example
**Example 12.3 (FIFO Execution).** Reference string: $\omega = 7, 0, 1, 2, 0, 3, 0, 4, 2, 3, 0, 3, 2, 1, 2, 0, 1, 7, 0, 1$. Frames: $m = 3$.

| Step | Ref | Frame 0 | Frame 1 | Frame 2 | Fault? | Evicted |
|------|-----|---------|---------|---------|--------|---------|
| 1 | 7 | 7 | -- | -- | Yes | -- |
| 2 | 0 | 7 | 0 | -- | Yes | -- |
| 3 | 1 | 7 | 0 | 1 | Yes | -- |
| 4 | 2 | 2 | 0 | 1 | Yes | 7 |
| 5 | 0 | 2 | 0 | 1 | No | -- |
| 6 | 3 | 2 | 3 | 1 | Yes | 0 |
| 7 | 0 | 2 | 3 | 0 | Yes | 1 |
| 8 | 4 | 4 | 3 | 0 | Yes | 2 |
| 9 | 2 | 4 | 2 | 0 | Yes | 3 |
| 10 | 3 | 4 | 2 | 3 | Yes | 0 |
| 11 | 0 | 0 | 2 | 3 | Yes | 4 |
| 12 | 3 | 0 | 2 | 3 | No | -- |
| 13 | 2 | 0 | 2 | 3 | No | -- |
| 14 | 1 | 0 | 1 | 3 | Yes | 2 |
| 15 | 2 | 0 | 1 | 2 | Yes | 3 |
| 16 | 0 | 0 | 1 | 2 | No | -- |
| 17 | 1 | 0 | 1 | 2 | No | -- |
| 18 | 7 | 7 | 1 | 2 | Yes | 0 |
| 19 | 0 | 7 | 0 | 2 | Yes | 1 |
| 20 | 1 | 7 | 0 | 1 | Yes | 2 |

Total page faults: 15. Compare to OPT's 9.
:::

FIFO is simple but performs poorly because it ignores access patterns. A page loaded long ago but still frequently accessed will be evicted, while a page loaded recently but never accessed again will be kept.

### 12.3.1 Analysis of FIFO

::: theorem
**Theorem 12.2b (FIFO Performance Bound).** For any reference string $\omega$ of length $n$ with $k$ distinct pages and $m$ frames ($m < k$):

$$f_{\text{FIFO}}(\omega, m) \leq n$$

(trivially), and

$$f_{\text{FIFO}}(\omega, m) \geq k$$

(at least one compulsory fault per distinct page). The tight lower bound is $k$ when the reference string is a permutation of the $k$ pages and $m \geq k$.
:::

FIFO's weakness is that it makes no distinction between "hot" and "cold" pages. Consider a process that loops over pages 1, 2, 3, 4, 5 with 4 frames. FIFO evicts the oldest page, which is exactly the page about to be re-referenced in the next iteration. This produces a fault on every fifth access.

::: example
**Example 12.3a (FIFO Worst Case).** Reference string: $\omega = 1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 1, 2, 3, 4, 5$ with $m = 4$ frames.

Since there are 5 distinct pages and only 4 frames, every time the process cycles through all 5 pages, it encounters a fault on the one that was evicted. FIFO evicts the oldest:

| Step | Ref | Queue | Fault? |
|------|-----|-------|--------|
| 1 | 1 | {1} | Yes |
| 2 | 2 | {1,2} | Yes |
| 3 | 3 | {1,2,3} | Yes |
| 4 | 4 | {1,2,3,4} | Yes |
| 5 | 5 | {2,3,4,5} evict 1 | Yes |
| 6 | 1 | {3,4,5,1} evict 2 | Yes |
| 7 | 2 | {4,5,1,2} evict 3 | Yes |
| 8 | 3 | {5,1,2,3} evict 4 | Yes |
| 9 | 4 | {1,2,3,4} evict 5 | Yes |
| 10 | 5 | {2,3,4,5} evict 1 | Yes |
| ... | ... | ... | ... |

Every single access is a fault. Fault rate: 100%. This is the worst possible behaviour --- identical to having no caching at all.

With LRU and the same reference string, the behaviour is identical (LRU also has 100% faults for a cyclic pattern larger than the cache). With OPT, faults = 5 (compulsory only, then every access hits because OPT evicts the page furthest from re-use, which is the page just used --- effectively keeping the next 4 in the cycle).
:::

---

## 12.4 Belady's Anomaly

### 12.4.1 The Counter-Example

::: definition
**Definition 12.4 (Belady's Anomaly).** *Belady's anomaly* is the phenomenon where increasing the number of available frames increases the number of page faults for a given reference string under a given replacement algorithm.
:::

::: example
**Example 12.4 (FIFO Anomaly).** Reference string: $\omega = 1, 2, 3, 4, 1, 2, 5, 1, 2, 3, 4, 5$.

**With 3 frames:**

| Step | Ref | F0 | F1 | F2 | Fault? |
|------|-----|----|----|----|--------|
| 1 | 1 | 1 | -- | -- | Yes |
| 2 | 2 | 1 | 2 | -- | Yes |
| 3 | 3 | 1 | 2 | 3 | Yes |
| 4 | 4 | 4 | 2 | 3 | Yes |
| 5 | 1 | 4 | 1 | 3 | Yes |
| 6 | 2 | 4 | 1 | 2 | Yes |
| 7 | 5 | 5 | 1 | 2 | Yes |
| 8 | 1 | 5 | 1 | 2 | No |
| 9 | 2 | 5 | 1 | 2 | No |
| 10 | 3 | 3 | 1 | 2 | Yes |
| 11 | 4 | 3 | 4 | 2 | Yes |
| 12 | 5 | 3 | 4 | 5 | Yes -- wait, let me redo this |

Let me trace this carefully.

| Step | Ref | Queue (oldest first) | Fault? |
|------|-----|---------------------|--------|
| 1 | 1 | {1} | Yes |
| 2 | 2 | {1, 2} | Yes |
| 3 | 3 | {1, 2, 3} | Yes |
| 4 | 4 | {4, 2, 3} evict 1 | Yes |
| 5 | 1 | {4, 1, 3} evict 2 | Yes |
| 6 | 2 | {4, 1, 2} evict 3 | Yes |
| 7 | 5 | {5, 1, 2} evict 4 | Yes |
| 8 | 1 | {5, 1, 2} | No |
| 9 | 2 | {5, 1, 2} | No |
| 10 | 3 | {5, 3, 2} evict 1 | Yes |
| 11 | 4 | {5, 3, 4} evict 2 | Yes |
| 12 | 5 | {5, 3, 4} | No |

Faults with 3 frames: **9**.

**With 4 frames:**

| Step | Ref | Queue (oldest first) | Fault? |
|------|-----|---------------------|--------|
| 1 | 1 | {1} | Yes |
| 2 | 2 | {1, 2} | Yes |
| 3 | 3 | {1, 2, 3} | Yes |
| 4 | 4 | {1, 2, 3, 4} | Yes |
| 5 | 1 | {1, 2, 3, 4} | No |
| 6 | 2 | {1, 2, 3, 4} | No |
| 7 | 5 | {2, 3, 4, 5} evict 1 | Yes |
| 8 | 1 | {3, 4, 5, 1} evict 2 | Yes |
| 9 | 2 | {4, 5, 1, 2} evict 3 | Yes |
| 10 | 3 | {5, 1, 2, 3} evict 4 | Yes |
| 11 | 4 | {1, 2, 3, 4} evict 5 | Yes |
| 12 | 5 | {2, 3, 4, 5} evict 1 | Yes |

Faults with 4 frames: **10**.

More frames (4) produced more faults (10) than fewer frames (3, which had 9). This is Belady's anomaly.
:::

### 12.4.2 Stack Algorithms and Immunity

::: definition
**Definition 12.5 (Stack Algorithm).** A page replacement algorithm is a *stack algorithm* if, for every reference string $\omega$ and every time $t$, the set of pages in memory with $m$ frames is a subset of the set of pages in memory with $m + 1$ frames:

$$S_t(m) \subseteq S_t(m+1)$$

This property is called the *inclusion property*.
:::

::: theorem
**Theorem 12.3 (Stack Algorithms are Anomaly-Free).** A stack algorithm cannot exhibit Belady's anomaly. That is, for any stack algorithm $A$ and any reference string $\omega$:

$$f_A(\omega, m+1) \leq f_A(\omega, m)$$

*Proof.* At any time $t$, a page fault occurs with $m$ frames if and only if $r_t \notin S_t(m)$. Since $S_t(m) \subseteq S_t(m+1)$ (the inclusion property), we have:

$$r_t \notin S_t(m+1) \implies r_t \notin S_t(m)$$

The contrapositive states: a page fault with $m+1$ frames implies a page fault with $m$ frames. Therefore, every fault with $m+1$ frames is also a fault with $m$ frames, so $f_A(\omega, m+1) \leq f_A(\omega, m)$. $\square$
:::

::: theorem
**Theorem 12.4 (OPT and LRU are Stack Algorithms).** Both OPT and LRU satisfy the inclusion property and are therefore immune to Belady's anomaly.

*Proof for LRU.* LRU maintains pages ordered by their most recent access time. With $m$ frames, LRU keeps the $m$ most recently used pages. With $m+1$ frames, LRU keeps the $m+1$ most recently used pages. Since the $m$ most recently used pages are a subset of the $m+1$ most recently used pages, $S_t(m) \subseteq S_t(m+1)$. $\square$

*Proof for OPT.* OPT can be characterised by a *priority stack* where pages are ordered by their next use time. With $m$ frames, OPT keeps the $m$ pages with the soonest next use. With $m+1$ frames, OPT keeps the $m+1$ pages with the soonest next use. The $m$-frame set is a subset of the $(m+1)$-frame set. $\square$
:::

::: theorem
**Theorem 12.5 (FIFO is Not a Stack Algorithm).** FIFO does not satisfy the inclusion property. The counter-example in Example 12.4 serves as proof.

*Proof.* At step 7 of the 3-frame trace, $S_7(3) = \{5, 1, 2\}$. At step 7 of the 4-frame trace, $S_7(4) = \{2, 3, 4, 5\}$. We have $1 \in S_7(3)$ but $1 \notin S_7(4)$, so $S_7(3) \not\subseteq S_7(4)$. $\square$
:::

---

## 12.5 LRU (Least Recently Used)

### 12.5.1 Definition

::: definition
**Definition 12.6 (LRU Replacement).** *LRU* evicts the page that has not been used for the longest time. It is based on the heuristic that pages used recently are likely to be used again soon (temporal locality), and pages not used recently are unlikely to be used soon.
:::

LRU is OPT's "mirror image": where OPT looks forward in time to find the page with the most distant next use, LRU looks backward in time to find the page with the most distant last use. Under the assumption that past behaviour predicts future behaviour (the locality principle), LRU is a good approximation of OPT.

::: example
**Example 12.5 (LRU Execution).** Reference string: $\omega = 7, 0, 1, 2, 0, 3, 0, 4, 2, 3, 0, 3, 2, 1, 2, 0, 1, 7, 0, 1$. Frames: $m = 3$.

| Step | Ref | Frames (most recent first) | Fault? | Evicted |
|------|-----|---------------------------|--------|---------|
| 1 | 7 | {7} | Yes | -- |
| 2 | 0 | {0, 7} | Yes | -- |
| 3 | 1 | {1, 0, 7} | Yes | -- |
| 4 | 2 | {2, 1, 0} | Yes | 7 (LRU) |
| 5 | 0 | {0, 2, 1} | No | -- |
| 6 | 3 | {3, 0, 2} | Yes | 1 (LRU) |
| 7 | 0 | {0, 3, 2} | No | -- |
| 8 | 4 | {4, 0, 3} | Yes | 2 (LRU) |
| 9 | 2 | {2, 4, 0} | Yes | 3 (LRU) |
| 10 | 3 | {3, 2, 4} | Yes | 0 (LRU) |
| 11 | 0 | {0, 3, 2} | Yes | 4 (LRU) |
| 12 | 3 | {3, 0, 2} | No | -- |
| 13 | 2 | {2, 3, 0} | No | -- |
| 14 | 1 | {1, 2, 3} | Yes | 0 (LRU) |
| 15 | 2 | {2, 1, 3} | No | -- |
| 16 | 0 | {0, 2, 1} | Yes | 3 (LRU) |
| 17 | 1 | {1, 0, 2} | No | -- |
| 18 | 7 | {7, 1, 0} | Yes | 2 (LRU) |
| 19 | 0 | {0, 7, 1} | No | -- |
| 20 | 1 | {1, 0, 7} | No | -- |

Total page faults: 12. Better than FIFO (15), worse than OPT (9).
:::

### 12.5.2 Implementation Challenges

Exact LRU requires maintaining a total ordering of pages by their last access time. Two common hardware implementations:

**Counter-based:** Each PTE has a counter field. On every memory access, a system-wide clock increments, and the accessed page's counter is set to the current clock value. On a page fault, the OS scans all frames to find the one with the smallest counter (the least recently accessed). Cost: $O(m)$ per page fault for the scan. The counter must be wide enough to avoid wraparound during the process's lifetime; a 64-bit counter suffices.

::: example
**Example 12.5a (Counter-Based LRU).** A system with 4 frames. The system clock starts at 0 and increments on every memory access.

| Access | Page | Clock | Frame 0 (cnt) | Frame 1 (cnt) | Frame 2 (cnt) | Frame 3 (cnt) |
|--------|------|-------|---------------|---------------|---------------|---------------|
| 1 | A | 1 | A (1) | -- | -- | -- |
| 2 | B | 2 | A (1) | B (2) | -- | -- |
| 3 | C | 3 | A (1) | B (2) | C (3) | -- |
| 4 | D | 4 | A (1) | B (2) | C (3) | D (4) |
| 5 | A | 5 | A (5) | B (2) | C (3) | D (4) |
| 6 | E | 6 | A (5) | E (6) | C (3) | D (4) |

At access 6, page E causes a fault. The LRU page is B (counter=2, the smallest). B is evicted and replaced by E.
:::

**Stack-based:** A doubly-linked list (stack) of page numbers. On every reference, the accessed page is moved to the top. On a page fault, the bottom of the stack is the LRU page. Cost: $O(1)$ per page fault, but moving the accessed page to the top on every memory access requires maintaining the linked list on *every* memory access --- this means updating 4--6 pointers billions of times per second. Without specialised hardware, the overhead is prohibitive.

**Why exact LRU is impractical for operating systems:** Modern systems have millions of physical frames. Scanning all frames to find the minimum counter takes milliseconds. Maintaining a linked list on every memory access (which happens every few nanoseconds) is impossible in software. Even hardware assistance would add significant area and power cost. This motivates the LRU approximations in Section 12.6, which use only the single *accessed bit* maintained by standard MMU hardware.

### 12.5.3 LRU and the Stack Distance

::: definition
**Definition 12.6a (Stack Distance).** For a reference to page $p$ at time $t$, the *stack distance* is the number of distinct pages accessed since $p$ was last referenced. If $p$ has not been previously referenced, the stack distance is $\infty$.
:::

Stack distance is a powerful tool for analysing LRU: a reference with stack distance $d$ is a hit if $d \leq m$ (the page is within the $m$ most recently used pages) and a miss if $d > m$. The stack distance distribution of a workload completely characterises its behaviour under LRU for all frame counts simultaneously.

::: theorem
**Theorem 12.5a (LRU Miss Rate from Stack Distance).** Let $D$ be the random variable representing the stack distance of a reference. Then the LRU miss rate for $m$ frames is:

$$p_{\text{miss}}(m) = P(D > m)$$

This means the miss rate is the tail probability of the stack distance distribution.
:::

::: example
**Example 12.5b (Stack Distance).** Reference string: A, B, C, A, B, D, A, B, C.

| Time | Ref | Stack (most recent first) | Stack Distance |
|------|-----|--------------------------|----------------|
| 1 | A | A | $\infty$ |
| 2 | B | B, A | $\infty$ |
| 3 | C | C, B, A | $\infty$ |
| 4 | A | A, C, B | 3 |
| 5 | B | B, A, C | 3 |
| 6 | D | D, B, A, C | $\infty$ |
| 7 | A | A, D, B, C | 2 |
| 8 | B | B, A, D, C | 3 |
| 9 | C | C, B, A, D | 4 |

With $m = 3$ frames: misses occur when stack distance $> 3$ or $\infty$. Misses at times 1, 2, 3, 6, 9 = 5 faults. Hits at times 4 (d=3 $\leq$ 3), 5 (d=3), 7 (d=2), 8 (d=3) = 4 hits.

With $m = 4$ frames: the additional miss at time 9 (d=4 $\leq$ 4) becomes a hit. Faults = 4.
:::

The stack distance distribution also confirms the inclusion property: since a hit with $m$ frames (stack distance $\leq m$) is certainly a hit with $m+1$ frames (stack distance $\leq m + 1$), adding frames can only reduce faults.

---

## 12.6 LRU Approximations

### 12.6.1 The Clock Algorithm (Second-Chance)

::: definition
**Definition 12.7 (Clock Algorithm / Second-Chance).** The *clock algorithm* uses the hardware-maintained *accessed bit* (A bit) in each PTE to approximate LRU. Frames are arranged in a circular buffer with a "clock hand" pointer.

On a page fault:
1. Examine the frame at the clock hand.
2. If its A bit is 0, evict this page (it has not been accessed since the last sweep).
3. If its A bit is 1, clear it to 0 (give the page a "second chance") and advance the clock hand.
4. Repeat until a victim with A = 0 is found.
:::

```text
        Clock hand
            |
            v
    +---+---+---+---+---+---+---+---+
    | 1 | 0 | 1 | 1 | 0 | 1 | 0 | 1 |  <-- A bits
    +---+---+---+---+---+---+---+---+
      0   1   2   3   4   5   6   7     <-- Frame numbers

Step 1: Frame 0, A=1 -> clear to 0, advance
Step 2: Frame 1, A=0 -> EVICT frame 1
```

The clock algorithm is O(m) in the worst case per page fault (if all A bits are 1, the hand must sweep the entire buffer). However, with frequent accesses resetting A bits, the amortised cost is much lower.

::: theorem
**Theorem 12.6 (Clock as LRU Approximation).** The clock algorithm partitions pages into two classes: recently accessed (A = 1) and not recently accessed (A = 0). It always evicts a page from the latter class. This provides an approximation of LRU where the "recently used" threshold is determined by the sweep rate of the clock hand. Under high memory pressure (frequent page faults), the hand sweeps quickly, providing finer-grained approximation. Under low memory pressure, the hand moves slowly, and the approximation is coarse.
:::

### 12.6.2 Enhanced Second-Chance (NRU)

::: definition
**Definition 12.8 (Enhanced Second-Chance / NRU).** The *enhanced second-chance* algorithm uses both the accessed bit (A) and the dirty bit (D) to classify pages into four categories, evicting pages from the lowest category first:

| Class | (A, D) | Description |
|-------|--------|-------------|
| 0 | (0, 0) | Not accessed, not dirty (best victim) |
| 1 | (0, 1) | Not accessed, dirty |
| 2 | (1, 0) | Accessed, not dirty |
| 3 | (1, 1) | Accessed, dirty (worst victim) |
:::

The algorithm sweeps the circular buffer looking for a Class 0 page. If none is found, it looks for Class 1, then Class 2, then Class 3. Each sweep clears the A bits, so on the second pass, Class 2 and 3 pages become Class 0 and 1.

The rationale for preferring clean pages over dirty ones: evicting a clean page is free (no disk write needed), while evicting a dirty page requires writing it to the backing store first. The I/O cost difference is significant: evicting a clean page takes ~0 ns of I/O; evicting a dirty page requires a 4 KB write to disk, costing ~50 $\mu$s on SSD or ~8 ms on HDD.

::: example
**Example 12.6a (Enhanced Clock Trace).** 8 frames with initial state:

| Frame | Page | A | D | Class |
|-------|------|---|---|-------|
| 0 | P | 1 | 0 | 2 |
| 1 | Q | 0 | 1 | 1 |
| 2 | R | 1 | 1 | 3 |
| 3 | S | 0 | 0 | 0 |
| 4 | T | 1 | 0 | 2 |
| 5 | U | 0 | 0 | 0 |
| 6 | V | 1 | 1 | 3 |
| 7 | W | 0 | 1 | 1 |

Clock hand at frame 0. Page fault for page X.

Sweep for Class 0: start at frame 0 (Class 2, skip), frame 1 (Class 1, skip), frame 2 (Class 3, skip), frame 3 (Class 0, found).

Evict page S from frame 3. Load page X into frame 3. Set A=1, D=0. Advance clock hand to frame 4.

Note that frame 3 was chosen over frame 5 (also Class 0) because the clock hand encountered frame 3 first. The algorithm does not search for the "best" Class 0 page; it takes the first one encountered.
:::

### 12.6.3 Linux's Two-List LRU

Linux does not use a simple clock algorithm. Instead, it maintains two LRU lists per memory zone:

::: definition
**Definition 12.8a (Linux Active/Inactive Lists).** Linux's page reclaim uses two linked lists:

- **Active list:** Pages that have been recently accessed. Pages on this list are considered "hot" and are not candidates for eviction.
- **Inactive list:** Pages that have not been recently accessed. Pages on this list are candidates for eviction.

Pages are promoted from the inactive list to the active list when accessed (and their accessed bit is set). Pages are demoted from the active list to the inactive list when the active list becomes too large relative to the inactive list.
:::

The lists are further divided by page type:

- **Anonymous pages** (heap, stack): tracked on `anon_active` and `anon_inactive` lists.
- **File-backed pages** (page cache): tracked on `file_active` and `file_inactive` lists.

This distinction allows the kernel to independently tune the eviction policy for anonymous and file-backed pages. The `vm.swappiness` parameter controls the relative weight: higher values evict more anonymous pages (writing them to swap), lower values evict more file-backed pages (which can be re-read from the file system).

### 12.6.4 Multi-Generation LRU (MGLRU)

::: definition
**Definition 12.8b (MGLRU).** *Multi-Generation LRU* is a page reclaim algorithm introduced in Linux 6.1 that replaces the two-list (active/inactive) approach with multiple generations. Each page is assigned a generation number. Newer generations contain more recently accessed pages. The kernel scans pages by generation, evicting from the oldest generation first.
:::

MGLRU provides finer-grained age tracking than the two-list approach. Instead of a binary "active/inactive" classification, pages pass through 4 generations, giving 4 levels of recency. This reduces both false positives (evicting a page that should be kept) and false negatives (keeping a page that should be evicted).

MGLRU is particularly effective for workloads with large working sets and gradual access pattern shifts, such as databases and virtual machines.

---

## 12.7 Counting-Based Algorithms

### 12.7.1 LFU (Least Frequently Used)

::: definition
**Definition 12.9 (LFU).** *LFU* evicts the page with the lowest access count. Each page has a counter that is incremented on every access.
:::

LFU has a problem: a page that was heavily used in the past but is no longer needed retains a high count and is never evicted. Solutions include periodically halving all counters (ageing) or using a decaying average.

### 12.7.2 MFU (Most Frequently Used)

::: definition
**Definition 12.10 (MFU).** *MFU* evicts the page with the highest access count, on the theory that a page with many accesses has been in memory a long time and the page with the fewest accesses was just brought in and will be needed again soon.
:::

MFU is counterintuitive and rarely performs well in practice. It is included for completeness.

> **Note:** Neither LFU nor MFU is commonly used in operating system kernels. LRU approximations (clock algorithm, enhanced second-chance) dominate because they are simple, efficient, and provide adequate performance for the vast majority of workloads.

---

## 12.8 Frame Allocation

Before discussing page replacement policies, we must address a prerequisite question: how many frames does each process receive?

### 12.8.1 Minimum Number of Frames

Each process needs a minimum number of frames determined by the instruction set architecture. An instruction that can reference multiple memory operands (e.g., a memory-to-memory move with indirect addressing) may touch several pages during a single instruction execution. If the process has fewer frames than the instruction requires, the instruction cannot complete (it would page fault, evict a page needed by the same instruction, and fault again in an infinite loop).

::: definition
**Definition 12.11 (Minimum Frame Count).** The minimum number of frames $m_{\min}$ for a process is determined by the maximum number of pages that can be referenced during the execution of a single instruction. For x86-64, this includes the instruction page(s), data operand page(s), and potentially a page table page, giving $m_{\min} \approx 6$--8 depending on the instruction.
:::

### 12.8.2 Equal Allocation

::: definition
**Definition 12.12 (Equal Allocation).** With $n$ processes and $M$ total frames, each process receives $\lfloor M / n \rfloor$ frames. The remaining $M \bmod n$ frames are kept in a free pool.
:::

Equal allocation is simple but unfair: a 10 MB process gets the same number of frames as a 10 GB process.

### 12.8.3 Proportional Allocation

::: definition
**Definition 12.13 (Proportional Allocation).** Each process receives frames in proportion to its size. If process $i$ has virtual memory size $s_i$, it receives:

$$a_i = \left\lfloor \frac{s_i}{\sum_{j=1}^{n} s_j} \times M \right\rfloor$$

frames, where $M$ is the total number of available frames.
:::

::: example
**Example 12.6 (Proportional Allocation).** Total frames: $M = 256$. Two processes: P1 has $s_1 = 10$ MB, P2 has $s_2 = 126$ MB. Total: 136 MB.

$$a_1 = \left\lfloor \frac{10}{136} \times 256 \right\rfloor = \left\lfloor 18.8 \right\rfloor = 18$$
$$a_2 = \left\lfloor \frac{126}{136} \times 256 \right\rfloor = \left\lfloor 237.2 \right\rfloor = 237$$

Remaining frames: $256 - 18 - 237 = 1$ (kept in free pool).
:::

Proportional allocation can also factor in process priority: higher-priority processes receive proportionally more frames.

### 12.8.4 Global vs Local Replacement

::: definition
**Definition 12.14 (Global Replacement).** Under *global replacement*, when a process faults, the replacement algorithm can select a victim frame from any process in the system (including the faulting process itself).
:::

::: definition
**Definition 12.15 (Local Replacement).** Under *local replacement*, when a process faults, the replacement algorithm selects a victim frame only from the faulting process's own set of frames.
:::

Global replacement allows a high-priority or memory-hungry process to steal frames from other processes, potentially causing those processes to fault more. Local replacement isolates processes from each other but may lead to inefficiency: a process with idle frames cannot donate them to a process that needs them.

::: example
**Example 12.6b (Global vs Local).** A system has 100 frames and 3 processes with working set sizes: P1 = 20, P2 = 50, P3 = 40. Total demand: 110 frames (exceeds capacity).

Under equal allocation (33 frames each):
- P1 has 33 frames for a 20-frame working set: no thrashing, 13 idle frames wasted.
- P2 has 33 frames for a 50-frame working set: thrashing, 17 frames short.
- P3 has 33 frames for a 40-frame working set: moderate thrashing, 7 frames short.

Under proportional allocation:
- P1: $\lfloor 20/110 \times 100 \rfloor = 18$ frames (ok, working set = 20, slight deficit).
- P2: $\lfloor 50/110 \times 100 \rfloor = 45$ frames (deficit of 5).
- P3: $\lfloor 40/110 \times 100 \rfloor = 36$ frames (deficit of 4).

Better balanced, but all three processes have some deficit.

Under global replacement, P1 might "donate" its excess frames to P2 and P3 dynamically, but P1's fault rate could unpredictably increase if P2 or P3 aggressively steal its frames.
:::

::: example
**Example 12.6c (Priority-Based Proportional Allocation).** Same system, but P1 has priority 3, P2 has priority 1, P3 has priority 2. We weight by priority:

$$a_i = \left\lfloor \frac{s_i \times \text{priority}_i}{\sum_j s_j \times \text{priority}_j} \times M \right\rfloor$$

Weighted sizes: P1 = $20 \times 3 = 60$, P2 = $50 \times 1 = 50$, P3 = $40 \times 2 = 80$. Total: 190.

- P1: $\lfloor 60/190 \times 100 \rfloor = 31$
- P2: $\lfloor 50/190 \times 100 \rfloor = 26$
- P3: $\lfloor 80/190 \times 100 \rfloor = 42$

High-priority P1 gets more than its working set (31 > 20), providing headroom. Low-priority P2 gets only 26 frames for a 50-frame working set and will thrash.
:::

::: theorem
**Theorem 12.7 (Global vs Local Trade-off).** Global replacement generally achieves higher system throughput than local replacement because it allows frames to flow to the processes that need them most. However, global replacement makes individual process performance less predictable and can lead to cascading faults if one process consumes too many frames.
:::

> **Programmer:** Linux uses a hybrid approach. The kernel maintains a global pool of free pages and per-cgroup memory limits. The `kswapd` daemon reclaims pages globally, using a modified clock algorithm (two-list LRU: active and inactive lists). When a cgroup (process group) exceeds its memory limit, only that cgroup's pages are scanned for eviction, providing local replacement semantics within the global system. The `memory.max` cgroup v2 setting controls this limit. In practice, most containerised workloads (Podman, Kubernetes) set memory limits to prevent any single container from starving others.

---

## 12.9 Working Set Model

### 12.9.1 Locality and the Working Set

::: definition
**Definition 12.16 (Working Set).** The *working set* of a process at time $t$ with window size $\Delta$ is the set of pages referenced in the most recent $\Delta$ memory accesses:

$$W(t, \Delta) = \{p : p \text{ was referenced in the interval } (t - \Delta, t]\}$$

The *working set size* is $|W(t, \Delta)|$.
:::

The working set captures the process's current locality: the pages it is actively using. As the process moves through different phases of execution (e.g., initialisation, main loop, cleanup), its working set changes.

::: example
**Example 12.7 (Working Set).** Reference string: $\ldots 2, 6, 1, 5, 7, 7, 7, 7, 5, 1, \ldots$ with $\Delta = 4$.

At time $t = 10$ (after the reference to 1), the last 4 references are $7, 7, 5, 1$. So $W(10, 4) = \{7, 5, 1\}$ and $|W(10, 4)| = 3$.

At time $t = 5$ (after the reference to 7), the last 4 references are $1, 5, 7, 7$. So $W(5, 4) = \{1, 5, 7\}$ and $|W(5, 4)| = 3$.

At time $t = 3$ (after the reference to 1), the last 4 references are $\ldots, 2, 6, 1$. So $W(3, 4) = \{2, 6, 1\}$ and $|W(3, 4)| = 3$.
:::

### 12.9.2 The Working Set Model

::: theorem
**Theorem 12.8 (Working Set Principle, Denning 1968).** If each process is allocated frames equal to its working set size $|W(t, \Delta)|$, then:

1. The page fault rate is low (most faults are compulsory faults for pages entering the working set for the first time).
2. The total number of frames in use across all processes is $D = \sum_i |W_i(t, \Delta)|$ (the *total demand*).
3. If $D > M$ (total demand exceeds available frames), at least one process must be suspended (swapped out) to prevent thrashing.
:::

The working set model provides a principled approach to multiprogramming control: the OS should admit a new process only if there are enough free frames to hold its working set.

### 12.9.3 Choosing $\Delta$

The window size $\Delta$ is critical:

- **Too small:** The working set underestimates the process's needs, leading to excessive page faults.
- **Too large:** The working set overestimates, wasting frames on pages no longer needed.

In practice, $\Delta$ is chosen empirically, often in the range of 10,000 to 100,000 memory references.

### 12.9.4 Implementing the Working Set Model

Exact implementation of the working set model is expensive: maintaining the set of pages accessed in the last $\Delta$ references requires recording every memory access. Practical approximations use a timer interrupt:

1. Every $T$ milliseconds, the OS interrupts each process and examines its page table entries.
2. For each page with the accessed bit set, the page is in the working set. Clear the accessed bit.
3. For each page with the accessed bit clear, increment a "not accessed" counter. If the counter exceeds a threshold (corresponding to $\Delta / T$ intervals), the page is not in the working set and can be reclaimed.

::: example
**Example 12.7a (Working Set Approximation).** Timer interval $T = 10$ ms. Threshold: 5 intervals (50 ms $\approx \Delta$). A page P's history:

| Interval | Accessed? | Counter | In Working Set? |
|----------|-----------|---------|----------------|
| 0 | Yes | 0 (reset) | Yes |
| 1 | Yes | 0 | Yes |
| 2 | No | 1 | Yes |
| 3 | No | 2 | Yes |
| 4 | No | 3 | Yes |
| 5 | No | 4 | Yes |
| 6 | No | 5 | No (evict candidate) |
| 7 | Yes | 0 (reset) | Yes |

Page P drops out of the working set after 5 consecutive intervals without access (50 ms).
:::

### 12.9.5 Locality and Phase Behaviour

::: definition
**Definition 12.16a (Locality).** A process exhibits *temporal locality* if it tends to reference the same pages repeatedly in short time intervals. It exhibits *spatial locality* if it tends to reference pages near recently accessed pages. Most real programs exhibit both forms of locality.
:::

Processes typically execute in *phases*: an initialisation phase (touching many pages), a main processing phase (working within a smaller set), and a cleanup phase. The working set changes at phase transitions, causing a burst of page faults. Between transitions, the working set is stable and the fault rate is low.

::: example
**Example 12.7b (Phase Behaviour).** A matrix multiplication program with three phases:

1. **Initialisation (t = 0--100):** Allocate and fill matrices A, B, C. Working set: ~1500 pages (all three matrices). Page faults: ~1500 (cold start).

2. **Computation (t = 100--10000):** Multiply $C = A \times B$ using a blocked algorithm with 64 KB blocks. Working set: ~50 pages (one block from each matrix plus temporaries). Page faults: rare (only at block boundaries).

3. **Output (t = 10000--10100):** Write result matrix C to disk. Working set: ~500 pages (matrix C, scanned sequentially). Page faults: moderate (sequential access, mitigated by readahead).

The working set size changes dramatically between phases, from 1500 to 50 to 500 pages.
:::

---

## 12.10 Thrashing

### 12.10.1 Definition and Cause

::: definition
**Definition 12.17 (Thrashing).** *Thrashing* is the condition where a process (or the entire system) spends more time servicing page faults than executing useful instructions. It occurs when the total working set demand of all active processes exceeds the available physical memory.
:::

The feedback loop that causes thrashing:

1. The OS increases the degree of multiprogramming (admits more processes).
2. Total working set demand exceeds physical memory.
3. Page fault rates rise dramatically for all processes.
4. Processes spend most of their time waiting for page I/O.
5. CPU utilisation drops (because all processes are waiting for I/O).
6. The OS scheduler, observing low CPU utilisation, admits more processes to "improve" utilisation.
7. This further increases memory pressure, causing more faults. Goto step 3.

```text
          CPU
        Utilisation
           ^
           |          ___
           |        /     \
           |      /         \
           |    /             \
           |  /                 \  <-- Thrashing begins
           | /                    \
           |/                       \___________
           +-------------------------------------------->
                 Degree of Multiprogramming
```

### 12.10.2 Detecting Thrashing

The OS can detect thrashing by monitoring:

- **Page fault rate:** If the system-wide page fault rate exceeds a threshold, the system may be thrashing.
- **Page fault frequency (PFF):** If a specific process's fault rate exceeds an upper threshold, it needs more frames. If it falls below a lower threshold, frames can be reclaimed.
- **CPU utilisation vs multiprogramming:** If CPU utilisation drops as the degree of multiprogramming increases, thrashing is likely.

### 12.10.3 Preventing Thrashing

::: definition
**Definition 12.18 (Page Fault Frequency Control).** *PFF control* monitors each process's page fault rate:

- If the fault rate exceeds an upper threshold $\tau_{\text{upper}}$, the process is allocated additional frames.
- If the fault rate falls below a lower threshold $\tau_{\text{lower}}$, frames are reclaimed from the process.
- If no frames are available to satisfy a process exceeding $\tau_{\text{upper}}$, a process is suspended (swapped out).
:::

::: theorem
**Theorem 12.9 (Thrashing Prevention).** Thrashing is prevented if and only if the sum of all processes' working set sizes does not exceed the available physical memory:

$$\sum_{i=1}^{n} |W_i(t, \Delta)| \leq M$$

If this condition is violated, the system must reduce the degree of multiprogramming by suspending one or more processes (moving their pages to swap and freeing their frames for the remaining processes).

*Proof.* The "if" direction: when the condition holds, each process can have its working set resident in memory, so page faults are limited to compulsory faults (accessing a page for the first time or after a working set transition). Compulsory faults are infrequent relative to the total access count. The "only if" direction: when the condition is violated, at least one process cannot fit its working set. By Denning's working set theorem, this process will fault on every access to a page outside its allocated frames. If the deficit is large, the fault rate approaches the access rate, which is thrashing by definition. $\square$
:::

::: example
**Example 12.8 (Thrashing Scenario).** A system has $M = 1000$ frames. Five processes have working set sizes: 200, 300, 250, 150, 200 frames. Total demand: 1100 frames $> 1000$.

The OS must suspend one process. Suspending the process with working set 300 reduces demand to 800, leaving 200 free frames as a buffer. Now all four remaining processes can operate within their working sets without thrashing.
:::

::: programmer
**Programmer's Perspective: Linux's Page Reclaim and the OOM Killer.**

Linux's approach to page replacement and thrashing prevention involves several subsystems:

**kswapd:** The kernel swap daemon runs as a kernel thread on each NUMA node. It wakes up when the number of free pages drops below a watermark and reclaims pages by scanning the inactive LRU list. Pages are promoted from the inactive list to the active list when accessed; pages that remain on the inactive list without being accessed are reclaimed. The scanning rate increases under memory pressure.

**vm.swappiness:** This sysctl parameter (0--200, default 60) controls how aggressively the kernel swaps out anonymous pages (heap, stack) relative to file-backed pages (page cache). A value of 0 tells the kernel to avoid swapping anonymous pages as long as possible; 200 maximises anonymous page reclaim. Database servers often set `vm.swappiness = 1` to minimise swap usage.

```c
/* Check current swappiness */
/* sysctl vm.swappiness */

/* Set temporarily */
/* sysctl -w vm.swappiness=10 */

/* Set permanently in /etc/sysctl.conf */
/* vm.swappiness = 10 */
```

**OOM Killer:** When the kernel cannot free enough memory through normal reclaim (and the system is effectively thrashing or out of memory), the Out-Of-Memory killer selects a process to terminate. The victim is chosen by a heuristic score (`/proc/PID/oom_score`) that considers process memory usage, CPU time, and other factors. The `oom_score_adj` value ($-1000$ to $+1000$) allows administrators to bias the selection. Critical processes (databases, application servers) should have a low `oom_score_adj` to avoid being killed.

```c
/* Protect a critical process from OOM killer */
/* echo -1000 > /proc/PID/oom_score_adj */
```

In Go, the runtime interacts with these mechanisms through `madvise` calls. When the garbage collector frees pages, it calls `madvise(MADV_DONTNEED)` (or `MADV_FREE` on newer kernels) to tell the kernel that the pages can be reclaimed without swap. This makes Go processes "good citizens" under memory pressure: their freed-but-not-returned pages are quickly reclaimable by kswapd without the cost of swapping them to disk.

You can monitor page reclaim activity on Linux using several tools:

```c
/* Monitor page faults for a specific process */
/* perf stat -e page-faults,major-faults,minor-faults ./my_program */

/* Watch kswapd activity in real time */
/* vmstat 1 */
/* Columns: si = swap in (KB/s), so = swap out (KB/s) */

/* Detailed memory pressure info */
/* cat /proc/pressure/memory */
/* Output: some avg10=0.50 avg60=1.20 avg300=0.80 total=12345678 */
```

The Pressure Stall Information (PSI) subsystem (Linux 4.20+) provides a quantitative measure of memory pressure. The `avg10` value indicates the percentage of time in the last 10 seconds that at least some tasks were stalled waiting for memory. Values above 10% indicate significant memory pressure; values above 40% indicate the system is likely thrashing.

In Go, you can detect memory pressure through `runtime.ReadMemStats`: a rapidly increasing `NumGC` with `PauseTotalNs` growing suggests the garbage collector is running frequently to free memory. The `GOMEMLIMIT` environment variable (Go 1.19+) sets a soft memory target, causing the GC to run more aggressively when the heap approaches the limit, which can help avoid triggering the OOM killer.

```go
package main

import (
    "fmt"
    "runtime"
    "runtime/debug"
    "time"
)

func main() {
    // Set a 500 MB memory limit
    debug.SetMemoryLimit(500 * 1024 * 1024)

    var m runtime.MemStats

    // Monitor memory usage
    for i := 0; i < 10; i++ {
        runtime.ReadMemStats(&m)
        fmt.Printf("HeapAlloc: %d MB, NumGC: %d, "+
            "GCCPUFraction: %.4f\n",
            m.HeapAlloc/1024/1024,
            m.NumGC,
            m.GCCPUFraction)
        time.Sleep(time.Second)
    }
}
```
:::

---

## 12.10a Quantifying Thrashing

### 12.10a.1 Page Fault Rate Model

::: theorem
**Theorem 12.9a (Fault Rate vs Frame Allocation).** For a process with a working set of size $w$ allocated $m$ frames ($m < w$), the page fault rate under LRU with random access to the working set is approximately:

$$p \approx \frac{w - m}{w}$$

When $m = w$, the fault rate drops to approximately 0 (only compulsory faults). When $m = 1$, the fault rate is $(w-1)/w \approx 1$ (every access faults).

For processes exhibiting temporal locality, the actual fault rate is lower because frequently accessed pages are more likely to be in memory. The Least Recently Used stack distance distribution captures this effect precisely.
:::

### 12.10a.2 The Lifetime Curve

::: definition
**Definition 12.18a (Lifetime Curve).** The *lifetime curve* of a process plots the mean time between page faults (the "lifetime") as a function of the number of allocated frames $m$. As $m$ increases, the lifetime increases. The curve typically has a "knee" at $m \approx |W|$ (the working set size), where the lifetime increases sharply.
:::

```text
Lifetime
(time between
 faults)
    ^
    |                          ___________
    |                         /
    |                        /
    |                       /
    |                      /
    |                 ____/  <-- Knee at m = |W|
    |          ______/
    |    _____/
    |___/
    +------------------------------------------>
                  Frames allocated (m)
```

The knee of the lifetime curve is the optimal operating point: allocating more frames beyond the knee yields diminishing returns. The working set model aims to keep each process at or near the knee.

---

## 12.10b Practical Thrashing Prevention on Linux

Linux uses several mechanisms to prevent and mitigate thrashing:

### 12.10b.1 Watermarks

The kernel maintains three watermarks for each memory zone:

- **High watermark ($W_{\text{high}}$):** When free memory is above this level, no reclaim activity occurs.
- **Low watermark ($W_{\text{low}}$):** When free memory drops below this level, `kswapd` wakes up and begins background reclaim.
- **Minimum watermark ($W_{\text{min}}$):** When free memory drops below this level, direct reclaim occurs synchronously (the allocating process itself must free pages before its allocation can proceed).

::: example
**Example 12.8a (Watermark Configuration).** A system with 16 GB of RAM, default watermarks:

```text
$ cat /proc/zoneinfo | grep -A 5 "Normal"
Node 0, zone   Normal
  pages free     1234567
        min      16384
        low      20480
        high     24576
```

$W_{\text{min}} = 16384 \times 4 \text{ KB} = 64$ MB
$W_{\text{low}} = 20480 \times 4 \text{ KB} = 80$ MB
$W_{\text{high}} = 24576 \times 4 \text{ KB} = 96$ MB

When free memory drops below 80 MB, kswapd starts reclaiming. Below 64 MB, allocations are stalled until reclaim completes.
:::

### 12.10b.2 Memory Cgroups

::: definition
**Definition 12.18b (Memory Cgroup).** A *memory cgroup* (control group) limits the memory usage of a group of processes. When the cgroup exceeds its limit, only pages belonging to that cgroup are reclaimed. This provides per-group local replacement, preventing one group from causing thrashing in another.
:::

::: example
**Example 12.8b (Cgroup Memory Limit).** Setting a 512 MB memory limit for a container:

```text
# Cgroup v2
echo 536870912 > /sys/fs/cgroup/mycontainer/memory.max
echo 268435456 > /sys/fs/cgroup/mycontainer/memory.high

# memory.max: hard limit (OOM kill if exceeded)
# memory.high: soft limit (throttling and aggressive reclaim)
```

When the container uses more than 256 MB (memory.high), the kernel aggressively reclaims its pages. If it exceeds 512 MB (memory.max), the OOM killer terminates a process within the container.
:::

### 12.10b.3 Swap Limits

Linux allows disabling swap entirely or limiting its use per-cgroup:

```text
# Disable swap for a cgroup
echo 0 > /sys/fs/cgroup/mycontainer/memory.swap.max

# System-wide: set swappiness to 0 (avoid anonymous page swap)
sysctl vm.swappiness=0
```

For latency-sensitive applications (databases, game servers), disabling swap ensures that memory access times are predictable (never incurring a swap-in delay).

---

## 12.11 Comparative Summary of Algorithms

| Algorithm | Faults (typical) | Anomaly? | Complexity | Practical? |
|-----------|-----------------|----------|------------|------------|
| OPT | Minimum | No | $O(n \cdot m)$ | No (needs future) |
| LRU | Good | No | $O(m)$ per fault | Expensive (exact) |
| FIFO | Poor | Yes | $O(1)$ | Yes (but poor) |
| Clock | Good | No | Amortised $O(1)$ | Yes (standard) |
| Enhanced Clock | Good | No | Amortised $O(1)$ | Yes (standard) |
| LFU | Variable | Yes | $O(\log m)$ | Rarely used |
| MFU | Poor | Yes | $O(\log m)$ | No |

> **Note:** The "standard" practical algorithms used in real operating systems are the clock algorithm and its enhanced variant. Linux uses a two-list LRU approximation (active/inactive lists) that is conceptually similar to the clock algorithm but with additional refinements for file-backed vs anonymous pages, multi-generation ageing (MGLRU in newer kernels), and NUMA-awareness.

---

## 12.12 Summary

This chapter addressed the central question of demand paging: when physical memory is full, which page should be evicted?

- **OPT** evicts the page with the most distant future reference, achieving the minimum fault count. It is provably optimal but requires future knowledge.
- **FIFO** evicts the oldest page. It is simple but performs poorly and is susceptible to Belady's anomaly.
- **LRU** evicts the least recently used page, approximating OPT by using past behaviour to predict future behaviour. It is a stack algorithm (immune to Belady's anomaly) but expensive to implement exactly.
- **Clock algorithm** (second-chance) uses the accessed bit to approximate LRU efficiently, making it the dominant practical algorithm.
- **Frame allocation** (equal, proportional, global, local) determines how many frames each process receives.
- **Working set model** and **PFF** control prevent thrashing by ensuring each process has enough frames for its current locality.
- **Thrashing** is a catastrophic feedback loop where the system spends all its time servicing page faults. Prevention requires monitoring working set sizes and reducing multiprogramming when demand exceeds supply.

Chapter 13 extends these foundations with advanced topics: copy-on-write mechanics, memory-mapped file I/O, kernel memory allocators (slab, SLUB, buddy system), NUMA-aware allocation, huge pages, memory compression, and address space randomisation.

---

::: exercises
**Exercise 12.1.** Given the reference string $\omega = 1, 2, 3, 4, 2, 1, 5, 6, 2, 1, 2, 3, 7, 6, 3, 2, 1, 2, 3, 6$ and $m = 4$ frames, compute the number of page faults for (a) FIFO, (b) LRU, and (c) OPT. Show the state of the frames after each reference.

**Exercise 12.2.** Construct a reference string and frame count that demonstrates Belady's anomaly for FIFO --- specifically, show that FIFO with $m = 4$ frames produces more faults than with $m = 3$ frames. Verify that LRU does not exhibit the anomaly for your reference string.

**Exercise 12.3.** Prove that LRU is a stack algorithm by formally establishing the inclusion property $S_t(m) \subseteq S_t(m+1)$ for all $t$. Use induction on $t$, considering the cases where the reference at time $t$ is a hit or a miss in both the $m$-frame and $(m+1)$-frame simulations.

**Exercise 12.4.** A system uses the clock algorithm with 8 frames. The initial state is: frames contain pages {A, B, C, D, E, F, G, H} with accessed bits {1, 0, 1, 1, 0, 0, 1, 0}, and the clock hand points to frame 0. Trace the algorithm for the page fault on page X: show which frames are examined, which accessed bits are cleared, and which page is evicted.

**Exercise 12.5.** A system has 5000 frames of physical memory shared among 10 processes. Process sizes (in frames): 200, 400, 300, 600, 100, 800, 500, 350, 250, 450. (a) Calculate the frame allocation for each process under proportional allocation. (b) If the working set sizes are 150, 350, 280, 500, 80, 700, 450, 300, 200, 400, is the system at risk of thrashing? Justify your answer.

**Exercise 12.6.** The effective access time for demand paging is $\text{EAT} = (1-p) \times t_{\text{mem}} + p \times t_{\text{fault}}$. A system upgrades from HDD ($t_{\text{fault}} = 8$ ms) to NVMe SSD ($t_{\text{fault}} = 80\ \mu\text{s}$). Memory access time is 100 ns. (a) For a page fault rate of $p = 0.001$, calculate the EAT and slowdown factor for both storage technologies. (b) What page fault rate on HDD gives the same EAT as $p = 0.01$ on NVMe SSD? (c) Discuss the implications for the viability of swap-heavy workloads on SSDs vs HDDs.

**Exercise 12.7.** A process has the following reference pattern over time, with working set window $\Delta = 5$:

Reference string: $3, 4, 3, 2, 1, 4, 4, 3, 2, 5, 1, 1, 2, 3, 3$

(a) Compute the working set $W(t, 5)$ and working set size $|W(t, 5)|$ for $t = 5, 8, 10, 13, 15$. (b) If the system allocates frames equal to the working set size (updated at each time step), what is the maximum frame allocation needed by this process? (c) If the system has only 3 frames available for this process, at which time steps will it be at risk of thrashing?
:::
