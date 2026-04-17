# Chapter 13: Advanced Memory Topics

The preceding three chapters built the foundations of memory management: address translation, demand paging, page tables, TLBs, and page replacement. These mechanisms are sufficient to understand how a basic virtual memory system works. But modern operating systems go far beyond the basics. They exploit copy-on-write to make `fork()` nearly free, use memory-mapped files to unify the file system and the address space, deploy specialised kernel memory allocators that eliminate fragmentation for internal data structures, handle non-uniform memory architectures where some RAM is faster than other RAM, use huge pages to tame TLB pressure, compress memory to defer swapping, and randomise address layouts to frustrate attackers.

This chapter covers these advanced topics. Each one is a refinement or extension of the core mechanisms, motivated by a real engineering problem and implemented in production operating systems. Together, they represent the state of the art in memory management.

---

## 13.1 Copy-on-Write

### 13.1.1 The fork() Problem

The `fork()` system call creates a child process that is a copy of the parent. Naively, this requires duplicating the parent's entire address space --- potentially gigabytes of memory. Most of the time, the child immediately calls `exec()` to replace its address space with a new program, rendering the copy wasteful.

::: definition
**Definition 13.1 (Copy-on-Write).** *Copy-on-write* (CoW) is an optimisation that defers the copying of memory pages until a write occurs. After `fork()`, the parent and child share all physical frames. The page table entries in both processes are marked read-only. When either process writes to a shared page, the hardware triggers a protection fault. The OS page fault handler then:

1. Allocates a new physical frame.
2. Copies the contents of the original frame to the new frame.
3. Updates the writing process's page table to point to the new frame (marked read-write).
4. If the original frame now has only one reference, marks it read-write in the remaining process's page table.
:::

### 13.1.2 Reference Counting

The OS maintains a reference count for each physical frame, tracking how many page table entries point to it. When a CoW fault occurs, the reference count determines the action:

- **ref\_count > 1:** Copy the page, decrement the original's reference count, set the new page's count to 1.
- **ref\_count = 1:** No copy needed; just mark the page read-write (the process is the sole owner).

::: definition
**Definition 13.2 (Frame Reference Count).** The *reference count* of a physical frame $f$, denoted $\text{refcount}(f)$, is the number of page table entries across all processes that currently map to $f$. A frame can be freed (returned to the free list) only when $\text{refcount}(f) = 0$.
:::

### 13.1.3 CoW Fault Handling

::: example
**Example 13.1 (CoW Fault Sequence).** A parent process P has 4 pages mapped. After `fork()`, child C shares all 4 frames:

```text
Before fork:
  P: PTE[0]->F0(rw), PTE[1]->F1(rw), PTE[2]->F2(rw), PTE[3]->F3(rw)
  refcounts: F0=1, F1=1, F2=1, F3=1

After fork (CoW):
  P: PTE[0]->F0(ro), PTE[1]->F1(ro), PTE[2]->F2(ro), PTE[3]->F3(ro)
  C: PTE[0]->F0(ro), PTE[1]->F1(ro), PTE[2]->F2(ro), PTE[3]->F3(ro)
  refcounts: F0=2, F1=2, F2=2, F3=2

Child writes to page 1:
  1. Protection fault on C's PTE[1] (read-only)
  2. Allocate new frame F4
  3. Copy F1 -> F4
  4. C: PTE[1]->F4(rw)
  5. refcount(F1)-- => 1, so P: PTE[1]->F1(rw)
  refcounts: F0=2, F1=1, F2=2, F3=2, F4=1

After child writes to pages 1 and 2:
  P: PTE[0]->F0(ro), PTE[1]->F1(rw), PTE[2]->F2(ro), PTE[3]->F3(ro)
  C: PTE[0]->F0(ro), PTE[1]->F4(rw), PTE[2]->F5(rw), PTE[3]->F3(ro)
  Only pages actually written are copied.
```
:::

### 13.1.4 Cost Analysis

::: theorem
**Theorem 13.1 (CoW Cost Bound).** Let $N$ be the total number of pages in the parent process and $W$ be the number of pages written by the child before calling `exec()`. The cost of `fork()` with CoW is:

$$C_{\text{CoW}} = C_{\text{table}} + W \times C_{\text{copy}}$$

where $C_{\text{table}}$ is the cost of duplicating the page table and $C_{\text{copy}}$ is the cost of copying one page. Without CoW:

$$C_{\text{naive}} = C_{\text{table}} + N \times C_{\text{copy}}$$

The savings ratio is:

$$\frac{C_{\text{naive}}}{C_{\text{CoW}}} \approx \frac{N}{W}$$

For a typical `fork()`/`exec()` pattern where $W \ll N$ (the child writes to only a few stack pages before calling `exec()`), this ratio can be 1000:1 or more.
:::

### 13.1.5 CoW for Zero Pages

A further optimisation: when a process allocates memory (e.g., via `mmap` with `MAP_ANONYMOUS`), the OS does not immediately allocate physical frames. Instead, all pages in the region are mapped to a single read-only *zero page*. When the process writes to a page, a CoW fault allocates a new frame and fills it with zeros. This is called *demand zeroing* and means that `calloc()` or `mmap()` of a large region is nearly free until the memory is actually used.

::: example
**Example 13.2 (Demand Zeroing).** A process calls `mmap(NULL, 1 GB, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)`. The kernel maps 262,144 pages (at 4 KB each) to the zero page. Physical memory used: 0 bytes (plus one page table page for the mapping).

The process then writes to addresses in 100 of those pages. Each write triggers a CoW fault that allocates a fresh, zeroed frame. Physical memory used: 100 pages (400 KB), not 1 GB.
:::

> **Note:** This is why `htop` shows two memory columns for each process: VIRT (virtual memory, including all mapped-but-not-touched regions) and RES (resident set size, only pages backed by physical frames). A Java or Go process may show VIRT of several gigabytes but RES of only a few hundred megabytes.

---

## 13.2 Memory-Mapped Files

### 13.2.1 Concept

::: definition
**Definition 13.3 (Memory-Mapped File).** A *memory-mapped file* is a file whose contents are mapped into a process's virtual address space. Reads and writes to the mapped region are translated into reads and writes to the file by the virtual memory system. The file's pages are loaded on demand (via page faults) and written back to disk by the OS's page writeback mechanism.
:::

Memory-mapped files unify file I/O and memory access. Instead of using `read()`/`write()` system calls with user-space buffers, the program simply accesses memory addresses, and the kernel handles the rest.

### 13.2.2 mmap() Semantics

```c
#include <sys/mman.h>

void *mmap(void *addr, size_t length, int prot, int flags,
           int fd, off_t offset);
int msync(void *addr, size_t length, int flags);
int munmap(void *addr, size_t length);
```

::: definition
**Definition 13.4 (mmap Parameters).**

- `addr`: Suggested starting address (usually NULL, letting the kernel choose).
- `length`: Number of bytes to map.
- `prot`: Protection flags: `PROT_READ`, `PROT_WRITE`, `PROT_EXEC`, `PROT_NONE`.
- `flags`: Mapping type:
  - `MAP_SHARED`: Writes are visible to other processes mapping the same file and are carried through to the underlying file.
  - `MAP_PRIVATE`: Writes create a private copy (CoW). Changes are not written to the file.
  - `MAP_ANONYMOUS`: Not backed by any file; used for allocating anonymous memory.
- `fd`: File descriptor of the file to map (-1 for anonymous).
- `offset`: Offset within the file where the mapping begins (must be page-aligned).
:::

### 13.2.3 Private vs Shared Mappings

::: definition
**Definition 13.5 (Shared Mapping).** A `MAP_SHARED` mapping creates a view of the file that is shared with all other processes that map the same file region. Writes by any process are visible to all others and are eventually written back to the file on disk.
:::

::: definition
**Definition 13.6 (Private Mapping).** A `MAP_PRIVATE` mapping creates a copy-on-write view of the file. The initial contents come from the file, but writes create private copies that are not visible to other processes and are not written to the file.
:::

Shared mappings are used for inter-process communication and shared databases. Private mappings are used for loading executable code and read-only data (shared libraries are loaded via private mappings of their `.text` segments).

### 13.2.4 msync()

::: definition
**Definition 13.7 (msync).** The `msync()` system call flushes modified pages of a shared mapping back to the underlying file. Without `msync()`, the kernel may buffer dirty pages indefinitely, and data could be lost on a crash.

- `MS_SYNC`: Synchronous flush; `msync()` blocks until all pages are written.
- `MS_ASYNC`: Asynchronous flush; schedules the writes but returns immediately.
- `MS_INVALIDATE`: Invalidates other mappings of the same file, forcing them to re-read from disk.
:::

::: example
**Example 13.3 (Memory-Mapped File I/O).** Reading and modifying a file via `mmap`:

```c
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    int fd = open("data.bin", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    struct stat sb;
    fstat(fd, &sb);

    /* Map the entire file as shared */
    char *map = mmap(NULL, sb.st_size, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }
    close(fd);  /* fd can be closed; mapping persists */

    /* Read directly from memory */
    printf("First 10 bytes: %.10s\n", map);

    /* Write directly to memory -> writes to file */
    memcpy(map, "MODIFIED: ", 10);

    /* Ensure changes reach disk */
    msync(map, sb.st_size, MS_SYNC);

    munmap(map, sb.st_size);
    return 0;
}
```
:::

### 13.2.5 Performance Advantages

Memory-mapped I/O avoids the double-copy inherent in `read()`/`write()`: data goes directly from the page cache to the process's address space (they share the same physical pages). There is no intermediate kernel buffer copy.

The `read()` system call path involves:

1. User calls `read(fd, buf, len)`. Context switch to kernel.
2. Kernel checks the page cache. If the pages are present, copies data from the page cache to the user buffer `buf`. If not, reads from disk into the page cache, then copies.
3. Return to user space.

The `mmap()` path:

1. User accesses `*ptr` (a memory load instruction). No system call.
2. If the page is in the TLB, the access completes in ~1 ns.
3. If TLB miss, the hardware walks the page table (~20--100 ns).
4. If the page is not in physical memory, a page fault loads it from disk.
5. No copy: the user reads directly from the page cache page.

::: theorem
**Theorem 13.2 (mmap vs read/write).** For sequential reads, `mmap` and `read()` have comparable performance because both benefit from the kernel's readahead. For random access patterns, `mmap` can be significantly faster because:

1. No system call overhead per access (after the initial `mmap` call). A `read()` system call costs ~200--500 ns; a TLB-cached `mmap` access costs ~1 ns.
2. No buffer copy. `read()` copies data from the page cache to user space; `mmap` shares the page cache pages directly.
3. The hardware TLB caches frequently accessed translations.

The advantage diminishes when the working set exceeds TLB coverage, as TLB misses add latency comparable to system call overhead.
:::

::: example
**Example 13.3a (Random Access Performance).** A database index file of 10 GB is accessed randomly by key lookup. Each lookup reads 256 bytes from a random position.

Using `pread()`: each lookup requires a system call (~300 ns) plus a potential page fault. For 1 million lookups per second, the system call overhead alone is $10^6 \times 300 = 300$ ms/s (30% of a core).

Using `mmap()`: each lookup is a pointer dereference. If the page is in the TLB and page cache, the access takes ~5 ns (TLB lookup + L1 cache miss to page cache). For 1 million lookups: $10^6 \times 5 = 5$ ms/s (0.5% of a core). A 60x improvement in CPU efficiency.
:::

### 13.2.6 Memory-Mapped IPC

`mmap()` with `MAP_SHARED` provides a high-performance inter-process communication mechanism. Two processes can map the same file (or anonymous shared mapping via `shm_open()`) and communicate by reading and writing the shared pages.

::: definition
**Definition 13.7a (Shared Memory IPC).** Two or more processes can establish shared memory by:

1. Creating a shared memory object: `int fd = shm_open("/my_shm", O_CREAT | O_RDWR, 0600);`
2. Setting its size: `ftruncate(fd, size);`
3. Mapping it in both processes: `mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);`

Writes by one process are immediately visible to the other (they share the same physical pages). No kernel involvement is needed for the data transfer itself --- only for the initial setup.
:::

Shared memory is the fastest IPC mechanism because it avoids all copying and system calls during data transfer. The processes must coordinate access using synchronisation primitives (mutexes, semaphores, atomics) placed in the shared region.

::: example
**Example 13.3b (Shared Memory Throughput).** Two processes share a 1 GB mapping. Process A writes 1 MB chunks; Process B reads them.

- Pipe: ~4 GB/s (kernel copy: user $\to$ kernel $\to$ user).
- Unix domain socket: ~6 GB/s (similar to pipe but slightly more efficient).
- Shared memory: ~20 GB/s (limited by DRAM bandwidth, no copies).

Shared memory achieves 3--5x the throughput of pipe/socket IPC because it eliminates all copies. The actual throughput is bounded by memory bandwidth rather than kernel overhead.
:::

> **Programmer:** Memory-mapped files are the foundation of many high-performance systems. BoltDB (used by etcd) maps its entire database file into memory, achieving read performance limited only by page fault and TLB miss rates. SQLite uses `mmap` as an optional I/O method. In Go, the `golang.org/x/exp/mmap` package provides a portable memory-mapped file reader. For write-heavy workloads, be aware that `mmap` with `MAP_SHARED` means the OS can write dirty pages to disk at any time, potentially interfering with application-level write ordering. Databases that require strict write ordering (WAL protocols) typically use `pwrite()` with `fdatasync()` rather than `mmap`.
>
> POSIX shared memory in Go is accessible through the `golang.org/x/sys/unix` package:
>
> ```go
> package main
>
> import (
>     "fmt"
>     "golang.org/x/sys/unix"
>     "unsafe"
> )
>
> func main() {
>     // Create shared memory object
>     fd, err := unix.ShmOpen("/go_shm",
>         unix.O_CREAT|unix.O_RDWR, 0600)
>     if err != nil {
>         panic(err)
>     }
>     defer unix.Close(fd)
>
>     size := 4096
>     unix.Ftruncate(fd, int64(size))
>
>     // Map into this process
>     data, err := unix.Mmap(fd, 0, size,
>         unix.PROT_READ|unix.PROT_WRITE,
>         unix.MAP_SHARED)
>     if err != nil {
>         panic(err)
>     }
>     defer unix.Munmap(data)
>
>     // Write a message
>     copy(data, []byte("Hello from Go!"))
>     fmt.Printf("Wrote to shared memory at %p\n",
>         unsafe.Pointer(&data[0]))
>
>     // Cleanup
>     unix.ShmUnlink("/go_shm")
> }
> ```

---

## 13.3 Kernel Memory Allocation

The kernel itself needs to allocate memory for its own data structures: process descriptors, file objects, inode caches, network buffers, page tables, and hundreds of other types. User-space allocation strategies (paging, demand allocation) are not always appropriate for kernel memory because:

1. Kernel memory is often non-pageable (cannot be swapped to disk).
2. Many kernel allocations are for small, fixed-size objects.
3. Kernel allocations must be fast (microseconds, not milliseconds).
4. Some allocations require physically contiguous memory (for DMA).

### 13.3.1 The Buddy System

::: definition
**Definition 13.8 (Buddy System).** The *buddy system* is a memory allocation algorithm that divides memory into blocks whose sizes are powers of two. When a block of size $2^k$ is requested:

1. If a free block of size $2^k$ exists, allocate it.
2. Otherwise, find the smallest free block of size $2^j > 2^k$.
3. Split it repeatedly into two *buddies* of size $2^{j-1}$ until a block of size $2^k$ is obtained.
4. On deallocation, check if the freed block's buddy is also free. If so, merge them into a block of size $2^{k+1}$ (*coalescing*). Repeat upward.
:::

::: example
**Example 13.4 (Buddy System).** Initial memory: one block of 256 KB. Request: 21 KB.

The smallest power of two $\geq$ 21 KB is 32 KB.

1. Split 256 KB $\to$ two 128 KB buddies.
2. Split one 128 KB $\to$ two 64 KB buddies.
3. Split one 64 KB $\to$ two 32 KB buddies.
4. Allocate one 32 KB block.

```text
         256 KB
        /      \
     128 KB   128 KB
     /    \
   64 KB  64 KB
   /   \
 32 KB 32 KB
 [A]   [free]
```

Free blocks: 32 KB, 64 KB, 128 KB.
Internal fragmentation: $32 - 21 = 11$ KB (34%).
:::

::: theorem
**Theorem 13.3 (Buddy System Fragmentation).** The worst-case internal fragmentation of the buddy system is nearly 50%: a request for $2^{k-1} + 1$ bytes receives a block of $2^k$ bytes, wasting $2^{k-1} - 1$ bytes. On average, for uniformly distributed request sizes in $[1, 2^n]$, the expected internal fragmentation is approximately 25%.

*Proof.* For a request of size $s$ where $2^{k-1} < s \leq 2^k$, the allocated block is $2^k$ bytes, wasting $2^k - s$ bytes. The waste ratio is $(2^k - s) / 2^k$. For $s$ uniform on $(2^{k-1}, 2^k]$, the expected waste ratio is:

$$E\left[\frac{2^k - s}{2^k}\right] = \frac{1}{2^{k-1}} \int_{2^{k-1}}^{2^k} \frac{2^k - s}{2^k} ds = \frac{1}{2^k \cdot 2^{k-1}} \cdot \frac{(2^{k-1})^2}{2} = \frac{1}{4}$$

Hence the expected internal fragmentation is 25%. $\square$
:::

### 13.3.1a Buddy System: Deallocation and Coalescing

The buddy system's key advantage is fast coalescing: the buddy of a block at address $A$ of size $2^k$ is at address $A \oplus 2^k$ (XOR with the block size). This makes buddy identification an $O(1)$ operation.

::: example
**Example 13.4a (Buddy Coalescing).** Continuing from Example 13.4, suppose we free the 21 KB allocation (block A at address 0, size 32 KB).

1. A's buddy is at address $0 \oplus 32\text{K} = 32\text{K}$. Check: is the 32 KB block at 32K free? Yes.
2. Merge: create a 64 KB block at address 0. Its buddy is at $0 \oplus 64\text{K} = 64\text{K}$. Check: is the 64 KB block at 64K free? Yes.
3. Merge: create a 128 KB block at address 0. Its buddy is at $0 \oplus 128\text{K} = 128\text{K}$. Check: is the 128 KB block at 128K free? Yes.
4. Merge: create a 256 KB block at address 0. No further merging possible (maximum size reached).

The memory is fully coalesced back into one 256 KB block. Total merges: 3. Each merge is $O(1)$ (XOR + lookup in the free list for that order).
:::

::: example
**Example 13.4b (Buddy System with Multiple Allocations).** Starting with 256 KB. Sequence: allocate A=30KB, allocate B=20KB, allocate C=10KB, free B, allocate D=15KB, free A, free D, free C.

Step 1 -- Allocate A=30KB (rounded to 32KB):
Split 256$\to$128+128, split 128$\to$64+64, split 64$\to$32+32. Allocate A at 0.
Free: 32K@32, 64K@64, 128K@128.

Step 2 -- Allocate B=20KB (rounded to 32KB):
Use 32K@32. Free: 64K@64, 128K@128.

Step 3 -- Allocate C=10KB (rounded to 16KB):
Split 64K@64$\to$32K@64+32K@96, split 32K@64$\to$16K@64+16K@80. Allocate C at 64.
Free: 16K@80, 32K@96, 128K@128.

Step 4 -- Free B (32KB at 32):
Buddy at $32 \oplus 32 = 0$ (block A). A is allocated, so no merge. Free: 32K@32, 16K@80, 32K@96, 128K@128.

Step 5 -- Allocate D=15KB (rounded to 16KB):
Use 16K@80. Free: 32K@32, 32K@96, 128K@128.

Step 6 -- Free A (32KB at 0):
Buddy at $0 \oplus 32 = 32$. Block at 32 is free. Merge$\to$64K@0.
Buddy at $0 \oplus 64 = 64$. Block at 64 is C (allocated). No merge.
Free: 64K@0, 32K@96, 128K@128.

Step 7 -- Free D (16KB at 80):
Buddy at $80 \oplus 16 = 64 + 16 = 64$. Wait: $80_{\text{dec}} = 0\text{x}50$, $16_{\text{dec}} = 0\text{x}10$. $0\text{x}50 \oplus 0\text{x}10 = 0\text{x}40 = 64$. Block at 64 is C (allocated). No merge.
Free: 64K@0, 16K@80, 32K@96, 128K@128.

Step 8 -- Free C (16KB at 64):
Buddy at $64 \oplus 16 = 80$. Block at 80 is free (D was freed). Merge$\to$32K@64.
Buddy at $64 \oplus 32 = 96$. Block at 96 is free. Merge$\to$64K@64.
Buddy at $64 \oplus 64 = 0$. Block at 0 is free (64K). Merge$\to$128K@0.
Buddy at $0 \oplus 128 = 128$. Block at 128 is free. Merge$\to$256K@0.

Full coalescing achieved after all frees. This illustrates the elegance of the buddy system: deferred coalescing happens automatically when both buddies are free.
:::

**Linux's use:** The Linux kernel uses the buddy system as its primary page allocator. The `alloc_pages()` function returns $2^k$ contiguous pages (orders 0 through 10, giving 4 KB to 4 MB). The `/proc/buddyinfo` file shows the current distribution of free blocks:

```text
$ cat /proc/buddyinfo
Node 0, zone      DMA      1    1    0    1    2    1    1    0    1    1    3
Node 0, zone    DMA32    130   84   36   18    5    2    1    0    0    0    0
Node 0, zone   Normal   3504 1827  912  480  241  120   60   30   15    7    3
```

Each column shows the number of free blocks of order 0 (4 KB), order 1 (8 KB), ..., order 10 (4 MB). The rightmost column (order 10) shows how many 4 MB contiguous regions are available --- essential for huge page allocation.

The buddy system's key advantage is fast coalescing: the buddy of a block at address $A$ of size $2^k$ is at address $A \oplus 2^k$ (XOR with the block size). This makes buddy checking an $O(1)$ operation.

**Linux's use:** The Linux kernel uses the buddy system as its primary page allocator. The `alloc_pages()` function returns $2^k$ contiguous pages (orders 0 through 10, giving 4 KB to 4 MB). The `/proc/buddyinfo` file shows the current distribution of free blocks:

```text
$ cat /proc/buddyinfo
Node 0, zone   Normal    4   12   32   18    5    2    1    0    0    0    0
```

Each column shows the number of free blocks of order 0 (4 KB), order 1 (8 KB), ..., order 10 (4 MB).

### 13.3.2 The Slab Allocator

::: definition
**Definition 13.9 (Slab Allocator, Bonwick 1994).** The *slab allocator* is a memory allocation system designed for kernel objects. It works as follows:

1. **Caches:** For each type of kernel object (e.g., `task_struct`, `inode`, `dentry`), a *cache* is created.
2. **Slabs:** Each cache consists of one or more *slabs*. A slab is a contiguous block of physical pages (obtained from the buddy system) divided into fixed-size *slots*, each capable of holding one object.
3. **States:** Each slab is in one of three states: *full* (all slots occupied), *partial* (some slots free), *empty* (all slots free).
4. **Allocation:** When an object is requested, the allocator finds a partial slab (or allocates a new slab from the buddy system) and returns a free slot.
5. **Deallocation:** When an object is freed, the allocator marks its slot as free. If the slab becomes empty, it may be returned to the buddy system.
:::

::: example
**Example 13.5 (Slab for task\_struct).** The `task_struct` in Linux is approximately 6 KB. The slab allocator creates a cache with:

- Slab size: 2 pages = 8192 bytes (from buddy system, order 1).
- Objects per slab: $\lfloor 8192 / 6144 \rfloor = 1$ (with some internal metadata).

For smaller objects like `dentry` (~192 bytes):
- Slab size: 1 page = 4096 bytes.
- Objects per slab: $\lfloor 4096 / 192 \rfloor \approx 21$.
:::

The slab allocator provides three key benefits:

1. **No fragmentation for fixed-size objects:** Since each cache handles objects of exactly one size, there is no external fragmentation.
2. **Cache colouring:** Objects in different slabs are offset to reduce cache line conflicts.
3. **Constructor/destructor caching:** Freed objects retain their initialised state, so re-allocation can skip the constructor.

### 13.3.3 SLUB: The Simplified Slab

::: definition
**Definition 13.10 (SLUB Allocator).** *SLUB* (the Unqueued Slab Allocator) is the default kernel memory allocator in Linux since 2.6.23. It simplifies the original slab allocator by eliminating the per-slab metadata and per-CPU queues. Instead, each CPU has a single "active" slab, and freed objects are placed on an in-slab free list (using the freed object's own memory as a linked list node).
:::

SLUB provides better performance on modern multi-core systems because:

- Reduced metadata overhead (no separate slab descriptors for most caches).
- Better NUMA awareness (per-node partial slab lists).
- Simpler debugging (SLUB has built-in red-zone, poisoning, and tracking features enabled by `CONFIG_SLUB_DEBUG`).

The `slabinfo` command (or `/proc/slabinfo`) shows statistics for all active slab caches:

```text
$ sudo cat /proc/slabinfo | head -5
# name          <active_objs> <num_objs> <objsize> <objperslab> <pagesperslab>
task_struct           452    460   6720      4      8
inode_cache          8291   8326    608     13      2
dentry              15204  15372    192     21      1
```

### 13.3.4 kmalloc and the Size-Class Hierarchy

For general-purpose kernel allocations (not tied to a specific object type), Linux provides `kmalloc()`, which allocates from a set of generic slab caches with sizes: 8, 16, 32, 64, 96, 128, 192, 256, 512, 1024, 2048, 4096, 8192 bytes. A request for $n$ bytes is rounded up to the nearest size class.

::: definition
**Definition 13.11 (kmalloc Size Classes).** The `kmalloc()` function allocates memory from a set of *size-class caches*. For a request of $n$ bytes, the allocator selects the smallest size class $s_k \geq n$ and allocates one object from the corresponding cache. The internal fragmentation is at most $s_k - n$ bytes.
:::

::: example
**Example 13.6 (kmalloc Allocation).** A kernel subsystem calls `kmalloc(100, GFP_KERNEL)`.

Available size classes: ..., 64, 96, 128, ...

The smallest class $\geq 100$ is 128. Internal fragmentation: 28 bytes (22%).

The `ksize()` function returns the actual usable size of a `kmalloc` allocation:

```c
void *p = kmalloc(100, GFP_KERNEL);
/* ksize(p) returns 128 */
```
:::

> **Note:** The GFP flags (`GFP_KERNEL`, `GFP_ATOMIC`, `GFP_DMA`, etc.) control how the allocator behaves. `GFP_KERNEL` allows sleeping (can trigger reclaim). `GFP_ATOMIC` is for interrupt context where sleeping is forbidden. `GFP_DMA` requests memory from the DMA-capable zone (lowest 16 MB on x86).

---

## 13.4 NUMA: Non-Uniform Memory Access

### 13.4.1 NUMA Architecture

::: definition
**Definition 13.12 (NUMA).** In a *Non-Uniform Memory Access* architecture, physical memory is divided into *nodes*, each attached to a specific processor (or group of processors). Accessing memory on the local node is faster than accessing memory on a remote node.
:::

```text
+-------------------+       Interconnect       +-------------------+
|     Node 0        |<========================>|     Node 1        |
|                   |       (e.g. QPI, UPI)     |                   |
|  +------+  +----+ |                           | +------+  +----+ |
|  | CPU 0|  |RAM | |                           | | CPU 1|  |RAM | |
|  | CPU 1|  | 64 | |                           | | CPU 2|  | 64 | |
|  +------+  | GB | |                           | | CPU 3|  | GB | |
|            +----+ |                           | +------+  +----+ |
+-------------------+                           +-------------------+

Local access:  ~80 ns
Remote access: ~140 ns (1.75x slower)
```

### 13.4.2 NUMA Ratio

::: definition
**Definition 13.13 (NUMA Ratio).** The *NUMA ratio* is the ratio of remote memory access latency to local memory access latency:

$$\text{NUMA ratio} = \frac{t_{\text{remote}}}{t_{\text{local}}}$$

Typical values range from 1.2 to 3.0, depending on the number of hops and interconnect technology.
:::

### 13.4.3 NUMA-Aware Allocation

The operating system's memory allocator should preferentially allocate memory from the node local to the requesting CPU. Linux implements this through *NUMA policies*:

::: definition
**Definition 13.14 (NUMA Memory Policies).**

- `MPOL_DEFAULT`: Allocate from the local node. Fall back to other nodes if local memory is exhausted.
- `MPOL_BIND`: Allocate only from a specified set of nodes. Fail (or trigger OOM) if those nodes are full.
- `MPOL_INTERLEAVE`: Spread allocations round-robin across a set of nodes. Useful for data structures accessed equally from all CPUs.
- `MPOL_PREFERRED`: Prefer a specific node but fall back to others if necessary.
:::

::: example
**Example 13.7 (NUMA Topology).** A 2-node server has 128 GB RAM per node. Two database processes run on Node 0 and Node 1 respectively.

With NUMA-unaware allocation: each process might allocate half its memory from the remote node, suffering 1.75x latency on 50% of accesses. Average latency: $(0.5 \times 80 + 0.5 \times 140) = 110$ ns.

With NUMA-aware allocation (MPOL_DEFAULT): each process allocates from its local node. Average latency: 80 ns.

Performance improvement: $110/80 = 37.5\%$.
:::

### 13.4.4 NUMA and Page Migration

When a process is migrated from one CPU to another on a different NUMA node (by the scheduler), its memory remains on the original node. This creates a *NUMA imbalance*: the process accesses remote memory for all its working set. Linux addresses this with *automatic NUMA balancing* (AutoNUMA):

::: definition
**Definition 13.14a (Automatic NUMA Balancing).** *AutoNUMA* is a Linux kernel feature that detects NUMA-suboptimal page placements and migrates pages to the node where they are most frequently accessed. It works by:

1. Periodically unmapping pages from the process's page table (setting present=0).
2. When the process accesses an unmapped page, a NUMA hint fault occurs.
3. The kernel records which node caused the fault and compares it to the page's current node.
4. If the page is on a remote node, the kernel migrates it to the local node.
:::

::: example
**Example 13.7a (NUMA Migration).** A process with a 1 GB working set is initially scheduled on Node 0, and all its pages are on Node 0. The scheduler migrates the process to Node 1.

Without AutoNUMA: all 262,144 pages remain on Node 0. Every memory access is remote: latency = 140 ns.

With AutoNUMA: the kernel gradually migrates hot pages to Node 1. After 10 seconds, 90% of the working set has been migrated. Average latency: $0.9 \times 80 + 0.1 \times 140 = 72 + 14 = 86$ ns.

Migration cost: each page migration requires copying 4 KB across the interconnect (~1 $\mu$s per page). For 90% of 262,144 pages: $0.9 \times 262{,}144 \times 1\ \mu\text{s} \approx 0.24$ seconds of migration overhead, spread over 10 seconds of runtime.
:::

### 13.4.5 NUMA Topology Discovery

Applications can discover the NUMA topology programmatically:

```c
#include <numa.h>
#include <stdio.h>

int main(void) {
    if (numa_available() < 0) {
        printf("NUMA not available\n");
        return 1;
    }

    int num_nodes = numa_max_node() + 1;
    printf("NUMA nodes: %d\n", num_nodes);

    for (int i = 0; i < num_nodes; i++) {
        long size = numa_node_size(i, NULL);
        printf("Node %d: %ld MB\n", i, size / (1024 * 1024));

        /* Print distance to other nodes */
        for (int j = 0; j < num_nodes; j++) {
            printf("  Distance to node %d: %d\n",
                   j, numa_distance(i, j));
        }
    }
    return 0;
}
/* Compile with: gcc -o numa_info numa_info.c -lnuma */
```

Output on a 2-node system:

```text
NUMA nodes: 2
Node 0: 65536 MB
  Distance to node 0: 10
  Distance to node 1: 21
Node 1: 65536 MB
  Distance to node 0: 21
  Distance to node 1: 10
```

The distance matrix (10 = local, 21 = remote) shows that remote access is 2.1x the cost of local access. Larger systems (4+ nodes) have asymmetric distances where some nodes are further than others.

The `numactl` command controls NUMA policy for user-space processes:

```text
# Run a process on Node 0 with memory allocated from Node 0
numactl --cpunodebind=0 --membind=0 ./my_database

# Interleave memory across all nodes (useful for hash tables)
numactl --interleave=all ./my_application

# Show NUMA topology
numactl --hardware
```

The `numastat` command shows per-node allocation statistics:

```text
$ numastat
                           node0           node1
numa_hit                12345678         9876543
numa_miss                   1234            5678
numa_foreign                5678            1234
local_node              12340000         9870000
other_node                  5678            6543
```

A high `numa_miss` count indicates the allocator is frequently falling back to remote nodes --- a sign that the local node's memory is under pressure.

::: theorem
**Theorem 13.4 (NUMA-Aware Scheduling).** For a process with working set $W$ allocated on node $N$, the optimal scheduling decision is to run the process on a CPU attached to node $N$. Migrating the process to a CPU on node $N'$ ($N' \neq N$) converts all memory accesses from local ($t_{\text{local}}$) to remote ($t_{\text{remote}}$), increasing the effective memory latency by a factor equal to the NUMA ratio. The performance degradation is:

$$\Delta = \frac{t_{\text{remote}} - t_{\text{local}}}{t_{\text{local}}} \times \frac{W_{\text{mem}}}{W_{\text{total}}}$$

where $W_{\text{mem}} / W_{\text{total}}$ is the fraction of execution time spent on memory accesses.
:::

> **Programmer:** Go's runtime is partially NUMA-aware. The goroutine scheduler (GMP model) pins each P (logical processor) to an OS thread, and the OS thread is typically scheduled on the same CPU. However, Go's memory allocator (`mheap`) does not have explicit NUMA policies --- it requests pages from the OS via `mmap`, and the kernel's default NUMA policy (allocate local) applies. For NUMA-intensive Go applications, you can use `numactl` to bind the process to a specific node, or use the `golang.org/x/sys/unix` package to call `set_mempolicy()` directly. Large Go services (databases, caches) running on multi-socket servers should profile with `numastat` and `perf stat -e node-load-misses` to quantify remote access overhead.

---

## 13.5 Huge Pages

### 13.5.1 TLB Pressure Revisited

As established in Chapter 11, the TLB caches virtual-to-physical translations. With standard 4 KB pages, a TLB with 1024 entries covers only 4 MB. For applications with working sets of tens or hundreds of gigabytes, TLB misses dominate performance.

::: definition
**Definition 13.15 (Huge Pages).** *Huge pages* are memory pages larger than the standard page size. On x86-64:

- *Large pages:* 2 MB (using the PS bit in the Page Directory entry, eliminating one level of page table walk).
- *Gigantic pages:* 1 GB (using the PS bit in the PDPT entry, eliminating two levels of page table walk).
:::

### 13.5.2 Explicit Huge Pages (hugetlbfs)

Linux supports explicit huge pages through the `hugetlbfs` pseudo-filesystem. The administrator reserves a pool of huge pages at boot time:

```text
# Reserve 1024 huge pages (2 MB each) = 2 GB
echo 1024 > /proc/sys/vm/nr_hugepages

# Or at boot via kernel parameter:
# hugepages=1024
```

Applications allocate huge pages via `mmap` with `MAP_HUGETLB`:

```c
#include <sys/mman.h>
#include <stdio.h>

int main(void) {
    size_t size = 2 * 1024 * 1024;  /* 2 MB = one huge page */
    void *p = mmap(NULL, size,
                   PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB,
                   -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap hugetlb");
        return 1;
    }
    printf("Huge page allocated at %p\n", p);
    *(int *)p = 42;
    munmap(p, size);
    return 0;
}
```

### 13.5.3 Transparent Huge Pages (THP)

::: definition
**Definition 13.16 (Transparent Huge Pages).** *Transparent Huge Pages* (THP) is a Linux kernel feature that automatically promotes contiguous regions of 4 KB pages to 2 MB huge pages without application changes. The kernel's `khugepaged` daemon scans for opportunities to coalesce 512 contiguous 4 KB pages into a single 2 MB huge page.
:::

THP operates transparently: the application allocates memory normally, and the kernel promotes eligible regions in the background. THP can be controlled via:

```text
# Check THP status
cat /sys/kernel/mm/transparent_hugepage/enabled
# Output: [always] madvise never

# Disable THP (recommended for latency-sensitive databases)
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# Enable only for regions explicitly marked with madvise
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
```

### 13.5.4 THP Drawbacks

THP can cause latency spikes due to:

1. **Compaction:** To create a 2 MB contiguous region, the kernel may need to migrate 4 KB pages, causing pauses.
2. **Splitting:** When part of a huge page is freed or swapped, the kernel must split the 2 MB page back into 512 small pages.
3. **Internal fragmentation:** A 2 MB page wastes on average 1 MB per allocation.

::: example
**Example 13.8 (THP Latency Impact).** A Redis instance runs with THP enabled. Under normal operation, p99 latency is 0.5 ms. Periodically, `khugepaged` triggers compaction, causing p99 spikes to 50 ms. After disabling THP:

```text
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

The p99 spikes disappear. Redis's documentation explicitly recommends disabling THP.
:::

---

## 13.6 Memory Compression

### 13.6.1 Motivation

When physical memory is scarce, the traditional solution is to swap pages to disk. But disk I/O (even SSD) is orders of magnitude slower than memory access. Memory compression offers a middle ground: instead of evicting a page to disk, compress it and store it in RAM. Decompression is much faster than disk I/O.

### 13.6.2 zswap

::: definition
**Definition 13.17 (zswap).** *zswap* is a Linux kernel feature that intercepts pages being swapped out and compresses them into a dynamically allocated RAM-based pool. If the pool is full, the least recently used compressed pages are written to the real swap device.

The flow:
1. A page is selected for eviction.
2. Instead of writing to disk, zswap compresses the page (using LZ4, LZO, or zstd).
3. The compressed page is stored in a RAM pool.
4. If the page is faulted back in, zswap decompresses it from RAM (fast).
5. If the RAM pool fills up, the oldest compressed pages are written to the backing swap device.
:::

::: theorem
**Theorem 13.5 (Compression Ratio and Effective Memory).** If the average compression ratio is $r$ (compressed size / original size, $0 < r < 1$) and the zswap pool size is $P$ bytes, the effective additional memory provided by zswap is:

$$M_{\text{effective}} = \frac{P}{r} - P = P \left(\frac{1}{r} - 1\right)$$

For $r = 0.5$ (2:1 compression) and $P = 4$ GB:

$$M_{\text{effective}} = 4 \times (2 - 1) = 4 \text{ GB}$$

The system effectively gains 4 GB of memory at the cost of CPU time for compression/decompression.
:::

### 13.6.3 zram

::: definition
**Definition 13.18 (zram).** *zram* creates a compressed block device in RAM. Unlike zswap (which acts as a cache in front of real swap), zram *is* the swap device. Pages swapped to zram are compressed and stored entirely in RAM. There is no backing disk swap.
:::

zram is commonly used on memory-constrained devices (Android, ChromeOS, lightweight servers):

```text
# Create a 4 GB zram device
modprobe zram
echo 4G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon /dev/zram0

# Check compression statistics
cat /sys/block/zram0/mm_stat
# orig_data_size  compr_data_size  mem_used  ...
```

::: example
**Example 13.9 (zram Compression Savings).** A system with 4 GB RAM and 4 GB zram. After compression, 4 GB of swapped pages occupy only 1.6 GB in the zram device (2.5:1 ratio).

Effective total memory: $4 + (4 - 1.6) = 6.4$ GB.

Decompression latency: ~1 $\mu$s (LZ4). Compared to SSD swap: ~50 $\mu$s. Compared to HDD swap: ~5 ms. zram is 50x faster than SSD swap and 5000x faster than HDD swap.
:::

### 13.6.4 Compression Algorithms

The choice of compression algorithm for zswap/zram involves a trade-off between compression ratio and speed:

| Algorithm | Compression Speed | Decompression Speed | Ratio | CPU Usage |
|-----------|------------------|--------------------|----|-----------|
| LZO | ~500 MB/s | ~800 MB/s | 2.0:1 | Low |
| LZ4 | ~700 MB/s | ~2000 MB/s | 1.8:1 | Very low |
| zstd | ~200 MB/s | ~600 MB/s | 3.0:1 | Moderate |
| deflate | ~100 MB/s | ~300 MB/s | 3.5:1 | High |

For zram/zswap, decompression speed is more important than compression speed (decompression happens on the critical path of a page fault; compression happens during eviction, which can be batched). LZ4 is the default in most Linux distributions because it has the best decompression speed.

::: example
**Example 13.9a (Compression Speed Impact).** A page fault on a compressed page requires decompression of 4 KB:

- LZ4: $4 \text{ KB} / 2000 \text{ MB/s} = 2\ \mu\text{s}$
- zstd: $4 \text{ KB} / 600 \text{ MB/s} = 6.7\ \mu\text{s}$
- SSD read: $4 \text{ KB} / 3000 \text{ MB/s} + 10\ \mu\text{s latency} \approx 11\ \mu\text{s}$

LZ4 decompression is ~5.5x faster than an SSD read. zstd is still faster than SSD but provides better compression (more pages fit in the zswap pool).
:::

### 13.6.5 When to Use Memory Compression

Memory compression is most effective when:

1. **Pages are compressible:** Text, structured data, and zero-heavy pages compress well (3:1 or better). Random binary data (encrypted pages, compressed files) compress poorly (1:1 or worse, meaning no benefit).

2. **The system is memory-constrained but not CPU-constrained:** Compression trades CPU for memory. On a server with idle CPU cores and tight memory, this is an excellent trade-off. On a CPU-bound system, compression adds unwanted overhead.

3. **Swap I/O is the bottleneck:** If the system is spending significant time on swap I/O (visible in `vmstat` as high `si`/`so` values), zswap can eliminate or reduce this I/O by keeping compressed pages in RAM.

::: theorem
**Theorem 13.5a (Compression Break-Even).** Let $t_{\text{compress}}$ be the time to compress a page, $t_{\text{decompress}}$ be the time to decompress, $t_{\text{io}}$ be the time for a disk I/O (read or write), and $r$ be the compression ratio. Compression is beneficial if:

$$t_{\text{compress}} + t_{\text{decompress}} < t_{\text{io,write}} + t_{\text{io,read}}$$

For LZ4 ($t_{\text{compress}} + t_{\text{decompress}} \approx 8\ \mu\text{s}$) and HDD ($t_{\text{io}} \approx 8 \text{ ms per page}$): $8\ \mu\text{s} \ll 16 \text{ ms}$. Compression wins by a factor of 2000.

For LZ4 and NVMe SSD ($t_{\text{io}} \approx 20\ \mu\text{s per page}$): $8\ \mu\text{s} < 40\ \mu\text{s}$. Compression still wins by a factor of 5.
:::

---

## 13.7 Address Space Layout Randomisation (ASLR)

### 13.7.1 The Security Problem

Buffer overflow attacks rely on knowing the addresses of key data structures: the stack (for return address overwrites), the heap (for object corruption), and shared libraries (for return-to-libc attacks). If these addresses are predictable, the attacker can craft exploits that reliably redirect control flow.

### 13.7.2 ASLR Mechanism

::: definition
**Definition 13.19 (ASLR).** *Address Space Layout Randomisation* randomises the base addresses of key memory regions each time a process is loaded:

- Stack base: randomised within a range.
- Heap base (brk): randomised.
- mmap base (for shared libraries and anonymous mappings): randomised.
- Executable base (with PIE --- Position-Independent Executable): randomised.
- VDSO (virtual dynamic shared object): randomised.
:::

With ASLR, the same program loaded twice will have its stack, heap, and libraries at different addresses. An attacker who discovers the address layout of one process invocation cannot reuse that knowledge for another.

### 13.7.3 Entropy

::: definition
**Definition 13.20 (ASLR Entropy).** The *entropy* of ASLR is the number of bits of randomness in the base address. For $k$ bits of entropy, there are $2^k$ possible base addresses, and an attacker has a $1/2^k$ probability of guessing the correct address.
:::

On x86-64 Linux, typical ASLR entropy:

| Region | Entropy (bits) | Possible Addresses |
|--------|:--------------:|:------------------:|
| Stack | 30 | ~$10^9$ |
| mmap base | 28 | ~$2.7 \times 10^8$ |
| Heap (brk) | 13 | ~8,000 |
| PIE executable | 28 | ~$2.7 \times 10^8$ |

::: theorem
**Theorem 13.6 (Brute-Force Attack Complexity).** With $k$ bits of ASLR entropy, a brute-force attack (guessing the randomised address) succeeds with probability $1/2^k$ per attempt. The expected number of attempts is $2^k$. If each failed attempt crashes the process (and the process is restarted with a new random layout), the expected time to succeed is:

$$E[T] = 2^k \times (t_{\text{crash}} + t_{\text{restart}})$$

For $k = 28$ and $t_{\text{crash}} + t_{\text{restart}} = 1$ second:

$$E[T] = 2^{28} \approx 2.7 \times 10^8 \text{ seconds} \approx 8.5 \text{ years}$$
:::

### 13.7.4 Checking ASLR

```c
#include <stdio.h>
#include <stdlib.h>

int global_var = 42;

int main(void) {
    int stack_var = 7;
    int *heap_var = malloc(sizeof(int));

    printf("main():     %p\n", (void *)main);
    printf("global:     %p\n", (void *)&global_var);
    printf("stack:      %p\n", (void *)&stack_var);
    printf("heap:       %p\n", (void *)heap_var);
    printf("printf:     %p\n", (void *)printf);

    free(heap_var);
    return 0;
}
```

Running this program twice (compiled as PIE: `gcc -pie -o aslr_demo aslr_demo.c`):

```text
$ ./aslr_demo
main():     0x5602a3c00149
global:     0x5602a3e01010
stack:      0x7ffd8a3e1c5c
heap:       0x5602a51002a0
printf:     0x7f4a38201a40

$ ./aslr_demo
main():     0x55a7e1200149
global:     0x55a7e1401010
stack:      0x7ffc12bf3c5c
heap:       0x55a7e22002a0
printf:     0x7f9c42801a40
```

Every address changes between runs. Without ASLR (or with `setarch -R`), the addresses would be identical.

### 13.7.5 ASLR Limitations

ASLR is not a complete defence:

- **Information leaks:** If the attacker can read a process's memory (via a format string vulnerability, side channel, or `/proc/PID/maps`), they can discover the randomised layout.
- **Low entropy:** On 32-bit systems, ASLR provides only ~8--16 bits of entropy, making brute-force feasible.
- **Non-PIE executables:** If the executable itself is not position-independent, its text segment is at a fixed address, providing known gadgets for ROP attacks.
- **Heap spraying:** By filling the heap with many copies of the payload, the attacker increases the probability that a random jump lands on valid exploit code.

> **Note:** ASLR is one layer in a defence-in-depth strategy. It is typically combined with stack canaries, NX (no-execute) pages, Control-Flow Integrity (CFI), and shadow stacks.

---

## 13.8 Go's Memory Allocator

::: programmer
**Programmer's Perspective: Go's Memory Allocator (mcache/mcentral/mheap).**

Go's memory allocator is a descendant of Google's TCMalloc (Thread-Caching Malloc), adapted for Go's goroutine-based concurrency model and integrated with the garbage collector. Understanding its architecture illuminates many of the concepts from this chapter.

**Three-level hierarchy:**

```go
// Conceptual structure (simplified from runtime/mheap.go)
//
// mcache (per-P, lock-free):
//   - One per logical processor (P in GMP model)
//   - Contains alloc[67] -- one mspan per size class
//   - Tiny allocator for objects <= 16 bytes with no pointers
//
// mcentral (per-size-class, locked):
//   - One per size class (67 classes)
//   - Manages partial and full spans
//   - mcache refills from mcentral when its span is exhausted
//
// mheap (global, locked):
//   - Manages the entire heap address space
//   - Allocates spans (contiguous runs of 8 KB pages)
//   - Backed by OS memory via mmap(MAP_ANONYMOUS)
```

**Size classes:** Go uses 67 size classes, from 8 bytes to 32,768 bytes. Each class is tuned to minimise internal fragmentation:

| Class | Object Size | Objects per Span | Tail Waste |
|-------|-------------|------------------|------------|
| 1 | 8 B | 1024 | 0 B |
| 2 | 16 B | 512 | 0 B |
| 5 | 48 B | 170 | 32 B |
| 10 | 128 B | 64 | 0 B |
| 30 | 1024 B | 8 | 0 B |
| 67 | 32768 B | 1 | 0 B |

Objects larger than 32 KB are allocated directly from the `mheap` as *large spans*, bypassing the size class mechanism entirely.

**Allocation path for a 100-byte object:**

1. Round up to size class 10 (128 bytes).
2. Check the current P's `mcache` for a span with free slots in class 10.
3. If found, return the next free slot (no lock needed --- per-P).
4. If the `mcache` span is full, obtain a new partial span from `mcentral[10]` (requires lock).
5. If `mcentral` has no partial spans, allocate a new span from `mheap` (global lock).
6. If `mheap` has no free pages, call `mmap` to get more memory from the OS.

**TCMalloc heritage:** The per-P cache is the Go equivalent of TCMalloc's per-thread cache. The key difference: Go uses per-P caches (one per GOMAXPROCS) rather than per-thread caches. Since the number of Ps is typically small (equal to the number of CPU cores), the total cache memory is bounded. This is more efficient than TCMalloc's per-thread approach when there are thousands of threads.

**Integration with GC:** The allocator is tightly coupled with Go's concurrent, tri-colour mark-and-sweep garbage collector. Each allocation checks whether a GC cycle should be triggered (based on `GOGC` / `GOMEMLIMIT`). The allocator marks newly allocated objects as white (unmarked), and the GC concurrently scans and marks reachable objects. Sweeping reclaims entire spans whose objects are all unmarked.

**Key runtime statistics (inspectable via `runtime.ReadMemStats`):**

```go
package main

import (
    "fmt"
    "runtime"
)

func main() {
    // Allocate some objects
    slices := make([][]byte, 1000)
    for i := range slices {
        slices[i] = make([]byte, 1024)
    }

    var m runtime.MemStats
    runtime.ReadMemStats(&m)

    fmt.Printf("Alloc:       %6d KB  (live heap objects)\n", m.Alloc/1024)
    fmt.Printf("TotalAlloc:  %6d KB  (cumulative)\n", m.TotalAlloc/1024)
    fmt.Printf("Sys:         %6d KB  (total OS memory)\n", m.Sys/1024)
    fmt.Printf("HeapObjects: %6d     (live objects)\n", m.HeapObjects)
    fmt.Printf("HeapInuse:   %6d KB  (spans with objects)\n", m.HeapInuse/1024)
    fmt.Printf("HeapIdle:    %6d KB  (spans without objects)\n", m.HeapIdle/1024)
    fmt.Printf("HeapSys:     %6d KB  (heap virtual memory)\n", m.HeapSys/1024)
    fmt.Printf("NumGC:       %6d     (completed GC cycles)\n", m.NumGC)

    _ = slices // keep alive
}
```

The gap between `HeapSys` (virtual memory reserved) and `HeapInuse` (physical memory backing live objects) directly reflects the concepts from this chapter: virtual memory is cheap (it is just page table entries pointing to the zero page), while physical memory is precious (it requires actual DRAM frames). Go reserves virtual address space aggressively but lets the OS manage physical frame allocation through demand paging and `madvise`.
:::

---

## 13.9 Summary

This chapter has covered seven advanced topics that extend the basic virtual memory framework:

- **Copy-on-write** defers page copying until a write occurs, making `fork()` nearly instantaneous and enabling demand zeroing for anonymous memory.
- **Memory-mapped files** unify file I/O and memory access, eliminating buffer copies and leveraging the page cache for high-performance data access.
- **Kernel memory allocators** --- the buddy system provides contiguous page blocks; the slab/SLUB allocator eliminates fragmentation for fixed-size kernel objects; `kmalloc` provides general-purpose kernel allocation via size classes.
- **NUMA** introduces topology-aware allocation, where the OS preferentially allocates memory from the node closest to the requesting CPU to minimise access latency.
- **Huge pages** (explicit and transparent) reduce TLB pressure by covering more virtual address space per TLB entry, with trade-offs in internal fragmentation and latency variability.
- **Memory compression** (zswap, zram) provides a middle layer between RAM and disk swap, compressing evicted pages in RAM to defer costly disk I/O.
- **ASLR** randomises the layout of a process's address space to frustrate memory-corruption exploits, providing probabilistic security proportional to the entropy of the randomisation.

Together with the fundamentals of Chapters 10--12, these topics form a complete picture of how modern operating systems manage memory --- from the hardware page tables and TLB, through the kernel's allocation and reclaim algorithms, to the user-space view presented to applications.

---

::: exercises
**Exercise 13.1.** A process with 2000 pages calls `fork()`. The child then: (a) calls `exec()` immediately (writing only 5 stack pages before `exec`), (b) modifies 200 pages before calling `exec()`, (c) never calls `exec()` and eventually modifies all 2000 pages. For each scenario, calculate the total number of page copies made with CoW and the peak physical memory usage (in pages) for the parent + child. Compare to the naive (full-copy) `fork()`.

**Exercise 13.2.** Write a C program that maps a 1 MB file using `mmap()` with `MAP_SHARED`, modifies the first 100 bytes, calls `msync()` with `MS_SYNC`, and then reads the file using standard `read()` to verify the modification persists. Explain why `msync()` is necessary and what could happen without it.

**Exercise 13.3.** A buddy system manages 1 MB of memory (minimum block size: 1 KB, maximum: 1 MB). Trace the state of the free lists after the following sequence: (a) allocate A = 100 KB, (b) allocate B = 240 KB, (c) allocate C = 60 KB, (d) free B, (e) free A, (f) allocate D = 130 KB. For each step, show all free blocks and their sizes. Calculate the total internal fragmentation at each step.

**Exercise 13.4.** A NUMA system has 2 nodes, each with 64 GB of RAM. Local access latency: 80 ns. Remote access latency: 150 ns. A process has a 50 GB working set. Under three scenarios, calculate the average memory access latency: (a) all memory allocated on the local node (possible since 50 GB < 64 GB), (b) memory allocated 50/50 across both nodes with uniform access pattern, (c) memory interleaved at page granularity (alternating pages between nodes). Which policy is best, and under what conditions might interleaving outperform local allocation?

**Exercise 13.5.** A system has a TLB with 512 entries. A database application has a working set of 8 GB. Calculate the TLB miss rate (assuming uniform random access within the working set) for: (a) 4 KB pages, (b) 2 MB pages, (c) 1 GB pages. For each case, compute the effective access time given $t_{\text{mem}} = 100$ ns, TLB hit time = 1 ns, and a 4-level page walk on miss (each level costs one memory access). Assume the page walk is reduced by one level for 2 MB pages and by two levels for 1 GB pages.

**Exercise 13.6.** Explain why database systems (PostgreSQL, MySQL) often recommend disabling Transparent Huge Pages. Your answer should address: (a) the mechanism by which THP causes latency spikes, (b) why the default THP promotion/splitting behaviour conflicts with database memory access patterns, and (c) what alternatives databases use to gain the TLB benefits of huge pages without the latency drawbacks.

**Exercise 13.7.** A 64-bit Linux system has ASLR enabled with the following entropy: stack = 30 bits, mmap base = 28 bits, heap = 13 bits, PIE text = 28 bits. (a) An attacker discovers a heap address via an information leak. How many bits of the overall layout remain unknown? (b) If the attacker can make 1000 guesses per second (each failed guess crashes and restarts the process), how long would a brute-force attack on the stack base take on average? (c) Why does 32-bit ASLR provide significantly less security than 64-bit ASLR? Calculate the brute-force time for a 32-bit system with 8 bits of stack entropy at the same guess rate.
:::
