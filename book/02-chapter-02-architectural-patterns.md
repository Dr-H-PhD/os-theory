# Chapter 2: Architectural Patterns

The previous chapter established what an operating system does. This chapter examines how it is structured internally -- the architectural decisions that determine where kernel code lives, how components communicate, and what belongs inside the trusted computing base. These decisions have profound consequences for performance, security, reliability, and the ability to formally verify correctness. No single architecture dominates; each pattern represents a different point in a vast design space, optimised for different constraints.

We begin with the fundamental question -- what code should run in kernel mode? -- and then systematically examine five architectural patterns: monolithic kernels, microkernels, hybrid kernels, exokernels, and unikernels. For each, we describe the structure, analyse the trade-offs, and examine real systems that embody the pattern. We conclude with a rigorous comparative analysis that equips you to reason about architectural choices for any given deployment scenario.

## The Fundamental Question: What Belongs in the Kernel?

Every OS architecture must answer one question: which code runs in kernel mode (ring 0, EL1) with full hardware access, and which code runs in user mode with restricted privileges?

Code that runs in kernel mode has two properties:

1. **Power.** It can execute privileged instructions, access any memory address, and manipulate hardware directly.

2. **Risk.** A bug in kernel-mode code can crash the entire system, corrupt arbitrary memory, or create security vulnerabilities exploitable by any process.

The tension between power and risk drives all architectural decisions. More code in the kernel means more power and potentially more performance (fewer mode transitions), but also more risk. Less code in the kernel means less risk but more overhead from crossing the user/kernel boundary.

We define the *Trusted Computing Base* (TCB) as the set of all code that must be correct for the system's security properties to hold.

> **Note:** **Trusted Computing Base (TCB).** The TCB of a system is the totality of hardware, firmware, and software components that are critical to its security. A vulnerability in any TCB component can compromise the entire system. A smaller TCB is easier to audit, test, and formally verify, and presents a smaller attack surface. The TCB includes not only the kernel but also the bootloader, firmware, hypervisor (if present), and any user-space code that runs with elevated privileges (e.g., setuid binaries).

The size of the TCB varies dramatically across architectures:

| Architecture | Approximate TCB Size | Example |
|---|---|---|
| Monolithic kernel | 15--30 million LoC | Linux 6.x |
| Hybrid kernel | 5--10 million LoC | Windows NT kernel |
| Microkernel | 10,000--50,000 LoC | seL4, L4 |
| Exokernel | 5,000--20,000 LoC | MIT Exokernel |
| Unikernel | Application-specific | MirageOS, IncludeOS |

To appreciate the significance of these numbers, consider that the probability of a security-critical bug is roughly proportional to code size. A system with 30 million lines of privileged code has approximately 3000x the attack surface of a system with 10,000 lines -- a qualitative, not merely quantitative, difference.

## Monolithic Kernels

### Architecture

In a monolithic kernel, the entire operating system -- process scheduler, memory manager, file systems, device drivers, network stack, and security modules -- runs in a single address space in kernel mode. All components can call each other directly through function calls, share data structures without serialisation, and access hardware without any indirection.

```text
 MONOLITHIC KERNEL ARCHITECTURE
 ─────────────────────────────────────────────────────────────

 User Space
 ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
 │ Process A│ │ Process B│ │ Process C│ │ Process D│
 └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘
      │            │            │            │
 ═════╪════════════╪════════════╪════════════╪═══════════
      │     System Call Interface (single entry point)
      ▼            ▼            ▼            ▼
 ┌───────────────────────────────────────────────────────┐
 │                   KERNEL SPACE                         │
 │                                                        │
 │  ┌────────────┐ ┌────────────┐ ┌────────────┐        │
 │  │ Scheduler  │ │ Memory Mgr │ │ VFS Layer  │        │
 │  └────────────┘ └────────────┘ └──────┬─────┘        │
 │                                       │               │
 │  ┌────────────┐ ┌────────────┐ ┌──────┴─────┐        │
 │  │ Net Stack  │ │  IPC       │ │ File Sys   │        │
 │  │ (TCP/IP)   │ │            │ │ ext4/btrfs │        │
 │  └────────────┘ └────────────┘ └────────────┘        │
 │                                                        │
 │  ┌────────────┐ ┌────────────┐ ┌────────────┐        │
 │  │ Disk Driver│ │ NIC Driver │ │ USB Driver │        │
 │  └────────────┘ └────────────┘ └────────────┘        │
 └───────────────────────────────────────────────────────┘
                        Hardware
 ─────────────────────────────────────────────────────────────
```

The term "monolithic" is somewhat misleading. It does not mean the kernel is an undifferentiated mass of code. Internally, the kernel is highly modular, with well-defined interfaces between subsystems. The term means that all modules share the same address space and the same privilege level -- a bug in any module can corrupt any other module's data.

### Linux: The Canonical Monolithic Kernel

Linux is the most prominent monolithic kernel in production use. As of version 6.x, the Linux kernel comprises approximately 28 million lines of code (including all drivers and architectures). The kernel source tree is organised into major subsystems:

| Directory | Subsystem | Approximate Size |
|---|---|---|
| `kernel/` | Core (scheduler, signals, timers) | 150,000 LoC |
| `mm/` | Memory management | 120,000 LoC |
| `fs/` | File systems (ext4, btrfs, XFS, NFS, ...) | 1,200,000 LoC |
| `net/` | Networking (TCP/IP, netfilter, ...) | 900,000 LoC |
| `drivers/` | Device drivers | 18,000,000+ LoC |
| `arch/` | Architecture-specific code (x86, ARM, ...) | 1,500,000 LoC |
| `security/` | Security modules (SELinux, AppArmor, ...) | 200,000 LoC |
| `crypto/` | Cryptographic algorithms | 100,000 LoC |
| `sound/` | Audio subsystem (ALSA) | 600,000 LoC |

The `drivers/` directory alone accounts for over 60% of the kernel's total size. This is characteristic of monolithic kernels: the vast majority of code is device drivers, and all of it runs with full kernel privileges.

The internal structure of Linux demonstrates that "monolithic" does not mean "unstructured." The kernel enforces a layered architecture through conventions and code review:

- The **VFS layer** provides a uniform file system interface, insulating upper layers from file system implementation details.
- The **block layer** provides a uniform block device interface, insulating file systems from device driver details.
- The **netdev layer** provides a uniform network interface, insulating protocol stacks from NIC driver details.

However, these layers are enforced by convention, not by hardware. Any kernel code can bypass any layer and access any data structure directly, because all code shares the same address space.

### Loadable Kernel Modules

Pure monolithic design would require recompiling the entire kernel to add support for a new device. Linux solves this with *loadable kernel modules* (LKMs) -- object files that can be inserted into and removed from the running kernel without rebooting.

A kernel module is compiled against the kernel headers and loaded with the `insmod` or `modprobe` command. Once loaded, the module's code runs in kernel space with full privileges, indistinguishable from statically compiled kernel code. The module infrastructure provides:

- **Symbol export** -- modules can export symbols (functions and variables) for other modules to use.
- **Dependency resolution** -- `modprobe` automatically loads prerequisite modules.
- **Reference counting** -- prevents unloading a module that is in use.
- **Version checking** -- prevents loading a module compiled against a different kernel version (vermagic).

```c
/* hello_module.c -- a minimal Linux kernel module */
#include <linux/init.h>
#include <linux/module.h>
#include <linux/kernel.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("OS Theory");
MODULE_DESCRIPTION("A minimal kernel module");
MODULE_VERSION("1.0");

static int __init hello_init(void) {
    pr_info("hello: module loaded (kernel version %s)\n",
            UTS_RELEASE);
    return 0;   /* 0 = success, negative = error code */
}

static void __exit hello_exit(void) {
    pr_info("hello: module unloaded\n");
}

module_init(hello_init);
module_exit(hello_exit);
```

The Makefile for building this module:

```text
obj-m += hello_module.o

KDIR := /lib/modules/$(shell uname -r)/build

all:
	make -C $(KDIR) M=$(PWD) modules

clean:
	make -C $(KDIR) M=$(PWD) clean
```

Building and loading:

```text
$ make
$ sudo insmod hello_module.ko
$ dmesg | tail -1
[12345.678] hello: module loaded (kernel version 6.5.0-generic)
$ sudo rmmod hello_module
$ dmesg | tail -1
[12345.789] hello: module unloaded
```

> **Programmer:** Writing kernel modules is one of the few programming activities where a bug can instantly crash the entire machine. There is no memory protection between your module and the rest of the kernel -- a null pointer dereference in a module triggers a kernel panic, not a segfault. A buffer overflow in a module can corrupt the scheduler's run queue, the page cache, or the file system's inode table. This is why kernel development requires extreme discipline: rigorous code review (every patch to the Linux kernel is reviewed by at least two maintainers), static analysis tools (`sparse`, `smatch`, `coccinelle`), and thorough testing in virtual machines before deployment. The `pr_info()` function is the kernel equivalent of `printf` -- its output goes to the kernel log buffer, readable via `dmesg`. Note that kernel code cannot use floating-point arithmetic: the kernel does not save/restore FPU state on every kernel entry (for performance reasons), so using floating-point instructions would corrupt user-space FPU registers. The `printk` format specifier `%pK` prints kernel pointers with hashing to prevent address leaks to unprivileged users.

### Advantages of Monolithic Kernels

**Performance.** Internal function calls within the kernel are simple C function calls -- no IPC overhead, no serialisation, no context switches. A file system can call the memory manager directly; the network stack can call the scheduler directly. On a hot path like packet reception, this directness matters enormously. A Linux networking stack can process millions of packets per second, partly because each packet traverses the stack through direct function calls rather than IPC messages.

**Simplicity of internal interfaces.** Kernel subsystems share data structures directly. The page cache, for example, is accessible to both the file system and the memory manager without any marshalling. The `struct page` data structure, which represents a physical page frame, is used by the memory allocator, the page cache, the swap subsystem, and the DMA subsystem -- all directly, with no copying or serialisation.

**Mature ecosystem.** Linux has drivers for virtually every hardware device in existence, built over three decades of development by thousands of contributors. The `drivers/` directory contains support for devices ranging from IBM mainframe channel adapters to Raspberry Pi GPIO pins.

**Debugging and tracing infrastructure.** Because all kernel code runs in the same address space, tools like ftrace, perf, and eBPF can trace any kernel function, measure any code path, and correlate events across subsystems -- capabilities that are much harder to achieve in a microkernel where subsystems run in separate address spaces.

### Disadvantages of Monolithic Kernels

**Large TCB.** Every line of kernel code is in the TCB. A buffer overflow in an obscure USB driver can compromise the entire system. A 2011 study by Chou et al. found that Linux device drivers had an error rate 3--7x higher than the rest of the kernel. Since drivers comprise the majority of kernel code and run with full privileges, they are the dominant source of kernel crashes.

**Fault propagation.** A bug in any kernel component can corrupt shared data structures, causing failures that manifest in unrelated subsystems. A memory corruption bug in a network driver might cause a page cache corruption that crashes the file system hours later. Debugging such failures is notoriously difficult because the symptom is far removed from the cause.

**Difficult to verify.** Formal verification of 28 million lines of C code is computationally and intellectually infeasible with current techniques. Even partial verification of individual subsystems is extremely challenging because of the unrestricted interactions between kernel components.

**Kernel-mode attack surface.** Every system call, every device driver, and every kernel module is a potential entry point for an attacker. A single exploitable bug anywhere in the kernel gives the attacker full system access.

> **Info:** The Linux kernel's quality is maintained not by formal verification but by an extraordinarily rigorous development process: every patch is reviewed by subsystem maintainers, tested by automated CI systems (the kernel test robot), run through static analysers, and deployed incrementally through the stable/longterm release cycle. This process catches most bugs but cannot guarantee their absence -- a fundamental limitation of testing-based quality assurance.

## Microkernels

### Architecture

A microkernel takes the opposite approach: *minimise* the code running in kernel mode. The kernel provides only the most fundamental services:

1. **Address space management** -- creating and manipulating page tables.
2. **Thread management** -- creating, scheduling, and destroying threads.
3. **Inter-process communication (IPC)** -- sending messages between processes.
4. **Basic hardware access** -- interrupt forwarding and device capability management.

Everything else -- file systems, device drivers, the network stack, even parts of the memory manager -- runs as user-space servers that communicate through IPC messages.

```text
 MICROKERNEL ARCHITECTURE
 ─────────────────────────────────────────────────────────────

 User Space
 ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
 │ Process A│ │ Process B│ │ File Sys │ │ Net Stack│
 └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘
      │            │            │            │
      │    ┌───────┴────────────┴────────────┘
      │    │     IPC Messages
      │    │
 ┌────┴────┴─────────────────────────────────────────────┐
 │ Disk     │ NIC      │ USB      │ Display  │ Timer    │
 │ Driver   │ Driver   │ Driver   │ Driver   │ Driver   │
 │ (user)   │ (user)   │ (user)   │ (user)   │ (user)   │
 └──┬───────┴──┬───────┴──┬───────┴──┬───────┴──┬───────┘
    │          │          │          │          │
 ═══╪══════════╪══════════╪══════════╪══════════╪════════
    ▼          ▼          ▼          ▼          ▼
 ┌───────────────────────────────────────────────────────┐
 │              MICROKERNEL (ring 0)                      │
 │                                                        │
 │  ┌────────────┐ ┌────────────┐ ┌────────────┐        │
 │  │ Address    │ │ Thread     │ │    IPC     │        │
 │  │ Spaces     │ │ Scheduling │ │  Mechanism │        │
 │  └────────────┘ └────────────┘ └────────────┘        │
 └───────────────────────────────────────────────────────┘
                        Hardware
 ─────────────────────────────────────────────────────────────
```

The microkernel philosophy is summarised by the *minimality principle*: a service should be moved to user space unless moving it would prevent the implementation of the system's required functionality. This principle was articulated by Jochen Liedtke, the architect of the L4 microkernel family.

### The IPC Problem

The critical design challenge in microkernels is IPC performance. In a monolithic kernel, a file `read()` is a direct function call to the file system code, costing perhaps 50 nanoseconds of overhead. In a microkernel, the same operation requires multiple IPC messages:

1. The application sends a "read" message to the file system server (user $\to$ kernel $\to$ user).
2. The file system server sends a "read block" message to the disk driver (user $\to$ kernel $\to$ user).
3. The disk driver programs the hardware and waits for a completion interrupt.
4. The disk driver sends the data back to the file system server (user $\to$ kernel $\to$ user).
5. The file system server sends the data back to the application (user $\to$ kernel $\to$ user).

Each arrow represents a mode transition and a potential context switch. If each IPC costs 1 microsecond, a single file read requires 4 IPC round trips = 8 mode transitions, adding 4--8 microseconds of overhead that does not exist in a monolithic design.

Let $T_{\text{mono}}$ be the cost of a file read in a monolithic kernel, and $T_{\text{micro}}$ be the cost in a microkernel:

$$
T_{\text{mono}} = T_{\text{syscall}} + T_{\text{fs}} + T_{\text{io}}
$$

$$
T_{\text{micro}} = T_{\text{syscall}} + T_{\text{fs}} + T_{\text{io}} + k \times T_{\text{ipc}}
$$

where $k$ is the number of IPC messages required and $T_{\text{ipc}}$ is the per-message IPC cost. The overhead ratio is:

$$
\text{overhead} = \frac{T_{\text{micro}} - T_{\text{mono}}}{T_{\text{mono}}} = \frac{k \times T_{\text{ipc}}}{T_{\text{syscall}} + T_{\text{fs}} + T_{\text{io}}}
$$

For a cached file read (no disk I/O), $T_{\text{io}} = 0$ and the denominator is small, making the relative overhead large. For a read that actually hits disk ($T_{\text{io}} \gg k \times T_{\text{ipc}}$), the IPC overhead is negligible.

This observation leads to an important insight: **microkernel overhead is significant for fast-path operations but negligible for slow-path operations**. Since disk and network I/O dominate real workloads, the practical impact of IPC overhead is often smaller than micro-benchmarks suggest.

### First-Generation Microkernels: Mach

Mach, developed at Carnegie Mellon University in the 1980s, was the first widely deployed microkernel. It provided virtual memory management, IPC, and thread scheduling in the kernel, with file systems, device drivers, and network stacks running as user-space servers.

Mach's IPC was designed for generality: messages could contain arbitrary data, port rights (capabilities), and out-of-line memory regions. This flexibility came at a cost -- each IPC operation required:

- Marshalling the message into a kernel-managed buffer
- Copying data from sender to kernel to receiver (double copy)
- Scheduling the receiver to run
- Returning the result through the same path

The result was approximately 100x overhead compared to a monolithic kernel function call. This performance gap was the central criticism of microkernels in the early 1990s and fuelled the famous Tanenbaum-Torvalds debate.

### L4: High-Performance Microkernels

Jochen Liedtke's L4 microkernel (1993) demonstrated that the IPC overhead problem was not inherent to the microkernel concept but rather a consequence of poor implementation in Mach. Liedtke redesigned IPC from first principles:

- **Synchronous IPC.** The sender blocks until the receiver accepts the message, eliminating the need for kernel-managed message buffers. The message exists only in CPU registers and the kernel stack during the transfer.

- **Direct process switch.** When process A sends a message to process B, the kernel switches directly from A to B without going through the scheduler. This halves the number of context switches and eliminates scheduling overhead.

- **Register-based short messages.** Small messages (up to a few machine words) are passed in CPU registers, avoiding memory copies entirely. On x86, the `EAX`, `EBX`, `ECX`, etc. registers carry the message payload.

- **Typed transfers for large data.** Large transfers use *map* and *grant* operations that modify page table entries rather than copying data. The sender can map a page into the receiver's address space with a single TLB operation, achieving zero-copy semantics.

- **Minimal kernel.** The L4 microkernel is approximately 10,000 lines of code, compared to Mach's hundreds of thousands. Less code means fewer cache misses in the IPC path.

These optimisations reduced IPC latency from approximately 100 microseconds (Mach on i486) to approximately 5 microseconds (L4 on i486) -- a 20x improvement that brought microkernel IPC within an order of magnitude of a function call.

> **Note:** Modern L4 descendants (seL4, Fiasco.OC, NOVA) achieve IPC latencies of 200--400 nanoseconds on current x86-64 hardware. While still 2--4x more expensive than a monolithic kernel function call on the same hardware, this overhead is acceptable for most workloads, especially when weighed against the security and reliability benefits. The key insight from L4 is that IPC performance is an engineering challenge, not a fundamental limitation of the microkernel architecture.

### seL4: The Formally Verified Microkernel

seL4, developed at NICTA (now Data61/CSIRO) in Australia, is the world's first operating system kernel with a complete, machine-checked proof of functional correctness. The proof establishes that:

1. The C implementation of seL4 correctly implements its abstract specification (refinement proof).
2. The binary code produced by the compiler correctly implements the C source (translation validation via a separate tool).
3. The kernel enforces the security properties defined by its access control model (integrity and confidentiality proofs).

The proof covers approximately 10,000 lines of C code and required roughly 200,000 lines of Isabelle/HOL proof script. The verification effort took approximately 20 person-years.

> **Info:** **seL4 Functional Correctness Theorem.** Let $S_{\text{abs}}$ be the abstract specification of seL4 (a state machine in Haskell), let $S_C$ be the C implementation, and let $S_{\text{bin}}$ be the compiled binary. Then for all possible executions: $\text{behaviour}(S_{\text{bin}}) \subseteq \text{behaviour}(S_C) \subseteq \text{behaviour}(S_{\text{abs}})$. That is, the binary can only exhibit behaviours that are permitted by the C source, which in turn can only exhibit behaviours permitted by the abstract specification. This is a *refinement* relation: each layer refines (implements faithfully) the layer above it.

This result means that seL4 is provably free of:

- Buffer overflows
- Null pointer dereferences
- Arithmetic overflows (in security-critical paths)
- Use-after-free bugs
- Memory leaks (in kernel objects)
- Deadlocks (in the kernel itself)
- Information leaks between isolated domains (integrity and confidentiality)

No monolithic kernel can make these guarantees because formal verification of millions of lines of code remains intractable. The seL4 team estimates that verifying the Linux kernel, if the same proof-to-code ratio applied, would require approximately 560,000 person-years.

seL4 uses a *capability-based* access control model. Each kernel object (thread, address space, endpoint, page frame) is referenced through a *capability* -- a kernel-managed, unforgeable token that grants specific access rights. A thread can only access objects for which it holds a capability, and capabilities can only be created through explicit kernel operations (not by guessing addresses).

### Minix 3: Reliability Through Isolation

Minix 3, developed by Andrew Tanenbaum (who also created the original Minix that inspired Linux), is a microkernel-based system designed for extreme reliability. Its key innovation is *automatic driver recovery*:

1. Each device driver runs as an isolated user-space process with minimal privileges. The driver process has access only to the I/O ports and memory regions required for its specific device, enforced by the kernel.

2. A *reincarnation server* monitors all driver processes via heartbeat messages. If a driver fails to respond to a heartbeat within a timeout, the reincarnation server considers it crashed.

3. If a driver crashes (segfault, infinite loop detected by watchdog, etc.), the reincarnation server automatically restarts it by spawning a new instance and re-initialising the device.

4. The restarted driver re-initialises its device and resumes operation, often without the user noticing any interruption beyond a brief pause.

This self-healing property is impossible in a monolithic kernel where a driver crash corrupts kernel data structures. In Minix 3, the crashed driver's memory is simply reclaimed by the kernel, leaving all other system components -- including other drivers, the file system, and the network stack -- unaffected.

Minix 3 enforces the *principle of least authority* (POLA): each system component has only the privileges it needs to perform its function, and no more. A printer driver has access to the printer's I/O ports but cannot touch the network card's registers or the disk controller's DMA buffers. This containment ensures that even a malicious driver (not just a buggy one) cannot compromise other system components.

### Advantages of Microkernels

**Small TCB.** Only 10,000--50,000 lines of code run in kernel mode, dramatically reducing the attack surface and making formal verification feasible.

**Fault isolation.** A bug in a user-space driver or server cannot corrupt kernel data structures. The worst case is that a single server crashes and can be restarted.

**Security.** The principle of least privilege is enforced architecturally: drivers and servers have only the capabilities they need, not full kernel access. Even a compromised driver cannot read other processes' memory or escalate privileges.

**Modularity.** System components can be independently developed, tested, and replaced. You can swap the file system server without rebooting. You can run two different file system implementations simultaneously and compare their behaviour.

**Verifiability.** A kernel of 10,000 lines can be formally verified, as demonstrated by seL4. This provides mathematical guarantees of correctness that no amount of testing can achieve.

### Disadvantages of Microkernels

**IPC overhead.** Even with optimised IPC, the cost of crossing the user/kernel boundary multiple times per operation adds latency and reduces throughput for fast-path operations.

**Complexity of user-space servers.** Moving functionality out of the kernel does not eliminate complexity -- it redistributes it. User-space servers must handle their own error recovery, resource management, and concurrency. A user-space file system server is not simpler than a kernel-space file system -- it is merely isolated.

**Ecosystem maturity.** Microkernel-based systems have fewer drivers, applications, and developers than Linux. This is a self-reinforcing problem: fewer users means less driver support, which means fewer users.

**Performance tuning difficulty.** Optimising a multi-server system requires understanding IPC patterns, server scheduling, and cache behaviour across multiple address spaces -- more complex than optimising a single kernel address space.

## Hybrid Kernels

### Architecture

A hybrid kernel attempts to combine the performance of a monolithic kernel with the modularity of a microkernel. The strategy is to run most OS services in kernel mode (like a monolithic kernel) but to structure them as separate modules with well-defined interfaces (like a microkernel). Some services -- particularly drivers that are unreliable or infrequently used -- may run in user space.

```text
 HYBRID KERNEL ARCHITECTURE
 ─────────────────────────────────────────────────────────────

 User Space
 ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
 │ Process A│ │ Process B│ │ User-mode│ │ Subsystem│
 │          │ │          │ │ Driver   │ │ Server   │
 └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘
      │            │            │            │
 ═════╪════════════╪════════════╪════════════╪═══════════
      ▼            ▼            ▼            ▼
 ┌───────────────────────────────────────────────────────┐
 │                   KERNEL SPACE                         │
 │  ┌─────────────────────────────────────────────────┐  │
 │  │            Executive / Core Services             │  │
 │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐        │  │
 │  │  │Scheduler │ │ VMM      │ │ IPC      │        │  │
 │  │  └──────────┘ └──────────┘ └──────────┘        │  │
 │  └─────────────────────────────────────────────────┘  │
 │  ┌──────────┐ ┌──────────┐ ┌──────────┐              │
 │  │ File Sys │ │ Net Stack│ │ Drivers  │              │
 │  │ (kernel) │ │ (kernel) │ │ (kernel) │              │
 │  └──────────┘ └──────────┘ └──────────┘              │
 └───────────────────────────────────────────────────────┘
                        Hardware
 ─────────────────────────────────────────────────────────────
```

The label "hybrid" is somewhat contentious. Critics argue that most hybrid kernels are essentially monolithic kernels with a microkernel-inspired internal structure -- the fact that services run in kernel mode means they share all the security and reliability problems of monolithic kernels. Proponents counter that the internal modularity provides engineering benefits (cleaner interfaces, easier testing) even without hardware-enforced isolation.

### Windows NT

The Windows NT kernel (used in all modern Windows versions from Windows NT 3.1 through Windows 11) is the most commercially successful hybrid kernel. Its architecture was designed by Dave Cutler, who previously led the VMS operating system project at Digital Equipment Corporation. The architecture has two layers:

**The NT Kernel (ntoskrnl.exe)** runs in kernel mode and provides:

- Thread scheduling and synchronisation primitives (dispatcher objects)
- Interrupt and exception dispatching (IDT management, DPC -- Deferred Procedure Calls)
- Low-level hardware abstraction (via the HAL -- Hardware Abstraction Layer, a replaceable DLL)
- Trap handling and system call dispatching

**The Executive** sits above the kernel (but still in kernel mode) and provides higher-level services:

- **Object Manager** -- a unified namespace for kernel objects (processes, threads, files, mutexes, events, sections). Every kernel resource is an "object" with a type, a security descriptor, and a reference count.
- **I/O Manager** -- a layered driver model based on I/O Request Packets (IRPs). An I/O request is encapsulated in an IRP that passes through a stack of driver layers (file system driver, volume manager, disk driver), each processing and forwarding it.
- **Memory Manager** -- virtual memory, section objects (memory-mapped files), page file management, working set trimming.
- **Configuration Manager** -- the Windows Registry, a hierarchical key-value database for system and application configuration.
- **Security Reference Monitor** -- access control, token management, security auditing. Every object access is checked against the caller's security token and the object's DACL (Discretionary Access Control List).
- **Process Manager** -- process and thread creation, job objects (groups of processes with shared resource limits).
- **Cache Manager** -- unified cache for file data, accessed by the Memory Manager and the I/O Manager.

The "hybrid" designation comes from the fact that several subsystems run in user mode as *environment subsystems*:

- The Windows subsystem (`csrss.exe`) manages the Win32 API and console windows.
- The Session Manager (`smss.exe`) manages login sessions and subsystem processes.
- User-mode drivers via the UMDF (User-Mode Driver Framework) -- USB cameras, printers, and other non-performance-critical devices can be implemented as user-mode services, gaining the fault isolation benefits of a microkernel.

Windows NT was originally designed with a more microkernel-like structure (influenced by Mach), but over successive versions, more components were moved into kernel mode for performance. The most notable migration was the graphics subsystem (`win32k.sys`), moved from user space to kernel space in Windows NT 4.0. This improved GUI performance significantly but introduced a large, complex, and historically bug-prone component into the TCB. The `win32k.sys` driver has been one of the most frequent sources of Windows kernel vulnerabilities.

### macOS / XNU

Apple's XNU kernel (the basis for macOS, iOS, iPadOS, watchOS, and tvOS) is a hybrid that combines three heritage components:

- **Mach microkernel** -- provides IPC (Mach messages and ports), virtual memory management, and basic thread scheduling. Mach ports are the fundamental IPC mechanism: every system service, including the file system and the window server, is accessed through Mach port messages.

- **BSD layer** -- provides the POSIX API: processes, file systems (HFS+, APFS), networking (TCP/IP, Unix domain sockets), and security (sandboxing, code signing). This layer runs in kernel mode alongside Mach, not as a separate user-space server.

- **I/O Kit** -- an object-oriented, restricted C++ (called Embedded C++) driver framework. I/O Kit uses a publish-subscribe model for device matching: when a new device appears, the I/O Kit finds and loads the appropriate driver based on a matching dictionary in the driver's Info.plist.

```text
 XNU KERNEL STRUCTURE
 ─────────────────────────────────────────────────────────────

 User Space     Applications, Frameworks, daemons

 ═══════════════════════════════════════════════════════════

 Kernel Space
 ┌──────────────────────────────────────────────────────┐
 │                    BSD Layer                          │
 │    (POSIX API, VFS, TCP/IP, security, processes)     │
 ├──────────────────────────────────────────────────────┤
 │                    Mach Layer                         │
 │    (IPC, virtual memory, thread scheduling)           │
 ├──────────────────────────────────────────────────────┤
 │                    I/O Kit                            │
 │    (driver framework, device tree, power mgmt)        │
 ├──────────────────────────────────────────────────────┤
 │           Platform Expert / HAL                       │
 └──────────────────────────────────────────────────────┘
                        Hardware
 ─────────────────────────────────────────────────────────────
```

XNU is structured internally as a microkernel (Mach provides the primitive abstractions), but the BSD layer and I/O Kit run in the same address space as Mach, making it functionally monolithic from a privilege perspective. A bug in the BSD network stack can corrupt Mach data structures, and vice versa.

Apple has increasingly moved toward user-space drivers with *DriverKit* (introduced in macOS 10.15), which provides a user-space driver framework with a subset of I/O Kit's API. This is a gradual migration toward microkernel-like fault isolation for drivers, without changing the kernel architecture.

## Exokernels

### Architecture

The exokernel, proposed by Dawson Engler at MIT in the mid-1990s, takes a radical approach: the kernel should *not* provide abstractions at all. Instead, it should only *securely multiplex hardware* -- dividing physical resources among applications -- and let each application define its own abstractions through a *library OS* linked into its address space.

Traditional operating systems impose policies: a single page replacement algorithm, a single TCP congestion control algorithm, a single file cache eviction strategy. These policies represent compromises that work reasonably well for average workloads but are suboptimal for specific applications. The exokernel philosophy is that the kernel should not impose policies; it should only provide mechanisms for secure resource sharing, and let applications choose their own policies.

```text
 EXOKERNEL ARCHITECTURE
 ─────────────────────────────────────────────────────────────

 ┌──────────────────────┐  ┌──────────────────────┐
 │     Application A    │  │     Application B    │
 │  ┌────────────────┐  │  │  ┌────────────────┐  │
 │  │  Library OS     │  │  │  Library OS       │  │
 │  │  (custom FS,   │  │  │  (custom net,    │  │
 │  │   custom VM,   │  │  │   custom sched,  │  │
 │  │   custom net)  │  │  │   standard FS)   │  │
 │  └────────────────┘  │  │  └────────────────┘  │
 └──────────┬───────────┘  └──────────┬───────────┘
            │                         │
 ═══════════╪═════════════════════════╪══════════════
            ▼                         ▼
 ┌───────────────────────────────────────────────────┐
 │                  EXOKERNEL                         │
 │                                                    │
 │  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
 │  │ Secure   │  │ Physical │  │ Network  │        │
 │  │ Bindings │  │ Memory   │  │ Multiplex│        │
 │  │          │  │ Multiplex│  │          │        │
 │  └──────────┘  └──────────┘  └──────────┘        │
 └───────────────────────────────────────────────────┘
                      Hardware
 ─────────────────────────────────────────────────────────────
```

### Secure Bindings

The exokernel's key mechanism is the *secure binding*: a kernel-level binding that authorises an application to use a specific physical resource (a page of RAM, a disk block, a network packet filter) without going through the kernel on every access.

Three types of secure bindings:

1. **Hardware mechanisms.** The exokernel programs the hardware (TLB entries, page tables, network packet filters) on behalf of the application. Once the binding is installed, the application accesses the resource directly through hardware, with no kernel involvement.

2. **Software caching.** The exokernel caches authorisation decisions (e.g., "this application is allowed to access disk block 1234") to avoid re-checking on every access.

3. **Downloaded code.** The application downloads a small, verified code fragment (similar to a packet filter) into the kernel, which the kernel executes on the application's behalf. This is remarkably similar to modern eBPF.

For example, to allocate a physical memory page:

1. The application requests page frame number 0x1A3C from the exokernel.
2. The exokernel checks the application's capabilities and, if authorised, grants ownership.
3. The application's library OS installs a page table entry mapping a virtual address to physical frame 0x1A3C.
4. All subsequent accesses to that page go directly through the hardware MMU -- no kernel involvement.

The exokernel only intervenes when resources are allocated, revoked, or when access violations occur.

### Library Operating Systems

The library OS is a user-space library that provides traditional OS abstractions (file systems, network protocols, virtual memory policies) tailored to the application's needs. Different applications can use different library OSes:

- A database server might use a library OS with a custom buffer cache optimised for B-tree access patterns, evicting pages based on the B-tree structure rather than LRU.
- A web server might use a library OS with a custom TCP stack optimised for short-lived connections, eliminating the TIME_WAIT state.
- A scientific application might use a library OS with a custom memory allocator optimised for large matrix operations, using huge pages and NUMA-aware placement.

This per-application customisation is the exokernel's greatest strength. In a traditional OS, all applications share the same policies. With an exokernel, each application can choose the policies that best match its workload.

### Performance Results and Legacy

The MIT Exokernel project (Aegis/Xok, 1995--1998) demonstrated impressive performance gains:

- A custom library OS file system (XN) achieved 5--8x the throughput of a traditional Unix file system for database workloads.
- A custom library OS network stack achieved 3--5x the throughput of the BSD TCP/IP stack for web server workloads.
- Application-level virtual memory management reduced page fault handling time by 2--4x.

These gains come not from any inherent speed advantage of the exokernel design but from the ability to *specialise* policies for specific workloads -- something traditional OS abstractions prevent.

No production exokernel system is in widespread use today, but the exokernel philosophy has influenced modern systems in important ways:

- **DPDK and SPDK** bypass the Linux kernel's network and storage stacks, giving applications direct access to NIC and NVMe hardware through user-space drivers. This is essentially an exokernel approach applied to specific subsystems.

- **Linux's `io_uring`** gives applications direct access to kernel I/O queues via shared memory rings, eliminating system call overhead in the steady state -- a form of secure binding.

- **XDP/eBPF** allows applications to download code into the kernel for packet processing, mimicking the exokernel's downloaded-code mechanism.

> **Programmer:** The exokernel philosophy manifests in modern Go systems programming in a subtle way. When you use `syscall.Mmap` to memory-map a file directly, bypassing Go's `os.File` abstraction and the standard library's buffered I/O, you are doing something exokernel-like: taking direct control of the memory-to-file mapping, choosing your own access patterns and caching strategy instead of relying on the OS's page cache and Go's `bufio` layer. DPDK-based Go networking libraries (like Google's `gVisor` netstack) bypass the kernel's TCP/IP stack entirely, implementing the protocol in user space for maximum performance and flexibility. These are exokernel ideas applied pragmatically within the Linux ecosystem. The lesson of the exokernel is not that you should replace Linux with an exokernel -- it is that abstraction has a cost, and when that cost matters, you should be able to reach through the abstraction to the hardware.

## Unikernels

### Architecture

A unikernel is a specialised, single-address-space machine image constructed by compiling an application together with only the OS library components it needs, linked directly against the hardware abstraction layer. The result is a bootable image that runs a single application with no distinction between kernel mode and user mode, no process isolation, and no multi-user support.

```text
 UNIKERNEL vs TRADITIONAL OS
 ─────────────────────────────────────────────────────────────

 Traditional OS Stack:            Unikernel:
 ┌────────────────────┐          ┌────────────────────┐
 │   Application      │          │                    │
 ├────────────────────┤          │   Application      │
 │   Language Runtime │          │   + OS Libraries   │
 ├────────────────────┤          │   + Runtime        │
 │   Std C Library    │          │   (single binary)  │
 ├────────────────────┤          │                    │
 │   System Calls     │          └─────────┬──────────┘
 ├────────────────────┤                    │
 │   OS Kernel        │          ──────────┼──────────
 ├────────────────────┤                    │
 │   Hypervisor / HW  │          ┌─────────┴──────────┐
 └────────────────────┘          │  Hypervisor / HW   │
                                 └────────────────────┘
   Multiple layers,                Single layer,
   general purpose,                specialised,
   large attack surface            minimal attack surface
 ─────────────────────────────────────────────────────────────
```

### How Unikernels Work

The build process for a unikernel:

1. The developer writes application code in a high-level language (OCaml for MirageOS, C/C++ for IncludeOS, Rust for Tock, Haskell for HaLVM).

2. A build tool analyses the application's dependencies and selects only the required OS library components. If the application does not use the file system, the file system library is not linked. If it does not use networking, the TCP/IP stack is omitted.

3. The application and selected libraries are compiled and linked into a single binary image, with a minimal hardware abstraction layer providing boot code, interrupt handling, and device access.

4. The image is bootable on a hypervisor (Xen, KVM, VMware, QEMU) or, in some cases, bare metal.

The resulting image is typically 1--10 MB in size, compared to hundreds of megabytes for a traditional OS installation. Boot times are measured in milliseconds rather than seconds.

### MirageOS

MirageOS is an OCaml-based unikernel framework developed at the University of Cambridge. The application and all OS libraries are written in OCaml, a type-safe functional language with strong static guarantees. This means that entire classes of bugs -- buffer overflows, use-after-free, null pointer dereferences, type confusion -- are eliminated by the type system at compile time, without requiring a runtime privilege boundary.

A MirageOS unikernel for a simple web server includes:

- The application code (~500 lines of OCaml)
- The HTTP library (cohttp, ~3,000 lines)
- The TCP/IP stack (mirage-tcpip, ~8,000 lines)
- The Xen block/network device drivers (~2,000 lines)
- The OCaml runtime (~5,000 lines)

Total: approximately 18,000 lines of code -- compared to millions of lines for a Linux VM running the same application.

MirageOS uses OCaml's module system to parameterise the application over its dependencies. A network application is written against an abstract `NETWORK` module type; at build time, the developer chooses a concrete implementation (Xen netfront, Unix socket, or a simulated network for testing). This *functorial* abstraction makes unikernels testable on a Unix host before deployment on a hypervisor.

### IncludeOS

IncludeOS is a C/C++ unikernel designed for cloud services. It provides a POSIX-compatible API subset, making it possible to run existing C/C++ applications with minimal modification. Key characteristics:

- Boot time: 300 microseconds to first instruction (vs 5--30 seconds for a full Linux VM)
- Image size: 1--5 MB typical (vs 200+ MB for a minimal Linux installation)
- Memory footprint: 5--50 MB typical (vs 200+ MB for a minimal Linux VM)
- Networking: custom TCP/IP stack with zero-copy packet handling

IncludeOS demonstrates that the unikernel approach is not limited to exotic functional languages -- it can be applied to mainstream C/C++ codebases with moderate engineering effort.

### Use Cases

Unikernels are suited for:

- **Cloud microservices** -- each service is a single-purpose VM, isolated by the hypervisor. The minimal image size enables rapid scaling: starting a new instance takes milliseconds, not minutes.

- **Network functions** -- firewalls, load balancers, DNS servers that need minimal latency and maximal throughput. ClickOS (a unikernel for middlebox processing) can boot in 30 milliseconds and process 10 Gbps of network traffic.

- **IoT devices** -- resource-constrained environments where a full OS is too heavy. A unikernel running on a microcontroller can provide a TCP/IP stack and application logic in under 1 MB.

- **Security-critical appliances** -- the minimal attack surface is attractive for devices exposed to hostile networks. No shell, no SSH daemon, no package manager means no secondary attack vectors.

### Advantages and Disadvantages

**Advantages:**

- Tiny attack surface: no shell, no package manager, no unused services, no login mechanism.
- Fast boot: millisecond-scale, enabling rapid scaling and live migration.
- Small image size: efficient storage, network transfer, and cache utilisation.
- Strong isolation: each unikernel is a separate VM, isolated by the hypervisor.
- Language-level safety (for type-safe unikernels like MirageOS and HaLVM).
- Deterministic behaviour: no background services, no cron jobs, no unexpected processes.

**Disadvantages:**

- No runtime debugging tools: no shell, no `strace`, no `gdb`, no `tcpdump`. Debugging requires serial console logging, specialised trace points, or solo5/hvt-based debugging frameworks.
- Single application per VM: no multi-process, no multi-user, no general-purpose computing.
- Limited hardware support: typically runs on hypervisors, not bare metal (though some unikernels support bare-metal deployment on specific hardware).
- Immutable deployment: changing the application requires rebuilding and redeploying the entire image. There is no `apt install` or `dnf update`.
- Ecosystem immaturity: limited library support compared to Linux.

> **Programmer:** Unikernels represent an extreme point in the design space, but their ideas are infiltrating mainstream systems. Go's static linking model produces self-contained binaries that include the runtime and garbage collector -- conceptually similar to a unikernel that includes its own memory manager. Container images built with `FROM scratch` in a Containerfile (for Podman) contain only the application binary and its direct dependencies -- no shell, no package manager, no init system. This "distroless" approach captures many unikernel benefits (small attack surface, fast startup, deterministic behaviour) while retaining the familiar container orchestration tooling (Kubernetes, Nomad). When you build a Go microservice as `CGO_ENABLED=0 go build -o /app` and package it in a scratch container, you are essentially building a unikernel that runs on a container runtime instead of a hypervisor. The mental model is identical: a single application, statically linked, with no external dependencies, isolated by the platform.

## Comparative Analysis

### Performance Comparison

The performance comparison between architectures depends heavily on the workload:

| Operation | Monolithic | Microkernel | Hybrid | Exokernel | Unikernel |
|---|---|---|---|---|---|
| System call overhead | Baseline | 2--4x baseline | ~1x baseline | 0.5x baseline | 0x (no syscall) |
| IPC latency | N/A (function call) | 200--500 ns | N/A (function call) | N/A | N/A |
| File I/O (cached) | Fast | Moderate | Fast | Very fast (custom) | Fast |
| Network throughput | Good | Moderate | Good | Excellent (custom) | Excellent |
| Boot time | 5--30 s | 2--10 s | 10--60 s | 1--5 s | 0.001--0.5 s |
| Context switch | 1--5 $\mu$s | 2--8 $\mu$s | 1--5 $\mu$s | 1--3 $\mu$s | N/A (single app) |

For general-purpose workloads, monolithic and hybrid kernels dominate because their internal function-call-based communication avoids IPC overhead. For specialised workloads (high-frequency trading, network functions, embedded systems), exokernels and unikernels can outperform traditional kernels by eliminating unnecessary abstraction layers.

### Security Comparison

| Property | Monolithic | Microkernel | Hybrid | Exokernel | Unikernel |
|---|---|---|---|---|---|
| TCB size | Very large | Very small | Large | Small | Minimal |
| Driver isolation | None | Full (user space) | Partial | Application-level | N/A |
| Formal verification | Infeasible | Demonstrated (seL4) | Infeasible | Partially feasible | Language-dependent |
| Attack surface | Large | Small | Large | Small | Minimal |
| Privilege escalation risk | High | Low | High | Medium | N/A (single priv) |

### Complexity and Development Effort

| Property | Monolithic | Microkernel | Hybrid | Exokernel | Unikernel |
|---|---|---|---|---|---|
| Kernel complexity | High | Low | High | Low | Low |
| User-space complexity | Low | High | Medium | Very high | Application-level |
| Driver development | In-kernel (risky) | User-space (safe) | Mixed | Library OS | Linked in |
| Debugging difficulty | Moderate | Easy (user-space) | Moderate | Hard | Hard |
| Ecosystem maturity | Excellent | Limited | Good | Minimal | Growing |

### A Formal Comparison: TCB and Failure Probability

Let $p$ be the probability of a bug per line of code, and let $n$ be the number of lines in the TCB. If we assume bugs are independently distributed (a simplification), the probability of at least one bug in the TCB is:

$$
P(\text{at least one bug}) = 1 - (1-p)^n \approx 1 - e^{-pn} \quad \text{for small } p
$$

For a monolithic kernel with $n = 20 \times 10^6$ LoC and an industry-average defect density of $p = 10^{-3}$ (one bug per thousand lines):

$$
P_{\text{mono}} \approx 1 - e^{-10^{-3} \times 20 \times 10^6} = 1 - e^{-20000} \approx 1
$$

For a microkernel with $n = 10^4$ LoC:

$$
P_{\text{micro}} \approx 1 - e^{-10^{-3} \times 10^4} = 1 - e^{-10} \approx 0.99995
$$

Both are near certainty -- which is why simply reducing TCB size is insufficient. The real value is that a microkernel's smaller TCB is *verifiable*. seL4's formal proof drives $p$ effectively to zero for the verified code, yielding $P_{\text{seL4}} = 0$ for the proven properties.

But the story does not end with the kernel. The total system reliability depends on the reliability of *all* components, not just the kernel. In a microkernel system, a buggy user-space file system server can still lose your data -- it just cannot crash the kernel. The microkernel's contribution is *fault containment*: a bug in one component cannot propagate to unrelated components.

The expected number of *system-wide crashes* (crashes that affect all running applications) is:

$$
E[\text{crashes/year}]_{\text{mono}} = \lambda_{\text{kernel}} + \lambda_{\text{drivers}}
$$

$$
E[\text{crashes/year}]_{\text{micro}} = \lambda_{\text{kernel}} \quad (\text{driver crashes are contained})
$$

where $\lambda_{\text{kernel}}$ and $\lambda_{\text{drivers}}$ are the failure rates of the kernel and drivers, respectively. Since $\lambda_{\text{drivers}} \gg \lambda_{\text{kernel}}$ (drivers have 3--7x higher bug density and constitute the majority of kernel code), the microkernel's elimination of driver-induced system crashes is a dramatic reliability improvement.

> **Note:** This probabilistic model is highly simplified. In practice, bugs cluster in complex code paths, and the assumption of independence is unrealistic. Nonetheless, the model illustrates the fundamental relationship between TCB size and reliability: all else being equal, a smaller TCB has fewer bugs, and fault containment prevents individual bugs from causing system-wide failures.

## Case Study: The Tanenbaum-Torvalds Debate

In January 1992, Andrew Tanenbaum (author of Minix) and Linus Torvalds (creator of Linux) engaged in a famous Usenet debate on comp.os.minix about OS architecture. Tanenbaum argued that monolithic kernels were obsolete and that microkernels were the future. Torvalds countered that monolithic kernels were more practical and performant.

Tanenbaum's key arguments:

1. Microkernels are more modular, reliable, and maintainable.
2. Moving to microkernels is an inevitable trend, just as structured programming replaced goto-based code.
3. Linux's monolithic design is "a giant step back into the 1970s."
4. Portability requires a microkernel (Minix ran on multiple architectures; early Linux was x86-only).

Torvalds' key counter-arguments:

1. Mach-based microkernels (the only practical ones at the time) were demonstrably slower.
2. Monolithic kernels with loadable modules provide sufficient modularity.
3. Practical engineering trumps theoretical elegance -- Linux works, and works well.
4. Portability is achievable in a monolithic kernel (Linux later ported to dozens of architectures).

Three decades later, the debate remains unresolved. Linux dominates servers, desktops, embedded systems, and supercomputers (100% of the Top500 as of 2024). seL4 dominates high-assurance systems where formal verification is required (military systems, autonomous vehicles, medical devices). Hybrid kernels (Windows, macOS) dominate consumer desktops and mobile devices. Each architecture thrives in its niche.

The real lesson of the debate is that the "best" architecture depends on the deployment context. There is no universal winner -- only trade-offs.

> **Programmer:** Understanding kernel architecture is not merely academic -- it affects the tools and techniques available to you as a systems programmer. On Linux (monolithic), you can write kernel modules and eBPF programs that run inside the kernel, use ftrace and perf for system-wide tracing, and leverage 30 years of driver support. On microkernels, your "kernel extensions" are regular user-space processes that you can debug with `gdb`, test with standard unit testing frameworks, and restart without rebooting. If you are building a high-assurance system (medical devices, avionics, autonomous vehicles), you should seriously consider seL4 as the foundation -- its formal proof provides guarantees that no amount of Linux kernel testing can match. If you are building cloud infrastructure, Linux's maturity, driver support, and container ecosystem (cgroups, namespaces, seccomp) are unmatched. As a practical exercise, try building the Linux kernel from source (`make defconfig && make -j$(nproc)`) and booting it in QEMU -- the process reveals the monolithic kernel's complexity (thousands of configuration options) and its flexibility (runs on everything from smartwatches to supercomputers).

## Emerging Patterns

### Multi-kernel (Barrelfish)

The Barrelfish OS, developed at ETH Zurich and Microsoft Research, treats a multi-core machine as a distributed system. Each core runs its own kernel instance (a "CPU driver"), and cores communicate through explicit message passing rather than shared memory. This design avoids the cache coherence overhead of shared-memory synchronisation on NUMA architectures and scales better on machines with hundreds of cores.

Barrelfish maintains a *system knowledge base* -- a Prolog-like constraint database that stores information about the hardware topology (NUMA distances, cache sharing, interrupt routing) and uses it to make placement decisions. This is a fundamentally different approach to hardware abstraction: instead of hiding hardware details behind uniform interfaces, Barrelfish exposes them to the OS through a queryable knowledge base.

### OS as a Library (Dune, gVisor)

The "OS as a library" approach runs a library implementation of OS abstractions in a hardware-isolated environment. Intel's VT-x virtualisation extensions enable a process to run in its own hardware-isolated domain (VMX non-root mode) with its own page tables, exception handlers, and I/O access, while still being managed by the host OS.

Dune (from Stanford) uses this approach to give applications direct, safe access to hardware features normally reserved for the kernel: page tables, exceptions, and privilege rings. A Dune application can implement its own page fault handler, garbage collector, or sandboxing mechanism using hardware privilege rings, without modifying the host kernel.

Google's gVisor is a user-space kernel that intercepts and reimplements Linux system calls. It provides a subset of the Linux syscall interface, implementing it in a memory-safe language (Go), and runs as a regular process on the host OS. Container workloads run on gVisor instead of directly on the host kernel, providing an additional layer of isolation: even if an application exploits a kernel vulnerability, it only compromises the gVisor process, not the host kernel.

### eBPF: Programmable Kernel Extensions

eBPF (extended Berkeley Packet Filter) allows user-space programs to load small, verified programs into the Linux kernel. The eBPF verifier statically analyses each program to ensure it terminates, does not access invalid memory, and does not violate security policies. Once verified, the program runs in kernel mode at near-native speed.

eBPF blurs the monolithic/microkernel boundary: the base kernel is monolithic, but user-defined extensions are sandboxed and verified, similar to the safety guarantees of a microkernel's user-space servers. eBPF is used for:

- **Networking** -- XDP (eXpress Data Path) programs process packets at the driver level, before the kernel's network stack.
- **Tracing** -- kprobes, tracepoints, and uprobes for dynamic kernel and user-space tracing.
- **Security** -- LSM (Linux Security Module) hooks for custom security policies.
- **Scheduling** -- sched_ext allows user-space scheduling policies loaded via eBPF.

```c
/* Simplified XDP program that drops ICMP packets */
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>

SEC("xdp")
int xdp_drop_icmp(struct xdp_md *ctx) {
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    /* Parse Ethernet header */
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;
    if (eth->h_proto != __constant_htons(ETH_P_IP))
        return XDP_PASS;

    /* Parse IP header */
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    /* Drop ICMP packets */
    if (ip->protocol == IPPROTO_ICMP)
        return XDP_DROP;

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

This XDP program runs in the kernel at the earliest point of packet reception, before the normal networking stack processes the packet. It can drop, redirect, or modify packets at wire speed -- a capability that previously required custom kernel modules or dedicated hardware.

## Summary

The choice of OS architecture is the most consequential design decision in systems software. Monolithic kernels like Linux pack everything into a single privileged address space, maximising performance at the cost of a massive TCB. Microkernels like seL4 minimise the privileged code to a verifiable core, achieving provable correctness at the cost of IPC overhead. Hybrid kernels like Windows NT and XNU attempt a pragmatic middle ground, keeping performance-critical services in the kernel while allowing some components to run in user space. Exokernels eliminate OS-imposed abstractions, giving applications direct control over hardware at the cost of increased application complexity. Unikernels collapse the application and OS into a single bootable image, achieving minimal footprint and attack surface at the cost of generality. Each architecture represents a different set of priorities -- performance, security, reliability, flexibility, verifiability -- and the right choice depends entirely on the constraints of the target domain.

## Exercises

### Exercise 2.1: Architecture Classification

For each of the following systems, identify the kernel architecture (monolithic, microkernel, hybrid, exokernel, or unikernel) and justify your classification with at least two structural arguments:

a) A system where the file system, network stack, and all device drivers run as user-space processes, and the kernel provides only IPC, scheduling, and address space management.

b) A system where a web server application is compiled together with a TCP/IP stack and a network driver into a single bootable image that runs on a hypervisor.

c) A system where the kernel provides only hardware multiplexing, and each application links against its own library that implements file system and networking abstractions.

d) A system where all OS services run in kernel mode but are structured as separate modules that communicate through well-defined interfaces, with some infrequently used drivers running in user mode.

e) A system where the kernel contains the scheduler, memory manager, file system, network stack, and 5000 device drivers, all compiled into a single binary that runs in ring 0.

### Exercise 2.2: IPC Overhead Analysis

Consider a microkernel-based system where a user-space file system server handles file `read()` requests. Each IPC message costs $T_{\text{ipc}} = 400$ ns (including two mode transitions). A `read()` request requires 4 IPC messages (request to file server, file server to disk driver, disk driver reply, file server reply).

a) Calculate the IPC overhead for a single `read()` call.

b) If the same operation in a monolithic kernel costs 200 ns of overhead (a single function call chain), what is the overhead ratio (microkernel / monolithic)?

c) Now suppose the monolithic kernel experiences one kernel crash per 1000 hours of operation due to driver bugs, and each crash costs 5 minutes of downtime. The microkernel system experiences zero kernel crashes (bugs in user-space drivers cause only server restarts, taking 100 ms). If the system handles $10^8$ `read()` calls per hour, calculate the total cost (time overhead + crash downtime) for each architecture over 1000 hours. Which architecture has lower total cost?

d) At what bug rate (crashes per hour) do the two architectures break even in total cost?

e) Extend the analysis to account for the value of data integrity: assume each kernel crash has a 1% probability of corrupting the file system, requiring a 1-hour fsck. How does this change the comparison?

### Exercise 2.3: TCB Size and Verification

The seL4 microkernel has approximately 10,000 lines of C code, and its formal verification required approximately 200,000 lines of proof (a 20:1 proof-to-code ratio).

a) If the Linux kernel has 28 million lines of code and the same proof-to-code ratio applied, how many lines of proof would be needed to verify Linux? If a verification engineer can produce 10 lines of proof per day, how many person-years would the verification take?

b) Explain why the 20:1 ratio would likely be *higher* for Linux, not the same. Consider: the complexity of pointer aliasing in a large address space, the number of entry points, the diversity of hardware configurations, and the use of inline assembly.

c) Propose a strategy for partially verifying a monolithic kernel. Which components would you prioritise, and why? How would you define the interface between verified and unverified components?

d) seL4's proof assumes specific hardware behaviour (e.g., the MMU correctly translates addresses). What happens if this assumption is violated? Research one real hardware bug (e.g., Meltdown, Rowhammer) and explain how it interacts with seL4's correctness guarantees.

### Exercise 2.4: Kernel Module Implementation

Write a Linux kernel module that:

a) Creates a `/proc/os_theory` entry that, when read, returns a string containing the current system uptime in seconds and the number of context switches since boot.

b) Implements proper cleanup (removing the `/proc` entry) when the module is unloaded.

c) Uses `pr_info()` to log a message each time the `/proc` file is read.

Provide the complete C source code and the `Makefile` needed to build it. Explain what would happen if your module contained a null pointer dereference: how would the system behave, and how does this differ from the same bug in a user-space program?

### Exercise 2.5: Exokernel Design

Design a library OS for a key-value store application running on an exokernel. Your library OS must manage:

a) **Physical memory allocation.** Describe how the application would request physical pages from the exokernel, and how it would implement its own virtual-to-physical mapping for a hash table data structure. What advantage does controlling page placement give over the kernel's default allocation?

b) **Disk I/O.** Describe how the application would request direct access to disk blocks from the exokernel, and how it would implement its own on-disk format optimised for key-value storage. Compare the expected performance with that of a key-value store running on ext4.

c) **Networking.** Describe how the application would register a packet filter with the exokernel to receive only its own network traffic, and how it would implement a custom protocol optimised for key-value operations (avoiding the overhead of TCP for short request/response pairs).

### Exercise 2.6: Unikernel Security Analysis

A company deploys a web application as a unikernel image on a cloud hypervisor. An attacker discovers a buffer overflow vulnerability in the application code.

a) Compare the impact of this vulnerability in the unikernel deployment versus a traditional deployment (application running on a full Linux OS). Consider: what can the attacker access, what persistent state exists, and what other services might be compromised.

b) The unikernel has no shell, no `ssh` daemon, and no package manager. Explain how this affects the attacker's ability to escalate the compromise (install backdoors, pivot to other systems, exfiltrate data).

c) Identify two security *disadvantages* of the unikernel approach compared to a traditional OS deployment. (Hint: consider Address Space Layout Randomisation in a single-address-space design, and the implications of running all code at the same privilege level.)

d) Propose a mitigation for each disadvantage you identified in part (c).

### Exercise 2.7: Architecture Trade-off Matrix

You are designing operating systems for four different deployment scenarios. For each scenario, recommend a kernel architecture and justify your choice with at least three specific technical arguments:

a) A pacemaker implanted in a patient's chest, which must operate reliably for 10+ years without maintenance or software updates.

b) A cloud platform hosting thousands of microservices from different (potentially hostile) customers, where strong isolation and rapid scaling are required.

c) A high-frequency trading system where every microsecond of latency costs money, running a single application on dedicated hardware.

d) A general-purpose desktop operating system for consumers with diverse hardware (thousands of device types) and software needs (productivity, gaming, development).
