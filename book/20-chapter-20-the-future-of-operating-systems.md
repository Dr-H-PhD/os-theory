# Chapter 20: The Future of Operating Systems

*"The best way to predict the future is to invent it."*
--- Alan Kay

---

The operating system as we know it --- a monolithic kernel managing hardware on behalf of user-space processes --- was designed for a world of single-core CPUs, small memories, and spinning disks. That world no longer exists. Today's hardware features hundreds of cores, terabytes of persistent memory, network interfaces that outperform disks, and transistors small enough that speculative execution leaks secrets through cache timing. The OS must evolve.

This chapter surveys the frontiers of operating system design: unikernels that compile away the kernel-application boundary, eBPF programs that extend the kernel safely, io_uring that bypasses the system call interface for I/O, capability-based hardware that enforces memory safety in silicon, persistent memory that blurs the line between storage and RAM, verified microkernels that carry mathematical proofs of correctness, Rust in the kernel for memory safety without garbage collection, and WebAssembly as a universal runtime.

These are not speculations --- every technology discussed here has working implementations deployed in production. The question is not whether the OS will change, but which of these ideas will define the next generation.

## 20.1 Unikernels Revisited

A **unikernel** collapses the traditional OS/application boundary: the application is compiled directly against the kernel services it needs, producing a single-address-space image that runs on bare metal or a hypervisor.

::: definition
**Unikernel.** A specialised, single-address-space machine image constructed by compiling an application together with only the OS library components it requires. A unikernel has:

- **No separate kernel and user space**: the application and OS code run in the same address space, at the same privilege level.
- **No process isolation**: there is only one "process" --- the application itself.
- **No shell, no SSH, no package manager**: there is no way to log in to a running unikernel.
- **No general-purpose OS services**: only the services the application uses are compiled in.
:::

### 20.1.1 Compile-Time Specialisation

The key insight is that a deployed service knows at compile time which OS services it needs. A web server needs TCP, HTTP parsing, and file I/O --- it does not need a process scheduler, a virtual memory system for multiple address spaces, a USB driver stack, or a sound subsystem. A unikernel includes only what is needed, achieving three benefits:

1. **Reduced attack surface**: the kernel attack surface shrinks from millions of lines of code (Linux: ~25M LOC) to tens of thousands (typically 10K--100K LOC). System calls that the application does not use simply do not exist in the image.

2. **Whole-program optimisation**: because the application and OS are compiled together, the compiler can inline OS functions, eliminate dead code paths, and optimise across the application-OS boundary. A `read()` call does not require a context switch --- it is a direct function call.

3. **Fast boot**: there is no kernel initialisation for hardware the application does not use, no service manager, no device enumeration. Boot times of 1--50 ms are typical.

::: example
**Example 20.1 (Unikernel vs Traditional OS).** Consider deploying a DNS server:

| Property | Linux VM | Unikernel |
|---|---|---|
| Boot time | 2--30 seconds | 10--50 milliseconds |
| Image size | 500 MB -- 2 GB | 1--10 MB |
| Memory footprint | 200+ MB | 10--50 MB |
| Attack surface | Entire kernel (25M+ LOC) | DNS handler + network stack (~50K LOC) |
| System calls available | ~400 | 0 (no user/kernel boundary) |
| Process isolation | Full (but unused --- single service) | None (not needed --- single service) |
| Runtime debugging | SSH in, attach debugger, read logs | External only (serial console, network) |

The unikernel boots in milliseconds because there is nothing to initialise except the application's dependencies. The image is tiny because it contains no shell, no systemd, no coreutils, no Python --- just the DNS server and a minimal network stack.
:::

### 20.1.2 MirageOS

**MirageOS** is a unikernel framework written in OCaml. Applications are structured as OCaml functors parameterised over abstract module signatures for OS services (network, storage, time, random). At compile time, these signatures are instantiated with concrete implementations for the target platform:

- **Xen backend**: MirageOS runs as a Xen PV guest, using Xen's grant tables for network and block I/O. The entire "OS" is an OCaml library linked with the application.
- **Unix backend**: MirageOS runs as a regular Unix process, using sockets and files --- useful for development and testing.
- **Solo5 backend**: MirageOS runs on Solo5, a minimal monitor that provides a hardware abstraction layer for KVM, bhyve, or bare metal.

The OCaml type system provides additional safety: many classes of bugs (null pointer dereferences, type confusions) are caught at compile time, and the garbage collector prevents memory leaks and use-after-free.

### 20.1.3 Unikraft

**Unikraft** (part of the Linux Foundation) takes a modular approach: the OS is decomposed into **micro-libraries** that can be selected and configured at build time. Each micro-library provides a specific service: scheduling (cooperative or preemptive), memory allocation (buddy, slab, or simple bump allocator), network stack (lwIP or a custom stack), file system (initrd, 9pfs, virtiofs), and so on.

Unlike MirageOS, Unikraft targets POSIX-compatible applications --- existing C/C++ programs can be compiled as unikernels with minimal or no modification. The build system uses KConfig (the same configuration system as the Linux kernel) to select which micro-libraries are included.

Unikraft achieves boot times under 1 ms for some configurations (a "hello world" unikernel boots in ~300 $\mu$s), with images as small as a few hundred kilobytes.

::: programmer
**Programmer's Perspective: When to Use a Unikernel.**
Unikernels are compelling for:

- **Microservices in the cloud**: each service becomes a dedicated VM with a minimal footprint and boot time. AWS Firecracker was partly inspired by this model.
- **IoT and embedded**: a sensor node running a unikernel has a tiny attack surface and boots instantly after power loss.
- **Network functions**: DNS resolvers, load balancers, firewalls --- single-purpose services that benefit from specialisation.
- **Serverless functions**: a unikernel can boot, execute a function, and shut down in milliseconds, matching the serverless execution model.

Unikernels are a poor fit for:

- **General-purpose computing**: no multi-process support, no shell, no runtime debugging tools.
- **Applications with dynamic dependencies**: if the application loads plugins or spawns subprocesses, the unikernel model breaks down.
- **Development**: debugging a unikernel is harder than debugging a process in a full OS. Most frameworks provide a Unix backend for development.

In practice, containers have captured most of the use cases that unikernels targeted, because containers are much easier to build, debug, and deploy. Unikernels remain relevant where the additional security (smaller TCB) and performance (faster boot, lower memory) justify the operational complexity.
:::

## 20.2 eBPF: Safe Kernel Extension

**eBPF** (extended Berkeley Packet Filter) is arguably the most important innovation in the Linux kernel since containers. It allows user-space programs to inject bytecode into the kernel that runs in response to kernel events --- safely, efficiently, and without modifying the kernel source or loading kernel modules.

::: definition
**eBPF (extended Berkeley Packet Filter).** A register-based virtual machine inside the Linux kernel that runs sandboxed programs attached to kernel events. eBPF programs are:

1. **Verified**: a static analyser (the eBPF verifier) checks every program before loading, proving it terminates (bounded loops only), does not access invalid memory, does not dereference null pointers, and does not perform unsafe operations.
2. **JIT-compiled**: after verification, the bytecode is compiled to native machine code for the host architecture (x86-64, ARM64, RISC-V, etc.).
3. **Efficient**: eBPF programs run at near-native speed, with no context switch overhead (they execute in kernel context, at the same privilege level as the kernel).
4. **Composable**: multiple eBPF programs can be attached to different hooks, and they can communicate through shared maps.
:::

### 20.2.1 The eBPF Architecture

```text
User Space                        Kernel Space
┌──────────────┐                 ┌──────────────────────────┐
│              │                 │                          │
│  eBPF        │  bpf() syscall │  eBPF Verifier           │
│  compiler    │ ───────────────>│  (static analysis,       │
│  (clang/LLVM │                 │   type tracking,         │
│   -target bpf)                 │   bounds checking)       │
│              │                 │        │                 │
│  User app    │                 │        ▼                 │
│  (libbpf,    │                 │  JIT Compiler            │
│   reads maps)│ <───────────────│  (bytecode -> native     │
│              │   shared maps   │   x86-64/ARM64)          │
│              │   (hash, array, │        │                 │
│              │    ringbuf,     │        ▼                 │
│              │    LRU, ...)    │  Attached to hook:       │
│              │                 │  - kprobe (any function) │
│              │                 │  - tracepoint (stable)   │
│              │                 │  - XDP (network ingress) │
│              │                 │  - tc  (traffic control) │
│              │                 │  - cgroup (per-group)    │
│              │                 │  - LSM (security hooks)  │
│              │                 │  - sched_ext (scheduler) │
│              │                 │  - fentry/fexit          │
│              │                 │  - uprobe (userspace)    │
└──────────────┘                 └──────────────────────────┘
```

### 20.2.2 The eBPF Verifier

The verifier is what makes eBPF safe. Without it, injecting code into the kernel would be equivalent to loading an arbitrary kernel module --- a massive security risk. The verifier performs:

1. **Control flow analysis**: the program's control flow graph must be a DAG with respect to back edges (no unbounded loops). Since Linux 5.3, bounded loops are permitted: the verifier proves the loop terminates by tracking the loop variable's bounds.

2. **Register type tracking**: the verifier maintains a type for every register at every instruction (scalar, pointer to map value, pointer to stack, pointer to packet data, pointer to context structure). It ensures that pointers are not used as scalars and vice versa.

3. **Bounds tracking**: for every scalar register, the verifier tracks the possible value range (min/max for signed and unsigned). Array accesses are checked against the tracked bounds.

4. **Pointer safety**: eBPF programs can only access kernel data through verified **helper functions** (e.g., `bpf_map_lookup_elem`, `bpf_probe_read_kernel`, `bpf_get_current_pid_tgid`). Direct pointer dereferences of arbitrary kernel addresses are forbidden.

5. **Stack safety**: the eBPF stack is limited to 512 bytes. The verifier ensures no stack overflow.

6. **Instruction limit**: a program can have at most 1 million verified instructions (to bound verification time).

If the verifier rejects a program, it provides a detailed log explaining which instruction failed and why. This is essentially a lightweight proof that the program is safe.

### 20.2.3 Applications of eBPF

**Networking (XDP):** eXpress Data Path allows eBPF programs to process packets at the earliest point in the network stack --- before the kernel allocates an `sk_buff`. Packets can be dropped, redirected, or modified at line rate (100 Gbps+). Meta's Katran L4 load balancer and Cloudflare's DDoS mitigation run as XDP programs.

**Observability:** eBPF programs attach to kernel functions (kprobes), tracepoints, or user-space functions (uprobes), collecting performance data without modifying the kernel or restarting services. Tools like `bpftrace`, BCC, and Cilium's Hubble use eBPF for zero-overhead tracing.

**Security (LSM):** eBPF programs attached to LSM hooks make access control decisions based on runtime context. Cilium Tetragon provides security observability --- monitoring system calls, file access, and network connections at the kernel level without the overhead of a user-space agent.

**Scheduling (sched_ext):** Since Linux 6.12, eBPF can implement custom CPU scheduling policies. The scheduler is loaded as an eBPF program that the kernel calls on scheduling events (enqueue, dequeue, pick_next). This allows experimentation with scheduling algorithms (e.g., EEVDF variants, game-optimised schedulers) without recompiling the kernel.

::: example
**Example 20.2 (eBPF in Production).**

| Organisation | Use Case | eBPF Hook | Scale |
|---|---|---|---|
| Meta (Facebook) | L4 load balancing (Katran) | XDP | Billions of packets/day |
| Cloudflare | DDoS mitigation | XDP | 100M+ RPS |
| Netflix | System-wide performance tracing | kprobes, tracepoints | Thousands of servers |
| Google/Isovalent | Kubernetes networking (Cilium) | tc, XDP, cgroup | Production clusters |
| Isovalent | Security observability (Tetragon) | LSM, kprobes | Runtime enforcement |
| Android | Network traffic management | cgroup/skb | Billions of devices |
:::

::: programmer
**Programmer's Perspective: Writing an eBPF Program in C.**
An eBPF program that counts system calls per process, using the CO-RE (Compile Once, Run Everywhere) framework:

```c
/* syscall_count.bpf.c -- eBPF kernel program */
#include <vmlinux.h>          /* BTF-generated kernel types */
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

/* Map: PID -> syscall count */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, __u32);    /* PID */
    __type(value, __u64);  /* count */
} syscall_counts SEC(".maps");

/* Attach to the raw_syscalls:sys_enter tracepoint.
   This fires on every system call, for every process. */
SEC("tracepoint/raw_syscalls/sys_enter")
int count_syscalls(struct trace_event_raw_sys_enter *ctx) {
    __u32 pid = bpf_get_current_pid_tgid() >> 32;

    __u64 *count = bpf_map_lookup_elem(&syscall_counts, &pid);
    if (count) {
        /* Atomic increment: safe even with concurrent access
           from multiple CPUs */
        __sync_fetch_and_add(count, 1);
    } else {
        __u64 init_val = 1;
        bpf_map_update_elem(&syscall_counts, &pid, &init_val, BPF_ANY);
    }
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
```

The verifier proves that:

- The `bpf_map_lookup_elem` return value is checked for NULL before dereference (line: `if (count)`).
- The map key and value sizes match the map definition.
- The program terminates (no loops).
- The stack usage is within 512 bytes.
- The program only accesses the tracepoint context fields, not arbitrary kernel memory.

Compile: `clang -target bpf -D__TARGET_ARCH_x86 -O2 -g -c syscall_count.bpf.c -o syscall_count.bpf.o`

A user-space loader (using libbpf) opens the `.bpf.o` file, loads and verifies the program, attaches it to the tracepoint, and periodically reads the hash map to display per-process syscall rates. The entire pipeline requires no kernel recompilation, no module loading, and no reboot.
:::

## 20.3 io_uring: Kernel-Bypass I/O

Traditional Unix I/O uses system calls: `read()`, `write()`, `sendmsg()`, `recvmsg()`. Each system call crosses the user-kernel boundary, costing approximately 100--1000 ns (plus TLB flush overhead with KPTI). For high-frequency I/O (millions of operations per second), this overhead dominates.

**io_uring** (introduced in Linux 5.1, 2019, by Jens Axboe) eliminates the system call overhead by using shared memory ring buffers between user space and the kernel.

::: definition
**io_uring.** A Linux kernel interface for asynchronous I/O based on two lock-free shared ring buffers:

1. **Submission Queue (SQ)**: user space writes I/O requests (Submission Queue Entries, SQEs) here. Each SQE specifies an opcode, file descriptor, buffer, offset, and user-data tag.

2. **Completion Queue (CQ)**: the kernel writes I/O results (Completion Queue Entries, CQEs) here. Each CQE contains the result code and the user-data tag from the corresponding SQE.

Both queues are memory-mapped (via `mmap` on the io_uring file descriptor) and accessed lock-free using memory barriers. In polling mode, no system calls are needed on the hot path.
:::

### 20.3.1 Submission Modes

io_uring supports three modes, trading CPU usage for latency:

**Default mode:** User space writes SQEs, then calls `io_uring_enter()` to submit them. The kernel processes the SQEs asynchronously and writes CQEs. The submission path requires one system call per batch.

**SQ polling (`IORING_SETUP_SQPOLL`):** The kernel spawns a dedicated polling thread that continuously checks the SQ for new entries. User space writes SQEs directly to shared memory --- no system call needed. The polling thread picks them up automatically. If the SQ is empty for a configurable period, the polling thread sleeps (and wakes on the next submission via `io_uring_enter`).

**IO polling (`IORING_SETUP_IOPOLL`):** The kernel polls the hardware for completions instead of waiting for interrupts. Combined with SQ polling, this achieves fully polled I/O: zero system calls and zero interrupts on the hot path. This mode requires a block device that supports polled I/O (most modern NVMe drives do).

```text
User Space                              Kernel Space
┌────────────────────────┐             ┌────────────────────────┐
│                        │             │                        │
│  Application           │             │  io_uring engine       │
│  │                     │             │  │                     │
│  ├─> Write SQE to SQ ─┼─ (mmap) ────┼──> Read SQE from SQ   │
│  │   (store + barrier, │  shared     │  │  (SQ poll thread    │
│  │    no syscall)      │  memory     │  │   or io_uring_enter)│
│  │                     │             │  │                     │
│  │                     │             │  ├─> Submit to block   │
│  │                     │             │  │   layer / network   │
│  │                     │             │  │                     │
│  └─< Read CQE from CQ <┼─ (mmap) ────┼──< Write CQE to CQ   │
│      (load + barrier,  │             │     (after I/O        │
│       no syscall)      │             │      completes)        │
│                        │             │                        │
└────────────────────────┘             └────────────────────────┘
```

### 20.3.2 Performance Impact

::: example
**Example 20.3 (io_uring Performance on NVMe).** Benchmarks on modern NVMe SSDs (4 KB random reads, single core):

| Interface | IOPS | Notes |
|---|---|---|
| Synchronous `read()` | ~200K | One syscall per I/O |
| `libaio` (Linux AIO) | ~400K | Async, but still uses syscalls for submit/reap |
| io_uring (default) | ~800K | Batched submissions, async completions |
| io_uring (SQ + IO poll) | ~1.2M | Zero syscalls, zero interrupts |
| SPDK (full kernel bypass) | ~1.5M | User-space NVMe driver, no kernel involvement |

io_uring achieves 80% of the performance of full kernel bypass (SPDK) while retaining the kernel's block layer, file systems, and scheduler. For most applications, this is the optimal trade-off: near-maximum performance without giving up the kernel's storage management.
:::

### 20.3.3 Advanced Features

io_uring has grown far beyond basic read/write:

- **Linked SQEs**: chain operations so that one starts only after the previous completes (e.g., open then read then close).
- **Fixed files and buffers**: register file descriptors and buffers once, avoiding per-I/O `fget`/`fput` and page table walks.
- **Zero-copy send** (`IORING_OP_SEND_ZC`): pass user-space buffers directly to the NIC's DMA engine.
- **Multishot accept**: a single SQE accepts multiple incoming connections, each generating a CQE.
- **Registered rings**: nested io_uring instances for hierarchical I/O management.
- **IORING_OP_WAITID**, `IORING_OP_FUTEX`: extending beyond I/O to general-purpose async operations.

## 20.4 Capability-Based Hardware: CHERI

Software-based memory safety (bounds checking, garbage collection, safe languages) imposes runtime overhead. **CHERI** (Capability Hardware Enhanced RISC Instructions) moves memory safety into the hardware, enforcing it at the speed of a pointer dereference.

::: definition
**CHERI Capability.** A CHERI capability is a hardware-enforced pointer that carries metadata:

1. **Address**: the current pointer value (the address being pointed to).
2. **Base and bounds**: the memory region the capability is authorised to access: $[\text{base}, \text{base} + \text{length})$.
3. **Permissions**: a bitmask of allowed operations (read, write, execute, load capability, store capability, seal, unseal).
4. **Object type**: for sealed capabilities (opaque references that cannot be dereferenced, only passed and unsealed by authorised code).
5. **Tag bit**: a 1-bit hardware flag that marks a register or memory word as containing a valid capability. The tag bit is maintained by the hardware and **cleared** if the capability is modified through non-capability instructions (e.g., integer arithmetic on the address). This makes capabilities **unforgeable**.
:::

CHERI capabilities are 128 bits wide on 64-bit architectures (compared to 64-bit raw pointers), using a compressed bounds encoding (CHERI Concentrate) that represents most practical bounds exactly.

::: example
**Example 20.4 (CHERI Preventing a Buffer Overflow).** The vulnerable C function from Chapter 17:

```c
void vulnerable(const char *input) {
    char buffer[64];
    strcpy(buffer, input);  /* overflow! */
}
```

On a CHERI processor:

1. `buffer` is a capability with address = stack pointer, base = stack pointer, length = 64, permissions = read/write.
2. `strcpy` increments the destination pointer as it copies bytes. When the pointer reaches `base + 64`, the next store instruction triggers a **capability bounds fault** --- a hardware exception, analogous to a page fault.
3. The fault occurs **at the exact instruction that overflows**, before any data is corrupted. No canary check, no ASLR, no NX bit needed.

CHERI also prevents **use-after-free**: when `free()` deallocates a buffer, the runtime can revoke (clear the tag bit of) all capabilities pointing to that buffer, using a hardware-assisted revocation mechanism. Any subsequent dereference through a revoked capability traps.
:::

The **ARM Morello** board (2022) is the first production-quality CHERI implementation, based on ARMv8.2-A with CHERI extensions. Research at the University of Cambridge has demonstrated that existing C/C++ code can be compiled for CHERI (using the CHERI Clang/LLVM toolchain) with modest source modifications, and the performance overhead is typically 5--15% for the "pure capability" ABI (all pointers are capabilities). A "hybrid" ABI allows mixing capability and raw pointers, reducing overhead at the cost of partial protection.

## 20.5 Persistent Memory

**Persistent memory** (PMEM) is byte-addressable storage that retains data across power cycles, sitting on the memory bus alongside DRAM. Intel Optane DC Persistent Memory was the first commercial product (2019--2022); CXL-attached persistent memory is the successor technology.

::: definition
**Persistent Memory.** A storage class that combines byte-addressability and low latency with persistence:

| Property | DRAM | PMEM (Optane) | NVMe SSD |
|---|---|---|---|
| Interface | DDR bus, load/store | DDR bus, load/store | PCIe, block I/O |
| Read latency | ~80 ns | ~300 ns | ~10 $\mu$s |
| Write latency | ~80 ns | ~100 ns | ~20 $\mu$s |
| Persistence | No | Yes | Yes |
| Granularity | 64 bytes (cache line) | 64 bytes (cache line) | 4 KB (sector/page) |
| Capacity | ~TB | ~TB (per socket) | ~TB |
| Endurance | Unlimited | ~$10^{15}$ writes | ~$10^{17}$ writes (TLC) |
:::

### 20.5.1 DAX File Systems

**DAX** (Direct Access) file systems allow applications to `mmap` a file on PMEM and access it directly via load/store instructions, **bypassing the page cache entirely**. The page cache exists to buffer slow block I/O in DRAM; with PMEM, the storage is already on the memory bus, so caching in DRAM is counterproductive (it wastes DRAM and adds latency).

Linux supports DAX on ext4 and XFS (mount with `-o dax=always`).

```c
#include <fcntl.h>
#include <sys/mman.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <immintrin.h>  /* for _mm_clwb, _mm_sfence */

int main(void) {
    /* Open a file on a DAX-mounted filesystem */
    int fd = open("/mnt/pmem0/data.bin", O_RDWR | O_CREAT, 0644);
    ftruncate(fd, 4096);

    /* mmap with MAP_SHARED_VALIDATE | MAP_SYNC for DAX guarantees:
       - MAP_SHARED: changes are visible to other processes
       - MAP_SYNC: msync is not needed; stores + clwb + sfence suffice */
    char *pmem = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                      MAP_SHARED_VALIDATE | MAP_SYNC, fd, 0);
    if (pmem == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    /* Write directly to persistent memory */
    strcpy(pmem, "Hello, persistent memory!");

    /* CRITICAL: CPU caches sit between the core and PMEM.
       A store may be in L1/L2/L3 cache, not yet on PMEM.
       We must explicitly flush cache lines and fence. */
    _mm_clwb(pmem);    /* write-back cache line (non-invalidating) */
    _mm_sfence();       /* ensure all prior stores and flushes are ordered */

    /* After sfence, the data is guaranteed to be on PMEM.
       It will survive a power failure. */

    printf("Persisted: %s\n", pmem);

    munmap(pmem, 4096);
    close(fd);
    return 0;
}
```

### 20.5.2 The Crash Consistency Challenge

PMEM introduces a new programming challenge: **crash consistency without a journal or log**. With traditional storage, the file system's journal ensures that a crash leaves the file system in a consistent state. With PMEM and DAX, the application writes directly to persistent storage, and the CPU's cache hierarchy introduces ambiguity about what has actually been persisted.

The store ordering through the memory hierarchy is:

$$\text{CPU register} \xrightarrow{\text{store}} \text{Store buffer} \xrightarrow{\text{drain}} \text{L1 cache} \xrightarrow{\text{evict}} \text{L2/L3} \xrightarrow{\text{evict}} \text{PMEM}$$

A power failure at any point in this chain causes data loss for stores that have not reached PMEM. The programmer must explicitly manage persistence:

- `CLWB` (Cache Line Write Back): writes back a cache line to PMEM without invalidating the cache (the line remains cached for subsequent reads). Available on Intel since Skylake.
- `CLFLUSH` / `CLFLUSHOPT`: write back and invalidate the cache line. `CLFLUSHOPT` is more efficient (can be pipelined).
- `SFENCE` (Store Fence): ensures all prior stores and cache flushes are ordered before subsequent stores.

::: example
**Example 20.5 (PMEM Crash Consistency Bug).** Consider updating a linked list node on PMEM:

```c
/* WRONG: if power fails between the two stores, the node is
   inconsistent --- data is new but next points to the old target */
node->data = new_value;
node->next = new_next;

/* The stores might reach PMEM in any order, or only partially.
   After a crash, we might see:
   - data=new_value, next=old_next  (partially updated)
   - data=old_value, next=new_next  (store reordering)
   - data=old_value, next=old_next  (neither persisted)
   - data=new_value, next=new_next  (both persisted, correct)
*/

/* CORRECT: use CLWB + SFENCE to enforce ordering */
node->data = new_value;
_mm_clwb(&node->data);
_mm_sfence();         /* data is now on PMEM */

node->next = new_next;
_mm_clwb(&node->next);
_mm_sfence();         /* next is now on PMEM, after data */
```

Even with correct fencing, the application must be designed for crash recovery. Common approaches:

- **Write-ahead logging**: write the new values to a log on PMEM, fence, then apply them to the data structure, fence, then mark the log entry as committed. On recovery, replay uncommitted log entries.
- **Copy-on-write**: allocate a new node, populate it, fence, then atomically update the parent's pointer (a single 8-byte store that is naturally atomic on x86-64).
- **Transactional libraries**: PMDK (Persistent Memory Development Kit, now PMEMOBJ) provides a transactional API that handles fencing and logging automatically.
:::

## 20.6 Microkernels Redux: seL4 and Fuchsia

The microkernel vs monolithic kernel debate, which appeared settled in favour of monolithic kernels in the 1990s (largely due to performance arguments), has been reopened by two developments: hardware that makes IPC fast (modern x86 and ARM cores achieve <1 $\mu$s IPC), and formal verification that makes microkernels provably correct.

### 20.6.1 seL4: The Verified Kernel

::: definition
**seL4.** A third-generation microkernel (approximately 10,000 lines of C and 600 lines of assembly) with machine-checked proofs of correctness covering:

1. **Functional correctness**: the C implementation is proven (in Isabelle/HOL) to behave exactly as specified by the abstract mathematical model. Every execution of the C code corresponds to a valid execution of the specification.
2. **Integrity** (information flow): a compromised user-space process cannot affect the kernel or other processes that it does not have capabilities to access.
3. **Confidentiality** (information flow): information flows only through explicitly authorised channels.
4. **Binary correctness**: the compiled ARM binary is proven to behave as the C source (via translation validation against the GCC/LLVM output).
5. **Worst-case execution time (WCET)**: proven bounds on interrupt latency, enabling hard real-time guarantees.
:::

::: theorem
**Theorem 20.1 (seL4 Functional Correctness).** Let $S$ be the abstract specification of seL4 (a mathematical model in Isabelle/HOL of all kernel operations), and let $I$ be the C implementation. The seL4 verification proves:

$$\forall \text{ inputs } x, \text{ states } \sigma : \text{exec}(I, x, \sigma) \text{ refines } \text{exec}(S, x, \sigma)$$

Every behaviour of the implementation is a valid behaviour of the specification. This implies: no buffer overflows, no null pointer dereferences, no use-after-free, no integer overflows, no uninitialised memory reads, no race conditions, and no deviations from the specification --- in the kernel code.

*Scope of the proof*: the verification covers the kernel's C code and its compiled binary (on ARM). It does **not** cover: the hardware (assumed correct), the bootloader, user-space code, or the compiler for non-verified targets. Approximately 200,000 lines of Isabelle/HOL proof were required for 10,000 lines of C --- a 20:1 proof-to-code ratio.
:::

seL4 is a **capability-based** microkernel: every kernel resource (memory frames, page tables, endpoints for IPC, interrupt handlers) is accessed through capabilities. A process can only perform operations on resources for which it holds capabilities, and capabilities can be selectively delegated. This naturally enforces the principle of least privilege.

### 20.6.2 Fuchsia and Zircon

Google's **Fuchsia** operating system uses **Zircon**, a microkernel written in C++. Zircon is also capability-based: every resource is accessed through a **handle** (the user-space representation of a capability), and handles carry specific rights (read, write, duplicate, transfer).

Unlike seL4, Zircon is not formally verified. Its strength is engineering quality and modern design: support for 64-bit only, ASLR by default, user-space device drivers, a component-based application framework (built on FIDL --- Fuchsia Interface Definition Language for IPC), and a capability-based security model throughout the stack.

Fuchsia is deployed in production on the Google Nest Hub (a consumer smart display), demonstrating that microkernels can achieve acceptable performance for interactive consumer products.

## 20.7 Rust in the Kernel

The Linux kernel is written in C, a language with no memory safety guarantees at the language level. Buffer overflows, use-after-free, and data races account for approximately 65--70% of kernel security vulnerabilities (per analyses by Microsoft, Google, and the Chromium project). **Rust** offers memory safety at compile time, without the runtime overhead of garbage collection.

### 20.7.1 Rust's Safety Model

::: definition
**Rust's Ownership System.** Rust enforces memory safety through three compile-time rules, checked by the **borrow checker**:

1. **Ownership**: every value has exactly one owner variable. When the owner goes out of scope, the value is dropped (its destructor runs and its memory is freed).
2. **Borrowing**: references to a value can be shared (`&T`, multiple immutable borrows allowed) or exclusive (`&mut T`, at most one mutable borrow allowed). Shared and exclusive borrows cannot coexist for the same value at the same time.
3. **Lifetimes**: every reference has a lifetime (a lexical scope during which it is valid). The compiler ensures that no reference outlives the value it points to.
:::

These rules prevent, at compile time, four of the most common classes of memory bugs:

| Bug Class | Rust Prevention Mechanism |
|---|---|
| Use-after-free | Ownership + lifetimes (reference cannot outlive value) |
| Double free | Unique ownership (only one owner can drop) |
| Data races | `Send`/`Sync` traits + borrow checker (no concurrent mutable access) |
| Null pointer dereference | No null pointers; `Option<T>` requires explicit handling |
| Buffer overflow | Bounds-checked indexing on `Vec<T>`, `[T]`, etc. |

### 20.7.2 Linux Rust Modules

Since Linux 6.1 (December 2022), the kernel supports modules written in Rust. The Rust-for-Linux project provides safe abstractions over kernel C APIs, allowing driver authors to write in safe Rust.

::: example
**Example 20.6 (Rust Kernel Module).**

```text
// SPDX-License-Identifier: GPL-2.0

//! A minimal Rust kernel module demonstrating safe abstractions.

use kernel::prelude::*;
use kernel::sync::Mutex;
use kernel::new_mutex;

module! {
    type: CounterModule,
    name: "counter_rust",
    author: "Example",
    description: "A counter demonstrating Rust safety in the kernel",
    license: "GPL",
}

struct CounterModule {
    counter: Mutex<u64>,
}

impl kernel::Module for CounterModule {
    fn init(_module: &'static ThisModule) -> Result<Self> {
        pr_info!("Rust counter module loaded\n");

        let module = CounterModule {
            counter: new_mutex!(0u64, "counter"),
        };

        // Demonstrate safe mutation: the Mutex enforces that
        // only one thread can access the counter at a time.
        {
            let mut guard = module.counter.lock();
            *guard += 1;
            pr_info!("Counter incremented to {}\n", *guard);
            // guard is dropped here, releasing the lock
        }

        Ok(module)
    }
}

impl Drop for CounterModule {
    fn drop(&mut self) {
        let guard = self.counter.lock();
        pr_info!("Module unloaded, final counter: {}\n", *guard);
    }
}
```

Key differences from a C kernel module:

- Every memory allocation returns a `Result`, forcing the programmer to handle allocation failure. In C, `kmalloc` returns NULL, and forgetting to check is a bug. In Rust, ignoring a `Result` is a compile error.
- The `Mutex` wrapper ensures that the protected data can only be accessed through the lock guard. In C, nothing prevents accessing the data without holding the lock.
- The `Drop` trait ensures cleanup on module unload --- no forgotten `kfree` calls.
- Buffer overflows in safe Rust are impossible. Array/slice indexing is bounds-checked.
:::

### 20.7.3 The Safe/Unsafe Boundary

Kernel code necessarily interacts with hardware registers, DMA buffers, and lock-free data structures that cannot be expressed in safe Rust. The Rust-for-Linux approach encapsulates `unsafe` operations in carefully audited safe abstractions:

```text
┌──────────────────────────────────────────┐
│  Driver code (100% safe Rust)            │
│  - No unsafe blocks                      │
│  - Uses safe abstractions: Mutex<T>,     │
│    Pin<T>, DmaBuffer<T>, IoMem<T>        │
├──────────────────────────────────────────┤
│  Safe abstractions (Rust wrappers)       │
│  - Contains unsafe blocks               │
│  - Provides safe API enforced by types   │
│  - Invariants documented and maintained  │
│  - Small, auditable surface             │
├──────────────────────────────────────────┤
│  Kernel C API (FFI bindings via bindgen) │
│  - All functions are extern "C", unsafe  │
│  - Generated from kernel C headers       │
└──────────────────────────────────────────┘
```

The goal is to maximise the ratio of safe to unsafe code. As more abstractions are built, driver authors write entirely in safe Rust. The Android team has reported that introducing Rust for new Binder driver code has resulted in zero memory safety vulnerabilities in the Rust components, compared to a steady stream in the C components.

::: programmer
**Programmer's Perspective: Rust Kernel Modules and the Safety Guarantee.**
The value proposition of Rust in the kernel is not about performance (C and Rust produce comparable machine code). It is about **eliminating classes of bugs at compile time**.

Consider a kernel driver that manages a DMA buffer. In C, the programmer must manually ensure:

1. The buffer is allocated with the correct alignment for the device.
2. The buffer is freed exactly once (no double free).
3. No reference to the buffer is used after free (no use-after-free).
4. The buffer is not accessed concurrently without proper locking (no data race).
5. The physical address (not virtual) is passed to the device for DMA.
6. The buffer is not larger than the allocated size (no overflow).

Any mistake in any of these is a potential kernel panic or security vulnerability. In Rust:

```text
// Hypothetical safe DMA buffer abstraction
struct DmaBuffer<T> {
    vaddr: *mut T,        // virtual address (unsafe internally)
    paddr: PhysAddr,      // physical address
    size: usize,          // allocated size
    _marker: PhantomData<T>,
}

impl<T> DmaBuffer<T> {
    // Allocation: returns Result, not raw pointer
    fn alloc(dev: &Device, count: usize) -> Result<Self> { ... }

    // Access: returns a slice with bounds checking
    fn as_slice(&self) -> &[T] { ... }
    fn as_mut_slice(&mut self) -> &mut [T] { ... }

    // Physical address: method, not cast
    fn phys_addr(&self) -> PhysAddr { self.paddr }
}

// Drop: automatically freed when DmaBuffer goes out of scope
impl<T> Drop for DmaBuffer<T> {
    fn drop(&mut self) { /* dma_free_coherent(...) */ }
}

// Send: can be transferred to another thread
// Sync: cannot be shared between threads without external sync
unsafe impl<T: Send> Send for DmaBuffer<T> {}
```

The Rust compiler enforces all six invariants through the type system. Incorrect code is rejected at compile time, not discovered through fuzzing or in production.
:::

## 20.8 WebAssembly as a Portable OS Interface

**WebAssembly** (Wasm) was originally designed for browsers, but its properties --- sandboxed execution, near-native performance, language independence, and deterministic semantics --- make it compelling as a universal runtime for server-side and edge computing.

::: definition
**WebAssembly (Wasm).** A portable, size-efficient binary instruction format with the following properties:

1. **Memory safety**: Wasm modules execute in a linear memory sandbox (a flat byte array). They cannot access host memory, the stack of the host process, or other Wasm modules' memory without explicit imports.
2. **Control flow integrity**: indirect calls go through a type-checked function table. There are no arbitrary jumps.
3. **Near-native performance**: Wasm is designed for efficient AOT and JIT compilation. Performance is typically within 10--30% of native code.
4. **Language independence**: C, C++, Rust, Go, AssemblyScript, Zig, and many other languages compile to Wasm.
5. **Deterministic semantics**: Wasm's specification leaves no undefined behaviour (unlike C). The same module produces the same results on any compliant runtime.
:::

### 20.8.1 WASI: The WebAssembly System Interface

**WASI** (WebAssembly System Interface) defines a set of APIs that Wasm modules can use to interact with the outside world: file I/O, networking, clocks, random numbers, and environment variables. WASI is **capability-based**: a Wasm module can only access files and network connections that the host explicitly grants through capability handles.

```text
┌────────────────────────────────────┐
│  Wasm Module                       │
│  (compiled from C, Rust, Go, etc.) │
│  │                                 │
│  ├─ fd_read(fd, iovs, nread)       │
│  ├─ fd_write(fd, iovs, nwritten)   │
│  ├─ path_open(dir_fd, path, ...)   │  WASI API calls
│  ├─ sock_accept(fd, ...)           │
│  └─ clock_time_get(clock_id, ...) │
└────────────┬───────────────────────┘
             │ only granted capabilities
             ▼
┌────────────────────────────────────┐
│  Wasm Runtime (Wasmtime, Wasmer)   │
│  │                                 │
│  ├─ Validates and compiles module  │
│  ├─ Enforces sandbox boundaries    │
│  ├─ Maps WASI calls to host OS     │
│  └─ Provides only granted dirs,    │
│     files, network access          │
└────────────┬───────────────────────┘
             │ real system calls
             ▼
┌────────────────────────────────────┐
│  Host Operating System             │
└────────────────────────────────────┘
```

### 20.8.2 Wasm as a Container Alternative

Solomon Hykes, co-founder of Docker, stated in 2019: "If WASM+WASI existed in 2008, we wouldn't have needed to create Docker." The reasoning:

- **Portability**: a Wasm binary runs on any platform with a compliant runtime --- no container image layers, no architecture-specific builds, no base images.
- **Sandboxing**: WASI's capability model provides fine-grained isolation without kernel namespaces or cgroups.
- **Startup time**: Wasm modules start in microseconds (pre-compiled AOT), not hundreds of milliseconds.
- **Size**: a Wasm module is typically kilobytes to low megabytes, versus hundreds of megabytes for a container image.

However, Wasm currently lacks the full POSIX interface that most server applications expect. WASI preview 2 (the Component Model) adds composability: Wasm modules can be linked together like shared libraries, with typed interfaces. But full threading, shared memory, and unrestricted networking are still evolving.

**Wasmtime** (Bytecode Alliance: Mozilla, Fastly, Intel, Red Hat) and **Wasmer** are the leading Wasm runtimes. **Spin** (Fermyon) and **wasmCloud** provide developer-friendly frameworks for building Wasm-based microservices. Cloudflare Workers uses V8's Wasm engine to run user code at edge locations with sub-millisecond cold start.

## 20.9 The Convergence of OS and Language Runtime

A recurring theme in this chapter is the erosion of the boundary between the operating system and the language runtime.

### 20.9.1 Go and the GMP Scheduler

Go's runtime is a user-space operating system: it schedules goroutines (the GMP model), manages memory (mspan/mcentral/mheap), provides synchronisation (channels, mutexes), performs garbage collection, and handles I/O multiplexing (netpoller wrapping epoll/kqueue). The Linux kernel sees a Go program as an ordinary multi-threaded process; the real scheduling and memory management happens in user space, invisible to the kernel.

### 20.9.2 The Erlang BEAM

The Erlang BEAM virtual machine goes further: it manages millions of lightweight processes with per-process garbage collection (each process has a tiny heap, and GC is incremental per-process), preemptive scheduling (based on reduction counts: each process gets ~4000 function calls before being preempted), and built-in distribution (processes on different machines communicate transparently using the same syntax as local message passing).

### 20.9.3 Green Threads Everywhere

The trend towards user-space scheduling is accelerating across all major languages:

| Runtime | Unit | Stack | Scheduling | Preemption |
|---|---|---|---|---|
| Go | goroutine | 2--8 KB (growable) | GMP M:N | Async signal (Go 1.14+) |
| Erlang/BEAM | process | ~300 words | Preemptive | Reduction count |
| Java (Loom) | virtual thread | ~1 KB | M:N | Cooperative (yield at I/O) |
| Rust (tokio) | task | stackless (state machine) | M:N | Cooperative (async/await) |
| C# (.NET) | Task | stackless (state machine) | Thread pool | Cooperative (async/await) |
| Kotlin | coroutine | stackless | Dispatchers | Cooperative (suspend) |

::: example
**Example 20.7 (User-Space vs Kernel Scheduling Costs).**

| Operation | Kernel Thread (pthread) | Goroutine (Go) | Ratio |
|---|---|---|---|
| Creation | ~100 $\mu$s, 1--8 MB stack | ~1 $\mu$s, 2 KB stack | 100x |
| Context switch | ~1--10 $\mu$s (kernel mode) | ~100--200 ns (user mode) | 10--100x |
| Max concurrent | ~10,000 (stack space limited) | ~1,000,000+ | 100x |
| Memory per unit | 1--8 MB (fixed stack) | 2--8 KB (growable) | 125--4000x |

The orders-of-magnitude differences explain why high-concurrency servers (web servers handling 100K+ connections, databases with thousands of concurrent queries, network proxies) benefit enormously from user-space scheduling. The kernel's thread abstraction was designed for tens to hundreds of concurrent activities, not millions.
:::

::: programmer
**Programmer's Perspective: The Emerging Systems Stack.**
The technologies in this chapter are converging into a new systems architecture:

```text
Traditional Stack (2000--2020)      Emerging Stack (2020+)
┌──────────────────┐              ┌──────────────────────────┐
│  Application     │              │  Application             │
│  (C/C++/Java)    │              │  (Rust/Go/Wasm)          │
├──────────────────┤              ├──────────────────────────┤
│  libc + syscalls │              │  io_uring (async I/O)    │
│  (read/write/    │              │  eBPF hooks (tracing,    │
│   mmap/ioctl)    │              │   networking, security)  │
├──────────────────┤              ├──────────────────────────┤
│  Linux kernel    │              │  Linux kernel            │
│  (C, ~25M LOC)   │              │  + Rust modules (safe)   │
│                  │              │  + eBPF extensions       │
│                  │              │  + sched_ext (custom     │
│                  │              │    schedulers)            │
├──────────────────┤              ├──────────────────────────┤
│  x86/ARM         │              │  CHERI (capability HW)   │
│  (raw pointers)  │              │  CXL (PMEM, disaggregated│
│                  │              │   memory)                │
└──────────────────┘              └──────────────────────────┘
```

The key shift is from **runtime checking** to **compile-time and hardware-time checking**:

- Memory safety: from ASLR + canaries (runtime) to Rust (compile-time) + CHERI (hardware).
- Kernel extension: from kernel modules (unrestricted) to eBPF (verified before loading).
- I/O: from synchronous syscalls (kernel boundary crossing) to io_uring (shared-memory rings).
- Isolation: from processes and VMs to Wasm modules (language-level sandboxing).

For a systems programmer today, the most impactful technologies to master are:

1. **Rust**: kernel modules, drivers, systems libraries, and embedded.
2. **eBPF**: observability, networking, and security at the kernel level.
3. **io_uring**: high-performance I/O for databases, proxies, and storage engines.
4. **Go**: distributed systems, container runtimes, and cloud infrastructure.
5. **Wasm/WASI**: portable, sandboxed edge computing and plugin systems.
:::

## 20.10 Summary: The OS in the Next Decade

The operating system is not dying --- it is **decomposing** into specialised layers, each verifiable, composable, and hardware-aware:

| Layer | Traditional (2020) | Emerging (2025+) |
|---|---|---|
| Kernel | Monolithic C (Linux 25M+ LOC) | Verified microkernel (seL4) or monolithic + Rust modules + eBPF |
| I/O | Synchronous syscalls | io_uring (shared rings), kernel bypass (DPDK, SPDK) |
| Memory safety | ASLR + canaries + NX (reactive) | CHERI (proactive, hardware), Rust (proactive, language) |
| Isolation | Processes + VMs + containers | + Wasm sandboxes + unikernels + Firecracker microVMs |
| Scheduling | Kernel scheduler (fixed policy) | + eBPF sched_ext + user-space (goroutines, virtual threads) |
| Storage | Block I/O + page cache | PMEM + DAX (byte-addressable persistence) |
| Extension | Kernel modules (unsafe, unrestricted) | eBPF (verified, sandboxed, JIT-compiled) |
| Verification | Testing + fuzzing | Formal proofs (seL4) + static analysis (eBPF verifier) |

The common thread is **pushing guarantees closer to the foundation**: memory safety into silicon (CHERI), correctness into proofs (seL4), safe extensibility into static analysis (eBPF verifier), and performance-critical paths into shared memory (io_uring). The operating system of the next decade will be less a monolithic artefact and more a **verified, composable, hardware-software co-design**.

---

::: exercises
1. **Unikernel Trade-offs.** A company deploys 50 microservices, each running in its own container on a shared Kubernetes cluster. The security team proposes migrating each microservice to a unikernel running in its own VM. (a) What security benefits does the unikernel approach provide over containers? Quantify the TCB reduction. (b) What operational challenges does it introduce (deployment pipelines, debugging, monitoring, log collection, live updates)? (c) Under what threat model and scale conditions would the migration be justified? (d) Could Firecracker microVMs provide a middle ground? Explain.

2. **eBPF Verifier Limits.** The eBPF verifier imposes a maximum of 1 million verified instructions per program. (a) Explain why this limit exists (consider the verifier's time complexity). (b) Describe a legitimate eBPF program that might exceed this limit (e.g., a complex packet parser with many protocol branches). (c) Explain how **tail calls** (one eBPF program calling another, up to 33 levels) can restructure such a program to work within the per-program limit while performing the same total computation.

3. **io_uring vs Traditional I/O.** A network proxy forwards packets between two TCP connections. For each packet, it reads from one socket and writes to the other. The proxy handles 100,000 concurrent connections, each producing 10 I/O operations per second. (a) Calculate the total system call overhead per second using traditional `read()`/`write()` (assume 500 ns per syscall). (b) Calculate the overhead using io_uring with SQ polling (assume 0 ns per operation, plus 1 $\mu$s per batch of 100 operations for ring synchronisation). (c) Calculate the percentage improvement. (d) Recalculate parts (a) and (b) with KPTI enabled, assuming syscall cost increases to 1500 ns. What happens to the relative improvement?

4. **CHERI Pointer Width.** A CHERI capability is 128 bits (compared to 64-bit pointers). (a) For a program with 10 million heap-allocated objects averaging 100 bytes each, with an average of 3 pointers per object, calculate the total memory used by pointers on a conventional 64-bit system and on CHERI. (b) What is the percentage overhead? (c) Explain why the compressed bounds encoding (CHERI Concentrate) does not simply use 128 raw bits for base and length. What does it actually encode, and what alignment restrictions result?

5. **seL4 Verification Scope.** The seL4 verification proves functional correctness of the C implementation against a formal specification. (a) List three specific categories of bugs that the verification does NOT cover. (b) For each, explain why it falls outside the proof's scope. (c) For each, propose a complementary technique or technology (from this chapter or Chapter 17) that could address it.

6. **Rust Soundness in the Kernel.** A Rust kernel module needs to read a 32-bit status register from a memory-mapped device at fixed physical address `0xFEED_0000`. (a) Write the Rust code (using `unsafe` and `core::ptr::read_volatile`) that reads the register. (b) Explain why this operation must be `unsafe` (which of Rust's safety invariants cannot be statically verified). (c) Design a safe wrapper type `StatusRegister` that encapsulates this `unsafe` operation and prevents misuse. What invariants should the constructor verify? What should the public API look like?

7. **Convergence Analysis.** Compare the isolation properties of five approaches: (a) a Linux process, (b) a Linux container (namespaces + cgroups + seccomp), (c) a KVM virtual machine with virtio, (d) a Wasm module in Wasmtime with WASI, (e) a unikernel on Xen. For each, determine: the trusted computing base (TCB) size in approximate LOC, the classes of bugs in the TCB that could break isolation, the performance overhead relative to bare metal, and the recovery mode if isolation is breached. Which combination of these technologies provides the strongest security for a multi-tenant serverless platform? Justify your answer.
:::
