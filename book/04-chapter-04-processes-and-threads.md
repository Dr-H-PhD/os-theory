# Chapter 4: Processes and Threads

A running program is not the same thing as the file sitting on disk. The moment the operating system loads an executable into memory, allocates resources, and begins executing its instructions, it creates something fundamentally new: a **process**. This chapter explores the process abstraction --- how operating systems create, manage, and destroy the units of execution that make modern computing possible. We then turn to threads, the lighter-weight units of execution that share a process's address space, and examine the models that map application-level concurrency onto kernel resources.

## 4.1 Program vs Process

A **program** is a passive entity: a file containing machine instructions, data initialisers, and metadata stored on disk. A **process** is the active entity that arises when the operating system loads that program into memory and begins executing it. The distinction is subtle but essential.

::: definition
**Definition 4.1 (Program).** A program is a static sequence of instructions and associated data, stored as an executable file in a filesystem. It is a passive entity that occupies no CPU time and holds no runtime state.
:::

::: definition
**Definition 4.2 (Process).** A process is an instance of a program in execution, together with all state necessary for its continued execution: the current values of the program counter, registers, stack, heap, open file descriptors, and associated kernel data structures.
:::

The same program can give rise to multiple processes. Consider a web server: the executable `/usr/bin/nginx` is a single program, but the operating system may spawn dozens of worker processes from that same binary. Each process has its own address space, its own set of open file descriptors, and its own position in the instruction stream.

::: example
**Example 4.1 (Multiple Instances).** Running the command `python3 script.py` twice in separate terminals creates two distinct processes. Each has its own PID, its own copy of the Python interpreter's heap, and its own program counter. Modifications to a variable in one process have no effect on the other --- they occupy entirely separate address spaces.
:::

The key resources that define a process include:

- **Address space**: The virtual memory layout (text, data, heap, stack segments)
- **Program counter (PC)**: The address of the next instruction to execute
- **Processor registers**: General-purpose registers, stack pointer, frame pointer
- **Open files**: File descriptor table mapping integers to kernel file structures
- **Credentials**: User ID (UID), group ID (GID), effective permissions
- **Signal state**: Pending signals, signal handlers, signal masks
- **Scheduling attributes**: Priority, scheduling class, CPU time consumed

## 4.2 Process States

A process does not simply run from start to finish without interruption. Over its lifetime, it transitions through a series of well-defined states as it competes for CPU time, waits for I/O, and interacts with the scheduler.

::: definition
**Definition 4.3 (Five-State Process Model).** The five-state process model defines the following states:

1. **New**: The process is being created; the kernel is allocating data structures and loading the executable image.
2. **Ready**: The process is loaded in memory and waiting to be assigned to a CPU by the scheduler.
3. **Running**: The process's instructions are being executed on a CPU core.
4. **Waiting** (Blocked): The process cannot proceed until some external event occurs (I/O completion, signal arrival, lock acquisition).
5. **Terminated**: The process has finished execution; the kernel retains its exit status until collected by the parent.
:::

The transitions between these states follow strict rules:

```text
                    ┌──────────────┐
                    │     New      │
                    └──────┬───────┘
                           │ admitted
                           ▼
          ┌────────────────────────────────┐
  timeout │                                │ scheduled
  ┌───────┤           Ready                │◄──────────┐
  │       │                                │           │
  │       └────────────────┬───────────────┘           │
  │                        │ dispatch                  │
  │                        ▼                           │
  │       ┌────────────────────────────────┐           │
  └──────►│          Running               ├───────────┘
          │                                │ I/O or event wait
          └─────────┬──────────┬───────────┘
                    │          │
              exit  │          ▼
                    │  ┌───────────────────┐
                    │  │     Waiting       │
                    │  │    (Blocked)      │
                    │  └───────────────────┘
                    ▼
          ┌────────────────────────────────┐
          │         Terminated             │
          └────────────────────────────────┘
```

The critical transitions are:

| Transition | Trigger | Direction |
|---|---|---|
| New $\to$ Ready | Process admitted by the kernel | Irreversible |
| Ready $\to$ Running | Scheduler dispatches process to CPU | May recur |
| Running $\to$ Ready | Timer interrupt (preemption) | May recur |
| Running $\to$ Waiting | Process initiates I/O or blocks on synchronisation | May recur |
| Waiting $\to$ Ready | I/O completes or event occurs | May recur |
| Running $\to$ Terminated | Process calls `exit()` or receives fatal signal | Irreversible |

::: example
**Example 4.2 (Process State Transitions).** Consider a process that reads a file. Initially in the **Running** state, it issues a `read()` system call. The kernel places the process in the **Waiting** state while the disk controller fetches the requested block. When the DMA transfer completes and the disk raises an interrupt, the interrupt handler moves the process to the **Ready** queue. The scheduler eventually dispatches it back to **Running**, where the `read()` call returns with the data.
:::

### 4.2.1 Zombie and Orphan Processes

Two additional states arise from the parent-child relationship in Unix-like systems.

A **zombie process** has terminated but its parent has not yet called `wait()` to collect its exit status. The kernel must retain the process's entry in the process table (PID, exit code, resource usage statistics) until the parent retrieves it. Zombies consume no CPU or memory beyond their process table entry, but they do consume a PID --- and PID space is finite.

An **orphan process** is one whose parent has terminated before it. On Linux, orphans are re-parented to the `init` process (PID 1) or the nearest subreaper (set via `prctl(PR_SET_CHILD_SUBREAPER)`). The adopting process is responsible for calling `wait()` on the orphan's behalf.

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

int main(void) {
    pid_t pid = fork();
    
    if (pid == 0) {
        /* Child process */
        printf("Child PID: %d, Parent PID: %d\n", getpid(), getppid());
        sleep(2);
        printf("Child exiting (will become zombie if parent doesn't wait)\n");
        exit(0);
    } else {
        /* Parent process */
        printf("Parent PID: %d, Child PID: %d\n", getpid(), pid);
        
        /* Not calling wait() immediately --- child becomes zombie */
        sleep(5);
        
        /* Reap the zombie */
        int status;
        waitpid(pid, &status, 0);
        printf("Reaped child, exit status: %d\n", WEXITSTATUS(status));
    }
    
    return 0;
}
```

## 4.3 Process Memory Layout

Before examining the Process Control Block, it is essential to understand the memory layout of a process. Each process has a virtual address space divided into distinct segments:

::: definition
**Definition 4.4 (Process Address Space).** The virtual address space of a process on a typical Unix system consists of the following segments, listed from low to high virtual addresses:

1. **Text segment**: The executable machine code, loaded from the ELF binary. Read-only and shared among all processes running the same program.
2. **Data segment**: Initialised global and static variables. Read-write.
3. **BSS segment** (Block Started by Symbol): Uninitialised global and static variables. Zero-filled at program start.
4. **Heap**: Dynamically allocated memory (via `malloc()`, `mmap()`). Grows upward from low addresses.
5. **Memory-mapped region**: Shared libraries, memory-mapped files, anonymous mappings. Located between heap and stack.
6. **Stack**: Function call frames, local variables, return addresses. Grows downward from high addresses.
:::

On a 64-bit Linux system with the default address space layout:

```text
High addresses
┌───────────────────────────────────┐ 0x7FFF_FFFF_FFFF
│            Kernel Space           │ (not accessible from user mode)
├───────────────────────────────────┤ 0x7FFF_FFFF_F000
│              Stack                │ grows downward
│              │                    │
│              ▼                    │
│                                   │
│         (unmapped gap)            │
│                                   │
│              ▲                    │
│              │                    │
│      Memory-mapped region         │ shared libraries, mmap
│                                   │
│              ▲                    │
│              │                    │
│             Heap                  │ grows upward
├───────────────────────────────────┤
│       BSS (uninitialised)         │
├───────────────────────────────────┤
│       Data (initialised)          │
├───────────────────────────────────┤
│       Text (code, read-only)      │
└───────────────────────────────────┘ 0x0000_0040_0000
Low addresses
```

The exact layout can be examined via `/proc/<pid>/maps`:

```text
$ cat /proc/self/maps
00400000-00452000 r-xp 00000000 08:01 131074  /bin/cat       (text)
00651000-00652000 r--p 00051000 08:01 131074  /bin/cat       (rodata)
00652000-00653000 rw-p 00052000 08:01 131074  /bin/cat       (data)
01a3a000-01a5b000 rw-p 00000000 00:00 0       [heap]
7f2a1b000000-7f2a1b021000 rw-p 00000000 00:00 0              (anon mmap)
7f2a1b6e2000-7f2a1b8a7000 r-xp 00000000 08:01 393219 /lib/libc.so.6
7ffe7e5c0000-7ffe7e5e1000 rw-p 00000000 00:00 0       [stack]
```

The kernel uses **Address Space Layout Randomisation** (ASLR) to randomise the base addresses of the stack, heap, and memory-mapped regions. This makes it harder for attackers to predict the location of code or data, mitigating buffer overflow and return-oriented programming (ROP) attacks.

::: example
**Example 4.3 (Inspecting Process Memory in C).** The following program prints the addresses of its own memory segments:

```c
#include <stdio.h>
#include <stdlib.h>

int global_init = 42;        /* Data segment */
int global_uninit;            /* BSS segment */

int main(void) {
    int local_var = 10;       /* Stack */
    int *heap_var = malloc(sizeof(int));  /* Heap */
    *heap_var = 20;
    
    printf("Text  (main):     %p\n", (void *)main);
    printf("Data  (global):   %p\n", (void *)&global_init);
    printf("BSS   (uninit):   %p\n", (void *)&global_uninit);
    printf("Heap  (malloc):   %p\n", (void *)heap_var);
    printf("Stack (local):    %p\n", (void *)&local_var);
    printf("Lib   (printf):   %p\n", (void *)printf);
    
    free(heap_var);
    return 0;
}
```

Typical output on x86-64 Linux (with ASLR):

```text
Text  (main):     0x55a3e4401169
Data  (global):   0x55a3e4404010
BSS   (uninit):   0x55a3e4404014
Heap  (malloc):   0x55a3e53a62a0
Stack (local):    0x7ffd2a3b1e4c
Lib   (printf):   0x7f8c2b4560f0
```

Note the large gaps between segments: text/data near `0x55...`, heap slightly above, libraries and stack near `0x7f...`. ASLR randomises these base addresses on each execution.
:::

## 4.4 The Process Control Block

Every process in the system is represented within the kernel by a data structure called the **Process Control Block** (PCB). This structure contains all the information the operating system needs to manage the process.

::: definition
**Definition 4.5 (Process Control Block).** The Process Control Block (PCB) is a kernel data structure that stores the complete execution context of a process. It serves as the repository for all information needed to suspend a process, switch to another, and later resume the original process exactly where it left off.
:::

The PCB typically contains:

**Identification**

- Process ID (PID): A unique integer identifying the process
- Parent process ID (PPID): The PID of the process that created this one
- User ID (UID) and Group ID (GID): Credentials for access control

**CPU State (Register Context)**

- Program counter (PC / RIP on x86-64): Address of next instruction
- Stack pointer (SP / RSP): Top of the process's kernel or user stack
- General-purpose registers: RAX, RBX, RCX, ... (on x86-64)
- Floating-point / SIMD registers: XMM, YMM, ZMM registers
- Status register (RFLAGS): Condition codes, interrupt enable flag

**Memory Management**

- Page table base register (CR3 on x86-64): Points to the process's page table hierarchy
- Virtual memory area (VMA) list: Describes each mapped region (text, data, heap, stack, mmap'd files)
- Memory limits: Maximum heap size, stack size, total virtual memory

**Scheduling Information**

- Process state: Running, Ready, Waiting, etc.
- Priority: Static and dynamic priority values
- Scheduling class: SCHED_NORMAL, SCHED_FIFO, SCHED_RR, etc.
- CPU time consumed: User time, system time, cumulative children times
- Processor affinity mask: Which CPUs this process may run on

**I/O and File State**

- File descriptor table: Array of pointers to kernel file structures
- Current working directory: Reference to the directory inode
- Root directory: For chroot environments

**Signal State**

- Pending signals: Bitmask of signals delivered but not yet handled
- Signal handlers: Function pointers for each signal number
- Signal mask: Which signals are currently blocked

On Linux, the PCB is the `task_struct` structure, defined in `include/linux/sched.h`. It is one of the largest structures in the kernel, containing over 200 fields and weighing approximately 6 KB per process.

::: example
**Example 4.4 (Examining Linux task_struct).** Key fields of the Linux `task_struct` include:

```c
struct task_struct {
    volatile long            state;           /* process state */
    void                    *stack;           /* kernel stack pointer */
    unsigned int             flags;           /* process flags (PF_*) */
    int                      prio;            /* dynamic priority */
    int                      static_prio;     /* static priority */
    struct sched_entity      se;              /* CFS scheduling entity */
    struct mm_struct        *mm;              /* memory descriptor */
    struct files_struct     *files;           /* open file table */
    pid_t                    pid;             /* process ID */
    pid_t                    tgid;            /* thread group ID */
    struct task_struct      *parent;          /* parent process */
    struct list_head         children;        /* list of child processes */
    struct signal_struct    *signal;          /* signal handling */
    /* ... 200+ more fields ... */
};
```

The `mm` field points to the memory descriptor (`mm_struct`) which holds the page table pointer (`pgd`), the list of VMAs, and memory usage counters. When two threads belong to the same process, they share the same `mm_struct`.
:::

## 4.4 Process Creation

The mechanism by which new processes come into existence differs fundamentally between Unix-like systems and Windows.

### 4.4.1 The Unix Model: fork() and exec()

Unix process creation follows a two-step pattern: **fork** creates a copy of the calling process, and **exec** replaces that copy's address space with a new program. This separation of concerns is one of Unix's most influential design decisions.

::: definition
**Definition 4.6 (fork).** The `fork()` system call creates a new process (the child) that is an almost exact copy of the calling process (the parent). The child receives a copy of the parent's address space, file descriptor table, signal handlers, and other attributes. The child gets a new PID. `fork()` returns the child's PID to the parent and 0 to the child.
:::

```c
#include <stdio.h>
#include <unistd.h>
#include <sys/wait.h>

int main(void) {
    int x = 42;
    
    pid_t pid = fork();
    
    if (pid < 0) {
        perror("fork failed");
        return 1;
    } else if (pid == 0) {
        /* Child process: has a COPY of x */
        x = 99;
        printf("Child: x = %d (PID %d)\n", x, getpid());
    } else {
        /* Parent process: x is unchanged */
        wait(NULL);
        printf("Parent: x = %d (PID %d)\n", x, getpid());
    }
    
    return 0;
}
```

Output:
```text
Child: x = 99 (PID 12346)
Parent: x = 42 (PID 12345)
```

The parent and child each have their own copy of `x`. Modifying it in one process has no effect on the other. In practice, modern kernels implement `fork()` using **copy-on-write** (COW): the parent and child initially share the same physical pages, marked read-only. A page is duplicated only when either process attempts to write to it, dramatically reducing the cost of `fork()` for processes that immediately call `exec()`.

::: theorem
**Theorem 4.1 (Copy-on-Write Efficiency).** Let $P$ be a process with $n$ pages of virtual memory. Under copy-on-write semantics, `fork()` requires $O(n)$ page table entries to be duplicated and marked read-only, but only $O(1)$ physical pages are allocated initially. If the child immediately calls `exec()`, only a small constant number of pages (stack, kernel structures) are ever physically copied, giving an effective cost of $O(1)$ memory for the fork+exec pattern.
:::

### 4.4.2 The exec() Family

After `fork()`, the child typically calls one of the `exec()` family of functions to replace its address space with a new program:

```c
#include <stdio.h>
#include <unistd.h>
#include <sys/wait.h>

int main(void) {
    pid_t pid = fork();
    
    if (pid == 0) {
        /* Replace this process's image with /bin/ls */
        char *args[] = {"ls", "-la", "/tmp", NULL};
        execvp("ls", args);
        
        /* If exec returns, it failed */
        perror("exec failed");
        _exit(1);
    } else {
        int status;
        waitpid(pid, &status, 0);
        printf("Child exited with status %d\n", WEXITSTATUS(status));
    }
    
    return 0;
}
```

The `exec()` call does not create a new process. It replaces the calling process's text, data, heap, and stack with those of the new program. The PID remains the same. Open file descriptors are preserved unless marked with `FD_CLOEXEC` (close-on-exec).

The `exec()` family includes six variants:

| Function | Path | Arguments | Environment |
|---|---|---|---|
| `execl` | Full path | Variadic list | Inherited |
| `execv` | Full path | Array | Inherited |
| `execlp` | PATH search | Variadic list | Inherited |
| `execvp` | PATH search | Array | Inherited |
| `execle` | Full path | Variadic list | Explicit |
| `execvpe` | PATH search | Array | Explicit |

### 4.4.3 The Windows Model: CreateProcess()

Windows takes a fundamentally different approach. Rather than separating creation and program loading, `CreateProcess()` performs both in a single call:

```c
BOOL CreateProcessW(
    LPCWSTR               lpApplicationName,    /* executable path */
    LPWSTR                lpCommandLine,         /* command line string */
    LPSECURITY_ATTRIBUTES lpProcessAttributes,   /* security for process handle */
    LPSECURITY_ATTRIBUTES lpThreadAttributes,    /* security for thread handle */
    BOOL                  bInheritHandles,       /* handle inheritance flag */
    DWORD                 dwCreationFlags,       /* creation flags */
    LPVOID                lpEnvironment,         /* environment block */
    LPCWSTR               lpCurrentDirectory,    /* working directory */
    LPSTARTUPINFOW        lpStartupInfo,         /* startup info */
    LPPROCESS_INFORMATION lpProcessInformation   /* output: handles and IDs */
);
```

The single-call design means Windows never creates a process that is an exact copy of the parent. The child process always begins executing a specified program. This avoids the overhead of copying the parent's address space (even with COW) and the complexity of the fork+exec pattern, but at the cost of flexibility.

### 4.4.4 Process Hierarchies

In Unix-like systems, processes form a tree rooted at `init` (PID 1). Every process (except `init`) has exactly one parent, and may have zero or more children. This hierarchy is visible through the `pstree` command:

```text
systemd(1)───┬───sshd(892)───sshd(1234)───bash(1235)───vim(1240)
             ├───nginx(900)───┬───nginx(901)
             │                ├───nginx(902)
             │                └───nginx(903)
             └───cron(850)
```

The process tree determines signal propagation (a `SIGHUP` to a session leader reaches all members), zombie reaping (the parent must call `wait()`), and resource accounting (CPU time can be summed across a subtree).

### 4.5.5 Process Groups and Sessions

Unix systems organise processes into **process groups** and **sessions** to support job control in interactive shells.

::: definition
**Definition 4.6a (Process Group and Session).** A **process group** is a collection of related processes (typically a pipeline) identified by a Process Group ID (PGID), which equals the PID of the group leader. A **session** is a collection of process groups associated with a controlling terminal, identified by a Session ID (SID) equal to the PID of the session leader. Each session has at most one **foreground process group** (which receives terminal input and signals like SIGINT from Ctrl+C) and zero or more **background process groups**.
:::

When you type `ls | grep foo | wc -l` in a shell, the three processes form a single process group. Pressing Ctrl+C sends SIGINT to the entire foreground process group, not just one process.

```text
Session (SID = bash PID)
├── Foreground process group (PGID = ls PID)
│   ├── ls    (PID=1001, PGID=1001)
│   ├── grep  (PID=1002, PGID=1001)
│   └── wc    (PID=1003, PGID=1001)
└── Background process groups
    └── ./server &  (PID=1004, PGID=1004)
```

The `setpgid()` system call changes a process's group, and `setsid()` creates a new session. Daemons typically call `setsid()` to detach from the controlling terminal, preventing terminal signals from reaching them.

> **Programmer:** **Programmer's Perspective: fork() in Go and Its Perils.** Go deliberately does not expose `fork()` in its standard library. The reason is subtle but important: `fork()` creates a child with a single thread of execution (the one that called `fork()`), but Go programs are inherently multi-threaded due to the runtime's garbage collector, network poller, and scheduler threads. After `fork()`, the child process has copies of all the mutexes from the parent, but only one of the threads that might have held those mutexes --- a recipe for deadlocks. The Go standard library's `os/exec` package uses a carefully orchestrated `fork()`/`exec()` combination (via `posix_spawn()` on some platforms) that minimises the window between forking and exec-ing. If you need to call `fork()` without `exec()` in Go, you must use `syscall.ForkExec()` or `syscall.RawSyscall(SYS_CLONE, ...)`, and you must not call any Go runtime functions in the child before `exec()`.

## 4.5 Process Termination

A process terminates either voluntarily or involuntarily:

**Voluntary termination:**

- Normal exit: The process calls `exit(status)` with a zero status code
- Error exit: The process calls `exit(status)` with a non-zero status code
- Return from `main()`: Equivalent to calling `exit()` with the return value

**Involuntary termination:**

- Fatal signal: The process receives a signal whose default action is termination (e.g., `SIGSEGV`, `SIGKILL`)
- Killed by another process: Another process sends `SIGKILL` or `SIGTERM`
- Resource limit exceeded: The kernel kills the process for exceeding a resource limit (e.g., the OOM killer)

Upon termination, the kernel performs cleanup:

1. Close all open file descriptors
2. Release all memory mappings (unmap pages, free page table entries)
3. Remove the process from the scheduler's queues
4. Notify the parent via `SIGCHLD`
5. Re-parent any children to `init` or the designated subreaper
6. Retain the `task_struct` with exit status (zombie state) until the parent calls `wait()`

### 4.5.1 posix_spawn(): A Modern Alternative

The fork-then-exec pattern has a longstanding problem on systems without virtual memory (embedded systems) or with very large processes (where even COW page table duplication is expensive). POSIX provides `posix_spawn()` as a combined creation-and-exec operation:

```c
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>

extern char **environ;

int main(void) {
    pid_t pid;
    char *argv[] = {"ls", "-la", "/tmp", NULL};
    
    int status = posix_spawn(&pid, "/bin/ls", NULL, NULL, argv, environ);
    if (status != 0) {
        fprintf(stderr, "posix_spawn failed: %d\n", status);
        return 1;
    }
    
    printf("Spawned child PID: %d\n", pid);
    waitpid(pid, &status, 0);
    printf("Child exited with status %d\n", WEXITSTATUS(status));
    
    return 0;
}
```

On Linux, `posix_spawn()` is implemented in glibc using `clone()` with `CLONE_VM | CLONE_VFORK`, which avoids duplicating the parent's page tables entirely. The child shares the parent's address space (as a vfork child) and immediately calls `exec()`. This makes `posix_spawn()` faster than `fork()` + `exec()` for large processes.

### 4.5.2 Process Resource Limits

Each process has a set of resource limits that constrain its resource consumption. These limits prevent runaway processes from consuming all available resources:

```c
#include <sys/resource.h>
#include <stdio.h>

int main(void) {
    struct rlimit rl;
    
    /* Query the maximum stack size */
    getrlimit(RLIMIT_STACK, &rl);
    printf("Stack: soft=%lu KB, hard=%lu KB\n",
           rl.rlim_cur / 1024, rl.rlim_max / 1024);
    
    /* Query the maximum number of open files */
    getrlimit(RLIMIT_NOFILE, &rl);
    printf("Open files: soft=%lu, hard=%lu\n",
           rl.rlim_cur, rl.rlim_max);
    
    /* Query the maximum virtual memory */
    getrlimit(RLIMIT_AS, &rl);
    if (rl.rlim_cur == RLIM_INFINITY)
        printf("Virtual memory: unlimited\n");
    else
        printf("Virtual memory: soft=%lu MB\n", rl.rlim_cur / (1024*1024));
    
    /* Query the CPU time limit */
    getrlimit(RLIMIT_CPU, &rl);
    if (rl.rlim_cur == RLIM_INFINITY)
        printf("CPU time: unlimited\n");
    else
        printf("CPU time: soft=%lu sec\n", rl.rlim_cur);
    
    return 0;
}
```

Key resource limits on Linux include:

| Limit | Resource | Default (soft) | Effect of exceeding |
|---|---|---|---|
| `RLIMIT_STACK` | Stack size | 8 MB | SIGSEGV |
| `RLIMIT_NOFILE` | Open files | 1024 | EMFILE error |
| `RLIMIT_AS` | Virtual memory | Unlimited | ENOMEM error |
| `RLIMIT_CPU` | CPU time | Unlimited | SIGXCPU, then SIGKILL |
| `RLIMIT_NPROC` | Processes per user | Varies | EAGAIN on fork() |
| `RLIMIT_CORE` | Core dump size | 0 (disabled) | Truncated core dump |

The soft limit is the effective limit; it can be raised up to the hard limit by the process itself. Only root can raise the hard limit.

## 4.6 Context Switching

When the scheduler decides to run a different process, it must save the current process's execution state and load the saved state of the next process. This operation is called a **context switch**.

::: definition
**Definition 4.7 (Context Switch).** A context switch is the mechanism by which the kernel saves the CPU state (registers, program counter, stack pointer, floating-point state) of the currently running process into its PCB, and loads the corresponding state from the PCB of the next process to run. The CPU then resumes executing the new process from where it previously left off.
:::

### 4.6.1 The Context Switch Mechanism

On x86-64 Linux, a context switch involves these steps:

1. **Enter kernel mode**: A timer interrupt, system call, or I/O interrupt transfers control from user mode to the kernel.

2. **Save user-space registers**: The interrupt/syscall entry code pushes the user-space register state onto the kernel stack.

3. **Scheduler decision**: The kernel's scheduler selects the next process to run based on priorities, fairness, and scheduling policy.

4. **Switch kernel stacks**: The kernel saves the current process's kernel stack pointer in its `task_struct` and loads the next process's kernel stack pointer.

5. **Switch address space**: The kernel loads the next process's page table base register (CR3 on x86-64). This invalidates the TLB, though PCID (Process Context IDentifier) can avoid full flushes.

6. **Switch CPU state**: Floating-point registers (FPU/SSE/AVX state) are saved and restored lazily or eagerly, depending on kernel configuration.

7. **Return to user space**: The kernel pops the new process's user-space registers from its kernel stack and executes `iretq` (or `sysret`) to return to user mode.

### 4.6.2 The Cost of Context Switching

Context switches are not free. The direct costs include:

- **Register save/restore**: Saving and loading 16+ general-purpose registers, plus floating-point state (up to 2 KB for AVX-512)
- **TLB flush**: Changing the page table base register invalidates TLB entries. Without PCID, the entire TLB is flushed, causing a cascade of page table walks for subsequent memory accesses.
- **Cache pollution**: The new process's working set will evict the previous process's cache lines. The L1 cache (32--64 KB) is typically polluted within microseconds; the L2 and L3 caches are shared and experience gradual displacement.
- **Pipeline flush**: The CPU's instruction pipeline must be drained when switching to a different instruction stream. Branch predictor state (often per-address, not per-process) may also suffer.

::: theorem
**Theorem 4.2 (Context Switch Overhead Bound).** Let $T_{\text{direct}}$ be the time to save and restore register state, $T_{\text{TLB}}$ be the amortised cost of TLB refills after a flush, and $T_{\text{cache}}$ be the amortised cost of cache misses as the new process warms its working set. The total cost of a context switch is:

$$T_{\text{switch}} = T_{\text{direct}} + T_{\text{TLB}} + T_{\text{cache}}$$

On modern x86-64 hardware, $T_{\text{direct}} \approx 1$--$3\ \mu\text{s}$, but $T_{\text{TLB}} + T_{\text{cache}}$ can dominate, pushing the effective cost to $5$--$30\ \mu\text{s}$ depending on working set size and TLB pressure.
:::

### 4.6.3 Hardware Support for Context Switching

Modern processors provide features to reduce context switch costs:

- **PCID (Process Context Identifiers)**: x86-64 CR3 carries a 12-bit PCID that tags TLB entries with the process that created them. On a context switch, the kernel sets the new process's PCID without flushing the TLB. This eliminates the TLB refill cost for processes that have been recently scheduled.

- **XSAVE/XRSTOR**: These instructions save and restore extended processor state (SSE, AVX, AVX-512, MPX) in a single operation, using a state-component bitmap to skip unused register banks.

- **Lazy FPU switching**: The kernel can mark the FPU as "not available" when switching to a new process. If the new process uses floating-point instructions, a `#NM` (Device Not Available) exception triggers the kernel to load the FPU state on demand. This avoids the cost of saving/restoring FPU state for processes that do not use it. Modern kernels (Linux 4.6+) have moved to eager FPU restore due to Spectre-class vulnerabilities.

::: example
**Example 4.5 (Measuring Context Switch Time).** The classic way to measure context switch time is to create two processes connected by a pipe. Each process writes a byte to the pipe and reads a byte from the other end, forcing a context switch each time:

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>

#define ITERATIONS 100000

int main(void) {
    int pipe1[2], pipe2[2];
    pipe(pipe1);
    pipe(pipe2);
    
    char byte = 'x';
    
    if (fork() == 0) {
        /* Child: read from pipe1, write to pipe2 */
        close(pipe1[1]);
        close(pipe2[0]);
        for (int i = 0; i < ITERATIONS; i++) {
            read(pipe1[0], &byte, 1);
            write(pipe2[1], &byte, 1);
        }
        _exit(0);
    }
    
    /* Parent: write to pipe1, read from pipe2 */
    close(pipe1[0]);
    close(pipe2[1]);
    
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    
    for (int i = 0; i < ITERATIONS; i++) {
        write(pipe1[1], &byte, 1);
        read(pipe2[0], &byte, 1);
    }
    
    clock_gettime(CLOCK_MONOTONIC, &end);
    
    double elapsed = (end.tv_sec - start.tv_sec) * 1e9 +
                     (end.tv_nsec - start.tv_nsec);
    printf("Average round-trip: %.1f ns\n", elapsed / ITERATIONS);
    printf("Estimated context switch: %.1f ns\n", elapsed / (2 * ITERATIONS));
    
    return 0;
}
```

On a modern Intel processor, this typically yields context switch times of 2--5 microseconds, though the indirect costs of cache and TLB pollution are not captured by this measurement.
:::

## 4.7 Threads

A thread is an independent flow of control within a process. While processes provide isolation (separate address spaces), threads provide concurrency within a shared address space. Multiple threads within the same process share the same code, data, and heap, but each has its own stack, program counter, and register state.

::: definition
**Definition 4.8 (Thread).** A thread (also called a lightweight process) is the smallest unit of CPU scheduling. A thread consists of a thread ID, a program counter, a register set, and a stack. It shares the code section, data section, heap, open files, and signal handlers with other threads belonging to the same process.
:::

### 4.7.1 Why Threads?

The motivation for threads comes from several directions:

**Responsiveness.** A multi-threaded GUI application can handle user input in one thread while performing computation in another. Without threads, the entire application freezes during a long computation.

**Resource sharing.** Threads within the same process share memory naturally. Inter-thread communication is as simple as reading and writing shared variables (with proper synchronisation). Inter-process communication requires explicit mechanisms (pipes, shared memory, sockets).

**Economy.** Creating a thread is 10--100x cheaper than creating a process. A `fork()` on Linux requires duplicating the page table, file descriptor table, signal handlers, and other PCB fields. A thread creation (via `clone()` with `CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND`) shares all of these, requiring only a new stack and kernel task structure.

**Scalability.** On a multiprocessor system, threads in the same process can execute simultaneously on different cores, providing true parallelism. A single-threaded process is limited to one core regardless of how many are available.

::: example
**Example 4.6 (Threads vs Processes for a Web Server).** Consider a web server handling 10,000 concurrent connections:

- **Process-per-connection** (Apache prefork): 10,000 processes, each with its own address space. At 6 KB per `task_struct` plus several MB of virtual memory mappings, this consumes significant kernel resources and suffers from context switch overhead.

- **Thread-per-connection** (Apache worker): 10,000 threads sharing a single address space. Kernel overhead is reduced (shared page tables, file tables), but 10,000 kernel threads still strain the scheduler.

- **Event-driven with thread pool** (Nginx, Go net/http): A small number of threads (typically matching the CPU count) handle all connections using non-blocking I/O and event multiplexing (`epoll`, `kqueue`). This minimises both memory usage and context switch overhead.
:::

### 4.7.2 Thread State

Each thread has its own:

- **Program counter**: Where in the code the thread is currently executing
- **Register set**: The thread's own copy of CPU registers
- **Stack**: A separate stack for local variables and function call frames
- **Thread-local storage**: Per-thread global variables
- **Scheduling state**: Ready, running, blocked, etc.

Threads within the same process share:

- **Address space**: Text, data, heap, memory-mapped regions
- **Open file descriptors**: The file descriptor table
- **Signal handlers**: The signal disposition table (but signal masks are per-thread)
- **Process ID**: All threads share the same PID (on Linux, the TGID)
- **Credentials**: UID, GID, supplementary groups

## 4.8 Thread Models

The relationship between application-level threads and kernel-level threads is characterised by three models.

### 4.8.1 Many-to-One (M:1) --- User-Level Threads

In the M:1 model, multiple user-level threads are mapped onto a single kernel thread. The thread library manages scheduling, context switching, and synchronisation entirely in user space, without kernel involvement.

**Advantages:**

- Thread operations (create, switch, synchronise) are extremely fast --- no system calls required
- Portable across operating systems that lack kernel thread support
- Scheduling can be customised (e.g., application-specific priority schemes)

**Disadvantages:**

- If one thread makes a blocking system call, all threads in the process block
- Cannot exploit multiple processors --- the kernel sees only one schedulable entity
- A page fault in one thread blocks all threads

Historical examples include GNU Pth (POSIX user-level threads) and early Java green threads (before JDK 1.2).

### 4.8.2 One-to-One (1:1) --- Kernel Threads

In the 1:1 model, each user-level thread maps directly to a kernel thread. The kernel handles all scheduling, context switching, and synchronisation.

**Advantages:**

- Threads can run in parallel on multiple CPUs
- A blocking system call in one thread does not block others
- Kernel can preempt individual threads for fair scheduling

**Disadvantages:**

- Thread creation requires a system call (overhead of ~2--10 microseconds)
- Each thread consumes kernel resources (kernel stack, `task_struct`)
- Scalability limited by kernel thread capacity (typically tens of thousands, not millions)

Linux (via NPTL), modern Windows, and macOS all use the 1:1 model.

### 4.8.3 Many-to-Many (M:N) --- Hybrid Model

The M:N model maps $M$ user-level threads onto $N$ kernel threads, where typically $M \gg N$. A user-space scheduler (sometimes called a **scheduler activations** layer) multiplexes user threads onto the available kernel threads.

**Advantages:**

- Combines the scalability of user-level threads with the parallelism of kernel threads
- A blocking user thread can be parked while the kernel thread serves another
- The application can create millions of user-level threads without exhausting kernel resources

**Disadvantages:**

- Complex implementation: requires cooperation between user-space scheduler and kernel
- Difficult to handle blocking system calls transparently
- Debugging is harder when the mapping between user and kernel threads is indirect

::: definition
**Definition 4.9 (M:N Threading Model).** In the M:N threading model, $M$ application-level threads are multiplexed onto $N$ kernel threads, where $1 \le N \le M$. The user-space runtime scheduler assigns user threads to available kernel threads, migrating user threads between kernel threads as needed to balance load and avoid blocking.
:::

The M:N model is used by Go's goroutine scheduler, Erlang's BEAM VM, and historically by Solaris's lightweight process (LWP) system.

## 4.9 Green Threads and Goroutines

The concept of **green threads** --- threads managed entirely by a runtime rather than the operating system kernel --- has a long history. The term originated from the Green Team at Sun Microsystems, who implemented user-level threads for Java before native thread support was widely available.

Modern green thread implementations have evolved far beyond simple user-level threading. The most prominent example is Go's **goroutines**, which implement a sophisticated M:N scheduling model.

### 4.9.1 What Makes Goroutines Different

A goroutine is a function executing concurrently with other goroutines in the same address space. Goroutines differ from OS threads in several critical ways:

| Property | OS Thread | Goroutine |
|---|---|---|
| Stack size (initial) | 1--8 MB (fixed) | 2--8 KB (growable) |
| Creation cost | ~2--10 microseconds | ~0.3 microseconds |
| Context switch cost | ~1--5 microseconds | ~0.2 microseconds |
| Maximum practical count | ~10,000 | ~1,000,000+ |
| Scheduling | Kernel preemptive | Runtime cooperative + preemptive (since Go 1.14) |
| Memory overhead per unit | ~8 KB kernel stack + user stack | ~2--8 KB total |

The key innovation is the **segmented stack** (originally) and **copyable stack** (since Go 1.4). Goroutine stacks start small (a few kilobytes) and grow dynamically by copying to a larger allocation when needed. This allows a Go program to run millions of goroutines without exhausting memory.

```go
package main

import (
    "fmt"
    "sync"
)

func worker(id int, wg *sync.WaitGroup) {
    defer wg.Done()
    fmt.Printf("Worker %d starting\n", id)
    // Simulate work
    sum := 0
    for i := 0; i < 1000; i++ {
        sum += i
    }
    fmt.Printf("Worker %d done, sum = %d\n", id, sum)
}

func main() {
    var wg sync.WaitGroup
    
    // Launch 100,000 goroutines --- try this with OS threads
    for i := 0; i < 100000; i++ {
        wg.Add(1)
        go worker(i, &wg)
    }
    
    wg.Wait()
    fmt.Println("All workers complete")
}
```

### 4.9.2 The GMP Model

Go's goroutine scheduler uses the **GMP model**, named after its three core abstractions:

- **G (Goroutine)**: A goroutine structure containing the stack, program counter, and scheduling metadata. Each G represents a unit of concurrent work.

- **M (Machine)**: An OS thread. Each M executes Go code by running goroutines. Ms are created on demand and cached for reuse. The number of Ms can exceed GOMAXPROCS when some are blocked in system calls.

- **P (Processor)**: A logical processor that provides the context needed to execute Go code. Each P holds a local run queue of goroutines. The number of Ps equals GOMAXPROCS (default: number of CPU cores).

The scheduling invariant is: **a goroutine (G) can only run on an OS thread (M) that is attached to a processor (P)**. This three-level structure enables efficient scheduling:

```text
    ┌─────────────────────────────────────────────────────┐
    │                  Global Run Queue                    │
    │              [G7] [G8] [G9] [G10] ...               │
    └───────────┬─────────────────────┬───────────────────┘
                │                     │
    ┌───────────▼───────┐ ┌──────────▼────────┐
    │    P0             │ │    P1              │
    │  Local Queue:     │ │  Local Queue:      │
    │  [G1] [G2] [G3]  │ │  [G4] [G5] [G6]   │
    │                   │ │                    │
    │  Running: ────────┤ │  Running: ─────────┤
    │     ▼             │ │     ▼              │
    │  ┌──────┐         │ │  ┌──────┐          │
    │  │  M0  │         │ │  │  M1  │          │
    │  └──────┘         │ │  └──────┘          │
    └───────────────────┘ └────────────────────┘
```

When a goroutine makes a blocking system call, the M executing it detaches from its P. The P is then handed to another M (or a new M is created) so that the remaining goroutines in P's run queue can continue executing. When the system call completes, the M attempts to reacquire a P; if none is available, the goroutine is placed on the global run queue and the M parks itself.

> **Programmer:** **Programmer's Perspective: Go's GMP Scheduler in Detail.** The Go scheduler implements **work-stealing** to balance load across Ps. When a P's local run queue is empty, it attempts (in order): (1) check the global run queue (every 61st scheduling tick, to prevent starvation), (2) check the network poller for ready goroutines, (3) steal half the goroutines from another P's local queue. The `runtime.GOMAXPROCS(n)` function sets the number of Ps. Setting it to 1 gives cooperative concurrency on a single core; setting it to `runtime.NumCPU()` (the default since Go 1.5) enables full parallelism. The scheduler became truly preemptive in Go 1.14 with the introduction of asynchronous preemption via `SIGURG` signals: a background thread (`sysmon`) detects goroutines that have been running for more than 10 ms and sends a signal to preempt them, even if they contain no function calls (tight loops without preemption points were a known issue before Go 1.14).

### 4.9.3 Goroutine Preemption

Early versions of Go's scheduler were **cooperatively scheduled**: goroutines yielded control only at specific preemption points (function calls, channel operations, system calls). A goroutine executing a tight computational loop without function calls could monopolise its P indefinitely, starving other goroutines.

Go 1.14 introduced **asynchronous preemption**. The `sysmon` goroutine (a special system monitor) runs on its own M without a P and periodically checks whether any goroutine has been running for too long (default threshold: 10 ms). If so, it sends a `SIGURG` signal to the offending M, which triggers a signal handler that saves the goroutine's state and schedules another goroutine from the run queue.

```go
package main

import (
    "fmt"
    "runtime"
    "time"
)

func busyLoop() {
    // Before Go 1.14, this would block the P forever
    // After Go 1.14, the scheduler preempts this goroutine
    for {
        // Pure computation, no function calls, no preemption points
        _ = 1 + 1
    }
}

func main() {
    runtime.GOMAXPROCS(1) // Single P
    
    go busyLoop()
    
    // This goroutine can still run thanks to async preemption
    time.Sleep(100 * time.Millisecond)
    fmt.Println("Main goroutine is not starved")
}
```

## 4.10 Linux clone() and Thread Creation

On Linux, threads and processes are both created by the `clone()` system call. The difference lies in the flags passed to `clone()`, which determine how much state is shared between the parent and child.

::: definition
**Definition 4.10 (clone System Call).** The Linux `clone()` system call creates a new execution context (task). Its behaviour is controlled by a bitmask of flags that specify which resources are shared between the calling task and the new task, and which are copied. Both `fork()` and `pthread_create()` are implemented in terms of `clone()` with different flag combinations.
:::

The key `clone()` flags are:

| Flag | Effect |
|---|---|
| `CLONE_VM` | Share the virtual address space (memory mappings, heap) |
| `CLONE_FS` | Share filesystem information (root, cwd, umask) |
| `CLONE_FILES` | Share the file descriptor table |
| `CLONE_SIGHAND` | Share signal handlers |
| `CLONE_THREAD` | Place the new task in the same thread group (share PID/TGID) |
| `CLONE_PARENT` | New task has the same parent as the calling task |
| `CLONE_NEWNS` | New mount namespace (for containers) |
| `CLONE_NEWPID` | New PID namespace (for containers) |

A `fork()` is equivalent to `clone()` with no sharing flags. A `pthread_create()` is equivalent to `clone()` with `CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD`.

::: example
**Example 4.7 (Creating a Thread with clone()).** The following C program uses `clone()` directly to create a thread that shares the parent's address space:

```c
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

#define STACK_SIZE (1024 * 1024)

static int shared_var = 0;

static int thread_func(void *arg) {
    shared_var = 42;
    printf("Child: shared_var = %d (PID=%d, TID=%d)\n",
           shared_var, getpid(), gettid());
    return 0;
}

int main(void) {
    char *stack = malloc(STACK_SIZE);
    if (!stack) {
        perror("malloc");
        return 1;
    }
    
    /* Stack grows downward on x86-64 */
    char *stack_top = stack + STACK_SIZE;
    
    int flags = CLONE_VM | CLONE_FS | CLONE_FILES |
                CLONE_SIGHAND | CLONE_THREAD | SIGCHLD;
    
    int tid = clone(thread_func, stack_top, flags, NULL);
    if (tid == -1) {
        perror("clone");
        return 1;
    }
    
    /* Wait for the child thread */
    sleep(1);
    printf("Parent: shared_var = %d (modified by child via shared VM)\n",
           shared_var);
    
    free(stack);
    return 0;
}
```

Because `CLONE_VM` is set, both parent and child operate on the same virtual address space. The child's modification to `shared_var` is visible to the parent. Without `CLONE_VM`, each would have its own copy (as with `fork()`).
:::

## 4.11 POSIX Threads (pthreads)

The POSIX Threads standard (IEEE 1003.1c) provides a portable API for multi-threaded programming on Unix-like systems. On Linux, the pthreads library is implemented by NPTL (Native POSIX Threads Library), which uses the 1:1 threading model.

### 4.11.1 Thread Lifecycle

```c
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    int thread_id;
    int iterations;
} thread_arg_t;

void *compute(void *arg) {
    thread_arg_t *params = (thread_arg_t *)arg;
    long sum = 0;
    
    for (int i = 0; i < params->iterations; i++) {
        sum += i;
    }
    
    printf("Thread %d: sum = %ld\n", params->thread_id, sum);
    
    /* Return value accessible via pthread_join */
    long *result = malloc(sizeof(long));
    *result = sum;
    return result;
}

int main(void) {
    pthread_t threads[4];
    thread_arg_t args[4];
    
    for (int i = 0; i < 4; i++) {
        args[i].thread_id = i;
        args[i].iterations = 1000000 * (i + 1);
        
        int rc = pthread_create(&threads[i], NULL, compute, &args[i]);
        if (rc != 0) {
            fprintf(stderr, "pthread_create failed: %d\n", rc);
            return 1;
        }
    }
    
    /* Wait for all threads to complete */
    for (int i = 0; i < 4; i++) {
        long *result;
        pthread_join(threads[i], (void **)&result);
        printf("Thread %d returned: %ld\n", i, *result);
        free(result);
    }
    
    return 0;
}
```

Compile with: `gcc -pthread -o threads threads.c`

### 4.11.2 Thread Attributes

Thread creation can be customised via `pthread_attr_t`:

```c
pthread_attr_t attr;
pthread_attr_init(&attr);

/* Set stack size to 4 MB (default is typically 8 MB on Linux) */
pthread_attr_setstacksize(&attr, 4 * 1024 * 1024);

/* Set scheduling policy */
pthread_attr_setschedpolicy(&attr, SCHED_FIFO);

/* Create a detached thread (no need to join) */
pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);

pthread_t thread;
pthread_create(&thread, &attr, worker_func, NULL);

pthread_attr_destroy(&attr);
```

A **detached thread** releases its resources automatically upon termination, without requiring another thread to call `pthread_join()`. A **joinable thread** (the default) retains its exit status until joined.

## 4.12 Thread-Local Storage

Thread-local storage (TLS) provides a mechanism for each thread to have its own instance of a variable, even though the variable has the same name and is accessed through the same identifier in all threads.

::: definition
**Definition 4.11 (Thread-Local Storage).** Thread-local storage (TLS) is a memory allocation mechanism where each thread in a process has its own private instance of a variable. TLS variables are global in scope (visible throughout the program) but local in storage (each thread's copy is independent). Writes to a TLS variable in one thread do not affect the value seen by other threads.
:::

### 4.12.1 TLS in C

The C11 standard introduced the `_Thread_local` storage class specifier (also available as `thread_local` via `<threads.h>`):

```c
#include <stdio.h>
#include <pthread.h>

/* Each thread gets its own copy of errno_local */
_Thread_local int errno_local = 0;

/* GCC/Clang extension (pre-C11) */
__thread int counter = 0;

void *worker(void *arg) {
    int id = *(int *)arg;
    counter = id * 100;
    errno_local = id;
    
    printf("Thread %d: counter=%d, errno_local=%d\n",
           id, counter, errno_local);
    return NULL;
}

int main(void) {
    pthread_t threads[4];
    int ids[4] = {0, 1, 2, 3};
    
    for (int i = 0; i < 4; i++) {
        pthread_create(&threads[i], NULL, worker, &ids[i]);
    }
    for (int i = 0; i < 4; i++) {
        pthread_join(threads[i], NULL);
    }
    
    printf("Main: counter=%d (main thread's copy)\n", counter);
    return 0;
}
```

### 4.12.2 TLS Implementation

On x86-64 Linux, TLS is implemented using the FS segment register. Each thread has a TLS block allocated at thread creation time. The FS base register (`IA32_FS_BASE` MSR, set via `arch_prctl(ARCH_SET_FS, addr)`) points to the thread's TLS area. Accessing a TLS variable compiles to a memory reference with an `%fs:` segment prefix:

```text
; Access to a __thread variable compiles to:
movl %fs:counter@TPOFF, %eax    ; Load thread-local 'counter'
```

This single-instruction access makes TLS extremely efficient --- no function calls, no hash table lookups. The cost is identical to accessing a regular global variable plus the segment prefix overhead (typically zero on modern x86-64 processors, which cache the FS base in the CPU).

### 4.12.3 TLS in Go

Go does not provide thread-local storage as a language feature. This is a deliberate design decision: because goroutines can migrate between OS threads (Ms in the GMP model), a TLS value that is logically "per-goroutine" cannot be stored in OS-level TLS. Instead, Go provides alternatives:

- **Context passing**: The `context.Context` type carries request-scoped values through function arguments
- **sync.Pool**: Per-processor caches that reduce contention for frequently allocated objects
- **runtime.LockOSThread()**: Pins a goroutine to its current OS thread, making OS-level TLS safe to use (used by CGo and graphics libraries that require thread affinity)

```go
package main

import (
    "context"
    "fmt"
)

type contextKey string

const requestIDKey contextKey = "requestID"

func handleRequest(ctx context.Context) {
    // Retrieve the per-request value from context
    reqID := ctx.Value(requestIDKey).(string)
    fmt.Printf("Handling request: %s\n", reqID)
}

func main() {
    // Context replaces TLS for goroutine-scoped values
    ctx := context.WithValue(context.Background(), requestIDKey, "req-42")
    go handleRequest(ctx)
    
    ctx2 := context.WithValue(context.Background(), requestIDKey, "req-99")
    go handleRequest(ctx2)
    
    // Wait for goroutines (simplified; use sync.WaitGroup in production)
    fmt.Scanln()
}
```

> **Programmer:** **Programmer's Perspective: Linux clone() Flags and Containers.** The `clone()` system call is not just for creating threads --- it is the foundation of Linux containers. By combining flags like `CLONE_NEWPID`, `CLONE_NEWNS`, `CLONE_NEWNET`, `CLONE_NEWUTS`, and `CLONE_NEWUSER`, `clone()` creates a new process that lives in isolated namespaces: it sees its own PID tree (starting from PID 1), its own filesystem mount hierarchy, its own network stack, its own hostname, and its own user/group mapping. Tools like Podman, Docker, and LXC use these namespace flags to create containers. The `unshare()` system call provides the same namespace isolation for an existing process, and `setns()` allows a process to join an existing namespace. Understanding `clone()` flags is the key to understanding how Linux containers provide process-level isolation without the overhead of full virtualisation.

## 4.13 Comparing Threading Models in Practice

The following table summarises the practical characteristics of the three threading models as implemented in real systems:

| Aspect | Pthreads (1:1) | Go Goroutines (M:N) | Green Threads (M:1) |
|---|---|---|---|
| Implementation | Linux NPTL | Go runtime | User-space library |
| Kernel visibility | Full | Partial (sees Ms, not Gs) | None |
| Blocking syscall impact | Only calling thread blocks | M detaches from P; P continues | All threads block |
| CPU parallelism | Yes | Yes | No |
| Stack size | Fixed (default 8 MB) | Dynamic (initial 2--8 KB) | Varies |
| Max practical threads | ~10,000 | ~1,000,000+ | ~1,000,000+ (single core) |
| Context switch cost | ~1--5 microseconds | ~0.2 microseconds | ~0.05 microseconds |
| Preemption | Kernel-level | Runtime + signal-based | Cooperative only |
| Debugging | Standard tools (gdb, strace) | Specialised (delve) | Difficult |

::: example
**Example 4.8 (Goroutine vs Thread Memory Overhead).** Consider running one million concurrent units of execution. With pthreads (default 8 MB stack per thread), the stack memory alone would require:

$$1{,}000{,}000 \times 8\ \text{MB} = 8\ \text{TB}$$

This exceeds the physical memory of virtually any system. With goroutines (initial 2 KB stack):

$$1{,}000{,}000 \times 2\ \text{KB} = 2\ \text{GB}$$

This fits comfortably in a modern server's memory. The goroutine stacks grow on demand, so most goroutines that are waiting (e.g., for channel operations) never grow beyond their initial allocation.
:::

::: theorem
**Theorem 4.3 (Scalability of M:N Threading).** In an M:N threading model with $M$ user-level threads, $N$ kernel threads, and a work-stealing scheduler, the overhead of scheduling $M$ threads is $O(M / N)$ amortised per kernel thread. With $N$ equal to the number of CPU cores $C$, the scheduler achieves $O(M / C)$ amortised overhead per core, compared to $O(M)$ total overhead for a centralised scheduler with a single global queue.
:::

## 4.14 Kernel Threads

Modern operating systems use kernel threads not only to support user-level multithreading but also for internal kernel work. These kernel threads have no user-space address space (their `mm` pointer is `NULL` in the Linux `task_struct`) and execute entirely in kernel mode.

Common kernel threads on Linux include:

- **kthreadd** (PID 2): The parent of all kernel threads
- **ksoftirqd/N**: Processes software interrupts (one per CPU)
- **kworker/N:M**: Kernel worker threads for deferred work
- **migration/N**: Handles thread migration between CPUs (one per CPU)
- **rcu_preempt**, **rcu_sched**: Read-Copy-Update (RCU) processing
- **kswapd**: Page reclamation (swapping)
- **jbd2**: Journalling for ext4 filesystems
- **kcompactd**: Memory compaction

These threads are visible in `ps` output with square-bracket names:

```text
$ ps aux | grep '\[' | head -10
root         2  0.0  0.0      0     0 ?  S    Apr10   0:00 [kthreadd]
root         3  0.0  0.0      0     0 ?  I<   Apr10   0:00 [rcu_gp]
root         4  0.0  0.0      0     0 ?  I<   Apr10   0:00 [rcu_par_gp]
root         5  0.0  0.0      0     0 ?  I<   Apr10   0:00 [slub_flushwq]
root         9  0.0  0.0      0     0 ?  I<   Apr10   0:00 [mm_percpu_wq]
root        10  0.0  0.0      0     0 ?  I    Apr10   0:12 [rcu_preempt]
root        11  0.0  0.0      0     0 ?  S    Apr10   0:01 [migration/0]
root        12  0.0  0.0      0     0 ?  S    Apr10   0:00 [idle_inject/0]
root        13  0.0  0.0      0     0 ?  S    Apr10   0:00 [cpuhp/0]
root        14  0.0  0.0      0     0 ?  S    Apr10   0:00 [cpuhp/1]
```

## 4.15 Parallelism and Amdahl's Law

The primary motivation for multithreading is to exploit parallelism on multicore processors. But how much speedup can we actually achieve? Amdahl's Law provides the fundamental answer.

::: theorem
**Theorem 4.4 (Amdahl's Law).** If a fraction $f$ of a program's execution time is inherently sequential (cannot be parallelised), and the remaining fraction $1 - f$ can be perfectly parallelised across $N$ processors, then the maximum speedup is:

$$S(N) = \frac{1}{f + \frac{1 - f}{N}}$$

As $N \to \infty$:

$$S(\infty) = \frac{1}{f}$$

Even with infinitely many processors, the speedup is limited by the serial fraction.
:::

::: example
**Example 4.9 (Amdahl's Law in Practice).** A web server spends 10% of its request-handling time in serial operations (accepting connections, logging) and 90% in parallelisable work (request parsing, database queries, response generation).

| Cores ($N$) | Speedup $S(N)$ | Efficiency $S(N)/N$ |
|---|---|---|
| 1 | 1.00 | 100% |
| 2 | 1.82 | 91% |
| 4 | 3.08 | 77% |
| 8 | 4.71 | 59% |
| 16 | 6.40 | 40% |
| 64 | 8.77 | 14% |
| $\infty$ | 10.00 | 0% |

With 10% serial work, the maximum speedup is 10x regardless of how many cores are available. Adding cores beyond 16 provides diminishing returns.
:::

::: definition
**Definition 4.12 (Gustafson's Law).** While Amdahl's Law assumes a fixed problem size, Gustafson's Law assumes that the problem size scales with the number of processors. If a parallel program running on $N$ processors spends fraction $s$ of its time in serial code and fraction $1 - s$ in parallel code, the scaled speedup is:

$$S_G(N) = N - s \cdot (N - 1) = s + N \cdot (1 - s)$$

This gives a much more optimistic view of parallelism: as we add more processors, we can solve proportionally larger problems, and the serial fraction becomes less significant.
:::

### 4.15.1 Data Parallelism vs Task Parallelism

Two fundamental patterns of parallel computation arise from the thread model:

**Data parallelism** distributes data across threads, with each thread performing the same operation on its subset. This is the pattern used in parallel array processing, map-reduce computations, and GPU programming:

```go
package main

import (
    "fmt"
    "runtime"
    "sync"
)

func parallelSum(data []int) int64 {
    n := runtime.NumCPU()
    var total int64
    var mu sync.Mutex
    var wg sync.WaitGroup
    
    chunkSize := len(data) / n
    
    for i := 0; i < n; i++ {
        start := i * chunkSize
        end := start + chunkSize
        if i == n-1 {
            end = len(data)
        }
        
        wg.Add(1)
        go func(s, e int) {
            defer wg.Done()
            var localSum int64
            for j := s; j < e; j++ {
                localSum += int64(data[j])
            }
            mu.Lock()
            total += localSum
            mu.Unlock()
        }(start, end)
    }
    
    wg.Wait()
    return total
}

func main() {
    data := make([]int, 100_000_000)
    for i := range data {
        data[i] = i % 100
    }
    
    sum := parallelSum(data)
    fmt.Printf("Sum: %d\n", sum)
}
```

**Task parallelism** distributes different tasks across threads, with each thread performing a different operation. This is the pattern used in pipeline processing, producer-consumer systems, and service architectures.

### 4.15.2 False Sharing

A subtle performance problem arises when multiple threads access different variables that happen to reside on the same cache line. This is called **false sharing**: the hardware cache coherence protocol treats the entire cache line as a single unit of sharing, forcing unnecessary invalidations and transfers between cores.

::: definition
**Definition 4.13 (False Sharing).** False sharing occurs when two or more threads on different cores modify independent variables that share the same cache line (typically 64 bytes on x86-64). Each modification invalidates the cache line on all other cores, even though no actual data sharing occurs. The result is a dramatic slowdown due to cache coherence traffic --- often orders of magnitude worse than expected.
:::

```c
#include <pthread.h>
#include <stdio.h>
#include <time.h>

#define ITERATIONS 100000000
#define NUM_THREADS 4

/* BAD: counters share cache lines (false sharing) */
struct BadCounters {
    long c0;
    long c1;
    long c2;
    long c3;
} bad;

/* GOOD: each counter on its own cache line */
struct GoodCounters {
    long c0; char pad0[56];
    long c1; char pad1[56];
    long c2; char pad2[56];
    long c3; char pad3[56];
} good;

void *increment_bad(void *arg) {
    int id = *(int *)arg;
    long *counter = &bad.c0 + id;
    for (long i = 0; i < ITERATIONS; i++) {
        (*counter)++;
    }
    return NULL;
}

void *increment_good(void *arg) {
    int id = *(int *)arg;
    long *counters[] = {&good.c0, &good.c1, &good.c2, &good.c3};
    long *counter = counters[id];
    for (long i = 0; i < ITERATIONS; i++) {
        (*counter)++;
    }
    return NULL;
}

int main(void) {
    pthread_t threads[NUM_THREADS];
    int ids[NUM_THREADS] = {0, 1, 2, 3};
    struct timespec start, end;
    
    /* Benchmark with false sharing */
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (int i = 0; i < NUM_THREADS; i++)
        pthread_create(&threads[i], NULL, increment_bad, &ids[i]);
    for (int i = 0; i < NUM_THREADS; i++)
        pthread_join(threads[i], NULL);
    clock_gettime(CLOCK_MONOTONIC, &end);
    double bad_time = (end.tv_sec - start.tv_sec) +
                      (end.tv_nsec - start.tv_nsec) / 1e9;
    
    /* Benchmark without false sharing */
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (int i = 0; i < NUM_THREADS; i++)
        pthread_create(&threads[i], NULL, increment_good, &ids[i]);
    for (int i = 0; i < NUM_THREADS; i++)
        pthread_join(threads[i], NULL);
    clock_gettime(CLOCK_MONOTONIC, &end);
    double good_time = (end.tv_sec - start.tv_sec) +
                       (end.tv_nsec - start.tv_nsec) / 1e9;
    
    printf("With false sharing:    %.3f sec\n", bad_time);
    printf("Without false sharing: %.3f sec\n", good_time);
    printf("Slowdown factor:       %.1fx\n", bad_time / good_time);
    
    return 0;
}
```

On a 4-core system, the false sharing version typically runs 3--10x slower than the padded version, despite both versions performing exactly the same amount of work.

### 4.15.3 Thread Safety Levels

When designing multithreaded code, it is useful to classify functions and data structures by their thread safety guarantees:

| Level | Description | Example |
|---|---|---|
| Thread-safe (reentrant) | Can be called concurrently from multiple threads without external synchronisation | `strtok_r()`, `rand_r()`, Go's `sync.Map` |
| Conditionally safe | Safe if different threads access different instances | C++ `std::vector` (different vectors) |
| Unsafe | Must not be called concurrently without external locking | `strtok()`, `asctime()`, Go's `map` |

The POSIX standard marks each function as either thread-safe or not. Functions ending in `_r` (reentrant) are thread-safe versions of traditionally unsafe functions. In Go, the `sync` package provides thread-safe primitives (`Mutex`, `RWMutex`, `Map`, `Pool`), and the race detector (`go run -race`) automatically detects data races at runtime.

## 4.16 Process and Thread Lifecycle Summary

The following table provides a complete lifecycle comparison:

| Event | Process (fork) | Thread (pthread_create) | Goroutine (go func) |
|---|---|---|---|
| Creation | `fork()` + COW pages | `clone(CLONE_VM\|...)` | Runtime allocation (~0.3 us) |
| Address space | New (COW copy) | Shared | Shared |
| Stack | Copied (COW) | New allocation (default 8 MB) | New allocation (initial 2-8 KB) |
| File descriptors | Copied | Shared | Shared (via runtime) |
| Scheduling | Kernel scheduler | Kernel scheduler | Go runtime scheduler |
| Synchronisation | IPC mechanisms (pipes, shm) | Mutexes, condition variables | Channels, mutexes |
| Termination | `exit()`, `_exit()` | `pthread_exit()`, return | Function return |
| Cleanup | `wait()` by parent | `pthread_join()` or detach | Automatic (GC) |

## Exercises

1. **Exercise 4.1.** Write a C program that creates a child process using `fork()`. The parent process should store the value 100 in a variable `x` before forking. The child should modify `x` to 200 and print it. The parent should then print its own value of `x`. Explain why the parent and child see different values, referencing copy-on-write semantics. What physical memory operations occur if the child modifies `x` on a system using COW?

2. **Exercise 4.2.** Using the five-state process model, trace the complete sequence of state transitions for a process that: (a) is created, (b) runs for a time quantum, (c) is preempted, (d) runs again, (e) issues a disk read, (f) is woken up when the read completes, and (g) terminates normally. Draw the state diagram with labelled transitions and identify which transitions are triggered by hardware interrupts versus software actions.

3. **Exercise 4.3.** Write a C program using pthreads that creates $n$ threads (where $n$ is a command-line argument). Each thread should compute the sum $\sum_{i=\text{start}}^{\text{end}} i$ for its assigned range, where the full range $[1, 10^8]$ is divided equally among threads. The main thread should collect all partial sums and compute the total. Measure the wall-clock time for $n = 1, 2, 4, 8$. Plot the speedup relative to $n = 1$ and explain any deviation from linear speedup.

4. **Exercise 4.4.** Explain why Go does not expose `fork()` in its standard library. Describe a specific deadlock scenario that can occur when `fork()` is called in a multi-threaded program where one thread holds a mutex at the time of the fork. What happens to the mutex in the child process, and why can the child never acquire it?

5. **Exercise 4.5.** Compare the memory overhead of running 10,000 concurrent tasks using: (a) processes created with `fork()`, (b) POSIX threads with default stack size, and (c) Go goroutines. For each model, compute the total memory consumed by stacks alone. Then compute the total memory including kernel data structures (assume 6 KB per `task_struct` for processes/threads, and 360 bytes per goroutine struct). Which model is feasible on a system with 8 GB of RAM?

6. **Exercise 4.6.** Write a Go program that launches 100,000 goroutines, each of which increments a shared counter using `sync/atomic.AddInt64()`. Measure the total time. Then rewrite the program using channels: each goroutine sends its increment to a single aggregator goroutine via a channel. Compare the performance of the two approaches and explain the difference in terms of the GMP scheduler's behaviour and cache contention.

7. **Exercise 4.7.** The Linux `clone()` system call creates both processes and threads depending on its flags. Write a C program that uses `clone()` with `CLONE_VM | CLONE_FS | CLONE_FILES` (but without `CLONE_THREAD`) to create a child that shares the parent's address space but has a different PID. Verify that the child can modify a variable visible to the parent. What happens if you add `CLONE_NEWPID` to the flags? What PID does the child see for itself, and what PID does the parent see for the child?
