# Chapter 5: CPU Scheduling

The CPU is the most contested resource in any computer system. Dozens or hundreds of processes compete for time on a handful of processor cores, and the operating system must decide, moment by moment, which process gets to run next. This decision --- **CPU scheduling** --- has profound implications for system responsiveness, throughput, and fairness. A poorly chosen scheduling algorithm can make a powerful machine feel sluggish, while a well-designed one can extract remarkable performance from modest hardware.

This chapter develops the theory of CPU scheduling from first principles. We begin with the criteria by which scheduling algorithms are judged, proceed through the classical algorithms (FCFS, SJF, Round-Robin), and arrive at the sophisticated multi-level feedback queues and fair schedulers used in modern operating systems. We conclude with real-time scheduling theory and multiprocessor considerations.

## 5.1 Scheduling Criteria

Before we can compare scheduling algorithms, we need to define what "good" scheduling means. Different workloads and different users care about different metrics.

::: definition
**Definition 5.1 (Scheduling Criteria).** The primary metrics for evaluating CPU scheduling algorithms are:

1. **CPU utilisation**: The fraction of time the CPU is busy executing processes (not idle). Target: 40--90% on a well-loaded system.
2. **Throughput**: The number of processes that complete per unit time.
3. **Turnaround time**: The total elapsed time from process submission to completion: $T_{\text{turnaround}} = T_{\text{completion}} - T_{\text{arrival}}$.
4. **Waiting time**: The total time a process spends in the ready queue, not executing: $T_{\text{waiting}} = T_{\text{turnaround}} - T_{\text{burst}}$.
5. **Response time**: The time from process submission to the first response (first time the process is scheduled): $T_{\text{response}} = T_{\text{first\_run}} - T_{\text{arrival}}$.
:::

These criteria often conflict. Maximising throughput may increase average response time (batching favours throughput but hurts interactivity). Minimising response time for interactive processes may reduce throughput (frequent context switches waste CPU cycles on overhead). The art of scheduling lies in balancing these trade-offs for the target workload.

### 5.1.1 CPU Bursts and I/O Bursts

Process execution alternates between **CPU bursts** (periods of computation) and **I/O bursts** (periods of waiting for I/O operations to complete). The distribution of CPU burst lengths is a key input to scheduling algorithm design.

Empirical measurements show that CPU burst lengths follow an approximately exponential distribution: most bursts are short (a few milliseconds), with a long tail of occasional long bursts. This observation motivates algorithms like Shortest Job First that favour short bursts.

::: definition
**Definition 5.2 (CPU-Bound and I/O-Bound Processes).** A **CPU-bound process** spends most of its time executing instructions, with long CPU bursts and infrequent I/O. A **I/O-bound process** spends most of its time waiting for I/O, with short CPU bursts and frequent I/O requests. Most interactive programs (editors, browsers, shells) are I/O-bound; most scientific computations and compilers are CPU-bound.
:::

## 5.2 Preemptive vs Non-Preemptive Scheduling

A fundamental distinction among scheduling algorithms is whether the currently running process can be involuntarily removed from the CPU.

::: definition
**Definition 5.3 (Preemptive and Non-Preemptive Scheduling).**

- **Non-preemptive (cooperative) scheduling**: Once a process is allocated the CPU, it retains the CPU until it voluntarily relinquishes it (by terminating, blocking on I/O, or explicitly yielding).
- **Preemptive scheduling**: The scheduler can forcibly remove a running process from the CPU, typically when a timer interrupt fires or when a higher-priority process becomes ready.
:::

Non-preemptive scheduling is simpler to implement and avoids some concurrency issues (a process in a critical section cannot be preempted), but it cannot guarantee responsiveness: a CPU-bound process can monopolise the CPU indefinitely. All modern general-purpose operating systems use preemptive scheduling.

Scheduling decisions are made at four points:

1. A running process switches from running to waiting (e.g., I/O request)
2. A running process switches from running to ready (e.g., timer interrupt)
3. A process switches from waiting to ready (e.g., I/O completion)
4. A process terminates

Non-preemptive scheduling makes decisions only at points 1 and 4. Preemptive scheduling can act at all four points.

### 5.2.1 The Dispatcher

The **dispatcher** is the kernel component that actually performs the context switch selected by the scheduler. It is distinct from the scheduler (which makes the decision) but closely coupled to it.

::: definition
**Definition 5.4 (Dispatcher).** The dispatcher is the kernel module that gives control of the CPU to the process selected by the scheduler. Its responsibilities include:

1. Switching context (saving the current process's registers, loading the next process's registers)
2. Switching to user mode (from kernel mode, via `iretq` or `sysret` on x86-64)
3. Jumping to the proper location in the user program to resume execution

The **dispatch latency** is the time it takes the dispatcher to stop one process and start another. It includes the time for context switching and TLB invalidation, typically 1--10 microseconds on modern hardware.
:::

::: example
**Example 5.1 (Dispatch Latency Measurement).** On a Linux system, dispatch latency can be measured using `cyclictest` from the `rt-tests` package:

```text
$ sudo cyclictest --mlockall --priority=80 --interval=1000 --loops=10000
T: 0 ( 1234) P:80 I:1000 C:  10000 Min:      1 Act:    3 Avg:    2 Max:   15
```

This shows minimum dispatch latency of 1 microsecond, average of 2 microseconds, and worst-case of 15 microseconds. The worst case occurs when the dispatcher must flush the TLB and the new process's working set is not in cache.
:::

## 5.3 First-Come, First-Served (FCFS)

The simplest scheduling algorithm: processes are served in the order they arrive in the ready queue.

::: definition
**Definition 5.5 (FCFS).** First-Come, First-Served (FCFS) scheduling dispatches processes in arrival order. The ready queue is a FIFO queue. FCFS is non-preemptive: once a process begins executing, it runs until it completes its CPU burst or blocks on I/O.
:::

::: example
**Example 5.2 (FCFS Scheduling).** Consider three processes arriving at time 0 with the following CPU burst lengths:

| Process | Arrival Time | Burst Time |
|---|---|---|
| $P_1$ | 0 | 24 |
| $P_2$ | 0 | 3 |
| $P_3$ | 0 | 3 |

**Execution order** $P_1, P_2, P_3$ (arrival order):

```text
|---- P1 (24) ----|-- P2 (3) --|-- P3 (3) --|
0                 24           27           30
```

- Waiting times: $P_1 = 0$, $P_2 = 24$, $P_3 = 27$
- Average waiting time: $(0 + 24 + 27) / 3 = 17.0$

If instead the order were $P_2, P_3, P_1$:

```text
|P2(3)|P3(3)|---- P1 (24) ----|
0     3     6                 30
```

- Waiting times: $P_2 = 0$, $P_3 = 3$, $P_1 = 6$
- Average waiting time: $(0 + 3 + 6) / 3 = 3.0$
:::

This example illustrates the **convoy effect**: a long CPU-bound process arriving before short I/O-bound processes forces all short processes to wait, dramatically inflating average waiting time. FCFS is simple but poorly suited to mixed workloads.

::: definition
**Definition 5.6 (Convoy Effect).** The convoy effect occurs in FCFS scheduling when a single long CPU-bound process monopolises the CPU, causing all shorter processes to queue behind it. The average waiting time becomes dominated by the long process's burst time, regardless of how short the other processes are. Formally, if one process has burst time $B$ and $n-1$ processes have burst time $\epsilon \ll B$, the average waiting time under FCFS (with the long process first) is approximately $\frac{(n-1) \cdot B}{n} \approx B$ for large $n$.
:::

### 5.3.1 FCFS with Staggered Arrivals

When processes arrive at different times, FCFS becomes more reasonable because the convoy effect is mitigated by natural interleaving:

::: example
**Example 5.3 (FCFS with Staggered Arrivals).** Consider:

| Process | Arrival Time | Burst Time |
|---|---|---|
| $P_1$ | 0 | 5 |
| $P_2$ | 2 | 3 |
| $P_3$ | 4 | 1 |
| $P_4$ | 5 | 4 |

```text
|-- P1 (5) --|-- P2 (3) --|P3(1)|-- P4 (4) --|
0            5            8     9            13
```

- Waiting times: $P_1 = 0$, $P_2 = 5 - 2 = 3$, $P_3 = 8 - 4 = 4$, $P_4 = 9 - 5 = 4$
- Average waiting time: $(0 + 3 + 4 + 4) / 4 = 2.75$
- Average turnaround time: $(5 + 6 + 5 + 8) / 4 = 6.0$
:::

### 5.3.2 Implementation

FCFS is trivially implemented with a FIFO queue:

```c
#include <stdio.h>

typedef struct {
    int pid;
    int arrival;
    int burst;
    int start;
    int finish;
    int waiting;
    int turnaround;
} Process;

void fcfs_schedule(Process procs[], int n) {
    int current_time = 0;
    
    /* Assume processes are sorted by arrival time */
    for (int i = 0; i < n; i++) {
        if (current_time < procs[i].arrival) {
            current_time = procs[i].arrival;  /* CPU idle */
        }
        
        procs[i].start = current_time;
        procs[i].finish = current_time + procs[i].burst;
        procs[i].waiting = procs[i].start - procs[i].arrival;
        procs[i].turnaround = procs[i].finish - procs[i].arrival;
        
        current_time = procs[i].finish;
        
        printf("P%d: start=%d, finish=%d, waiting=%d, turnaround=%d\n",
               procs[i].pid, procs[i].start, procs[i].finish,
               procs[i].waiting, procs[i].turnaround);
    }
}

int main(void) {
    Process procs[] = {
        {1, 0, 5, 0, 0, 0, 0},
        {2, 2, 3, 0, 0, 0, 0},
        {3, 4, 1, 0, 0, 0, 0},
        {4, 5, 4, 0, 0, 0, 0}
    };
    
    fcfs_schedule(procs, 4);
    return 0;
}
```

## 5.4 Shortest Job First (SJF)

Shortest Job First scheduling always selects the process with the smallest next CPU burst.

::: definition
**Definition 5.7 (Shortest Job First).** Shortest Job First (SJF) scheduling selects the ready process whose next CPU burst is the shortest. When two processes have equal burst lengths, FCFS order is used as a tiebreaker. Non-preemptive SJF runs the selected process to completion of its burst.
:::

::: theorem
**Theorem 5.1 (Optimality of SJF).** Among all non-preemptive scheduling algorithms for a set of processes with known burst times that arrive simultaneously, SJF minimises the average waiting time.

*Proof.* Let $n$ processes have burst times $b_1, b_2, \ldots, b_n$. Under any schedule $\sigma$ (a permutation of $\{1, \ldots, n\}$), the waiting time of the $k$-th process in the schedule is:

$$W_{\sigma(k)} = \sum_{j=1}^{k-1} b_{\sigma(j)}$$

The total waiting time is:

$$W_{\text{total}} = \sum_{k=1}^{n} W_{\sigma(k)} = \sum_{k=1}^{n} \sum_{j=1}^{k-1} b_{\sigma(j)} = \sum_{k=1}^{n} (n - k) \cdot b_{\sigma(k)}$$

The last equality follows because process $\sigma(k)$ contributes its burst time to the waiting time of all $n - k$ processes that follow it in the schedule. To minimise this weighted sum $\sum_{k=1}^{n} (n - k) \cdot b_{\sigma(k)}$, we must assign the largest weights $(n - 1, n - 2, \ldots, 0)$ to the smallest burst times. This is achieved by sorting burst times in non-decreasing order: $b_{\sigma(1)} \le b_{\sigma(2)} \le \cdots \le b_{\sigma(n)}$. This is precisely the SJF order. $\square$
:::

::: example
**Example 5.4 (SJF Scheduling).** Consider:

| Process | Arrival Time | Burst Time |
|---|---|---|
| $P_1$ | 0.0 | 6 |
| $P_2$ | 0.0 | 8 |
| $P_3$ | 0.0 | 7 |
| $P_4$ | 0.0 | 3 |

SJF order: $P_4, P_1, P_3, P_2$:

```text
|P4(3)|-- P1 (6) --|-- P3 (7) --|--- P2 (8) ---|
0     3            9            16             24
```

- Waiting times: $P_4 = 0$, $P_1 = 3$, $P_3 = 9$, $P_2 = 16$
- Average waiting time: $(0 + 3 + 9 + 16) / 4 = 7.0$

Compare with FCFS order $P_1, P_2, P_3, P_4$: average waiting time = $(0 + 6 + 14 + 21) / 4 = 10.25$.
:::

### 5.4.1 The Prediction Problem

SJF is optimal but impractical in its pure form: the scheduler cannot know the length of the next CPU burst in advance. The standard approximation uses **exponential averaging** to predict the next burst from past behaviour:

::: definition
**Definition 5.8 (Exponential Average Prediction).** Let $\tau_{n+1}$ be the predicted length of the next CPU burst, $t_n$ be the measured length of the $n$-th burst, and $\alpha \in [0, 1]$ be a smoothing parameter. The prediction is:

$$\tau_{n+1} = \alpha \cdot t_n + (1 - \alpha) \cdot \tau_n$$

Expanding the recurrence:

$$\tau_{n+1} = \alpha \cdot t_n + (1 - \alpha) \cdot \alpha \cdot t_{n-1} + (1 - \alpha)^2 \cdot \alpha \cdot t_{n-2} + \cdots + (1 - \alpha)^n \cdot \tau_0$$

Each past burst $t_k$ is weighted by $\alpha(1 - \alpha)^{n-k}$, giving exponentially decreasing influence to older observations.
:::

Typical values of $\alpha$ range from 0.5 (equal weight to recent and predicted) to 0.8 (strong bias toward recent measurements). With $\alpha = 0$, the prediction never changes; with $\alpha = 1$, the prediction equals the last observed burst.

::: example
**Example 5.5 (Exponential Average Trace).** A process exhibits the following CPU burst lengths: $t_1 = 6$, $t_2 = 4$, $t_3 = 6$, $t_4 = 4$, $t_5 = 13$, $t_6 = 13$, $t_7 = 13$. With $\alpha = 0.5$ and $\tau_0 = 10$:

| $n$ | Actual $t_n$ | Predicted $\tau_n$ | Error $|t_n - \tau_n|$ |
|---|---|---|---|
| 1 | 6 | 10.0 | 4.0 |
| 2 | 4 | 8.0 | 4.0 |
| 3 | 6 | 6.0 | 0.0 |
| 4 | 4 | 6.0 | 2.0 |
| 5 | 13 | 5.0 | 8.0 |
| 6 | 13 | 9.0 | 4.0 |
| 7 | 13 | 11.0 | 2.0 |

The predictor adapts to the process's behaviour, though it lags behind sudden changes (the jump from burst lengths of 4--6 to 13 takes several bursts to track).
:::

### 5.4.2 Starvation in SJF

A major drawback of SJF is **starvation**: a process with a long burst can wait indefinitely if shorter processes keep arriving. In a system where short jobs arrive frequently, a long job may never be scheduled.

::: definition
**Definition 5.9 (Starvation).** Starvation occurs when a process waits indefinitely in the ready queue because other processes are always selected by the scheduler. Starvation is a liveness failure: the starved process makes no progress despite being ready to run.
:::

The standard remedy for starvation is **aging**: gradually increasing the priority of processes that have been waiting in the ready queue. After sufficient waiting time, even a long-burst process will be promoted to the highest priority and scheduled. Formally, if a process has waited $w$ time units, its effective priority can be defined as:

$$p_{\text{effective}} = p_{\text{base}} - \lfloor w / \Delta \rfloor$$

where $\Delta$ is the aging interval. This ensures that any waiting process eventually reaches the highest priority.

## 5.5 Shortest Remaining Time First (SRTF)

The preemptive version of SJF is called Shortest Remaining Time First (SRTF), also known as Preemptive SJF.

::: definition
**Definition 5.10 (Shortest Remaining Time First).** SRTF scheduling always runs the process whose remaining CPU burst time is the shortest. When a new process arrives with a burst time shorter than the remaining time of the currently running process, the running process is preempted and the new process takes the CPU.
:::

::: example
**Example 5.6 (SRTF Scheduling).** Consider:

| Process | Arrival Time | Burst Time |
|---|---|---|
| $P_1$ | 0 | 8 |
| $P_2$ | 1 | 4 |
| $P_3$ | 2 | 9 |
| $P_4$ | 3 | 5 |

Execution trace:

```text
|P1|--- P2 (4) ---|-- P4 (5) --|---- P1 (7) ----|------ P3 (9) ------|
0  1              5            10               17                   26
```

- At $t=0$: Only $P_1$ available, runs.
- At $t=1$: $P_2$ arrives with burst 4; $P_1$ has remaining 7. Since $4 < 7$, preempt $P_1$, run $P_2$.
- At $t=2$: $P_3$ arrives with burst 9; $P_2$ has remaining 3. Since $9 > 3$, $P_2$ continues.
- At $t=3$: $P_4$ arrives with burst 5; $P_2$ has remaining 2. Since $5 > 2$, $P_2$ continues.
- At $t=5$: $P_2$ completes. Ready: $P_1$ (remaining 7), $P_3$ (9), $P_4$ (5). Run $P_4$.
- At $t=10$: $P_4$ completes. Ready: $P_1$ (7), $P_3$ (9). Run $P_1$.
- At $t=17$: $P_1$ completes. Run $P_3$.
- At $t=26$: $P_3$ completes.

Waiting times: $P_1 = (0-0) + (10-1) = 9$, $P_2 = 0$, $P_3 = 17-2 = 15$, $P_4 = 5-3 = 2$.

Average waiting time: $(9 + 0 + 15 + 2)/4 = 6.5$.
:::

::: theorem
**Theorem 5.2 (Optimality of SRTF).** Among all scheduling algorithms (preemptive and non-preemptive) for a set of processes with known burst times, SRTF minimises the average waiting time.

*Proof sketch.* Consider any schedule $S$ that is not SRTF. There exists a time $t$ at which $S$ runs process $P_i$ while process $P_j$ is ready with a shorter remaining time. We can construct a new schedule $S'$ that swaps an infinitesimal interval $\epsilon$ of execution between $P_i$ and $P_j$ at time $t$. In $S'$, $P_j$'s waiting time decreases by $\epsilon$ and $P_i$'s increases by $\epsilon$. Since $P_j$'s remaining time is shorter, it finishes sooner, reducing the waiting time of all processes waiting behind it. By induction over all such swap points, we transform any non-SRTF schedule into the SRTF schedule without increasing total waiting time. $\square$
:::

## 5.6 Round-Robin (RR) Scheduling

Round-Robin scheduling is designed for time-sharing systems. Each process gets a small unit of CPU time, called a **time quantum** (or time slice), after which it is preempted and placed at the back of the ready queue.

::: definition
**Definition 5.11 (Round-Robin Scheduling).** Round-Robin (RR) scheduling maintains a FIFO ready queue and allocates each process a fixed time quantum $q$. If a process's CPU burst exceeds $q$, it is preempted after $q$ time units and placed at the tail of the ready queue. If the burst is less than or equal to $q$, the process runs to completion and releases the CPU voluntarily.
:::

::: example
**Example 5.7 (Round-Robin with $q = 4$).** Consider:

| Process | Arrival Time | Burst Time |
|---|---|---|
| $P_1$ | 0 | 24 |
| $P_2$ | 0 | 3 |
| $P_3$ | 0 | 3 |

With quantum $q = 4$:

```text
|P1(4)|P2(3)|P3(3)|P1(4)|P1(4)|P1(4)|P1(4)|P1(4)|
0     4     7    10    14    18    22    26    30
```

- $P_1$ gets 4 units, preempted, goes to back of queue
- $P_2$ gets 3 units, completes (burst $\le q$)
- $P_3$ gets 3 units, completes
- $P_1$ runs remaining 20 units in 5 quanta of 4 each

Waiting times: $P_1 = (0) + (10 - 4) = 6$, $P_2 = 4$, $P_3 = 7$.

Average waiting time: $(6 + 4 + 7) / 3 = 5.67$.
:::

### 5.6.1 Quantum Analysis

The choice of quantum $q$ is critical:

- **If $q$ is very large** (larger than all burst times), RR degenerates to FCFS. No preemption ever occurs.
- **If $q$ is very small**, the system spends most of its time context-switching rather than executing useful work.

::: theorem
**Theorem 5.3 (Context Switch Overhead in Round-Robin).** Let $q$ be the time quantum, $T_{\text{cs}}$ be the context switch time, and $n$ be the number of ready processes. The fraction of CPU time spent on context switching (CPU overhead) is:

$$\text{Overhead} = \frac{T_{\text{cs}}}{q + T_{\text{cs}}}$$

For the system to spend at least fraction $f$ of CPU time on useful work, we need:

$$q \ge \frac{T_{\text{cs}} \cdot f}{1 - f}$$

For example, with $T_{\text{cs}} = 5\ \mu\text{s}$ and $f = 0.99$ (99% useful work):

$$q \ge \frac{5 \times 0.99}{0.01} = 495\ \mu\text{s} \approx 0.5\ \text{ms}$$
:::

In practice, typical quantum values are:

- **Linux CFS**: Dynamic, based on the number of runnable tasks and their niceness (typically 1--20 ms)
- **Windows**: 20 ms for desktop (foreground bias), 120 ms for server
- **macOS**: Varies by scheduling band; typically 10 ms for interactive, longer for background

### 5.6.2 Turnaround Time Analysis

Round-Robin does not optimise turnaround time --- in fact, it can be worse than FCFS for homogeneous workloads:

::: example
**Example 5.8 (RR Turnaround Time Penalty).** Three processes, all arriving at time 0, each with burst time 10. With quantum $q = 1$:

Under FCFS: Turnaround times are 10, 20, 30. Average = 20.

Under RR ($q = 1$): Each process finishes at time 28, 29, 30 respectively (they interleave in round-robin fashion, each getting 1 unit every 3 units).

- $P_1$ finishes at $t = 28$ (last unit at $t = 28$)
- $P_2$ finishes at $t = 29$
- $P_3$ finishes at $t = 30$
- Average turnaround = $(28 + 29 + 30) / 3 = 29.0$

The average turnaround under RR is significantly worse than FCFS (29 vs 20). This is the fundamental trade-off: RR improves response time at the cost of turnaround time. RR is designed for interactive systems where response time matters more than total completion time.
:::

::: theorem
**Theorem 5.4 (RR Turnaround for Equal Bursts).** For $n$ processes each with burst time $B$ and quantum $q$, the average turnaround time under Round-Robin is:

$$\bar{T}_{\text{turnaround}}^{\text{RR}} = B + \frac{(n-1)(B - q)}{2} \cdot \frac{q}{B}$$

when $q$ divides $B$ evenly. As $q \to 0$, the turnaround time for all processes approaches $n \cdot B$ (each process finishes near the end because all are interleaved), compared to $\frac{(n+1) \cdot B}{2}$ under FCFS.
:::

### 5.6.3 Implementation

```c
#include <stdio.h>
#include <stdbool.h>

typedef struct {
    int pid;
    int arrival;
    int burst;
    int remaining;
    int finish;
    int waiting;
    int turnaround;
    int first_run;
    bool started;
} Process;

void rr_schedule(Process procs[], int n, int quantum) {
    int time = 0;
    int completed = 0;
    int queue[1000];
    int front = 0, rear = 0;
    bool in_queue[100] = {false};
    
    /* Add initially arrived processes */
    for (int i = 0; i < n; i++) {
        procs[i].remaining = procs[i].burst;
        procs[i].started = false;
        if (procs[i].arrival <= time) {
            queue[rear++] = i;
            in_queue[i] = true;
        }
    }
    
    while (completed < n) {
        if (front == rear) {
            /* Queue empty: advance time to next arrival */
            time++;
            for (int i = 0; i < n; i++) {
                if (!in_queue[i] && procs[i].arrival <= time &&
                    procs[i].remaining > 0) {
                    queue[rear++] = i;
                    in_queue[i] = true;
                }
            }
            continue;
        }
        
        int idx = queue[front++];
        
        if (!procs[idx].started) {
            procs[idx].first_run = time;
            procs[idx].started = true;
        }
        
        int run_time = procs[idx].remaining < quantum ?
                       procs[idx].remaining : quantum;
        
        time += run_time;
        procs[idx].remaining -= run_time;
        
        /* Check for new arrivals during this quantum */
        for (int i = 0; i < n; i++) {
            if (!in_queue[i] && procs[i].arrival <= time &&
                procs[i].remaining > 0) {
                queue[rear++] = i;
                in_queue[i] = true;
            }
        }
        
        if (procs[idx].remaining > 0) {
            queue[rear++] = idx;  /* Re-enqueue */
        } else {
            procs[idx].finish = time;
            procs[idx].turnaround = time - procs[idx].arrival;
            procs[idx].waiting = procs[idx].turnaround - procs[idx].burst;
            completed++;
        }
    }
    
    float avg_wait = 0, avg_turnaround = 0, avg_response = 0;
    for (int i = 0; i < n; i++) {
        avg_wait += procs[i].waiting;
        avg_turnaround += procs[i].turnaround;
        avg_response += (procs[i].first_run - procs[i].arrival);
        printf("P%d: finish=%d, wait=%d, turnaround=%d, response=%d\n",
               procs[i].pid, procs[i].finish, procs[i].waiting,
               procs[i].turnaround, procs[i].first_run - procs[i].arrival);
    }
    printf("Averages: wait=%.2f, turnaround=%.2f, response=%.2f\n",
           avg_wait / n, avg_turnaround / n, avg_response / n);
}
```

::: theorem
**Theorem 5.5 (Response Time Bound for Round-Robin).** In a Round-Robin schedule with $n$ processes and quantum $q$, the worst-case response time for any process is:

$$T_{\text{response}}^{\max} = (n - 1) \cdot q$$

This occurs when a process arrives just after its slot and must wait for all other $n - 1$ processes to receive their quanta before being scheduled.
:::

## 5.7 Priority Scheduling

In priority scheduling, each process is assigned a priority, and the scheduler always runs the highest-priority ready process. Priorities may be assigned externally (by the user or administrator) or computed internally (based on resource usage, aging, or other factors).

::: definition
**Definition 5.12 (Priority Scheduling).** In priority scheduling, each process $P_i$ is assigned an integer priority $p_i$. The scheduler selects the ready process with the highest priority (lowest numerical value in some conventions, highest in others). Priority scheduling can be either preemptive (a newly arrived higher-priority process preempts the running process) or non-preemptive (the running process completes its burst before a priority comparison is made).
:::

### 5.7.1 Priority Inversion

Priority scheduling introduces a subtle problem known as **priority inversion**: a high-priority process can be blocked indefinitely by a low-priority process.

::: definition
**Definition 5.13 (Priority Inversion).** Priority inversion occurs when a high-priority process $H$ is blocked waiting for a resource held by a low-priority process $L$, while a medium-priority process $M$ preempts $L$. Because $M$ runs instead of $L$, the resource held by $L$ is not released, and $H$ remains blocked. The effective priority ordering becomes $M > H > L$, inverting the intended priority of $H$ and $M$.
:::

::: example
**Example 5.9 (The Mars Pathfinder Bug).** In 1997, NASA's Mars Pathfinder experienced repeated system resets caused by priority inversion. The scenario involved three tasks:

1. **Bus management task** (low priority): Held a mutex on a shared data bus
2. **Communication task** (medium priority): Ran frequently for data collection
3. **Information bus task** (high priority): Needed the bus mutex

When the low-priority task held the mutex and the medium-priority task preempted it, the high-priority task starved. A watchdog timer detected the stall and reset the system. The fix was to enable **priority inheritance** on the mutex, which the VxWorks RTOS supported but had left disabled.
:::

### 5.7.2 Priority Inheritance and Priority Ceiling

Two protocols solve priority inversion:

::: definition
**Definition 5.14 (Priority Inheritance Protocol).** When a low-priority process $L$ holds a resource needed by a higher-priority process $H$, $L$ temporarily inherits $H$'s priority for the duration of the critical section. Once $L$ releases the resource, its priority reverts to its original value. This prevents medium-priority processes from preempting $L$ while it holds the resource.
:::

::: definition
**Definition 5.15 (Priority Ceiling Protocol).** Each resource $R$ is assigned a **priority ceiling** $\Pi(R)$ equal to the highest priority of any process that may lock $R$. A process can acquire $R$ only if its priority is strictly higher than the priority ceiling of all resources currently locked by other processes. This prevents deadlocks and bounds the duration of priority inversion.
:::

::: theorem
**Theorem 5.6 (Priority Inversion Bound).** Under the Priority Ceiling Protocol, a high-priority process can be blocked by at most one lower-priority critical section. Specifically, if process $P_i$ has the $i$-th highest priority, then $P_i$ can be blocked for at most $\max_{j > i} \{C_j^k\}$ time units, where $C_j^k$ is the worst-case execution time of the longest critical section of any lower-priority process $P_j$ that accesses a resource shared with $P_i$ or a higher-priority process.
:::

## 5.8 Lottery and Stride Scheduling

Before examining MLFQ and CFS, we consider two elegant proportional-share schedulers that provide provable fairness guarantees.

### 5.8.1 Lottery Scheduling

::: definition
**Definition 5.16 (Lottery Scheduling).** In lottery scheduling, each process holds some number of **lottery tickets**. At each scheduling decision, the scheduler draws a random ticket uniformly from the total pool. The process holding the winning ticket gets to run for one time quantum. A process with $t_i$ tickets out of a total $T = \sum_j t_j$ tickets has a probability $t_i / T$ of winning each lottery, and thus receives approximately $t_i / T$ of the CPU over time.
:::

Lottery scheduling has several appealing properties:

- **Proportional share**: CPU time is distributed in proportion to ticket holdings
- **Responsive**: A new process that arrives with tickets immediately participates in the next lottery
- **Simple**: Implementation requires only a random number generator and a list of ticket holders
- **Composable**: Ticket transfers allow processes to temporarily donate their CPU share to other processes (useful for priority donation)

::: example
**Example 5.10 (Lottery Scheduling).** Process $A$ holds 75 tickets, process $B$ holds 25 tickets. Total: 100 tickets.

At each scheduling event, a random number in $[0, 99]$ is drawn. If the number falls in $[0, 74]$, $A$ runs; if it falls in $[75, 99]$, $B$ runs.

Over 1000 quanta, the expected number of quanta for $A$ is 750, and for $B$ is 250. The standard deviation is:

$$\sigma = \sqrt{n \cdot p \cdot (1-p)} = \sqrt{1000 \times 0.75 \times 0.25} \approx 13.7$$

So $A$ will receive $750 \pm 27$ quanta (within 2 standard deviations) with 95% probability. The fairness improves with the number of scheduling events.
:::

::: theorem
**Theorem 5.7 (Lottery Fairness Convergence).** Let process $P_i$ hold fraction $f_i = t_i / T$ of the total tickets. After $n$ scheduling events, the fraction of CPU time received by $P_i$ converges to $f_i$ with standard deviation $O(1/\sqrt{n})$. Specifically, by the Central Limit Theorem:

$$\Pr\left[\left|\frac{X_i}{n} - f_i\right| > \epsilon\right] \le 2\exp\left(-\frac{2n\epsilon^2}{1}\right)$$

where $X_i$ is the number of quanta received by $P_i$ (Hoeffding's inequality). For $\epsilon = 0.01$ and $n = 10000$, the probability of more than 1% deviation is less than $2e^{-200} \approx 0$.
:::

### 5.8.2 Stride Scheduling

Lottery scheduling's randomness means it can be unfair over short timescales. **Stride scheduling** is the deterministic counterpart.

::: definition
**Definition 5.17 (Stride Scheduling).** In stride scheduling, each process $P_i$ with ticket count $t_i$ is assigned a **stride** $s_i = L / t_i$, where $L$ is a large constant (e.g., 10000). Each process maintains a **pass value**, initially 0. At each scheduling event:

1. Select the process with the smallest pass value
2. Run that process for one quantum
3. Increment that process's pass value by its stride: $\text{pass}_i \mathrel{+}= s_i$

Processes with more tickets have smaller strides and thus accumulate pass value more slowly, running more frequently.
:::

::: example
**Example 5.11 (Stride Scheduling Trace).** Three processes with strides $A: 100$, $B: 200$, $C: 40$:

| Step | Pass A | Pass B | Pass C | Run |
|---|---|---|---|---|
| 0 | 0 | 0 | 0 | A (tiebreak) |
| 1 | 100 | 0 | 0 | B (tiebreak) |
| 2 | 100 | 200 | 0 | C |
| 3 | 100 | 200 | 40 | C |
| 4 | 100 | 200 | 80 | C |
| 5 | 100 | 200 | 120 | A |
| 6 | 200 | 200 | 120 | C |
| 7 | 200 | 200 | 160 | C |
| 8 | 200 | 200 | 200 | A (tiebreak) |

After 9 steps: A ran 3 times (33%), B ran 1 time (11%), C ran 5 times (56%). With $L = 200$, tickets are $A: 2$, $B: 1$, $C: 5$, total 8. Expected: $A: 25\%$, $B: 12.5\%$, $C: 62.5\%$. The proportions converge as more steps are executed.
:::

Stride scheduling provides **deterministic proportional-share scheduling**: unlike lottery scheduling, it never makes random choices, so fairness over short timescales is guaranteed. CFS uses a similar idea with its virtual runtime mechanism.

## 5.9 Multi-Level Feedback Queue (MLFQ)

The Multi-Level Feedback Queue is one of the most important scheduling algorithms in practice. It aims to optimise both turnaround time (by favouring short jobs) and response time (by rapidly serving interactive processes), without requiring prior knowledge of burst lengths.

::: definition
**Definition 5.18 (Multi-Level Feedback Queue).** An MLFQ scheduler maintains multiple priority queues $Q_0, Q_1, \ldots, Q_{k-1}$, where $Q_0$ has the highest priority and $Q_{k-1}$ the lowest. Each queue may use a different scheduling algorithm (typically Round-Robin with increasing quanta). Processes move between queues based on their observed behaviour:

1. **Rule 1**: If Priority($A$) > Priority($B$), $A$ runs (and $B$ does not).
2. **Rule 2**: If Priority($A$) = Priority($B$), $A$ and $B$ run in Round-Robin within their queue.
3. **Rule 3**: When a process enters the system (or after a priority boost), it is placed in $Q_0$ (highest priority).
4. **Rule 4a**: If a process uses up its time quantum in queue $Q_i$, it is demoted to $Q_{i+1}$.
5. **Rule 4b**: If a process gives up the CPU before its quantum expires (e.g., for I/O), it stays in $Q_i$.
:::

The intuition is that MLFQ **learns** the nature of each process. Interactive processes (short CPU bursts, frequent I/O) stay in high-priority queues. CPU-bound processes (long bursts) are gradually demoted to lower-priority queues with longer quanta.

### 5.8.1 Problems with Basic MLFQ

The basic rules above have several problems:

**Starvation.** If many interactive processes keep arriving, CPU-bound processes in low-priority queues may never run.

**Gaming.** A process can game the scheduler by issuing a spurious I/O request just before its quantum expires, staying in a high-priority queue while consuming nearly as much CPU as a CPU-bound process.

**Behaviour change.** A CPU-bound process that becomes interactive (e.g., a compiler that finishes compiling and starts accepting user input) is stuck in a low-priority queue.

### 5.8.2 MLFQ Refinements

Modern MLFQ implementations address these problems:

::: definition
**Definition 5.19 (MLFQ with Anti-Gaming and Boosting).**

- **Priority boost** (Rule 5): After a fixed time period $S$ (the boost interval), all processes are moved to $Q_0$. This prevents starvation and allows CPU-bound processes that become interactive to be reclassified.
- **Accounting-based demotion** (Rule 4, revised): Instead of demoting a process when it uses a single quantum, track the **total CPU time** a process has used at its current priority level. Once it exceeds the allotment for that level, demote it, regardless of how many quanta it has used. This prevents gaming by breaking CPU time into many small intervals separated by I/O.
:::

::: example
**Example 5.12 (MLFQ with Three Queues).** Consider an MLFQ with three queues:

| Queue | Priority | Quantum | Algorithm |
|---|---|---|---|
| $Q_0$ | Highest | 8 ms | Round-Robin |
| $Q_1$ | Medium | 16 ms | Round-Robin |
| $Q_2$ | Lowest | $\infty$ | FCFS |

Process $A$ (interactive): Arrives, placed in $Q_0$. Uses 3 ms CPU, then does I/O. Returns to $Q_0$. This pattern repeats --- $A$ always stays in $Q_0$, getting excellent response time.

Process $B$ (CPU-bound): Arrives, placed in $Q_0$. Uses full 8 ms quantum, demoted to $Q_1$. Uses full 16 ms quantum, demoted to $Q_2$. Runs in FCFS order with other CPU-bound processes.

After the boost interval $S$, both $A$ and $B$ are moved back to $Q_0$, and the classification process begins again.
:::

### 5.9.3 Detailed MLFQ Trace

::: example
**Example 5.12a (Complete MLFQ Trace).** Consider an MLFQ with three queues: $Q_0$ (quantum 2 ms), $Q_1$ (quantum 4 ms), $Q_2$ (FCFS). Boost interval $S = 20$ ms. Two processes arrive at $t = 0$:

- $P_A$: Interactive (pattern: 1 ms CPU, I/O, 1 ms CPU, I/O, ...)
- $P_B$: CPU-bound (needs 30 ms total CPU)

**Trace:**

```text
t=0:  P_A enters Q_0, P_B enters Q_0
      Schedule P_A from Q_0 (quantum=2)
t=0-1:  P_A runs 1 ms, issues I/O. Stays in Q_0 (didn't use full quantum)
t=1:  Schedule P_B from Q_0 (quantum=2)
t=1-3:  P_B runs 2 ms (full quantum). Demoted to Q_1.
t=3:  P_A returns from I/O, enters Q_0.
      Schedule P_A from Q_0 (higher priority than Q_1)
t=3-4:  P_A runs 1 ms, issues I/O. Stays in Q_0.
t=4:  Schedule P_B from Q_1 (quantum=4)
t=4-8:  P_B runs 4 ms (full quantum). Demoted to Q_2.
t=5:  P_A returns from I/O, enters Q_0.
      P_B is preempted! Schedule P_A from Q_0.
t=5-6:  P_A runs 1 ms, issues I/O.
t=6:  Resume P_B from Q_2 (remaining from preemption).
...
```

The key observation: $P_A$ always stays in $Q_0$ because it never uses its full quantum. $P_B$ is progressively demoted to $Q_2$. The interactive process receives excellent response time, while the CPU-bound process still makes progress in the background.
:::

### 5.9.4 MLFQ in Real Systems

Real operating systems use MLFQ variants:

- **FreeBSD ULE scheduler**: 256 priority levels grouped into three classes (interrupt, real-time, timeshare). Interactive detection uses a "score" based on voluntary context switches vs CPU time.

- **Windows**: Uses a simplified MLFQ with 32 priority levels. Variable-priority threads (1--15) receive dynamic boosts for I/O completion, foreground status, and starvation prevention.

- **Solaris** (historically): Used a table-driven MLFQ with configurable quantum, priority boost, and demotion rules per priority level. The table could be replaced at runtime to tune for different workloads.

## 5.10 Linux Scheduler History

Before examining CFS, it is instructive to understand the evolution of Linux schedulers, as each generation addressed specific limitations of its predecessor.

### 5.10.1 The O(n) Scheduler (Linux 2.4)

The original Linux scheduler scanned the entire run queue at each scheduling decision, examining every process to find the one with the highest "goodness" score. With $n$ runnable processes, each scheduling decision took $O(n)$ time. This was acceptable for workstations with a few dozen processes but became a bottleneck on servers with hundreds or thousands of threads.

### 5.10.2 The O(1) Scheduler (Linux 2.6.0--2.6.22)

Ingo Molnar's O(1) scheduler (2003) maintained two priority arrays per CPU: an **active** array and an **expired** array. Each array had 140 priority levels (0--99 for real-time, 100--139 for normal), with a bitmap indicating which levels had runnable processes. Finding the highest-priority process required only a `__ffs()` (find-first-set-bit) operation --- $O(1)$ time.

The O(1) scheduler used heuristics to classify processes as "interactive" or "batch" and boosted the priority of interactive processes. However, these heuristics were fragile: they worked well for some workloads but performed poorly for others. Desktop users reported stuttering audio and video, and the heuristics were notoriously difficult to tune.

### 5.10.3 The Completely Fair Scheduler (Linux 2.6.23+)

The Linux Completely Fair Scheduler, introduced in kernel 2.6.23 (2007) by Ingo Molnar, replaced the O(1) scheduler. CFS takes a radically different approach: instead of using multiple queues and heuristic rules, it attempts to give each process an exactly fair share of the CPU. The insight behind CFS is simple: in an ideal multitasking CPU, every process would run simultaneously, each receiving $1/n$ of the CPU power (where $n$ is the number of runnable processes). Since this is physically impossible on a real CPU, CFS approximates it by tracking how much CPU time each process "deserves" versus how much it has received, and always running the process that is furthest behind its fair share.

### 5.10.4 Virtual Runtime

The central concept in CFS is **virtual runtime** (vruntime): the amount of CPU time a process has received, weighted by its priority.

::: definition
**Definition 5.20 (Virtual Runtime).** The virtual runtime of a process $P$ is the total CPU time it has consumed, scaled by its weight relative to the default weight:

$$\text{vruntime}(P) = \sum \frac{\delta_t \cdot w_0}{w_P}$$

where $\delta_t$ is a physical time interval during which $P$ was running, $w_P$ is $P$'s weight (determined by its nice value), and $w_0$ is the weight of a process with nice value 0 (the default).
:::

A higher-priority process (lower nice value, higher weight) accumulates vruntime more slowly. A lower-priority process (higher nice value, lower weight) accumulates vruntime more quickly. The scheduler always runs the process with the **smallest vruntime**, ensuring that all processes make progress proportional to their weight.

### 5.10.5 Nice Values and Weights

Linux nice values range from $-20$ (highest priority) to $+19$ (lowest priority), with 0 as the default. CFS maps nice values to weights using a carefully chosen table:

::: definition
**Definition 5.21 (Nice-to-Weight Mapping).** The weight $w$ of a process with nice value $n$ is approximately:

$$w(n) = \frac{1024}{1.25^n}$$

The ratio of weights between adjacent nice levels is approximately 1.25 (or 10% CPU share difference per nice level). The exact weights used in the Linux kernel are:
:::

| Nice | Weight | Nice | Weight |
|---|---|---|---|
| $-20$ | 88761 | 0 | 1024 |
| $-10$ | 9548 | 5 | 335 |
| $-5$ | 3121 | 10 | 110 |
| $-1$ | 1277 | 15 | 36 |
| 0 | 1024 | 19 | 15 |

::: example
**Example 5.13 (CFS Fair Share Computation).** Two processes $A$ and $B$ compete for a single CPU. Process $A$ has nice value 0 (weight 1024), process $B$ has nice value 5 (weight 335).

Total weight: $W = 1024 + 335 = 1359$.

CPU share of $A$: $1024 / 1359 \approx 75.3\%$.

CPU share of $B$: $335 / 1359 \approx 24.7\%$.

Over a 100 ms scheduling period, $A$ receives approximately 75.3 ms and $B$ receives approximately 24.7 ms.

Vruntime accumulation per millisecond of physical time:

- $A$: $\Delta\text{vruntime} = 1 \times (1024 / 1024) = 1.0$ ms/ms
- $B$: $\Delta\text{vruntime} = 1 \times (1024 / 335) \approx 3.06$ ms/ms

So $B$'s vruntime grows 3x faster, meaning $B$ is selected less often, which is exactly the intended behaviour.
:::

### 5.10.6 The Red-Black Tree

CFS uses a **red-black tree** (a self-balancing binary search tree) to maintain all runnable processes, keyed by vruntime. The process with the smallest vruntime is always the leftmost node.

::: definition
**Definition 5.22 (CFS Red-Black Tree).** The CFS run queue is a red-black tree $T$ where each node represents a runnable process, keyed by its vruntime. The tree provides:

- $O(\log n)$ insertion when a process becomes runnable
- $O(\log n)$ removal when a process is selected to run or blocks
- $O(1)$ access to the minimum-vruntime process (the leftmost node is cached)

where $n$ is the number of runnable processes.
:::

The scheduler's decision at each scheduling point is: **run the leftmost node** (minimum vruntime). After running for a time slice, the process's vruntime is updated and the node is reinserted into the tree at its new position. If another process now has a smaller vruntime, a context switch occurs.

### 5.10.7 Time Slice Computation

CFS does not use a fixed quantum. Instead, the **scheduling period** (also called the target latency) is divided among all runnable processes proportionally to their weights:

$$\text{timeslice}(P) = \text{period} \times \frac{w_P}{\sum_i w_i}$$

The default scheduling period is:

$$\text{period} = \max\left(\text{sched\_latency}, n \times \text{sched\_min\_granularity}\right)$$

where `sched_latency` defaults to 6 ms, `sched_min_granularity` to 0.75 ms, and $n$ is the number of runnable processes. With many runnable processes, the period grows to ensure each process gets at least `sched_min_granularity` of CPU time.

> **Programmer:** **Programmer's Perspective: Tuning CFS in Linux.** CFS parameters are exposed via `/proc/sys/kernel/`:

> - `sched_latency_ns` (default 6,000,000 ns = 6 ms): The target scheduling period. Lower values improve interactivity but increase context switch overhead.
> - `sched_min_granularity_ns` (default 750,000 ns = 0.75 ms): Minimum time slice per process. Prevents excessive context switching with many runnable processes.
> - `sched_wakeup_granularity_ns` (default 1,000,000 ns = 1 ms): Minimum vruntime advantage a newly woken process must have to preempt the current process. Higher values reduce "ping-pong" switching between processes.
>
> The nice value is set per-process with `nice(2)` or `setpriority(2)`. The `renice` command adjusts it at runtime. Only root can set negative nice values (higher priority). In Go, you can set the niceness of the current process via `syscall.Setpriority()`, though this affects the entire OS thread, not a single goroutine.

### 5.10.8 Sleeper Fairness

A subtle problem arises when a process sleeps (blocks on I/O or waits) and then wakes up. While sleeping, the process's vruntime does not advance. Meanwhile, all running processes accumulate vruntime. When the sleeper wakes up, its vruntime may be far behind the other processes, giving it a temporary CPU monopoly as the scheduler tries to "make up" for the time it was asleep.

CFS handles this by capping the vruntime advantage of newly woken processes. When a process wakes up, its vruntime is set to:

$$\text{vruntime}_{\text{wakeup}} = \max\left(\text{vruntime}_{\text{old}},\ \text{min\_vruntime} - \text{sched\_latency}\right)$$

where `min_vruntime` is the smallest vruntime among all currently runnable processes. This gives the waker a bounded advantage (at most one scheduling period of catch-up) without allowing it to monopolise the CPU.

### 5.10.9 Group Scheduling (CFS Bandwidth Control)

CFS supports hierarchical scheduling via **control groups** (cgroups). Processes in the same cgroup share a collective CPU allocation. This prevents scenarios where one user running 100 processes gets 100x the CPU of another user running 1 process.

::: definition
**Definition 5.23 (CFS Group Scheduling).** CFS group scheduling organises processes into hierarchical groups via cgroups. Each group has a weight (derived from `cpu.shares`) that determines its share of CPU time relative to sibling groups. Within a group, individual processes are scheduled fairly according to their own weights. The two-level hierarchy ensures fairness both between groups and within groups.
:::

::: example
**Example 5.14 (Group Scheduling Fairness).** Two users share a system. User A runs 10 CPU-bound processes, User B runs 1 CPU-bound process.

Without cgroups: All 11 processes have equal weight. User A gets $10/11 \approx 91\%$ of the CPU, User B gets $1/11 \approx 9\%$.

With cgroups (each user in their own cgroup with equal `cpu.shares`): User A's group gets 50% of the CPU (shared among 10 processes, 5% each). User B's group gets 50% of the CPU (all for the single process). Fair.
:::

### 5.10.10 EEVDF: CFS's Successor

Linux 6.6 (October 2023) introduced **EEVDF** (Earliest Eligible Virtual Deadline First) as the default scheduler, replacing classic CFS. EEVDF extends the virtual runtime concept with per-task virtual deadlines:

::: definition
**Definition 5.24 (EEVDF Scheduler).** In EEVDF, each task has a **virtual deadline** computed as:

$$\text{vdeadline}_i = \text{vruntime}_i + \frac{\text{request\_size}}{w_i / W}$$

where $\text{request\_size}$ is the task's requested time slice and $w_i / W$ is its weight fraction. The scheduler selects the eligible task (one whose vruntime $\le$ the current virtual time) with the earliest virtual deadline. This provides better latency guarantees than classic CFS, particularly for latency-sensitive workloads like audio and interactive applications.
:::

EEVDF preserves CFS's fairness properties while providing tighter bounds on how long a task can wait before being scheduled. The `sched_latency` and `sched_min_granularity` tunables are replaced by a unified model based on virtual deadlines and time slices.

## 5.11 Real-Time Scheduling

Real-time systems must meet **deadlines**: a correct result delivered too late is a failure. Real-time scheduling theory provides algorithms with provable guarantees about deadline satisfaction.

### 5.11.1 Real-Time Task Model

::: definition
**Definition 5.25 (Periodic Real-Time Task).** A periodic real-time task $\tau_i$ is characterised by three parameters:

- $C_i$: Worst-case execution time (WCET) per invocation
- $T_i$: Period (time between successive invocations)
- $D_i$: Relative deadline (time by which each invocation must complete, typically $D_i = T_i$)

The utilisation of task $\tau_i$ is $U_i = C_i / T_i$, representing the fraction of CPU time the task requires.
:::

::: definition
**Definition 5.26 (Feasibility and Schedulability).** A set of real-time tasks is **feasible** if there exists a schedule that meets all deadlines. A scheduling algorithm is said to provide a **schedulability guarantee** if it can schedule all task sets whose total utilisation satisfies a given bound.
:::

### 5.11.2 Rate Monotonic Scheduling (RMS)

::: definition
**Definition 5.27 (Rate Monotonic Scheduling).** Rate Monotonic (RM) scheduling assigns static priorities based on period: the task with the shortest period gets the highest priority. RM is a fixed-priority, preemptive algorithm.
:::

::: theorem
**Theorem 5.8 (RM Optimality).** Among all fixed-priority scheduling algorithms for periodic tasks with $D_i = T_i$, Rate Monotonic scheduling is optimal. That is, if any fixed-priority assignment can schedule a task set, then RM can also schedule it.

*Proof sketch.* Consider any feasible fixed-priority assignment where task $\tau_i$ (period $T_i$) has higher priority than task $\tau_j$ (period $T_j$) but $T_i > T_j$ (i.e., the shorter-period task has lower priority). We can swap their priorities. The shorter-period task $\tau_j$ now has higher priority and generates less interference on $\tau_i$ per unit time (since $C_j$ arrives more frequently but in smaller chunks relative to $T_i$). A careful analysis shows that the swapped assignment is also feasible. Repeated swaps converge to the RM assignment. $\square$
:::

::: theorem
**Theorem 5.9 (RM Schedulability Bound).** A set of $n$ periodic tasks with $D_i = T_i$ is schedulable under Rate Monotonic scheduling if the total utilisation satisfies:

$$U = \sum_{i=1}^{n} \frac{C_i}{T_i} \le n\left(2^{1/n} - 1\right)$$

The bound $n(2^{1/n} - 1)$ decreases with $n$:

| $n$ | Bound |
|---|---|
| 1 | 1.000 |
| 2 | 0.828 |
| 3 | 0.780 |
| 4 | 0.757 |
| 5 | 0.743 |
| $\to \infty$ | $\ln 2 \approx 0.693$ |

The bound is sufficient but not necessary: many task sets with $U > n(2^{1/n} - 1)$ are still schedulable under RM, as long as $U \le 1$.
:::

::: example
**Example 5.15 (RM Schedulability Test).** Consider three tasks:

| Task | $C_i$ | $T_i$ | $U_i$ |
|---|---|---|---|
| $\tau_1$ | 1 | 4 | 0.250 |
| $\tau_2$ | 2 | 6 | 0.333 |
| $\tau_3$ | 3 | 12 | 0.250 |

Total utilisation: $U = 0.250 + 0.333 + 0.250 = 0.833$.

RM bound for $n = 3$: $3(2^{1/3} - 1) = 3(1.2599 - 1) = 0.780$.

Since $U = 0.833 > 0.780$, the sufficient condition is not met. However, $U < 1$, so the task set might still be schedulable. We must perform an exact analysis (response time analysis or time-demand analysis) to determine feasibility.

**Time-demand analysis for $\tau_3$** (lowest priority): The time demand at time $t$ is:

$$W_3(t) = C_3 + \left\lceil \frac{t}{T_1} \right\rceil C_1 + \left\lceil \frac{t}{T_2} \right\rceil C_2 = 3 + \left\lceil \frac{t}{4} \right\rceil \cdot 1 + \left\lceil \frac{t}{6} \right\rceil \cdot 2$$

We need to find the smallest $t \le T_3 = 12$ such that $W_3(t) \le t$:

- $t = 12$: $W_3(12) = 3 + 3 \cdot 1 + 2 \cdot 2 = 10 \le 12$. Schedulable.
:::

### 5.11.3 Earliest Deadline First (EDF)

::: definition
**Definition 5.28 (Earliest Deadline First).** EDF scheduling is a dynamic-priority algorithm that assigns priorities based on absolute deadlines: the task whose deadline is nearest has the highest priority. At each scheduling point, EDF runs the ready task with the earliest absolute deadline.
:::

::: theorem
**Theorem 5.10 (EDF Optimality).** EDF is optimal among all uniprocessor scheduling algorithms for preemptive scheduling of periodic and aperiodic tasks. If a set of tasks is feasible (i.e., there exists any schedule that meets all deadlines), then EDF will also meet all deadlines.
:::

::: theorem
**Theorem 5.11 (EDF Schedulability).** A set of $n$ periodic tasks with $D_i = T_i$ is schedulable under EDF if and only if:

$$U = \sum_{i=1}^{n} \frac{C_i}{T_i} \le 1$$

This is both a necessary and sufficient condition, meaning EDF can utilise the processor up to 100% while still meeting all deadlines --- a significant improvement over the RM bound of $\ln 2 \approx 69.3\%$.

*Proof.* The necessity is clear: if $U > 1$, the tasks require more CPU time than is available, so no schedule can meet all deadlines. For sufficiency, assume $U \le 1$ and suppose for contradiction that EDF misses a deadline at time $t^*$ for some task instance. Consider the busy interval $[0, t^*]$. The total demand in this interval is $\sum_{i} \lfloor t^* / T_i \rfloor \cdot C_i \le t^* \cdot U \le t^*$. Since the total demand does not exceed the available time, EDF (which always works on the most urgent task) must have completed all work by $t^*$, contradicting the assumption. $\square$
:::

::: example
**Example 5.16 (EDF vs RM).** Using the same tasks from Example 5.15 ($U = 0.833$):

Under EDF, the task set is schedulable because $U = 0.833 \le 1$. Under RM, the sufficient condition ($U \le 0.780$) fails, though the exact analysis showed it was still schedulable. For task sets with $0.693 < U \le 1.0$, EDF guarantees schedulability while RM may or may not succeed depending on the specific task parameters.
:::

### 5.11.4 Linux SCHED_DEADLINE

Linux 3.14 (2014) introduced `SCHED_DEADLINE`, the first mainstream implementation of EDF with CBS (Constant Bandwidth Server) in a general-purpose operating system. A process scheduled with `SCHED_DEADLINE` specifies three parameters:

- **Runtime** ($C$): Maximum execution time per period
- **Deadline** ($D$): Relative deadline from the start of each period
- **Period** ($T$): The period of activation

```c
#define _GNU_SOURCE
#include <sched.h>
#include <linux/sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

struct sched_attr {
    unsigned int size;
    unsigned int sched_policy;
    unsigned long long sched_flags;
    int sched_nice;
    unsigned int sched_priority;
    unsigned long long sched_runtime;
    unsigned long long sched_deadline;
    unsigned long long sched_period;
};

int main(void) {
    struct sched_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.size = sizeof(attr);
    attr.sched_policy = 6;  /* SCHED_DEADLINE */
    attr.sched_runtime  =  5000000;  /* 5 ms */
    attr.sched_deadline = 10000000;  /* 10 ms */
    attr.sched_period   = 10000000;  /* 10 ms */
    
    int ret = syscall(SYS_sched_setattr, 0, &attr, 0);
    if (ret < 0) {
        perror("sched_setattr");
        return 1;
    }
    
    printf("Running with SCHED_DEADLINE: C=5ms, D=10ms, T=10ms\n");
    
    /* Real-time periodic task */
    for (int i = 0; i < 100; i++) {
        /* Do computation (must complete within 5 ms) */
        volatile long sum = 0;
        for (long j = 0; j < 1000000; j++) sum += j;
        
        /* Yield until next period */
        sched_yield();
    }
    
    return 0;
}
```

`SCHED_DEADLINE` has the highest priority among all Linux scheduling classes, even above `SCHED_FIFO`. The kernel performs admission control: a new `SCHED_DEADLINE` task is rejected if its acceptance would cause the total utilisation to exceed the CPU capacity. This prevents deadline misses due to overcommitment.

### 5.11.5 Windows Thread Scheduling

Windows uses a priority-based, preemptive scheduler with 32 priority levels:

- **Real-time priorities** (16--31): For time-critical threads. Not true hard real-time, but highest scheduling priority.
- **Variable priorities** (1--15): For normal threads. The scheduler dynamically adjusts priorities based on behaviour.
- **Idle priority** (0): Only runs when no other thread is ready.

Windows dynamically boosts thread priority in several situations:

- **Foreground boost**: Threads in the foreground window receive a priority boost (typically +2)
- **I/O completion boost**: A thread completing an I/O operation receives a temporary boost (varies by device: +1 for disk, +2 for serial, +6 for keyboard, +8 for sound)
- **Starvation prevention**: The "balance set manager" periodically boosts starved threads to priority 15 for one quantum

The Windows quantum defaults to 2 clock ticks (approximately 30 ms on client systems) for foreground threads and 12 clock ticks (approximately 180 ms) for server workloads, controllable via the "Processor scheduling" setting in System Properties.

## 5.12 Multiprocessor Scheduling

When a system has multiple CPUs, scheduling becomes more complex. The scheduler must decide not only **when** to run each process but also **where** (on which CPU).

### 5.12.1 Processor Affinity

::: definition
**Definition 5.29 (Processor Affinity).** Processor affinity is the tendency to keep a process running on the same CPU across successive scheduling events. **Soft affinity** means the scheduler prefers to keep a process on the same CPU but may migrate it for load balancing. **Hard affinity** means the process is restricted to a specific set of CPUs and cannot be migrated.
:::

Processor affinity matters because of caches: when a process runs on a CPU, its working set is loaded into that CPU's private L1 and L2 caches. Migrating the process to a different CPU invalidates these cached lines, causing a burst of cache misses on the new CPU (a **cold start**). The cost of migration can be tens of microseconds for L2 and hundreds of microseconds for L3.

On Linux, hard affinity is set via `sched_setaffinity()`:

```c
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>

int main(void) {
    cpu_set_t mask;
    CPU_ZERO(&mask);
    CPU_SET(0, &mask);  /* Pin to CPU 0 */
    CPU_SET(1, &mask);  /* Also allow CPU 1 */
    
    if (sched_setaffinity(0, sizeof(mask), &mask) == -1) {
        perror("sched_setaffinity");
        return 1;
    }
    
    printf("Process pinned to CPUs 0 and 1\n");
    
    /* Verify */
    CPU_ZERO(&mask);
    sched_getaffinity(0, sizeof(mask), &mask);
    for (int i = 0; i < CPU_SETSIZE; i++) {
        if (CPU_ISSET(i, &mask)) {
            printf("  CPU %d: allowed\n", i);
        }
    }
    
    return 0;
}
```

### 5.12.2 Load Balancing

The scheduler must distribute work across CPUs to maximise throughput and minimise response time. Two approaches:

**Push migration**: A kernel thread periodically checks the load on each CPU and migrates processes from overloaded CPUs to underloaded ones. Linux's load balancer runs at regular intervals (controlled by `sched_migration_cost_ns`, default 500 microseconds).

**Pull migration (work stealing)**: An idle CPU's scheduler "steals" a process from a busy CPU's run queue. This is reactive and low-overhead: no work is done unless a CPU is idle.

::: definition
**Definition 5.30 (Work Stealing).** In a work-stealing scheduler, each CPU maintains a local run queue (often a deque). When a CPU's local queue is empty, it selects a victim CPU (typically at random) and steals half of the victim's queued work. Work stealing achieves $O(P \cdot T_\infty + T_1 / P)$ expected time for a computation with work $T_1$ and span $T_\infty$ on $P$ processors.
:::

### 5.12.3 NUMA-Aware Scheduling

On Non-Uniform Memory Access (NUMA) systems, memory access latency depends on which CPU accesses which memory bank. Each CPU has "local" memory (fast, ~80 ns) and "remote" memory (slow, ~150 ns). NUMA-aware scheduling keeps processes near their data:

- The scheduler prefers to run a process on the NUMA node where most of its memory resides
- Linux uses automatic NUMA balancing (`numa_balancing` sysctl): the kernel periodically unmaps pages, observes where page faults occur, and migrates pages to the NUMA node of the accessing CPU
- Explicit control via `numactl`, `mbind()`, and `set_mempolicy()`

### 5.12.4 Gang Scheduling

::: definition
**Definition 5.31 (Gang Scheduling).** Gang scheduling (also called co-scheduling) schedules all threads of a parallel application simultaneously across different processors. If the application has $k$ threads and the system has $P \ge k$ processors, all $k$ threads run at the same time. If $P < k$, the threads are divided into gangs that are context-switched together.
:::

Gang scheduling is particularly important for parallel applications where threads communicate frequently (e.g., via shared memory barriers). If threads are scheduled independently, a thread waiting for a synchronisation partner that is not currently running wastes CPU cycles spinning or blocking. Gang scheduling eliminates this **synchronisation waste**.

> **Programmer:** **Programmer's Perspective: Linux sched_setscheduler() and Go's GOMAXPROCS.** Linux exposes three scheduling policies through `sched_setscheduler()`:

> - `SCHED_OTHER` (default, CFS): Fair scheduling for normal processes. Priority is controlled by nice value ($-20$ to $+19$).
> - `SCHED_FIFO`: Real-time FIFO. The highest-priority SCHED_FIFO process runs until it blocks or yields. Dangerous if misused --- a runaway SCHED_FIFO process can lock out all normal processes.
> - `SCHED_RR`: Real-time Round-Robin. Like SCHED_FIFO but with a time quantum (default 100 ms). Processes at the same priority level are Round-Robin scheduled.
>
> Real-time priorities range from 1 (lowest) to 99 (highest), and all real-time processes have priority over all SCHED_OTHER processes. Setting real-time scheduling requires `CAP_SYS_NICE` capability or root.
>
> In Go, `runtime.GOMAXPROCS(n)` sets the number of OS threads (Ps) that can execute goroutines simultaneously. This is not a traditional scheduler setting --- it controls the degree of parallelism in the Go runtime's M:N scheduler. Since Go 1.5, the default is `runtime.NumCPU()`. Setting `GOMAXPROCS=1` serialises all goroutine execution (useful for debugging race conditions). Go's work-stealing scheduler balances goroutines across Ps automatically, but you can use `runtime.LockOSThread()` to pin a goroutine to a specific OS thread for latency-sensitive work or CGo calls.

### 5.12.5 Heterogeneous Multiprocessor Scheduling

Modern mobile and laptop processors use **heterogeneous architectures** (e.g., ARM big.LITTLE, Intel's hybrid P-core/E-core designs) where cores have different performance and power characteristics.

::: definition
**Definition 5.32 (Heterogeneous Multiprocessor Scheduling).** In a heterogeneous multiprocessor system, cores differ in performance, power consumption, or both. The scheduler must decide not only when to run a task but also on which type of core. High-performance cores ("big" or "P-cores") provide fast execution at higher power consumption, while efficient cores ("LITTLE" or "E-cores") provide lower performance at reduced power. The goal is to match task requirements to core capabilities: interactive and latency-sensitive tasks run on big cores; background and throughput-oriented tasks run on little cores.
:::

Linux's **Energy Aware Scheduling** (EAS), introduced in kernel 5.0, integrates with CFS to make energy-efficient placement decisions. EAS uses an energy model (describing the power consumption of each CPU at each frequency) to find the most energy-efficient core for each newly woken task, while respecting performance constraints.

On Intel hybrid processors (Alder Lake and later), the **Thread Director** provides hardware hints to the scheduler about which core type is best for the current workload. The Linux kernel's `intel_thread_director` driver communicates these hints to the scheduler via the `sched_asym_prefer` mechanism.

## 5.13 Scheduling in Practice: A Comparison

| Algorithm | Type | Optimal? | Starvation? | Overhead | Use Case |
|---|---|---|---|---|---|
| FCFS | Non-preemptive | No | No | $O(1)$ | Batch systems |
| SJF | Non-preemptive | Yes (avg wait) | Yes | $O(n \log n)$ | Short-job systems |
| SRTF | Preemptive | Yes (avg wait) | Yes | $O(n \log n)$ | Theoretical |
| Round-Robin | Preemptive | No | No | $O(1)$ | Time-sharing |
| Priority | Either | N/A | Yes | $O(n)$ or $O(\log n)$ | Mixed systems |
| MLFQ | Preemptive | Heuristic | With boosting, no | $O(1)$ per level | General-purpose |
| CFS | Preemptive | Fair | No | $O(\log n)$ | Linux default |
| RM | Preemptive | Yes (fixed-pri) | N/A | $O(n)$ | Hard real-time |
| EDF | Preemptive | Yes (all) | N/A | $O(n \log n)$ | Hard real-time |

::: theorem
**Theorem 5.12 (No Universally Optimal Scheduler).** There is no single scheduling algorithm that simultaneously optimises all scheduling criteria (throughput, turnaround time, waiting time, response time, fairness) for all possible workloads. For any algorithm $A$ and any set of criteria weights, there exists a workload $W$ for which some other algorithm $B$ outperforms $A$ on the weighted objective.
:::

This result is a consequence of the fundamental trade-off between throughput (favouring long, batch-oriented quanta) and responsiveness (favouring short, interactive quanta). Practical schedulers like MLFQ and CFS achieve a good compromise by adapting their behaviour to the observed workload.

> **Programmer:** **Programmer's Perspective: Go's Work-Stealing Scheduler.** Go's runtime scheduler implements a variant of work-stealing that is tailored to the goroutine model. Each P (processor) has a local run queue (a lock-free, bounded deque of 256 entries) and there is a single global run queue (mutex-protected). The scheduling algorithm for `findrunnable()` proceeds as follows:

> 1. Check the local run queue (lock-free pop from head).
> 2. Every 61st scheduling tick, check the global queue to prevent starvation.
> 3. Check the network poller for goroutines unblocked by I/O readiness.
> 4. Attempt to steal from another random P's local queue (steal half, rounded up).
> 5. If all else fails, park the M (OS thread) and wait for work.
>
> The "steal half" strategy ensures that stolen work is substantial enough to amortise the cost of the steal. The 61-tick global queue check is a prime number to avoid phase-locked behaviour with periodic goroutine patterns. This design gives $O(1)$ amortised scheduling for the common case (local queue non-empty) and $O(P)$ worst case for stealing (must probe all Ps), where $P$ is GOMAXPROCS.

## 5.14 Scheduling Algorithm Evaluation

How do we choose the right scheduling algorithm for a given system? Several evaluation methods exist, each with different trade-offs between accuracy and cost.

### 5.14.1 Deterministic Modelling

Deterministic modelling (also called **analytic evaluation**) uses a predetermined workload and computes the exact schedule for each algorithm. This is the method used in all our examples above: given specific arrival times and burst lengths, we compute waiting times, turnaround times, and response times exactly.

::: example
**Example 5.17 (Comprehensive Algorithm Comparison).** Consider the following workload:

| Process | Arrival | Burst | Priority |
|---|---|---|---|
| $P_1$ | 0 | 8 | 3 |
| $P_2$ | 1 | 4 | 1 |
| $P_3$ | 2 | 2 | 4 |
| $P_4$ | 3 | 1 | 2 |
| $P_5$ | 4 | 5 | 5 |

Results summary (lower is better):

| Algorithm | Avg Wait | Avg Turnaround | Avg Response |
|---|---|---|---|
| FCFS | 7.2 | 11.2 | 7.2 |
| SJF (non-preemptive) | 4.6 | 8.6 | 4.6 |
| SRTF | 3.2 | 7.2 | 1.8 |
| RR ($q = 2$) | 6.6 | 10.6 | 2.2 |
| Priority (preemptive) | 5.0 | 9.0 | 3.0 |

SRTF provides the best average waiting time (as expected from Theorem 5.2), but RR provides competitive response time with much simpler implementation and no starvation risk.
:::

### 5.14.2 Queueing Models

For analytical results, we can model the system as a queueing network. The simplest model treats the CPU as a single server with Poisson arrivals (rate $\lambda$) and exponentially distributed service times (rate $\mu$):

::: theorem
**Theorem 5.13 (Little's Law).** For any stable queueing system, the long-run average number of customers in the system $L$, the long-run average arrival rate $\lambda$, and the long-run average time a customer spends in the system $W$ are related by:

$$L = \lambda \cdot W$$

This holds regardless of the arrival distribution, service distribution, or scheduling discipline. Applied to CPU scheduling: if the average number of processes in the ready queue is $L_q$ and the average arrival rate is $\lambda$, then the average waiting time is $W_q = L_q / \lambda$.
:::

For an M/M/1 queue (Poisson arrivals, exponential service, single server), the utilisation $\rho = \lambda / \mu$, and the average waiting time is:

$$W_q = \frac{\rho}{\mu(1 - \rho)}$$

This diverges as $\rho \to 1$, reflecting the reality that a fully loaded CPU has infinite waiting times.

### 5.14.3 Simulation

The most flexible evaluation method is discrete-event simulation. A simulator maintains a clock, a set of events (process arrivals, burst completions, I/O completions), and the state of the scheduling algorithm. It processes events in chronological order, updating the schedule and collecting statistics.

```c
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

/* Simple FCFS simulator */
typedef struct {
    int arrival;
    int burst;
} Job;

int compare_arrival(const void *a, const void *b) {
    return ((Job *)a)->arrival - ((Job *)b)->arrival;
}

void simulate_fcfs(Job jobs[], int n) {
    qsort(jobs, n, sizeof(Job), compare_arrival);
    
    int time = 0;
    double total_wait = 0, total_turnaround = 0;
    
    for (int i = 0; i < n; i++) {
        if (time < jobs[i].arrival) {
            time = jobs[i].arrival;
        }
        int wait = time - jobs[i].arrival;
        int turnaround = wait + jobs[i].burst;
        total_wait += wait;
        total_turnaround += turnaround;
        time += jobs[i].burst;
    }
    
    printf("FCFS: avg_wait=%.2f, avg_turnaround=%.2f\n",
           total_wait / n, total_turnaround / n);
}

int main(void) {
    srand(time(NULL));
    
    int n = 1000;
    Job *jobs = malloc(n * sizeof(Job));
    
    /* Generate random workload: Poisson arrivals, exponential bursts */
    int arrival = 0;
    for (int i = 0; i < n; i++) {
        arrival += rand() % 10 + 1;  /* Inter-arrival: 1-10 */
        jobs[i].arrival = arrival;
        jobs[i].burst = rand() % 20 + 1;  /* Burst: 1-20 */
    }
    
    simulate_fcfs(jobs, n);
    
    free(jobs);
    return 0;
}
```

Simulation allows evaluation with realistic workload distributions (e.g., heavy-tailed burst distributions, bursty arrivals) that are difficult to analyse mathematically.

### 5.14.4 Implementation and Measurement

The ultimate evaluation is to implement the algorithm in a real operating system and measure its performance with actual workloads. Linux provides several tools for this:

- **`perf sched`**: Records and analyses scheduling events (context switches, migration, latency)
- **`schedstat`**: Per-CPU scheduling statistics in `/proc/schedstat`
- **`/proc/<pid>/sched`**: Per-process scheduling statistics (wait time, run time, switches)
- **`trace-cmd`**: Frontend for `ftrace` kernel tracing, including the `sched` tracer

```text
$ perf sched record -- sleep 10
$ perf sched latency
-------------------------------------------------
  Task              |   Runtime   |  Switches  | Avg delay |
-------------------------------------------------
  firefox       :  4218.432 ms  |     3847   | 0.312 ms  |
  Xorg          :  1847.221 ms  |     5821   | 0.087 ms  |
  pulseaudio    :   127.894 ms  |      842   | 0.041 ms  |
  bash          :    34.102 ms  |       12   | 2.341 ms  |
-------------------------------------------------
```

## Exercises

1. **Exercise 5.1.** Five processes arrive at the following times with the given burst lengths:

   | Process | Arrival | Burst |
   |---|---|---|
   | $P_1$ | 0 | 10 |
   | $P_2$ | 1 | 5 |
   | $P_3$ | 3 | 2 |
   | $P_4$ | 5 | 8 |
   | $P_5$ | 6 | 4 |

   Compute the average waiting time and average turnaround time under: (a) FCFS, (b) non-preemptive SJF, (c) SRTF, and (d) Round-Robin with $q = 3$. Draw the Gantt chart for each. Which algorithm gives the best average waiting time, and why?

2. **Exercise 5.2.** Prove that for $n$ periodic real-time tasks, the Rate Monotonic utilisation bound $n(2^{1/n} - 1)$ converges to $\ln 2$ as $n \to \infty$. *Hint*: Use the Taylor expansion of $2^{1/n} = e^{(\ln 2)/n}$ and the limit $\lim_{n \to \infty} n(e^{x/n} - 1) = x$.

3. **Exercise 5.3.** Consider two processes running under CFS on a single-core system. Process $A$ has nice value $0$ (weight 1024) and process $B$ has nice value $10$ (weight 110). Compute: (a) the CPU share of each process, (b) the time slice of each process assuming a scheduling period of 6 ms, (c) how much physical time must elapse for each process to accumulate 1 ms of vruntime. If both processes are CPU-bound, describe the scheduling pattern over a 60 ms window.

4. **Exercise 5.4.** An MLFQ has three queues with quanta 4 ms, 8 ms, and 16 ms. A process $P$ arrives and exhibits the following CPU burst pattern: 3 ms, I/O, 6 ms, I/O, 20 ms. Trace $P$'s movement through the queues under: (a) basic MLFQ rules (Rule 4a: demote on full quantum), (b) accounting-based MLFQ (demote when total CPU time at a level exceeds the quantum). In which case does $P$ receive better response time, and why?

5. **Exercise 5.5.** Three periodic tasks have parameters $\tau_1 = (C_1 = 1, T_1 = 5)$, $\tau_2 = (C_2 = 2, T_2 = 8)$, $\tau_3 = (C_3 = 4, T_3 = 20)$. Determine whether this task set is schedulable under: (a) Rate Monotonic scheduling (using both the utilisation bound and exact response time analysis), (b) EDF scheduling. Draw the schedule for both algorithms over the hyperperiod $\text{lcm}(5, 8, 20) = 40$ time units.

6. **Exercise 5.6.** The priority inversion problem can lead to unbounded blocking under basic priority scheduling. Describe a concrete scenario with three processes $H$ (high priority), $M$ (medium), and $L$ (low) where $H$ is blocked for an arbitrarily long time due to priority inversion. Then show how the Priority Inheritance Protocol bounds $H$'s blocking time to the length of $L$'s critical section. Finally, explain why Priority Ceiling Protocol provides an even stronger guarantee (at most one blocking per resource).

7. **Exercise 5.7.** Write a C program that creates two processes: one CPU-bound (infinite loop incrementing a counter) and one I/O-bound (repeatedly writing to `/dev/null` with small writes). Use `sched_setscheduler()` to set the CPU-bound process to `SCHED_RR` with priority 50 and the I/O-bound process to `SCHED_FIFO` with priority 60. Observe the behaviour using `top` or `htop`. Then swap the priorities and observe again. Explain the difference in terms of Linux's real-time scheduling semantics. *Note*: this requires root or `CAP_SYS_NICE`.
