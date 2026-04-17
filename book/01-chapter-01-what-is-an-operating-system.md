# Chapter 1: What Is an Operating System?

Every piece of software you have ever used -- from a command-line compiler to a web browser rendering millions of pixels -- runs on top of an operating system. The OS is the single most consequential piece of software on any general-purpose computer. It decides which programs run, when they run, how much memory they receive, and whether they are allowed to touch a particular file or device. Yet most programmers interact with it only indirectly, through high-level libraries that hide the underlying machinery. This chapter strips away that abstraction layer and examines what an operating system actually is, why it exists, and how it presents itself to the programs that depend on it.

We begin with the three fundamental roles that every operating system must fulfil, then trace the historical evolution from bare-metal programming to the sophisticated multi-subsystem kernels of today. We examine the hardware mechanism -- dual-mode CPU operation -- that makes protection possible, and the software mechanism -- system calls -- that mediates every interaction between application code and the kernel. Finally, we survey POSIX, the standard that codifies this interface, and explore the practical tools that reveal the OS boundary at work.

## The Three Roles of an Operating System

An operating system serves three distinct but intertwined roles. Every design decision in OS theory can be traced back to tensions between these roles.

### Role 1: Resource Manager

A computer contains a finite set of physical resources: CPU cores, bytes of RAM, disk sectors, network bandwidth, GPU compute units. Multiple programs compete for these resources simultaneously. The OS acts as an *arbiter*, deciding how to allocate resources fairly, efficiently, and without conflict.

Resource management encompasses:

- **CPU scheduling** -- deciding which thread runs on which core and for how long.

- **Memory allocation** -- partitioning physical RAM among processes and the kernel itself.

- **I/O multiplexing** -- ensuring that two processes do not simultaneously write to the same disk sector or network port.

- **Energy management** -- throttling CPU frequency and powering down idle devices on battery-constrained systems.

- **Bandwidth allocation** -- dividing network and disk bandwidth among competing applications using mechanisms like traffic shaping and I/O schedulers.

The fundamental constraint is scarcity. If every program could have unlimited CPU time and unlimited memory, there would be no need for an operating system at all. The existence of the OS is a direct consequence of resource contention.

> **Note:** **Resource multiplexing** refers to the technique of sharing a single physical resource among multiple logical consumers. *Time multiplexing* shares a resource over time (e.g., CPU scheduling assigns each process a time slice), while *space multiplexing* divides a resource into partitions (e.g., memory pages assigned to different processes). Most OS resources use a combination of both: the CPU is time-multiplexed, memory is space-multiplexed, and the disk is both (space-multiplexed into blocks owned by different files, and time-multiplexed when multiple processes issue I/O requests).

To illustrate the consequences of poor resource management, consider what happens without it. Suppose two programs attempt to write to the same disk block simultaneously. Without OS mediation, one program's data could be partially overwritten by the other, producing a corrupted block that neither intended. The OS prevents this by serialising disk writes through a block I/O layer that queues requests, resolves conflicts, and ensures atomicity.

Similarly, without CPU scheduling, a single compute-bound program would consume 100% of a CPU core indefinitely. Other programs -- including the user's shell and desktop environment -- would be starved of CPU time and become unresponsive. The scheduler prevents this by preempting long-running programs and distributing CPU time according to a fairness policy.

### Role 2: Abstraction Provider

Raw hardware is extraordinarily difficult to program directly. Consider writing data to a spinning hard disk: you would need to issue commands to the disk controller specifying cylinder, head, and sector numbers; handle rotational latency; manage the DMA transfer; poll or handle an interrupt when the transfer completes; and retry on error. Every program that touches the disk would need to duplicate this logic.

The OS provides *abstractions* -- simplified, uniform interfaces that hide hardware complexity:

| Hardware Reality | OS Abstraction |
|---|---|
| Physical RAM addresses | Virtual address spaces |
| Disk sectors and cylinders | Files and directories |
| CPU cores and registers | Processes and threads |
| Network interface cards | Sockets and connections |
| GPU command buffers | Graphics contexts |
| Timer hardware counters | Clock and sleep APIs |

These abstractions serve two purposes. First, they make programming tractable: a `write()` system call is vastly simpler than programming a disk controller. Second, they provide *portability*: the same program binary can run on machines with different disk controllers, as long as the OS exposes the same `write()` interface.

The quality of an abstraction is measured by how well it balances simplicity with power. A too-simple abstraction forces programmers to work around its limitations (e.g., early Unix's lack of file locking forced applications to use ad-hoc locking schemes). A too-complex abstraction is difficult to learn and implement correctly (e.g., the Windows registry, with its hierarchical key-value store, complex permission model, and transaction support).

> **Info:** The concept of abstraction in operating systems mirrors the layered model in computer architecture. Just as the ISA provides an abstraction boundary between hardware and software, the system call interface provides an abstraction boundary between the kernel and user programs. Each layer hides complexity and exposes a cleaner interface to the layer above. The key insight, attributed to David Wheeler, is that "all problems in computer science can be solved by another level of indirection" -- but each level of indirection adds overhead, so the art lies in choosing the right levels.

### Role 3: Protection Boundary

Without an OS, any program could read or write any byte of memory, access any device, and corrupt any other program's data. The OS enforces *isolation*: each process operates within a confined sandbox, unable to interfere with other processes or with the kernel itself.

Protection operates at multiple levels:

- **Memory isolation.** Each process has its own virtual address space. Accessing memory outside that space triggers a hardware fault that the OS intercepts.

- **Privilege separation.** The CPU distinguishes between kernel mode (where the OS runs) and user mode (where applications run). Certain instructions -- such as those that modify page tables or disable interrupts -- are only available in kernel mode.

- **Access control.** The file system enforces permissions: user A cannot read user B's files unless explicitly authorised. On Unix systems, each file has an owner, a group, and permission bits (read, write, execute) for owner, group, and others.

- **Resource limits.** The OS can cap the amount of CPU time, memory, or disk space a process may consume. On Linux, this is enforced via cgroups (control groups), which are the foundation of container isolation.

- **Namespace isolation.** Modern Linux kernels can give each process (or group of processes) its own view of the file system, network stack, process table, and other OS resources. This is the mechanism behind containers: each container sees its own root file system, its own network interfaces, and its own PID 1, even though it shares the host kernel.

> **Tip:** Protection is not merely a security feature -- it is a reliability feature. A bug in one user-space program should not crash the entire system. The OS's protection boundary confines the blast radius of faults to the offending process. This is why a segmentation fault in your web browser does not crash your text editor or your operating system: the hardware MMU and the kernel's signal delivery mechanism collaborate to terminate only the faulting process.

### The Interplay of Roles

The three roles are not independent -- they interact in subtle ways. Resource management often requires protection: the scheduler must prevent a process from consuming more CPU time than its allocation, which requires the timer interrupt (a protection mechanism) to enforce preemption. Abstraction often requires resource management: the virtual memory abstraction allocates physical pages on demand, which is a resource management function. Protection often requires abstraction: the file permission model is an abstraction over raw disk sectors, and the process isolation model is an abstraction over raw memory addresses.

Understanding this interplay is essential for understanding why OS design is difficult. Optimising one role often compromises another. Making the system call interface simpler (better abstraction) may require more kernel code (harder to protect). Making resource allocation more efficient may require exposing hardware details (weaker abstraction). Making protection stronger may require more mode transitions (lower performance).

## A Formal View: The OS as a State Machine

We can model an operating system as a state machine $\mathcal{S} = (Q, q_0, \Sigma, \delta)$ where:

- $Q$ is the set of all possible system states, including the contents of every register, memory cell, and device register.

- $q_0 \in Q$ is the initial state at boot time.

- $\Sigma$ is the set of events: hardware interrupts, system calls, timer ticks, and I/O completions.

- $\delta: Q \times \Sigma \to Q$ is the transition function -- the kernel code that responds to each event and produces a new system state.

Every system call is a transition. When a user program invokes `read(fd, buf, n)`, the event $\sigma_{\text{read}} \in \Sigma$ triggers a transition that may block the calling process, initiate a DMA transfer, and schedule another process to run. The new state $q' = \delta(q, \sigma_{\text{read}})$ reflects all of these changes.

This model is useful for reasoning about correctness. A *safety property* asserts that the system never enters a bad state (e.g., two processes never hold the same lock simultaneously). A *liveness property* asserts that the system eventually reaches a good state (e.g., every I/O request eventually completes). Formal verification of OS kernels, such as the seL4 project, proves these properties rigorously over the state machine model.

$$
\forall q \in Q, \forall \sigma \in \Sigma: \text{invariant}(q) \implies \text{invariant}(\delta(q, \sigma))
$$

The equation above expresses the key inductive argument: if the system invariant holds in state $q$, it must also hold after any transition. This is the foundation of every kernel correctness proof.

The state space $Q$ of a real operating system is astronomically large -- for a system with 16 GB of RAM, $|Q| \geq 2^{128 \times 10^9}$, making exhaustive exploration impossible. Formal verification works by proving properties about the *transition function* $\delta$ rather than enumerating states. If we can prove that $\delta$ preserves the invariant for every possible input, we know the invariant holds in every reachable state, regardless of how many states exist.

## Historical Evolution

The history of operating systems is a history of increasing abstraction, driven by the need to share ever-more-powerful hardware among ever-more-demanding users.

### Era 1: No Operating System (1940s--1950s)

The earliest computers -- ENIAC, EDSAC, UNIVAC -- had no operating system at all. A single programmer had exclusive access to the machine for a scheduled block of time. Programs were loaded via punched cards or paper tape, and the programmer interacted directly with the hardware through front-panel switches and lights.

The workflow was:

1. Sign up for a time slot on the machine (perhaps 2 hours).
2. Arrive at the machine room with a deck of punched cards.
3. Load the cards into the card reader.
4. Set switches on the front panel to configure the initial state.
5. Press the start button.
6. Wait. If the program crashed, examine the console lights and registers to diagnose the problem.
7. Fix the error, modify the card deck, and repeat.

This approach was simple but extraordinarily wasteful. The computer sat idle while the programmer debugged their program, loaded cards, or examined output. CPU utilisation rates were often below 10%. A machine that cost millions of dollars spent most of its time waiting for humans.

### Era 2: Batch Systems (Late 1950s--1960s)

To improve utilisation, operators began grouping jobs into *batches*. A resident monitor -- the first operating system -- loaded jobs sequentially from a card reader, executed each one, and printed the output. The programmer never touched the machine directly; instead, they submitted a deck of cards and collected printout hours or days later.

```text
 BATCH PROCESSING TIMELINE
 ─────────────────────────────────────────────────────────────
  Time ──────────────────────────────────────────────────────▶

  CPU:  │ Job A │ Job B │ Job C │ Job D │ Job E │
        ├───────┼───────┼───────┼───────┼───────┤
  I/O:  │ idle  │ idle  │ idle  │ idle  │ idle  │

  Problem: CPU waits for I/O; I/O waits for CPU.
  Utilisation remains low because jobs are sequential.
 ─────────────────────────────────────────────────────────────
```

The batch monitor introduced the first system calls -- primitives for reading cards, writing to the printer, and signalling job completion. It also introduced the first protection problem: a buggy job could overwrite the monitor itself. Early solutions used hardware *memory bounds registers* to confine each job to its allocated region.

Job Control Language (JCL) emerged as the first "shell" -- a way for programmers to specify job parameters (which compiler to use, which input files to read, which output files to write) in the card deck itself. IBM's JCL for OS/360 was notoriously cryptic:

```text
//MYJOB  JOB  (ACCT),'PROGRAMMER NAME',CLASS=A
//STEP1  EXEC PGM=FORTRAN
//SYSIN  DD   *
      PROGRAM HELLO
      PRINT *, 'HELLO WORLD'
      END
/*
//SYSPRINT DD  SYSOUT=A
```

### Era 3: Multiprogramming (1960s--1970s)

The key insight of multiprogramming was that while one job waits for I/O (a disk read, a tape rewind), the CPU could execute another job. By keeping multiple jobs in memory simultaneously and switching between them, the CPU could be kept busy almost continuously.

```text
 MULTIPROGRAMMING TIMELINE
 ─────────────────────────────────────────────────────────────
  Time ──────────────────────────────────────────────────────▶

  CPU:  │ Job A │ Job B │ Job A │ Job C │ Job B │ Job C │
        ├───────┼───────┼───────┼───────┼───────┼───────┤
  I/O:  │       │ A:disk│       │ A:net │ C:dsk │       │

  While Job A waits for disk I/O, the CPU runs Job B.
  CPU utilisation increases dramatically.
 ─────────────────────────────────────────────────────────────
```

Multiprogramming required significant OS infrastructure:

- **Memory management** -- multiple jobs in memory simultaneously, each needing protection from the others. Base and limit registers were used initially; later systems introduced segmentation and paging.

- **CPU scheduling** -- deciding which job to run when the current one blocks on I/O. Early schedulers used simple priority schemes; later ones introduced round-robin and multi-level feedback queues.

- **I/O device management** -- handling concurrent I/O requests from multiple jobs without corruption. Device queues, interrupt handlers, and DMA transfers all originated in this era.

- **Spooling** -- Simultaneous Peripheral Operation On-Line. Output was written to disk rather than directly to the printer, allowing multiple jobs' output to be printed later without tying up the CPU.

IBM's OS/360 (1964) was the landmark multiprogramming system. It supported multiple job classes, spooled I/O, and a rudimentary file system. It was also notoriously complex -- Fred Brooks' *The Mythical Man-Month* drew its lessons from the OS/360 project, concluding that "adding manpower to a late software project makes it later."

We can quantify the benefit of multiprogramming. If a single job spends a fraction $p$ of its time waiting for I/O, then the CPU utilisation with $n$ jobs in memory (assuming they all have independent I/O patterns) is:

$$
U = 1 - p^n
$$

For $p = 0.8$ (a job that spends 80% of its time waiting for I/O):

| $n$ (jobs in memory) | $U$ (CPU utilisation) |
|---|---|
| 1 | 0.20 |
| 2 | 0.36 |
| 4 | 0.59 |
| 8 | 0.83 |
| 16 | 0.97 |

This formula, while simplified (it assumes statistical independence of I/O patterns), demonstrates why multiprogramming was transformative: even with heavily I/O-bound jobs, keeping enough of them in memory ensures high CPU utilisation.

### Era 4: Time-Sharing (1970s--1980s)

Multiprogramming optimised throughput -- total work done per unit time. But interactive users care about *response time* -- how quickly the system responds to a keystroke. Time-sharing systems gave each user a short *quantum* of CPU time (typically 10--100 milliseconds) and rapidly rotated among users, creating the illusion that each had a dedicated machine.

> **Note:** The distinction between multiprogramming and time-sharing is one of emphasis, not mechanism. Both keep multiple programs in memory and switch between them. Multiprogramming switches on I/O events to maximise throughput; time-sharing switches on timer interrupts to minimise response time. Modern systems do both simultaneously.

MIT's Compatible Time-Sharing System (CTSS, 1961) and Multics (1969) pioneered these ideas. CTSS was one of the first systems to provide interactive computing to multiple simultaneous users, each with their own terminal. Its success demonstrated that time-sharing was practical, contradicting sceptics who believed the overhead of context switching would make it uneconomical.

Multics, a joint project between MIT, Bell Labs, and General Electric, was far more ambitious. It introduced concepts that remain central to modern operating systems:

- Hierarchical file system with directory trees and path names
- Per-process virtual memory with demand paging (segments and pages)
- Dynamic linking of shared libraries at load time
- Ring-based protection (eight privilege levels, more than any successor has used)
- Access control lists on files (beyond simple permission bits)
- Hot-pluggable hardware and online reconfiguration
- A shell implemented as a user-level program (not built into the kernel)

Multics was commercially unsuccessful -- too complex, too slow, too expensive. But its influence was enormous: virtually every OS concept in use today can be traced to Multics.

### Era 5: Unix and the Modern Era (1970s--Present)

Ken Thompson and Dennis Ritchie, frustrated by Multics' complexity, created Unix at Bell Labs in 1969. Where Multics was ambitious and baroque, Unix was minimalist and elegant. Its design philosophy -- small programs that do one thing well, connected by pipes -- proved extraordinarily influential.

Unix introduced or popularised:

- The process model (fork/exec/wait) -- a clean separation between creating a process and specifying what it should run
- The unified file abstraction ("everything is a file") -- devices, pipes, and sockets are all accessed through file descriptors
- The shell as a user-level program -- not part of the kernel, replaceable by the user
- Pipes for inter-process communication -- connecting the output of one program to the input of another
- The C programming language as a systems implementation language
- Portable OS code (Unix was rewritten in C in 1973, making it the first portable operating system)
- Regular expressions for text processing (through tools like `grep`, `sed`, `awk`)

From Unix descended two major lineages: the BSD family (FreeBSD, OpenBSD, NetBSD, macOS) and the System V family (Solaris, AIX, HP-UX). Linux, created by Linus Torvalds in 1991, borrowed Unix's design but was written from scratch, avoiding AT&T licensing issues.

The Unix philosophy can be summarised in three principles, articulated by Doug McIlroy:

1. Make each program do one thing well.
2. Expect the output of every program to become the input to another.
3. Design and build software to be tried early, ideally within weeks.

These principles shaped not just operating system design but the entire culture of software engineering.

### Timeline Summary

| Era | Period | Key Systems | Key Innovation |
|---|---|---|---|
| No OS | 1940s--1950s | ENIAC, EDSAC | Direct hardware access |
| Batch | Late 1950s--1960s | FMS, IBSYS | Resident monitor, job queues |
| Multiprogramming | 1960s--1970s | OS/360, THE | Multiple jobs in memory |
| Time-sharing | 1970s--1980s | CTSS, Multics | Interactive terminals, quanta |
| Modern | 1970s--present | Unix, Linux, Windows NT | Portability, networking, virtualisation |

## Kernel Mode vs User Mode

The most fundamental architectural feature that enables an operating system is the CPU's *dual-mode operation*. The processor maintains a status bit -- often called the *mode bit* -- that indicates whether the currently executing code is trusted (kernel mode) or untrusted (user mode).

### Kernel Mode (Supervisor Mode)

In kernel mode, the CPU can execute *any* instruction, including privileged instructions that:

- Modify the page table base register (changing virtual-to-physical address mappings)
- Enable or disable hardware interrupts
- Access I/O device registers directly
- Execute the `HLT` instruction to halt the processor
- Write to model-specific registers (MSRs) for CPU configuration
- Load the interrupt descriptor table register (IDTR)
- Load the global descriptor table register (GDTR)
- Access debug registers for hardware breakpoints

Only the operating system kernel runs in kernel mode. When the kernel executes, it has unrestricted access to all hardware and all memory. This is an immense amount of power, which is why kernel code must be written with extreme care: a bug in the kernel can compromise the entire system.

### User Mode

In user mode, the CPU restricts the instruction set. Any attempt to execute a privileged instruction triggers a *general protection fault* -- a hardware exception that transfers control to the kernel. The offending process is typically terminated with a signal (e.g., `SIGSEGV` or `SIGILL` on Unix).

User-mode code can only access its own virtual address space. It cannot directly touch hardware devices, other processes' memory, or kernel data structures. This restriction is enforced by the hardware MMU (Memory Management Unit), which consults the page table on every memory access and checks the access permissions.

The restrictions of user mode are comprehensive:

- Cannot modify page tables (so it cannot access other processes' memory)
- Cannot disable interrupts (so the kernel can always preempt it)
- Cannot access I/O ports (so it cannot directly control hardware)
- Cannot change the privilege level (so it cannot promote itself to kernel mode)
- Cannot access kernel memory (even though kernel pages exist in the same virtual address space, they are marked supervisor-only)

### Mode Transitions

There are exactly three ways to transition from user mode to kernel mode:

1. **System call (trap).** The user program executes a special instruction (`SYSCALL` on x86-64, `SVC` on ARM) that transfers control to the kernel at a predetermined entry point. This is a *voluntary* transition -- the user program explicitly requests kernel services.

2. **Hardware interrupt.** An external device (disk controller, network card, timer) signals the CPU. The CPU suspends the current user program and transfers control to the kernel's interrupt handler. This is an *involuntary* transition -- the user program did not request it and may not even be aware of it.

3. **Exception (fault).** The user program triggers an error condition -- a page fault, a division by zero, an illegal instruction. The CPU transfers control to the kernel's exception handler. This is also involuntary, but unlike interrupts, it is caused by the program's own instruction, not by an external event.

```text
 MODE TRANSITIONS
 ─────────────────────────────────────────────────────────────

           System Call         Interrupt          Exception
  User ──────────────▶ Kernel ◀────────── Hardware
  Mode   (voluntary)   Mode   (involuntary)       Mode
           ◀──────────                        ▲
           return from                        │
           system call                        │
                                         Page fault,
                                         div by zero,
                                         illegal insn
 ─────────────────────────────────────────────────────────────
```

The transition from kernel mode back to user mode occurs when the kernel executes a special return instruction (`SYSRET` on x86-64, `ERET` on ARM) that restores the saved user-mode context and clears the kernel-mode bit.

Importantly, there is no way to transition from user mode to kernel mode at an arbitrary kernel address. The `SYSCALL` instruction always jumps to the address stored in a specific MSR (Model-Specific Register), which is set by the kernel during boot and cannot be modified from user mode. Similarly, interrupts and exceptions always vector through the Interrupt Descriptor Table (IDT), which is also set by the kernel. This *controlled entry* property is essential for security: without it, a malicious program could jump to the middle of a kernel function, bypassing security checks.

> **Programmer:** Understanding mode transitions explains why system calls are expensive relative to ordinary function calls. A regular function call on x86-64 involves pushing a return address and jumping to the target -- roughly 1--2 nanoseconds. A system call requires saving all user-mode registers, switching the stack pointer to the kernel stack, executing the kernel code, restoring registers, and switching back. On a modern x86-64 processor, the `SYSCALL`/`SYSRET` pair alone costs approximately 50--100 nanoseconds, plus the actual kernel work. On systems with Meltdown mitigations (KPTI -- Kernel Page Table Isolation), each mode switch requires flushing page table entries, adding another 200--500 nanoseconds. This is why high-performance systems use techniques like `io_uring` (Linux 5.1+) to batch system calls and reduce mode transitions. In Go, the runtime's `syscall.RawSyscall` bypasses some runtime bookkeeping for performance, but even so, the hardware cost of the mode switch remains.

### The System Call as the OS API

System calls are the *only* mechanism by which user-space programs can request services from the kernel. They form the Application Programming Interface of the operating system.

A system call is conceptually similar to a function call, but with three critical differences:

1. **Privilege elevation.** The system call transitions the CPU to kernel mode, granting access to privileged resources.

2. **Controlled entry point.** The user program cannot jump to an arbitrary kernel address. The `SYSCALL` instruction always vectors to a single entry point (the system call dispatcher), which uses the system call number to index into a jump table.

3. **Argument validation.** The kernel must validate every argument passed from user space. A user could pass a malicious pointer or an out-of-range value. Trusting user-supplied data without validation is the root cause of many kernel security vulnerabilities.

The typical system call flow on x86-64 Linux proceeds as follows:

```text
 SYSTEM CALL FLOW (x86-64 Linux)
 ─────────────────────────────────────────────────────────────

 User Space:
   1. Place system call number in RAX
   2. Place arguments in RDI, RSI, RDX, R10, R8, R9
   3. Execute SYSCALL instruction

 ─── mode switch ─── (hardware saves RIP, RFLAGS to RCX, R11)

 Kernel Space:
   4. entry_SYSCALL_64 saves user registers on kernel stack
   5. Index into sys_call_table[RAX]
   6. Execute the handler (e.g., sys_read, sys_write)
   7. Place return value in RAX
   8. Execute SYSRET instruction

 ─── mode switch ─── (hardware restores RIP, RFLAGS from RCX, R11)

 User Space:
   9. Check RAX for error (negative = -errno)
 ─────────────────────────────────────────────────────────────
```

A concrete example in C -- reading bytes from a file:

```c
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>

int main(void) {
    char buf[1024];
    int fd = open("/etc/hostname", O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n < 0) {
        perror("read");
        close(fd);
        return 1;
    }

    buf[n] = '\0';
    printf("hostname: %s", buf);
    close(fd);
    return 0;
}
```

In this program, `open()`, `read()`, `write()` (called by `printf` internally), and `close()` are all system calls. Each one triggers a user-to-kernel-to-user mode transition. The C library (`glibc`, `musl`) provides thin wrapper functions that set up registers and execute the `SYSCALL` instruction.

The number of system calls varies by OS. Linux 6.x defines approximately 450 system calls (the exact number depends on the architecture). macOS defines approximately 500. Windows defines roughly 2000 (though many are undocumented). The trend is toward more system calls over time, as new kernel features are added.

## OS Structure Overview

A modern operating system is organised into several subsystems, each managing a different class of resource. These subsystems interact extensively but can be understood independently.

### The Process Subsystem

A *process* is an instance of a running program. It consists of:

- A virtual address space (code, data, heap, stack segments)
- One or more threads of execution, each with its own program counter, stack pointer, and register state
- Open file descriptors, signal handlers, and other kernel-managed metadata
- A process ID (PID), parent process ID (PPID), user ID (UID), and group ID (GID)
- Scheduling priority and CPU affinity
- Resource usage counters (CPU time consumed, memory pages allocated, I/O bytes transferred)

The process subsystem handles:

- **Process creation** (`fork()` on Unix, `CreateProcess()` on Windows) -- creating new processes by cloning existing ones or loading new programs.

- **Process termination** (`exit()`, signal delivery) -- cleaning up resources when a process finishes or is killed.

- **CPU scheduling** (selecting which process/thread runs next on each core) -- the topic of Chapters 5 and 6 of this book.

- **Inter-process communication** (pipes, shared memory, message queues, sockets) -- allowing processes to exchange data and coordinate.

- **Synchronisation** (mutexes, semaphores, condition variables) -- preventing race conditions when multiple threads access shared data.

> **Info:** The process is arguably the most important abstraction in operating systems. Every other subsystem exists to serve processes: memory management provides each process with a virtual address space, the file system provides persistent storage for process data, and the I/O subsystem provides communication channels. The process concept is so fundamental that it appears in every OS ever built, from the simplest embedded RTOS to the most complex mainframe OS.

### The Memory Subsystem

The memory subsystem manages the mapping between *virtual addresses* (what processes see) and *physical addresses* (actual RAM locations). Key responsibilities include:

- **Virtual memory** -- giving each process the illusion of a large, contiguous address space, even when physical RAM is limited. On a 64-bit system, each process can address up to $2^{48}$ bytes (256 TB) of virtual memory, even though the machine may have only 16 GB of physical RAM.

- **Demand paging** -- loading pages from disk into RAM only when accessed, and evicting infrequently used pages back to disk (the swap partition or swap file).

- **Page table management** -- maintaining the multi-level data structures that the hardware MMU uses to translate virtual addresses to physical addresses.

- **Memory protection** -- ensuring that each process can only access its own pages, and that read-only pages (such as code) cannot be written.

- **Shared memory** -- allowing multiple processes to share physical pages, used for inter-process communication and shared libraries (e.g., `libc.so` is mapped into every process's address space but exists only once in physical RAM).

The memory subsystem interacts tightly with the hardware Memory Management Unit (MMU). When a process accesses a virtual address, the MMU translates it to a physical address using the page table. If the page is not in RAM (a *page fault*), the MMU raises an exception, and the kernel's page fault handler loads the page from disk.

$$
\text{virtual address} \xrightarrow{\text{MMU + page table}} \text{physical address}
$$

On a system with 4 KB pages (the standard on x86-64), a 256 TB virtual address space contains $2^{48} / 2^{12} = 2^{36} \approx 68$ billion virtual pages. Storing a page table entry for each would require 512 GB of RAM -- larger than the address space itself. This is why page tables use a multi-level tree structure (4 levels on x86-64), where only the branches corresponding to mapped pages actually exist.

### The File Subsystem

The file system provides a persistent, hierarchical namespace for data. It abstracts away the details of disk geometry (sectors, tracks, platters) or flash translation layers (wear levelling, garbage collection) and presents a simple model: named files organised in directories.

Key responsibilities:

- **Namespace management** -- creating, deleting, and renaming files and directories. The namespace is a tree (or DAG, in the case of hard links) rooted at `/`.

- **Storage allocation** -- mapping file data to disk blocks and managing free space. Different file systems use different allocation strategies: ext4 uses extents (contiguous runs of blocks), btrfs uses B-trees, and ZFS uses a copy-on-write block allocation tree.

- **Metadata management** -- maintaining file attributes (size, permissions, timestamps, ownership) in data structures called *inodes* (on Unix) or *MFT entries* (on NTFS).

- **Caching** -- buffering frequently accessed file data in RAM (the *page cache* on Linux) to reduce disk I/O. On a system with ample RAM, the page cache can absorb the vast majority of read operations, serving data from memory at nanosecond latency rather than from disk at millisecond latency.

- **Journaling/logging** -- ensuring file system consistency after crashes. A journaling file system (ext4, NTFS, XFS) writes pending metadata changes to a log before applying them. If the system crashes mid-operation, the log can be replayed at boot time to restore consistency.

- **Virtual File System (VFS)** -- a kernel-internal abstraction layer that presents a uniform interface to user space, regardless of the underlying file system type. The VFS allows a single `read()` system call to work whether the file resides on ext4, NFS, procfs, or a FUSE-based user-space file system.

### The I/O Subsystem

The I/O subsystem manages communication with hardware devices: disks, network interfaces, keyboards, displays, USB devices, and more. It provides a layered architecture:

```text
 I/O SUBSYSTEM LAYERS
 ─────────────────────────────────────────────────────────────
  User program
      │
      ▼
  System call interface    (read, write, ioctl)
      │
      ▼
  Device-independent layer (buffering, caching, error handling)
      │
      ▼
  Device driver            (hardware-specific code)
      │
      ▼
  Device controller        (hardware registers, DMA)
      │
      ▼
  Physical device           (disk, NIC, keyboard)
 ─────────────────────────────────────────────────────────────
```

The *device driver* is the critical abstraction boundary. Each driver understands the specific hardware it manages and presents a uniform interface to the device-independent layer above. This is why adding a new hardware device to an OS requires only writing a new driver, not modifying the kernel's core I/O logic.

On Linux, the device driver model distinguishes between:

- **Character devices** (serial ports, keyboards, mice) -- accessed as a stream of bytes, one at a time.
- **Block devices** (disks, SSDs) -- accessed in fixed-size blocks, with a request queue and I/O scheduler.
- **Network devices** (Ethernet, Wi-Fi) -- accessed through the socket API, with a packet-based interface.

### Subsystem Interactions

These four subsystems do not operate in isolation. Consider what happens when a process calls `read(fd, buf, 4096)`:

1. The **process subsystem** identifies the calling process and validates the file descriptor `fd` against the process's file descriptor table.

2. The **file subsystem** looks up the VFS inode associated with `fd`, determines the file system type, and calls the appropriate file system's `read` method. The method maps the file offset to a disk block number, checking the page cache first.

3. If the data is cached in the page cache, the **memory subsystem** copies it directly from the cache page to the user-space buffer at address `buf`. The `read()` returns immediately, without any disk I/O.

4. If the data is not cached, the **I/O subsystem** issues a read request to the disk driver, which programs the disk controller via DMA.

5. The **process subsystem** blocks the calling thread and schedules another runnable thread to use the CPU.

6. When the disk DMA transfer completes, the disk controller raises a hardware interrupt. The **I/O subsystem** invokes the driver's interrupt handler, which marks the I/O request as complete and wakes the page cache waiter.

7. The **memory subsystem** copies the data from the newly populated page cache page into the process's user-space buffer at address `buf`, checking that the destination page is mapped and writable.

8. The **process subsystem** unblocks the calling thread and eventually schedules it to resume. The `read()` system call returns the number of bytes read.

A single `read()` call thus involves all four subsystems cooperating through well-defined internal interfaces.

## POSIX and the System Call Interface

### What is POSIX?

POSIX (Portable Operating System Interface) is a family of standards specified by IEEE (formally, IEEE 1003) that define the API, shell, and utility interfaces for Unix-like operating systems. POSIX compliance means that a program written using POSIX APIs can be compiled and run on any conforming system without modification.

> **Note:** POSIX is a *source-level* portability standard, not a binary compatibility standard. A POSIX program must be recompiled for each target platform because different systems have different instruction sets, calling conventions, and binary formats. Binary compatibility is handled separately by standards like the ELF specification and platform-specific ABIs (Application Binary Interfaces).

POSIX was created in the 1980s to resolve the growing incompatibilities between different Unix variants. As Unix fragmented into BSD, System V, and various vendor-specific versions, programs written for one variant often failed to compile on another. POSIX defined a common subset that all Unix-like systems could agree on, restoring portability.

The standard is organised into several parts:

- **POSIX.1 (IEEE 1003.1)** -- the core API: system calls, C library functions, header files, and error codes.
- **POSIX.2 (IEEE 1003.2)** -- the shell and utility interface: the behaviour of `sh`, `awk`, `grep`, `make`, and other standard commands.
- **POSIX threads (pthreads)** -- the multi-threading API: thread creation, mutexes, condition variables, read-write locks.
- **POSIX real-time extensions** -- priority scheduling, timers, asynchronous I/O, message queues.

### Key POSIX System Calls

The POSIX system call interface encompasses several hundred calls. The most fundamental ones fall into categories:

**Process management:**

| System Call | Purpose |
|---|---|
| `fork()` | Create a child process (clone of the parent) |
| `exec()` | Replace the current process image with a new program |
| `wait()` / `waitpid()` | Wait for a child process to terminate |
| `exit()` | Terminate the calling process |
| `getpid()` | Return the process ID |
| `kill()` | Send a signal to a process |

**File operations:**

| System Call | Purpose |
|---|---|
| `open()` | Open a file and return a file descriptor |
| `close()` | Close a file descriptor |
| `read()` | Read bytes from a file descriptor |
| `write()` | Write bytes to a file descriptor |
| `lseek()` | Reposition the file offset |
| `stat()` | Retrieve file metadata |
| `unlink()` | Remove a directory entry (delete a file) |

**Directory operations:**

| System Call | Purpose |
|---|---|
| `mkdir()` | Create a directory |
| `rmdir()` | Remove an empty directory |
| `opendir()` / `readdir()` | Iterate over directory entries |
| `chdir()` | Change the working directory |

**Inter-process communication:**

| System Call | Purpose |
|---|---|
| `pipe()` | Create a unidirectional data channel |
| `mmap()` | Map a file or device into memory |
| `shmget()` / `shmat()` | System V shared memory |
| `socket()` / `bind()` / `listen()` / `accept()` | Network communication |

### The fork-exec Model

The Unix process creation model is distinctive: creating a new process is separated into two steps.

1. `fork()` creates an exact copy of the calling process. Both parent and child resume execution at the instruction following the `fork()` call. The only difference is the return value: `fork()` returns 0 in the child and the child's PID in the parent.

2. `exec()` replaces the calling process's memory image with a new program loaded from disk. The process ID does not change -- the same process is now running a different program.

This two-step design is elegant because it allows the parent to modify the child's environment between `fork()` and `exec()` -- for example, redirecting file descriptors to implement shell I/O redirection, changing the working directory, setting environment variables, or modifying signal handlers.

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

int main(void) {
    pid_t pid = fork();

    if (pid < 0) {
        perror("fork");
        return 1;
    }

    if (pid == 0) {
        /* Child process */
        printf("Child: my PID is %d, parent PID is %d\n",
               getpid(), getppid());

        /* Replace this process with /bin/ls */
        execlp("ls", "ls", "-l", "/tmp", NULL);

        /* If exec returns, it failed */
        perror("execlp");
        exit(1);
    }

    /* Parent process */
    printf("Parent: created child with PID %d\n", pid);

    int status;
    waitpid(pid, &status, 0);

    if (WIFEXITED(status)) {
        printf("Parent: child exited with status %d\n",
               WEXITSTATUS(status));
    }

    return 0;
}
```

Modern implementations of `fork()` use *copy-on-write* (COW) semantics: the parent and child initially share the same physical memory pages, marked read-only. Only when either process writes to a page is a private copy made. This makes `fork()` fast even for processes with large address spaces, because the copying is deferred until (and unless) it is needed.

> **Programmer:** Go deliberately avoids exposing `fork()` directly because goroutines and the Go runtime's thread model make `fork()` semantics dangerous. When you `fork()` a multi-threaded process, only the calling thread survives in the child -- all other threads vanish, potentially leaving mutexes locked and data structures in inconsistent states. The Go runtime is inherently multi-threaded (the garbage collector, the network poller, and the timer goroutine all run on separate OS threads), so `fork()` would leave the child in an unrecoverable state. Instead, Go provides `os/exec.Command()` which internally uses a combination of `clone()` (on Linux) or `posix_spawn()` to safely create child processes. If you need low-level control, the `syscall` package exposes `syscall.ForkExec()`, which atomically forks and execs in a single operation, avoiding the hazardous window between `fork()` and `exec()`.

### File Descriptors: The Universal Handle

In Unix, a *file descriptor* is a small non-negative integer that serves as a handle to an open file, pipe, socket, or device. File descriptors are per-process: each process maintains a table mapping integers to kernel file objects.

By convention, every process starts with three open file descriptors:

| FD | Name | C Constant | Purpose |
|---|---|---|---|
| 0 | Standard input | `STDIN_FILENO` | Input stream (keyboard by default) |
| 1 | Standard output | `STDOUT_FILENO` | Output stream (terminal by default) |
| 2 | Standard error | `STDERR_FILENO` | Error stream (terminal by default) |

The beauty of this design is *uniformity*. The `read()` and `write()` system calls work identically regardless of whether the file descriptor refers to a regular file, a pipe, a network socket, or a hardware device. This is the Unix philosophy of "everything is a file" -- or more precisely, "everything is a file descriptor."

This uniformity has profound consequences for software composition. The shell command `sort < input.txt | uniq > output.txt` works because:

1. `sort` reads from FD 0 (redirected to `input.txt` by the shell).
2. `sort` writes to FD 1 (connected to `uniq`'s FD 0 by a pipe).
3. `uniq` reads from FD 0 (the pipe) and writes to FD 1 (redirected to `output.txt`).

Neither `sort` nor `uniq` needs to know anything about files, pipes, or I/O redirection. They simply read from FD 0 and write to FD 1. The shell arranges the plumbing using `fork()`, `exec()`, `pipe()`, and `dup2()`.

```c
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

int main(void) {
    const char *msg = "Hello from file descriptor 1\n";

    /* Write to stdout using the raw system call */
    write(STDOUT_FILENO, msg, strlen(msg));

    /* Open a file -- returns the lowest available FD */
    int fd = open("/tmp/test.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        const char *data = "Written via file descriptor\n";
        write(fd, data, strlen(data));
        close(fd);
    }

    return 0;
}
```

### Beyond POSIX: Linux-Specific Extensions

While POSIX provides a portable baseline, Linux extends it significantly with system calls that have no POSIX equivalent:

- `epoll` -- scalable I/O event notification (replaces `select`/`poll` for high-connection-count servers). Can monitor millions of file descriptors efficiently using a kernel-internal red-black tree.

- `io_uring` -- asynchronous I/O with shared ring buffers between kernel and user space. Allows submitting and completing I/O operations with zero system calls in the steady state (the kernel and user space communicate through shared memory queues).

- `clone()` -- fine-grained process/thread creation (more flexible than `fork()`). The caller specifies exactly which resources to share with the child: memory, file descriptors, signal handlers, PID namespace, network namespace, etc.

- `namespaces` and `cgroups` -- the building blocks of containers. Namespaces provide isolated views of system resources (PID, network, filesystem, user IDs). Cgroups limit, account for, and isolate resource usage (CPU, memory, I/O).

- `seccomp` -- system call filtering for sandboxing. A process can install a BPF filter that restricts which system calls it (and its children) can invoke, reducing the attack surface.

- `bpf()` -- programmable in-kernel virtual machine for tracing, networking, and security. eBPF programs are verified for safety before execution and run at near-native speed.

These extensions are not portable to other Unix systems, but they enable performance and functionality that POSIX alone cannot provide.

## The System Call Interface in Practice

### Tracing System Calls with strace

The `strace` utility intercepts and records every system call made by a process. It is the single most useful tool for understanding the interaction between a program and the OS kernel.

```c
/* trace_demo.c -- a minimal program to demonstrate strace */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

int main(void) {
    /* This single line generates multiple system calls:
     * write() to stdout, and internally fstat() to check
     * if stdout is a terminal (for buffering decisions). */
    printf("Hello, OS Theory!\n");

    /* Explicit file I/O */
    int fd = open("/tmp/os_demo.txt",
                  O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    const char *data = "Operating Systems Theory\n";
    write(fd, data, strlen(data));
    close(fd);

    return 0;
}
```

Compiling and tracing this program:

```text
$ gcc -o trace_demo trace_demo.c
$ strace -e trace=open,openat,read,write,close ./trace_demo

openat(AT_FDCWD, "/tmp/os_demo.txt", O_WRONLY|O_CREAT|O_TRUNC, 0644) = 3
write(1, "Hello, OS Theory!\n", 18)     = 18
write(3, "Operating Systems Theory\n", 25) = 25
close(3)                                = 0
+++ exited with 0 +++
```

Each line shows: the system call name, its arguments, and its return value. This reveals exactly how the program interacts with the kernel -- information that is invisible from source code alone.

> **Programmer:** When you use `strace` to trace a Go program, you will see Linux-specific system calls that the Go runtime uses internally. For example, `futex()` for goroutine synchronisation, `clone()` for creating OS threads, `epoll_wait()` for the network poller, and `mmap()`/`madvise()` for memory management. Running `strace -c ./myprogram` gives you a summary of all system calls and their frequency -- an invaluable tool for understanding where your program spends its time in the kernel. Try it on a simple Go HTTP server and you will see that `epoll_wait` dominates, as the runtime's netpoller waits for incoming connections. The `-f` flag traces all child threads, which is essential for Go programs since the runtime spawns multiple OS threads. The `ltrace` tool is the user-space counterpart, tracing library calls rather than system calls. Together, `strace` and `ltrace` give you a complete picture of the boundary between your code and the OS.

### System Call Overhead

System calls are not free. Each invocation incurs overhead from:

1. **Mode switch cost.** The `SYSCALL`/`SYSRET` instruction pair on x86-64 takes approximately 50--150 cycles.

2. **TLB and cache effects.** Entering the kernel may pollute the L1 instruction cache and TLB with kernel code and data, displacing user-space entries.

3. **Security mitigations.** On systems with Meltdown/Spectre mitigations enabled (KPTI -- Kernel Page Table Isolation), each mode switch requires flushing and reloading page tables, adding 200--500 cycles.

4. **Argument validation.** The kernel must check every pointer and length argument for validity before using it.

5. **Auditing and security hooks.** If SELinux, AppArmor, or other Linux Security Modules (LSMs) are active, each system call triggers security policy checks.

The following table shows approximate costs for common system calls on a modern x86-64 Linux system (single-core, no contention):

| System Call | Approximate Latency |
|---|---|
| `getpid()` | 50--100 ns (cached, vDSO-optimised) |
| `gettimeofday()` | 15--30 ns (vDSO, no kernel entry) |
| `read()` (cached data) | 200--500 ns |
| `write()` (buffered) | 200--500 ns |
| `open()` | 1--5 $\mu$s (path resolution, permission checks) |
| `fork()` | 50--200 $\mu$s (depends on address space size) |
| `mmap()` | 1--10 $\mu$s |

> **Note:** Linux's vDSO (virtual Dynamic Shared Object) is a clever optimisation that maps a small kernel-provided shared library into every process's address space. Functions like `gettimeofday()` can read the current time from a memory-mapped kernel page without ever entering kernel mode, reducing their cost from hundreds of nanoseconds to tens. The vDSO contains read-only data that the kernel updates on every timer tick, and a handful of functions that can operate on this data entirely in user space. The `clock_gettime()`, `getcpu()`, and `gettimeofday()` functions are all vDSO-accelerated on Linux.

### The Cost-Benefit Calculus

Understanding system call overhead informs practical design decisions. Consider a program that reads a file byte by byte:

```c
/* Slow: one system call per byte */
char c;
while (read(fd, &c, 1) == 1) {
    process(c);
}
```

If the file contains $n$ bytes, this issues $n$ system calls, each costing approximately 300 ns. For a 1 MB file ($n = 10^6$), the overhead alone is 300 milliseconds -- entirely dominated by mode-switch costs.

The solution is *buffered I/O*: read large blocks and process them in user space.

```c
/* Fast: one system call per 4096 bytes */
char buf[4096];
ssize_t n;
while ((n = read(fd, buf, sizeof(buf))) > 0) {
    for (ssize_t i = 0; i < n; i++) {
        process(buf[i]);
    }
}
```

Now the same 1 MB file requires only 256 system calls ($10^6 / 4096 \approx 256$), reducing overhead to approximately 77 microseconds -- a 4000x improvement. This is precisely why the C standard library's `stdio.h` (`fread`, `fgets`, `fprintf`) performs user-space buffering automatically.

$$
\text{overhead} = n_{\text{syscalls}} \times t_{\text{syscall}} = \left\lceil \frac{\text{file size}}{\text{buffer size}} \right\rceil \times t_{\text{syscall}}
$$

As the buffer size increases, the overhead decreases hyperbolically. But beyond a point (typically 4--16 KB, matching the OS page size and disk sector size), the benefit of larger buffers diminishes because the per-byte transfer cost dominates and cache locality degrades.

## The Kernel's Execution Model

A common misconception is that the kernel is a separate program running alongside user processes. In reality, the kernel has no dedicated process or thread of its own (with minor exceptions for kernel worker threads). Instead, the kernel executes *on behalf of* user processes.

When process P makes a system call, P's thread transitions to kernel mode and executes kernel code. From the scheduler's perspective, the thread is still "P's thread" -- it simply has elevated privileges. The kernel's code runs in P's context, using P's kernel stack.

Similarly, when a hardware interrupt arrives while process P is running, P's thread is commandeered to execute the interrupt handler. After the handler completes, control may return to P or switch to a different process if the scheduler so decides.

This model has important implications:

- The kernel does not consume CPU time independently; its time is charged to the processes that invoke it. In `top` or `htop`, the "system" CPU percentage reflects time spent in kernel mode on behalf of user processes.

- Kernel code must be reentrant: multiple threads may be executing kernel code simultaneously on different cores. Shared kernel data structures must be protected by locks or other synchronisation mechanisms.

- Kernel code must never block indefinitely while holding a spinlock, because doing so would prevent other threads from making progress on that core (and potentially cause deadlock if another core needs the same lock).

- The kernel stack is a limited resource -- typically 8 KB or 16 KB per thread on Linux. Kernel functions must be conservative with stack usage; deep recursion or large stack-allocated buffers can overflow the kernel stack, causing a kernel panic.

```text
 KERNEL EXECUTION MODEL
 ─────────────────────────────────────────────────────────────
  Core 0                    Core 1
  ─────────                 ─────────
  Process A (user mode)     Process B (user mode)
      │                         │
      │ system call             │ interrupt
      ▼                         ▼
  Process A (kernel mode)   Process B (kernel mode)
      │ executing sys_read      │ executing IRQ handler
      │                         │
      ▼                         ▼
  Process A (user mode)     Process C (user mode)
                            [scheduler chose C]
 ─────────────────────────────────────────────────────────────
```

There is one important exception to the "kernel runs on behalf of processes" model: **kernel threads** (kthreads). These are threads created by the kernel itself, with no associated user-space process. They perform background tasks like:

- `kswapd` -- the swap daemon, which proactively moves pages to swap when memory pressure is high.
- `ksoftirqd` -- processes deferred interrupt work (softirqs) when the softirq load is too high to handle in interrupt context.
- `kworker` -- worker threads that execute asynchronous work items queued by drivers and other kernel subsystems.
- `migration` -- handles CPU migration of threads for load balancing.

You can see kernel threads in `ps aux` -- they appear with names in square brackets (e.g., `[kswapd0]`, `[ksoftirqd/0]`).

## Design Goals and Trade-offs

Operating system designers face fundamental trade-offs that have no universally correct resolution. Every OS reflects a particular set of priorities.

### Correctness vs Performance

A correct but slow OS is useless in practice; a fast but buggy OS is dangerous. The tension manifests in decisions like:

- **Locking granularity.** A single global lock (the "Big Kernel Lock" that Linux used until version 2.6.39) is simple and correct but serialises all kernel operations. Fine-grained locking allows concurrency but introduces the risk of deadlocks and race conditions. Linux's evolution from the Big Kernel Lock to per-subsystem locks to per-object locks is a case study in this trade-off.

- **Bounds checking.** Validating every array index and pointer dereference prevents buffer overflows but adds overhead. Most production kernels check only at system call boundaries and trust internal kernel code.

- **Defensive programming.** Adding assertions, sanity checks, and redundant validation catches bugs early but costs CPU cycles. Linux's `CONFIG_DEBUG_*` options enable extensive checking in development builds but are disabled in production.

### Generality vs Specialisation

A general-purpose OS (Linux, Windows) must handle everything from embedded devices to supercomputers. A specialised OS (RTOS, unikernel) can be optimised for a single workload but is useless outside that niche.

Linux is the supreme example of generality: the same kernel runs on smartphones (Android), supercomputers (100% of the Top500), cloud servers, routers, televisions, and automobiles. This generality comes at a cost: the kernel must support thousands of device drivers, dozens of file systems, and multiple scheduling policies, all of which add complexity and code size.

### Security vs Usability

Strict security policies (mandatory access control, capability-based addressing) make systems harder to use and administer. Permissive defaults (Windows XP running everything as Administrator) make systems easy to use but vulnerable. The challenge is finding the right default: secure enough to prevent common attacks, permissive enough to not frustrate users.

### Compatibility vs Innovation

Maintaining backward compatibility constrains design: x86-64 still supports real-mode instructions from the 8086 era, and Linux still supports the 32-bit `INT 0x80` system call path. Breaking compatibility enables cleaner designs but strands existing software. Linus Torvalds has famously declared "we do not break user space" as Linux's cardinal rule, even when the existing interface is acknowledged to be poorly designed.

> **Programmer:** These trade-offs are not abstract philosophical questions -- they affect your daily work. When you choose between Go's `os.ReadFile()` (simple but loads the entire file into memory) and `bufio.Scanner` (more complex but memory-efficient), you are making the same correctness-vs-performance trade-off that OS designers face. When you choose between `sync.Mutex` (simple, correct, potentially slow under contention) and `sync/atomic` operations (fast but error-prone), you are navigating the same locking granularity trade-off. When you decide whether to use cgo for performance-critical code (breaking Go's cross-compilation guarantee) or stay in pure Go (portable but potentially slower), you are confronting the compatibility-vs-innovation trade-off. OS design principles are software engineering principles at the most demanding scale.

## Summary

An operating system is simultaneously a resource manager, an abstraction provider, and a protection boundary. It evolved from non-existent (bare hardware) through batch monitors, multiprogramming systems, and time-sharing systems to the complex, multi-subsystem kernels we use today. The CPU's dual-mode operation -- kernel mode and user mode -- provides the hardware foundation for protection, and system calls provide the controlled gateway between the two modes. The POSIX standard codifies the system call interface, enabling portable software across Unix-like systems. Understanding the OS at this level -- not just as a black box that runs programs, but as a carefully engineered piece of software that mediates every interaction between your code and the hardware -- is the foundation for everything that follows in this book.

## Exercises

### Exercise 1.1: Role Classification

Classify each of the following OS activities as primarily resource management, abstraction provision, or protection enforcement. Some may involve more than one role; justify your reasoning for each.

a) The scheduler selects a new process to run after a time quantum expires.

b) The virtual memory system translates virtual address 0x7FFE4000 to physical address 0x1A3C000.

c) The file system returns `EACCES` when a process tries to open a file it does not have permission to read.

d) The network stack fragments a 5000-byte message into multiple Ethernet frames.

e) The OOM (Out of Memory) killer terminates a process to free memory when RAM is exhausted.

f) The VFS layer allows the same `read()` system call to work on ext4 files, NFS mounts, and `/proc` virtual files.

g) Linux cgroups limit a container to using at most 2 CPU cores and 4 GB of RAM.

### Exercise 1.2: State Machine Model

Consider an OS managing two processes, P1 and P2, on a single-core CPU. The system state includes: which process is running, the PC (program counter) value for each process, and the contents of a single shared variable $x$ (initially 0).

a) Define the state space $Q$ formally, specifying the type and range of each component.

b) List the possible events $\Sigma$ (assume: P1 can increment $x$, P2 can decrement $x$, and a timer interrupt can cause a context switch).

c) Write the transition function $\delta$ for the timer interrupt event. Be precise about what state changes and what is preserved.

d) Prove that the invariant "exactly one process is in the running state at any time" is preserved by all transitions.

e) Is the property "$x$ is always non-negative" a safety property, a liveness property, or neither? Justify your answer and determine whether this property holds for all possible executions.

### Exercise 1.3: System Call Cost Analysis

A program reads a 10 MB file using `read()` system calls. Each system call has a fixed overhead of 400 ns (mode switch + validation) plus a variable cost of 10 ns per byte transferred (memory copy).

a) Calculate the total time to read the file with a buffer size of 1 byte.

b) Calculate the total time with a buffer size of 4096 bytes.

c) Calculate the total time with a buffer size of 1 MB.

d) Derive a formula for total time $T$ as a function of buffer size $B$, and find the buffer size that minimises $T$. Explain why the optimal buffer size in practice is often close to the page size (4096 bytes) despite the formula suggesting a larger value.

e) How does the analysis change if the file data is not in the page cache and must be read from an NVMe SSD with a 10 $\mu$s latency per I/O request?

### Exercise 1.4: fork-exec Implementation

Write a C program that implements a simple shell command: `cat file1 file2 > output`. Your program must:

a) Use `fork()` to create a child process.

b) In the child, redirect standard output to the file `output` (using `open()` and `dup2()`).

c) In the child, use `execlp()` to run `cat` with the given arguments.

d) In the parent, wait for the child to finish and print its exit status.

e) Explain why the file descriptor manipulation must happen between `fork()` and `exec()`, and what would go wrong if it happened before `fork()`.

f) Explain why `dup2(fd, STDOUT_FILENO)` is used instead of simply closing FD 1 and opening the output file (relying on `open()` to return the lowest available FD). What race condition could the simpler approach introduce in a multi-threaded program?

### Exercise 1.5: Historical Analysis

Compare the process creation models of Multics and Unix.

a) Multics used a single `create_process()` call that specified the program to run, the initial arguments, and the execution environment. Unix uses the two-step `fork()`/`exec()` model. What are the advantages and disadvantages of each approach?

b) The Plan 9 operating system (also from Bell Labs) replaced `fork()` with `rfork()`, which allows fine-grained control over which resources are shared between parent and child (memory, file descriptors, namespace). Linux's `clone()` serves a similar purpose. Explain why this finer granularity is useful, giving at least two concrete examples.

c) Modern systems like Windows use `CreateProcess()`, which is closer to the Multics model. Why might a modern OS designer prefer this over `fork()`/`exec()`? Consider the implications for multi-threaded programs and the performance of `fork()` on systems with large address spaces.

### Exercise 1.6: POSIX Portability

A developer writes a Linux application that uses `epoll` for network event notification, `io_uring` for asynchronous file I/O, and `clone()` with `CLONE_NEWNET` for network namespace isolation.

a) Which of these APIs are POSIX-compliant? Which are Linux-specific?

b) For each Linux-specific API, identify the closest POSIX-compliant alternative and explain what functionality would be lost.

c) The developer wants to port the application to FreeBSD. For each Linux-specific API, describe the FreeBSD equivalent (if one exists) and the porting effort required.

d) Design an abstraction layer (a set of C function signatures) that would allow the application to use the optimal platform-specific API on each OS while presenting a uniform interface to the application code.

### Exercise 1.7: Protection Boundary Analysis

Consider a system without hardware-enforced kernel/user mode separation (i.e., all code runs at the same privilege level, as on some early microcontrollers).

a) Can such a system still implement an operating system? What properties would it lack compared to a system with hardware protection?

b) Describe a software-only mechanism that could provide *some* isolation between processes on such a system. What are its limitations? (Hint: consider language-based protection, as used in Singularity OS or Java's JVM.)

c) The WebAssembly (Wasm) runtime provides memory isolation without hardware privilege rings. Explain how Wasm achieves this and compare its isolation guarantees to those provided by hardware-enforced virtual memory.

d) Some real-time operating systems (e.g., FreeRTOS on Cortex-M0, which lacks an MPU) run all tasks in the same address space. Analyse the security implications and explain what mitigations are available.
