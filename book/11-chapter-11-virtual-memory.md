# Chapter 11: Virtual Memory

Chapter 10 established the fundamentals: logical addresses, physical addresses, contiguous allocation, and the fragmentation that plagues it. But contiguous allocation has a fatal flaw --- it requires that every byte of a process reside in physical memory before the process can run, and that these bytes form a contiguous block. Both requirements are absurd for modern systems where processes have gigabytes of virtual address space but use only a fraction at any moment.

Virtual memory shatters both constraints. It allows a process to execute with only part of its memory in physical RAM, loading pages on demand as the program touches them. And because it maps fixed-size virtual pages to fixed-size physical frames, a process's memory can be scattered across physical RAM in any order. The result is a system where each process sees a large, private, contiguous address space while the operating system juggles a much smaller physical memory behind the scenes.

This chapter covers the mechanisms that make virtual memory work: demand paging, page tables (from single-level to the four-level tables of x86-64), the Translation Lookaside Buffer that makes it fast, and the subtleties of shared pages, copy-on-write, and page size trade-offs.

---

## 11.1 Demand Paging

### 11.1.1 The Concept

::: definition
**Definition 11.1 (Demand Paging).** *Demand paging* is a memory management scheme in which pages of a process are loaded into physical memory only when they are accessed (demanded) by the CPU. Pages that are never accessed are never loaded. This is also called *lazy loading*.
:::

When a process is created, none of its pages need to be in physical memory. The operating system sets up the page table entries to indicate "not present." As the process executes and references an address, the MMU checks the page table entry. If the page is present, the translation proceeds normally. If the page is not present, the MMU raises a *page fault*.

The distinction between demand paging and ordinary paging is important. Ordinary paging loads all pages of a process before execution begins. Demand paging loads nothing in advance --- every page is loaded only when first touched. This dramatically reduces startup time and memory consumption, especially for large programs that use only a fraction of their code and data.

### 11.1.2 Page Faults

::: definition
**Definition 11.2 (Page Fault).** A *page fault* is a hardware exception raised by the MMU when a process attempts to access a page that is not currently mapped to a physical frame (i.e., the present bit in the page table entry is 0). The page fault transfers control to the operating system's page fault handler.
:::

The page fault handling sequence is:

1. **Trap to kernel:** The CPU saves the faulting address (in the CR2 register on x86) and transfers control to the page fault handler. The current instruction is suspended.

2. **Validate the reference:** The OS checks whether the faulting address is a valid part of the process's address space. It consults the process's memory map (on Linux, the `vm_area_struct` list). If the address is not in any valid region (e.g., the process dereferenced a null pointer into an unmapped region), the OS delivers a segmentation fault signal (SIGSEGV on Unix).

3. **Classify the fault:** Valid faults fall into several categories:
   - *File-backed fault:* The page is mapped to a file (executable code, shared library, mmap'd file). The page must be read from the file.
   - *Anonymous fault:* The page is anonymous (heap, stack, mmap'd anonymous). If first access, the page is zero-filled. If previously swapped, the page must be read from swap.
   - *CoW fault:* The page is present but read-only due to copy-on-write. A new frame must be allocated and the page copied.

4. **Find a free frame:** The OS locates a free physical frame from the free list. If no free frame exists, the OS must evict an existing page (page replacement, Chapter 12).

5. **Read the page:** The OS issues a disk I/O request to read the page from the backing store (swap space or the executable file on disk) into the free frame. The process is blocked during this I/O.

6. **Update the page table:** Once the I/O completes, the OS sets the page table entry to map the virtual page to the physical frame and sets the present bit to 1.

7. **Restart the instruction:** The CPU re-executes the instruction that caused the fault. This time, the translation succeeds.

::: example
**Example 11.1 (Page Fault Sequence).** A process executes `MOV R1, [0x7FA0]`. The virtual page number for address 0x7FA0 (with 4 KB pages) is $\lfloor 0\text{x}7\text{FA}0 / 4096 \rfloor = 31$. The page table entry for page 31 has present = 0.

1. MMU raises page fault. CR2 $\leftarrow$ 0x7FA0.
2. OS validates: page 31 is a valid heap page.
3. OS classifies: anonymous first-access (zero-fill).
4. OS finds free frame 42.
5. OS zero-fills frame 42 (no disk I/O needed for a first-access anonymous page).
6. OS sets PTE[31] $\leftarrow$ (frame=42, present=1, dirty=0, accessed=1, R/W=1).
7. CPU re-executes `MOV R1, [0x7FA0]`. Translation: frame 42, offset 0xFA0. Physical address = $42 \times 4096 + 0\text{xFA}0 = 0\text{x}2\text{AFA}0$.
:::

::: example
**Example 11.2 (File-Backed Page Fault).** A process executes code at virtual address 0x00400100. This is in the text segment, which is mapped to the executable file on disk.

1. Page fault on VPN = 0x400100 / 4096 = 0x400 (page 1024).
2. OS validates: this is the text segment, mapped to file `/usr/bin/myapp`, offset 0x100000.
3. OS finds free frame 200.
4. OS reads 4 KB from the file at offset 0x100000 into frame 200. This requires disk I/O.
5. OS updates PTE: frame=200, present=1, R/W=0 (text is read-only), NX=0 (executable).
6. CPU re-executes the instruction at 0x00400100.
:::

### 11.1.3 Types of Page Faults

::: definition
**Definition 11.3 (Minor vs Major Page Fault).**

- A *minor page fault* (soft fault) is one that can be resolved without disk I/O. The page is already in memory (e.g., in the page cache or shared by another process) but not yet mapped into the faulting process's page table.

- A *major page fault* (hard fault) requires disk I/O to read the page from storage (swap device or file system). Major faults are 1000--100,000 times slower than minor faults.
:::

On Linux, `ps -o min_flt,maj_flt PID` reports the minor and major fault counts for a process. A well-tuned system should have very few major faults during steady-state operation.

::: example
**Example 11.3 (Fault Counts).** A program processes a 500 MB data file:

```text
$ /usr/bin/time -v ./process_data big_file.dat 2>&1 | grep -i fault
Minor (reclaiming a frame) page faults: 128432
Major (requiring I/O) page faults: 12
```

The 128,432 minor faults correspond to mapping pages already in the page cache (previously read by the kernel's readahead mechanism). The 12 major faults correspond to pages not yet in the cache --- perhaps the first pages of the file before readahead kicks in.
:::

### 11.1.4 Performance of Demand Paging

The key performance metric is the *page fault rate*, denoted $p$, defined as the probability that a given memory access causes a page fault.

::: definition
**Definition 11.4 (Effective Access Time for Demand Paging).** If $t_{\text{mem}}$ is the memory access time and $t_{\text{fault}}$ is the time to service a page fault, the effective access time is:

$$\text{EAT} = (1 - p) \times t_{\text{mem}} + p \times t_{\text{fault}}$$
:::

The page fault service time $t_{\text{fault}}$ includes:

- Trap overhead: ~1 $\mu$s
- OS processing (validate, allocate frame, set up I/O): ~5 $\mu$s
- Page-in from disk: ~2--10 ms (HDD) or ~50--200 $\mu$s (SSD)
- Page table update and TLB invalidation: ~1 $\mu$s
- Process restart overhead: ~1 $\mu$s

::: example
**Example 11.4 (EAT Calculation).** $t_{\text{mem}} = 100$ ns. $t_{\text{fault}} = 8$ ms $= 8{,}000{,}000$ ns (HDD-backed).

$$\text{EAT} = (1 - p) \times 100 + p \times 8{,}000{,}000$$

For a 10% slowdown (EAT $\leq$ 110 ns):

$$110 \geq 100 - 100p + 8{,}000{,}000 p$$
$$10 \geq 7{,}999{,}900 p$$
$$p \leq 1.25 \times 10^{-6}$$

The page fault rate must be less than about one in 800,000 accesses to keep the slowdown under 10%. This is why effective page replacement algorithms (Chapter 12) are critical.
:::

::: theorem
**Theorem 11.1 (Page Fault Rate Bound for Acceptable Performance).** For a system with memory access time $t_{\text{mem}}$, page fault service time $t_{\text{fault}}$, and acceptable slowdown factor $\alpha > 1$, the page fault rate must satisfy:

$$p \leq \frac{(\alpha - 1) \cdot t_{\text{mem}}}{t_{\text{fault}} - t_{\text{mem}}}$$

*Proof.* We require $\text{EAT} \leq \alpha \cdot t_{\text{mem}}$:

$$(1 - p) \cdot t_{\text{mem}} + p \cdot t_{\text{fault}} \leq \alpha \cdot t_{\text{mem}}$$
$$t_{\text{mem}} + p(t_{\text{fault}} - t_{\text{mem}}) \leq \alpha \cdot t_{\text{mem}}$$
$$p(t_{\text{fault}} - t_{\text{mem}}) \leq (\alpha - 1) \cdot t_{\text{mem}}$$
$$p \leq \frac{(\alpha - 1) \cdot t_{\text{mem}}}{t_{\text{fault}} - t_{\text{mem}}} \quad \square$$
:::

::: example
**Example 11.5 (Acceptable Fault Rates Across Storage).** Using the bound from Theorem 11.1 with $\alpha = 1.1$ (10% slowdown) and $t_{\text{mem}} = 100$ ns:

| Storage | $t_{\text{fault}}$ | Max $p$ | Max fault rate |
|---------|-------------------|---------|----------------|
| HDD | 8 ms | $1.25 \times 10^{-6}$ | 1 in 800,000 |
| SATA SSD | 200 $\mu$s | $5.0 \times 10^{-5}$ | 1 in 20,000 |
| NVMe SSD | 50 $\mu$s | $2.0 \times 10^{-4}$ | 1 in 5,000 |

With NVMe storage, the system can tolerate 160 times more page faults than with HDD for the same performance impact. This has profound implications for memory management policy: aggressive overcommitment is more viable with fast storage.
:::

### 11.1.5 Pure Demand Paging vs Prepaging

*Pure demand paging* never loads a page until it is faulted. This means a process starts with zero pages in memory, and the first few instructions cause a cascade of page faults (one for the code page, one for the stack page, one for initialised data, etc.). This initial burst is called *cold start* or *cold cache* behaviour.

*Prepaging* (or *prefetching*) loads several pages at once, predicting which pages the process will need soon. The spatial locality principle suggests that if a process accesses page $k$, it is likely to access pages $k+1$, $k+2$, etc. Modern operating systems use a combination: demand paging with readahead (prefetching a window of pages beyond the faulted page).

::: definition
**Definition 11.5 (Readahead).** *Readahead* is a prefetching strategy where, upon a page fault for page $k$, the OS loads not only page $k$ but also pages $k+1, k+2, \ldots, k+W-1$, where $W$ is the readahead window. If the process's access pattern is sequential, these prefetched pages avoid future faults.
:::

::: example
**Example 11.6 (Readahead Effectiveness).** A process reads a 1 MB file sequentially. Page size: 4 KB. Total pages: 256.

Without readahead: 256 major page faults (one per page), each costing ~8 ms. Total: $256 \times 8 = 2048$ ms $\approx 2$ seconds.

With readahead (window = 32 pages = 128 KB): the first fault triggers a read of 32 pages. Subsequent faults trigger additional readahead. Total major faults: $256 / 32 = 8$, but each reads 128 KB. Total: $8 \times 8 = 64$ ms (plus the amortised disk access is more efficient for larger reads). In practice, the sequential read rate of the disk (~150 MB/s for HDD, ~3 GB/s for NVMe) dominates, giving ~6.7 ms (HDD) or ~0.3 ms (NVMe).
:::

> **Note:** Linux's page cache implements aggressive readahead for file-backed pages. The `readahead()` system call allows applications to hint which file regions they will need. The `fadvise()` system call provides additional hints: `POSIX_FADV_SEQUENTIAL` increases the readahead window, `POSIX_FADV_RANDOM` disables it, and `POSIX_FADV_DONTNEED` tells the kernel to evict the pages (useful after processing a file, to free page cache for other uses). For anonymous pages (heap, stack), Linux relies on demand paging without readahead, since access patterns for anonymous memory are less predictable than sequential file reads.

---

## 11.2 Page Tables

The page table is the data structure that maps virtual page numbers to physical frame numbers. Its design is one of the most important engineering decisions in a virtual memory system.

### 11.2.1 Single-Level Page Table

::: definition
**Definition 11.6 (Page Table).** A *page table* is an array indexed by the virtual page number (VPN). Each entry, called a *page table entry* (PTE), contains the physical frame number and a set of control bits (present, dirty, accessed, protection, etc.).
:::

For a system with a $v$-bit virtual address and page size $2^p$ bytes, the parameters are:

- Number of virtual pages: $N_{\text{pages}} = 2^{v-p}$
- Page table entries: $N_{\text{PTE}} = 2^{v-p}$
- VPN bits: $v - p$
- Offset bits: $p$
- Physical frame number bits: $\text{PA width} - p$

::: example
**Example 11.6a (Page Table Parameters).** Common configurations:

| System | VA bits ($v$) | PA bits | Page ($2^p$) | VPN bits | Offset | Pages | PTE size | PT size |
|--------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 16-bit micro | 16 | 16 | 256 B | 8 | 8 | 256 | 2 B | 512 B |
| 32-bit x86 | 32 | 32 | 4 KB | 20 | 12 | 1M | 4 B | 4 MB |
| 32-bit PAE | 32 | 36 | 4 KB | 20 | 12 | 1M | 8 B | 8 MB |
| 48-bit x86-64 | 48 | 52 | 4 KB | 36 | 12 | 64G | 8 B | 512 GB |

The last row shows why single-level page tables are infeasible for 64-bit systems.
:::

The address translation for a single-level page table:

1. Extract VPN from the virtual address: $\text{VPN} = \lfloor \text{VA} / 2^p \rfloor = \text{VA} \gg p$
2. Index the page table: $\text{PTE} = \text{PageTable}[\text{VPN}]$
3. Check the present bit. If 0, raise page fault.
4. Extract the frame number: $\text{FN} = \text{PTE.frame}$
5. Compute physical address: $\text{PA} = \text{FN} \times 2^p + (\text{VA} \bmod 2^p)$

Or equivalently: $\text{PA} = (\text{FN} \ll p) \;|\; (\text{VA} \;\&\; (2^p - 1))$

::: example
**Example 11.7 (Single-Level Translation).** A system has 16-bit virtual addresses and 4 KB pages ($p = 12$).

- VPN bits: $16 - 12 = 4$ bits, giving 16 pages
- Offset bits: 12 bits

Virtual address 0x3A7F:
- Binary: 0011 1010 0111 1111
- VPN: 0011 = 3 (top 4 bits)
- Offset: 1010 0111 1111 = 0xA7F (bottom 12 bits)
- Suppose PTE[3].frame = 7. Physical address: $(7 \ll 12) \;|\; 0\text{xA7F} = 0\text{x}7000 + 0\text{xA7F} = 0\text{x}7\text{A}7\text{F}$.
:::

::: example
**Example 11.8 (Complete Page Table).** A minimal 16-bit system with 4 KB pages (4-bit VPN). The page table for a process:

| VPN | Frame | Present | R/W | Accessed | Dirty |
|-----|-------|---------|-----|----------|-------|
| 0 | 5 | 1 | 0 | 1 | 0 |
| 1 | 9 | 1 | 1 | 1 | 1 |
| 2 | -- | 0 | -- | -- | -- |
| 3 | 2 | 1 | 1 | 0 | 0 |
| 4--14 | -- | 0 | -- | -- | -- |
| 15 | 12 | 1 | 1 | 1 | 0 |

Only pages 0, 1, 3, and 15 are present. Page 0 is read-only (code). Page 1 is read-write and dirty (modified data). Pages 2 and 4--14 are not present (not yet loaded or swapped out). Page 15 is the stack.

Translation of address 0x1B40: VPN = 1, offset = 0xB40. PTE[1]: present=1, frame=9. Physical address: 0x9B40.

Translation of address 0x2000: VPN = 2, offset = 0x000. PTE[2]: present=0. Page fault.
:::

### 11.2.2 The Size Problem

A single-level page table for a 32-bit address space with 4 KB pages has $2^{20} = 1{,}048{,}576$ entries. If each entry is 4 bytes, the table is 4 MB. Every process needs its own page table, so 100 processes consume 400 MB of page table memory alone.

For a 64-bit address space (even using only 48 bits), the table would have $2^{36}$ entries --- 256 GB per process. This is clearly infeasible.

::: theorem
**Theorem 11.2 (Page Table Size).** For a $v$-bit virtual address space with page size $2^p$ bytes and PTE size $e$ bytes, the page table size is:

$$S = \frac{2^v}{2^p} \times e = 2^{v-p} \times e$$

For the table to fit in physical memory, we require $S \leq M$ where $M$ is the total physical memory. This gives the constraint:

$$2^{v-p} \times e \leq M$$

For $v = 48$, $p = 12$, $e = 8$: $S = 2^{36} \times 8 = 512$ GB. This exceeds any reasonable physical memory size, mandating a hierarchical or inverted page table structure.
:::

### 11.2.3 Multi-Level Page Tables

The solution is to *page the page table itself*. Instead of one enormous array, we use a tree of smaller tables.

::: definition
**Definition 11.7 (Multi-Level Page Table).** A *$k$-level page table* is a tree of depth $k$ where each internal node is a *page directory* containing pointers to the next level, and each leaf contains the physical frame number. The virtual page number is split into $k$ fields, each used to index one level of the tree.
:::

The key insight is sparsity: most processes use only a tiny fraction of their virtual address space. If a large region is unused, the corresponding subtree need not exist. The directory entry for that region is simply marked "not present," saving all the memory that would have been used for the missing page table pages.

**Two-Level Page Table (32-bit x86):**

A 32-bit virtual address with 4 KB pages is split as:

```text
31         22 21         12 11           0
+------------+------------+--------------+
| Dir Index  | Table Index|   Offset     |
|  10 bits   |  10 bits   |   12 bits    |
+------------+------------+--------------+
```

- Level 1 (Page Directory): $2^{10} = 1024$ entries, each pointing to a page table.
- Level 2 (Page Table): $2^{10} = 1024$ entries, each mapping a page to a frame.

Each level fits in exactly one 4 KB page ($1024 \times 4 = 4096$ bytes), which is elegant and intentional.

::: example
**Example 11.9 (Two-Level Savings).** A 32-bit process uses only 12 MB of memory: 4 MB of code (starting at 0x08048000), 4 MB of heap, and 4 MB of stack (near the top of the address space).

With a single-level page table: $2^{20}$ entries $\times$ 4 bytes = 4 MB.

With a two-level page table:
- Page Directory: 1024 entries $\times$ 4 bytes = 4 KB (always present).
- Code occupies VAs 0x08048000--0x0844FFFF. Directory entries: indices $32$--$33$ (two entries). Page tables: 2, each 4 KB.
- Heap (say 0x08450000--0x08850000): directory entries 33--34. Page tables: ~2.
- Stack (say 0xBFC00000--0xC0000000): directory entries 767--768. Page tables: ~2.
- Total page tables: ~6, each 4 KB.
- Total: $4 + 6 \times 4 = 28$ KB.

Savings: 4 MB $\to$ 28 KB (a factor of ~146).
:::

::: example
**Example 11.10 (Two-Level Translation Step by Step).** Virtual address: 0x0804A100 on a 32-bit x86 system with 4 KB pages and a two-level page table.

1. Split the address:
   - Directory index (bits 31--22): $0\text{x}0804\text{A}100 \gg 22 = 0\text{x}20 = 32$
   - Table index (bits 21--12): $(0\text{x}0804\text{A}100 \gg 12) \;\&\; 0\text{x}3\text{FF} = 0\text{x}4\text{A} = 74$
   - Offset (bits 11--0): $0\text{x}0804\text{A}100 \;\&\; 0\text{xFFF} = 0\text{x}100$

2. Read Page Directory entry 32 from the page directory (base in CR3). Suppose it contains physical address 0x1F000 (the page table for this region).

3. Read Page Table entry 74 from the page table at 0x1F000. Suppose it contains frame number 0x3A0, present=1.

4. Physical address: $0\text{x}3\text{A}0 \times 0\text{x}1000 + 0\text{x}100 = 0\text{x}3\text{A}0100$.
:::

### 11.2.4 Four-Level Page Table (x86-64)

Modern x86-64 processors use a 4-level page table to handle 48-bit virtual addresses:

::: definition
**Definition 11.8 (x86-64 Four-Level Page Table).** The x86-64 architecture translates 48-bit virtual addresses using four levels of page tables:

| Level | Name | Bits | Entries | Entry Size |
|-------|------|------|---------|------------|
| 4 | PML4 (Page Map Level 4) | 47--39 | 512 | 8 bytes |
| 3 | PDPT (Page Directory Pointer Table) | 38--30 | 512 | 8 bytes |
| 2 | PD (Page Directory) | 29--21 | 512 | 8 bytes |
| 1 | PT (Page Table) | 20--12 | 512 | 8 bytes |

Each level uses 9 bits of the virtual address to index 512 entries (each 8 bytes, fitting exactly in a 4 KB page). Bits 11--0 form the 12-bit page offset.
:::

```text
Virtual Address (48 bits used, 64 bits total):
63    48 47    39 38    30 29    21 20    12 11       0
+------+--------+--------+--------+--------+----------+
| Sign |  PML4  |  PDPT  |   PD   |   PT   |  Offset  |
|extend| 9 bits | 9 bits | 9 bits | 9 bits | 12 bits  |
+------+--------+--------+--------+--------+----------+
         |          |         |         |
         v          v         v         v
       PML4       PDPT       PD        PT
       Table      Table     Table     Table
      [512]      [512]     [512]     [512]
         |          |         |         |
         +----->----+---->----+--->-----+--> Frame Number
                                              + Offset
                                              = Physical Address
```

Bits 63--48 are *sign-extended* from bit 47. This means virtual addresses are either in the range 0x0000000000000000--0x00007FFFFFFFFFFF (user space) or 0xFFFF800000000000--0xFFFFFFFFFFFFFFFF (kernel space). Addresses in between are *non-canonical* and cause a general protection fault if used.

The translation requires four memory accesses (one per level) to walk the page table. This is why the TLB (Section 11.3) is critical for performance.

::: example
**Example 11.11 (x86-64 Translation).** Virtual address: 0x00007F4A38201A40.

We need to extract the indices for each level:

- PML4 index (bits 47--39): $(0\text{x}7\text{F}4\text{A}38201\text{A}40 \gg 39) \;\&\; 0\text{x}1\text{FF} = 254$
- PDPT index (bits 38--30): $(0\text{x}7\text{F}4\text{A}38201\text{A}40 \gg 30) \;\&\; 0\text{x}1\text{FF} = 328$
- PD index (bits 29--21): $(0\text{x}7\text{F}4\text{A}38201\text{A}40 \gg 21) \;\&\; 0\text{x}1\text{FF} = 257$
- PT index (bits 20--12): $(0\text{x}7\text{F}4\text{A}38201\text{A}40 \gg 12) \;\&\; 0\text{x}1\text{FF} = 1$
- Offset (bits 11--0): $0\text{x}7\text{F}4\text{A}38201\text{A}40 \;\&\; 0\text{xFFF} = 0\text{xA}40$

The hardware performs:
1. Read PML4[254] from the PML4 table (base address in CR3 register).
2. Read PDPT[328] from the PDPT table pointed to by PML4[254].
3. Read PD[257] from the PD table pointed to by PDPT[328].
4. Read PT[1] from the PT table pointed to by PD[257].
5. Extract frame number from PT[1], append offset 0xA40.

If any entry along the path has its present bit clear, the hardware raises a page fault.
:::

### 11.2.5 Five-Level Page Tables

Intel's Ice Lake and later processors support *5-level paging* (LA57), adding a PML5 level that extends the virtual address space from 48 to 57 bits (128 PB). The PML5 uses 9 bits (bits 56--48), adding 512 more entries at the top level. This is motivated by applications (databases, in-memory analytics) that need more than 256 TB of virtual address space, and by persistent memory (Intel Optane) that blurs the line between storage and memory.

::: definition
**Definition 11.9 (Five-Level Paging).** In five-level paging, the virtual address is extended to 57 bits:

| Level | Name | Bits |
|-------|------|------|
| 5 | PML5 | 56--48 |
| 4 | PML4 | 47--39 |
| 3 | PDPT | 38--30 |
| 2 | PD | 29--21 |
| 1 | PT | 20--12 |

The PML5 table has 512 entries, each pointing to a PML4 table. The additional level costs one more memory access per page table walk.
:::

### 11.2.6 Inverted Page Tables

An alternative to hierarchical page tables is the *inverted page table*, which has one entry per physical frame rather than one entry per virtual page.

::: definition
**Definition 11.10 (Inverted Page Table).** An *inverted page table* is an array with one entry per physical frame. Each entry contains the virtual page number and process ID of the page currently occupying that frame. To translate a virtual address, the hardware (or software) searches the table for an entry matching the (process ID, VPN) pair.
:::

The inverted page table has a fixed size proportional to the physical memory, not the virtual address space. For a system with 4 GB of physical memory and 4 KB pages, the inverted page table has $2^{20}$ entries, regardless of whether the virtual address space is 48 or 57 bits.

The drawback is the search: a naive linear scan is $O(n)$ per memory access. This is solved using a hash table:

$$\text{hash}(\text{PID}, \text{VPN}) \to \text{index into inverted page table}$$

Collisions are resolved by chaining. The IBM PowerPC and the IA-64 (Itanium) architectures used inverted page tables.

::: example
**Example 11.12 (Inverted Page Table).** Physical memory: 16 frames. Inverted page table:

| Frame | PID | VPN | Present | Chain |
|-------|-----|-----|---------|-------|
| 0 | 1 | 5 | 1 | -- |
| 1 | 2 | 3 | 1 | -- |
| 2 | 1 | 0 | 1 | -- |
| 3 | -- | -- | 0 | -- |
| 4 | 1 | 12 | 1 | -- |
| ... | ... | ... | ... | ... |

To translate (PID=1, VPN=5): hash(1, 5) = 0. Frame 0 contains (1, 5). Match. Physical address = frame 0 + offset.

To translate (PID=1, VPN=7): hash(1, 7) = 3. Frame 3 is empty. No match found after following the chain. Page fault.
:::

::: theorem
**Theorem 11.3 (Inverted vs Hierarchical Trade-off).** The inverted page table uses $O(M / P)$ space (where $M$ is physical memory size and $P$ is page size), independent of virtual address space size. The hierarchical page table uses $O(U / P)$ space (where $U$ is the amount of virtual address space actually used by the process), which can be much smaller or much larger than the inverted table depending on the workload. The inverted table has $O(1)$ expected lookup time (with good hashing) but does not directly support shared pages.
:::

> **Note:** Inverted page tables make shared memory more complex. If two processes share a physical frame, the inverted page table entry can only store one (PID, VPN) pair. Sharing is typically handled by a separate mechanism, such as a supplementary hash chain or a segment table overlay.

---

## 11.3 Translation Lookaside Buffer (TLB)

### 11.3.1 The Performance Problem

A 4-level page table requires four memory accesses just to translate one virtual address, plus a fifth access to actually read or write the target data. This makes every memory operation five times slower --- clearly unacceptable.

The solution is caching. The *Translation Lookaside Buffer* (TLB) is a small, fast cache that stores recently used page table entries.

::: definition
**Definition 11.11 (Translation Lookaside Buffer).** The *TLB* is a fully associative (or set-associative) hardware cache within the MMU that stores recently used virtual-to-physical page translations. On each memory access, the TLB is consulted first. A *TLB hit* produces the physical frame number without any page table walk. A *TLB miss* triggers a page table walk, and the result is inserted into the TLB.
:::

Typical TLB parameters:

| Parameter | L1 dTLB | L1 iTLB | L2 TLB |
|-----------|---------|---------|--------|
| Entries | 64--128 | 64--128 | 512--2048 |
| Associativity | 4--8 way | 4--8 way | 8--12 way |
| Access time | 0.5--1 ns | 0.5--1 ns | 3--7 ns |

### 11.3.2 TLB Operation

```text
Virtual Address
      |
      v
  +-------+
  |  TLB  |--HIT--> Frame Number --> Physical Address
  +-------+
      |
     MISS
      |
      v
  +------------+
  | Page Table |--PRESENT--> Frame Number --> TLB Update --> Physical Address
  |   Walk     |
  +------------+
      |
   NOT PRESENT
      |
      v
  +------------+
  | Page Fault |
  | Handler    |
  +------------+
```

The TLB is typically split into separate instruction TLB (iTLB) and data TLB (dTLB), mirroring the split L1 cache. Some processors have a unified L2 TLB that backs both. On modern Intel processors, the TLB hierarchy looks like:

```text
L1 iTLB: 128 entries, 8-way, 4KB/2MB pages
L1 dTLB: 64 entries, 4-way, 4KB pages
         32 entries, 4-way, 2MB/1GB pages
L2 sTLB: 1536 entries, 12-way, 4KB/2MB pages (unified)
```

### 11.3.2a TLB Reach

::: definition
**Definition 11.11a (TLB Reach).** The *TLB reach* is the total amount of virtual address space accessible through the TLB without a miss:

$$\text{TLB reach} = \text{TLB entries} \times \text{page size}$$

For a mixed TLB with entries for different page sizes:

$$\text{TLB reach} = \sum_i n_i \times P_i$$

where $n_i$ is the number of TLB entries for page size $P_i$.
:::

::: example
**Example 11.12a (TLB Reach with Mixed Page Sizes).** A TLB has 64 entries for 4 KB pages and 32 entries for 2 MB pages.

$$\text{TLB reach} = 64 \times 4 \text{ KB} + 32 \times 2 \text{ MB} = 256 \text{ KB} + 64 \text{ MB} = 64.25 \text{ MB}$$

The 32 huge page entries contribute 99.6% of the TLB reach despite being only 33% of the entries. This illustrates why huge pages are so effective at reducing TLB pressure.
:::

### 11.3.3 TLB Hit Ratio and EAT

::: definition
**Definition 11.12 (Effective Access Time with TLB).** Let $h$ be the TLB hit ratio (probability of a TLB hit), $t_{\text{TLB}}$ be the TLB lookup time, $t_{\text{mem}}$ be the memory access time, and $k$ be the number of page table levels. The effective access time is:

$$\text{EAT} = h \times (t_{\text{TLB}} + t_{\text{mem}}) + (1 - h) \times (t_{\text{TLB}} + k \times t_{\text{mem}} + t_{\text{mem}})$$

Simplifying (and noting that $t_{\text{TLB}}$ is typically overlapped with the cache access in a pipelined processor):

$$\text{EAT} \approx h \times t_{\text{mem}} + (1 - h) \times (k + 1) \times t_{\text{mem}}$$
:::

::: example
**Example 11.13 (EAT with TLB).** 4-level page table ($k = 4$), $t_{\text{mem}} = 100$ ns, TLB hit ratio $h = 0.99$.

$$\text{EAT} = 0.99 \times 100 + 0.01 \times 5 \times 100 = 99 + 5 = 104 \text{ ns}$$

With TLB: 4% slowdown. Without TLB: $5 \times 100 = 500$ ns (400% slowdown).

If the TLB hit ratio drops to 0.90:

$$\text{EAT} = 0.90 \times 100 + 0.10 \times 500 = 90 + 50 = 140 \text{ ns}$$

A 40% slowdown --- the TLB hit ratio is the single most important factor in virtual memory performance.
:::

::: example
**Example 11.14 (TLB with Page Table Cache).** In practice, the intermediate levels of the page table walk may hit in the data cache. If the L1 cache has a hit rate of 80% for page table entries and $t_{L1} = 4$ ns:

$$t_{\text{walk}} = k \times (0.8 \times t_{L1} + 0.2 \times t_{\text{mem}}) = 4 \times (0.8 \times 4 + 0.2 \times 100) = 4 \times (3.2 + 20) = 92.8 \text{ ns}$$

Compared to $k \times t_{\text{mem}} = 400$ ns. The data cache reduces the penalty of TLB misses by about 4x.
:::

::: theorem
**Theorem 11.4 (TLB Coverage).** A TLB with $n$ entries and page size $P$ can cover $n \times P$ bytes of virtual address space without any misses. For a workload with working set size $W$, TLB misses are approximately zero if $n \times P \geq W$, and the miss rate increases as $W / (n \times P)$ exceeds 1.

*Proof sketch.* Each TLB entry caches the translation for one page of size $P$. If all $n$ entries hold translations for the working set, every access within the working set hits in the TLB. The working set fits if $W \leq n \times P$. When $W > n \times P$, the process cycles through more pages than TLB entries, causing capacity misses. For a uniform random access pattern over $W / P$ pages with $n < W / P$, the miss rate is approximately $1 - nP/W$. $\square$
:::

::: example
**Example 11.15 (TLB Coverage).** A TLB has 1024 entries. Page size: 4 KB.

- TLB coverage: $1024 \times 4 \text{ KB} = 4$ MB

A process with a working set of 2 MB fits entirely in the TLB --- near-zero TLB misses. A process with a working set of 64 MB uses only $4/64 = 6.25\%$ of its working set through the TLB at any time, leading to frequent TLB misses.

With 2 MB huge pages: TLB coverage = $1024 \times 2 \text{ MB} = 2$ GB. The 64 MB working set now fits easily.
:::

### 11.3.4 TLB Miss Handling

Two approaches to handling TLB misses:

**Hardware-managed TLB (x86, ARM):** The CPU hardware contains a *page table walker* (PTW) that automatically traverses the page table on a TLB miss, loads the PTE, and inserts it into the TLB. The OS is not involved in TLB misses (only in page faults). The page table format is fixed by the hardware.

**Software-managed TLB (MIPS, SPARC, PA-RISC):** A TLB miss raises a special exception (TLB miss exception, not a page fault), and the OS's TLB miss handler software walks the page table and loads the TLB entry using special instructions (e.g., MIPS `tlbwr`). This gives the OS complete flexibility over the page table format but adds overhead (typically 10--50 cycles for the exception handling). The handler is performance-critical and is usually written in hand-optimised assembly.

::: definition
**Definition 11.13 (Page Table Walker).** A *page table walker* (PTW) is a hardware state machine that traverses a multi-level page table to resolve a TLB miss. It reads page table entries from memory (potentially hitting in the data cache or dedicated page table caches), follows the chain of pointers from the top level to the leaf, and loads the resulting translation into the TLB.
:::

### 11.3.5 Address Space Identifiers (ASID)

::: definition
**Definition 11.14 (Address Space Identifier).** An *ASID* is a tag stored in each TLB entry that identifies which process's address space the entry belongs to. When the TLB is searched, both the virtual page number and the ASID must match. This allows entries from multiple processes to coexist in the TLB, eliminating the need to flush the TLB on every context switch.
:::

Without ASIDs, a context switch requires flushing the entire TLB (invalidating all entries), because virtual page 5 in Process A maps to a different physical frame than virtual page 5 in Process B. With ASIDs, both mappings can coexist:

| VPN | ASID | Frame | Valid |
|-----|------|-------|-------|
| 5 | 1 | 42 | 1 |
| 5 | 2 | 87 | 1 |
| 12 | 1 | 3 | 1 |

When Process 1 accesses VPN 5, the TLB matches (VPN=5, ASID=1) and returns frame 42. When Process 2 accesses VPN 5, the TLB matches (VPN=5, ASID=2) and returns frame 87.

x86-64 supports ASIDs through *Process Context Identifiers* (PCIDs), a 12-bit field that tags TLB entries. With 12 bits, up to 4096 distinct address spaces can coexist in the TLB. Linux enables PCIDs by default on supported hardware, significantly reducing context switch overhead.

::: example
**Example 11.16 (PCID Impact on Context Switch).** Without PCIDs: every context switch flushes the TLB. With 512 TLB entries and a 99% hit rate, the first ~512 memory accesses after a switch are TLB misses (cold cache). If context switches happen every 4 ms, and the miss penalty is 20 ns per miss, the overhead is $512 \times 20 = 10,240$ ns $\approx 10\ \mu$s per switch.

With PCIDs: TLB entries from the previous context remain valid. If the process was recently running (its entries are still in the TLB), most accesses hit immediately. The context switch overhead is reduced to the CR3 load latency (~50 ns) plus any conflicts for the same TLB entry.
:::

::: programmer
**Programmer's Perspective: Measuring TLB Performance.**

On Linux, you can measure TLB behaviour using `perf stat`:

```text
$ perf stat -e dTLB-load-misses,dTLB-loads,dTLB-store-misses,dTLB-stores \
            -e iTLB-load-misses,iTLB-loads \
            ./my_program
```

Sample output:

```text
     2,847,321  dTLB-load-misses    #  0.03% of all dTLB loads
 8,421,567,890  dTLB-loads
       123,456  dTLB-store-misses
 2,105,391,972  dTLB-stores
        45,678  iTLB-load-misses    #  0.00% of all iTLB loads
 4,210,783,945  iTLB-loads
```

A data TLB miss rate of 0.03% is excellent. If the rate exceeds 1%, investigate:

1. Check if the working set exceeds TLB coverage ($\text{entries} \times \text{page size}$).
2. Consider using huge pages to increase coverage (Section 11.7).
3. Restructure data for better spatial locality: arrays of structures vs structures of arrays, loop tiling, etc.
4. On NUMA systems, ensure memory is allocated on the local node (remote accesses add to the effective miss penalty).

In Go, the runtime's memory allocator is designed to minimise TLB pressure by allocating small objects from per-P caches backed by spans (contiguous runs of pages). Since objects of the same size class are packed into the same span, iterating over them exhibits good spatial locality. The `runtime.MemProfileRate` variable controls allocation profiling, which can help identify hot allocation paths.
:::

---

## 11.4 Page Table Entry Format

Each page table entry contains the physical frame number and several control bits that govern access permissions and assist the OS in page management.

### 11.4.1 x86-64 PTE Format

::: definition
**Definition 11.15 (x86-64 Page Table Entry).** An x86-64 PTE is 64 bits wide with the following fields:

| Bits | Name | Description |
|------|------|-------------|
| 0 | P (Present) | 1 if the page is in physical memory |
| 1 | R/W | 0 = read-only, 1 = read/write |
| 2 | U/S | 0 = supervisor only, 1 = user accessible |
| 3 | PWT | Page-level write-through |
| 4 | PCD | Page-level cache disable |
| 5 | A (Accessed) | Set by hardware when the page is read or written |
| 6 | D (Dirty) | Set by hardware when the page is written |
| 7 | PS (Page Size) | 1 = large page (2 MB at PD level, 1 GB at PDPT level) |
| 8--11 | (Available) | Available for OS use |
| 12--51 | Frame Number | Physical frame number (40 bits $\to$ 1 TB addressable) |
| 52--58 | (Available) | Available for OS use |
| 59--62 | MPK | Memory protection key (4 bits, 16 domains) |
| 63 | NX (No Execute) | 1 = page cannot be executed |
:::

The 40-bit frame number allows addressing up to $2^{40} \times 4 \text{ KB} = 4$ PB of physical memory. The 11 available bits (4 + 7) are used by the OS for purposes such as swap location encoding, page state tracking, and reference counting.

### 11.4.2 The Present Bit

The present bit is the gateway to demand paging. When P = 0, all other bits are available for the OS to use as it sees fit. Linux uses the remaining bits to store the location of the page on disk (swap device number and offset), enabling the page fault handler to locate the page quickly.

### 11.4.3 The Dirty Bit

::: definition
**Definition 11.16 (Dirty Bit).** The *dirty bit* (D) is set by the hardware whenever the CPU writes to a page. A page with D = 1 has been modified since it was loaded into memory and must be written back to disk before its frame can be reclaimed. A page with D = 0 (clean) can be discarded without writing, since the copy on disk is still valid.
:::

The dirty bit is critical for page replacement efficiency: evicting a clean page is free (no I/O), while evicting a dirty page requires a write to the backing store. This asymmetry influences both the replacement algorithm (prefer evicting clean pages) and the kernel's background writeback policy (periodically writing dirty pages to disk to reduce the number of dirty pages that accumulate).

### 11.4.4 The Accessed Bit

The accessed bit (A) is set by the hardware whenever the CPU reads or writes the page. The operating system periodically clears the accessed bits and uses them to approximate LRU behaviour for page replacement (the "clock algorithm," Chapter 12). Pages with A = 0 after the OS clears the bit have not been accessed in the recent past and are candidates for eviction.

### 11.4.5 The NX (No-Execute) Bit

::: definition
**Definition 11.17 (NX Bit).** The *NX bit* (No eXecute), also called *XD* (eXecute Disable) on Intel or *EVP* on AMD, marks a page as non-executable. Any attempt to fetch an instruction from an NX-marked page raises a page fault. This is a critical security feature that prevents code injection attacks (e.g., buffer overflow exploits that place shellcode on the stack or heap).
:::

::: example
**Example 11.17 (NX Protection).** A buffer overflow attack overwrites a return address on the stack to point to malicious code injected into the same stack buffer. Without NX: the CPU executes the injected code. With NX: the stack pages are marked NX, so the CPU raises a page fault when it tries to execute code from the stack. The attack fails.

This defence is not absolute: Return-Oriented Programming (ROP) attacks bypass NX by chaining together small sequences of existing code (gadgets) already present in executable pages. But NX eliminates the simplest class of code injection attacks.
:::

---

## 11.5 Shared Pages

### 11.5.1 Shared Libraries

Multiple processes running the same program (or using the same library) can share the read-only code pages. Each process's page table maps the relevant virtual pages to the same physical frames.

::: definition
**Definition 11.18 (Shared Page).** A *shared page* is a physical frame that appears in the page tables of two or more processes. The processes may map the frame at different virtual addresses, but they all access the same physical memory.
:::

::: example
**Example 11.18 (Shared libc).** Three processes (A, B, C) all use the C library (libc), which occupies 500 pages. Without sharing: $3 \times 500 = 1500$ frames. With sharing: 500 frames (one copy), mapped into all three address spaces. Savings: 1000 frames.
:::

### 11.5.2 Copy-on-Write (CoW)

::: definition
**Definition 11.19 (Copy-on-Write).** *Copy-on-write* (CoW) is an optimisation where two processes initially share the same physical pages (marked read-only). When either process writes to a shared page, the hardware triggers a protection fault. The OS then copies the page to a new frame, updates the page table of the writing process to point to the copy, and marks both the original and the copy as writable (if appropriate).
:::

CoW is the foundation of efficient `fork()` in Unix. When a process calls `fork()`, the child inherits the parent's entire address space. Without CoW, this requires copying all of the parent's memory --- potentially hundreds of megabytes. With CoW, `fork()` merely duplicates the page table (each entry pointing to the same physical frame, marked read-only). Pages are copied only when written, and pages that are never written (such as the text segment) are never copied.

::: example
**Example 11.19 (Fork with CoW).** A process with 1000 pages calls `fork()`. Immediately after fork:

- Parent and child page tables both point to the same 1000 physical frames.
- All 1000 frames are marked read-only in both page tables.
- Memory cost of fork: one page table (a few KB), not 1000 pages.

The child then writes to 3 pages. Each write triggers a CoW fault:
1. OS allocates a new frame.
2. Copies the original page to the new frame.
3. Updates the child's PTE to point to the new frame (read-write).
4. If the original frame now has ref\_count = 1, marks it read-write in the parent's PTE.

Total pages allocated: $1000 + 3 = 1003$ (instead of $1000 + 1000 = 2000$).
:::

::: programmer
**Programmer's Perspective: mmap() in C and Go's Virtual Memory.**

The `mmap()` system call is the primary interface for manipulating virtual memory in user space:

```c
#include <sys/mman.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>

int main(void) {
    /* Anonymous mapping: allocate 4 pages of private memory */
    size_t len = 4 * 4096;
    void *anon = mmap(NULL, len,
                      PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS,
                      -1, 0);
    if (anon == MAP_FAILED) { perror("mmap anon"); return 1; }

    memset(anon, 0x42, len);
    printf("Anonymous mapping at %p, first byte: 0x%02x\n",
           anon, *(unsigned char *)anon);

    /* File-backed mapping: map a file read-only */
    int fd = open("/etc/hostname", O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    void *file_map = mmap(NULL, 4096, PROT_READ,
                          MAP_PRIVATE, fd, 0);
    close(fd);
    if (file_map == MAP_FAILED) { perror("mmap file"); return 1; }

    printf("File mapping at %p: %.40s\n",
           file_map, (char *)file_map);

    munmap(anon, len);
    munmap(file_map, 4096);
    return 0;
}
```

In Go, the runtime uses `mmap` internally (via `runtime.sysAlloc`) to obtain memory from the OS. The Go heap is a large `mmap`'d region divided into 8 KB pages managed by the runtime's page allocator. You can inspect a Go process's virtual memory through `/proc/PID/maps`:

```go
package main

import (
    "fmt"
    "os"
    "runtime"
)

func main() {
    var m runtime.MemStats
    runtime.ReadMemStats(&m)
    fmt.Printf("HeapAlloc:  %d MB\n", m.HeapAlloc/1024/1024)
    fmt.Printf("HeapSys:    %d MB\n", m.HeapSys/1024/1024)
    fmt.Printf("StackSys:   %d MB\n", m.StackSys/1024/1024)

    pid := os.Getpid()
    fmt.Printf("\n/proc/%d/maps (first 20 lines):\n", pid)
    data, _ := os.ReadFile(fmt.Sprintf("/proc/%d/maps", pid))
    lines := 0
    for i, b := range data {
        if b == '\n' {
            lines++
            if lines >= 20 {
                fmt.Print(string(data[:i+1]))
                break
            }
        }
    }
}
```

On Linux, you can also inspect the page-level mapping through `/proc/PID/pagemap`, a binary file where each 64-bit entry describes the physical frame (or swap location) of the corresponding virtual page. Tools like `pagemap` and `page-types` (from the kernel source tree) parse this file to show which pages are resident, swapped, or shared. The `smaps` file (`/proc/PID/smaps`) provides per-region statistics including resident size, shared vs private pages, and swap usage.

```c
/* Read /proc/PID/pagemap to check if a page is resident */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>

#define PAGE_SIZE 4096

int main(void) {
    void *buf = aligned_alloc(PAGE_SIZE, PAGE_SIZE);
    if (!buf) { perror("aligned_alloc"); return 1; }

    *(volatile char *)buf = 'A';  /* Touch to make resident */

    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/pagemap", getpid());
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open pagemap"); return 1; }

    uint64_t vaddr = (uint64_t)buf;
    uint64_t vpn = vaddr / PAGE_SIZE;
    off_t offset = vpn * sizeof(uint64_t);

    uint64_t entry;
    if (pread(fd, &entry, sizeof(entry), offset) != sizeof(entry)) {
        perror("pread"); return 1;
    }

    printf("Virtual address: %p\n", buf);
    printf("Present:  %lu\n", (entry >> 63) & 1);
    printf("Swapped:  %lu\n", (entry >> 62) & 1);
    if ((entry >> 63) & 1)
        printf("PFN:      %lu (phys: 0x%lx)\n",
               entry & ((1ULL << 55) - 1),
               (entry & ((1ULL << 55) - 1)) * PAGE_SIZE);

    close(fd);
    free(buf);
    return 0;
}
```
:::

---

## 11.6 Page Size Trade-offs

The choice of page size has profound implications for system performance.

### 11.6.1 Arguments for Small Pages

- **Less internal fragmentation:** On average, each process wastes half a page in internal fragmentation. Smaller pages mean less waste per allocation.
- **Finer granularity:** More precise control over which memory is in RAM. A process's working set can be represented more accurately.
- **Faster page faults:** Less data to transfer per page fault.
- **Better sharing granularity:** Shared libraries can be shared at a finer granularity.

### 11.6.2 Arguments for Large Pages

- **Smaller page tables:** Fewer entries mean less memory consumed by page tables and less time spent on page table walks.
- **Better TLB coverage:** Each TLB entry covers more memory, reducing TLB misses.
- **More efficient disk I/O:** Disk transfers are more efficient in larger chunks (amortising the seek/rotational latency).
- **Fewer page faults:** Each fault loads more data, so fewer total faults for sequential access.

### 11.6.3 Quantitative Analysis

::: theorem
**Theorem 11.5 (Optimal Page Size).** Let $s$ be the average process size, $e$ be the page table entry size, and $P$ be the page size. The total overhead per process from the page table and internal fragmentation is:

$$\text{Overhead}(P) = \frac{s \cdot e}{P} + \frac{P}{2}$$

The first term is the page table size (number of pages $\times$ entry size). The second term is the expected internal fragmentation (half a page on average). Minimising with respect to $P$:

$$\frac{d}{dP}\left(\frac{se}{P} + \frac{P}{2}\right) = -\frac{se}{P^2} + \frac{1}{2} = 0$$

$$P^* = \sqrt{2se}$$

*Proof.* The second derivative is $2se / P^3 > 0$, confirming a minimum. $\square$
:::

::: example
**Example 11.20 (Optimal Page Size).** Average process size $s = 1$ MB $= 2^{20}$ bytes. PTE size $e = 8$ bytes.

$$P^* = \sqrt{2 \times 2^{20} \times 8} = \sqrt{2^{24}} = 2^{12} = 4096 \text{ bytes} = 4 \text{ KB}$$

This analysis provides one justification for the ubiquitous 4 KB page size. Note that this is a rough estimate --- real workloads have non-uniform process sizes and access patterns that complicate the analysis.
:::

::: example
**Example 11.21 (Optimal Page Size for Large Processes).** Average process size $s = 1$ GB $= 2^{30}$ bytes. PTE size $e = 8$ bytes.

$$P^* = \sqrt{2 \times 2^{30} \times 8} = \sqrt{2^{34}} = 2^{17} = 131{,}072 \text{ bytes} = 128 \text{ KB}$$

For large processes, the optimal page size is much larger than 4 KB. This motivates huge pages (Section 11.7).
:::

### 11.6.4 Common Page Sizes in Practice

| Architecture | Standard Page | Large Page | Huge Page |
|-------------|--------------|------------|-----------|
| x86-64 | 4 KB | 2 MB | 1 GB |
| ARM (AArch64, 4K granule) | 4 KB | 2 MB | 1 GB |
| ARM (AArch64, 16K granule) | 16 KB | 32 MB | -- |
| ARM (AArch64, 64K granule) | 64 KB | 512 MB | -- |
| POWER | 4 KB | 64 KB | 16 MB |
| SPARC | 8 KB | 64 KB | 4 MB |
| RISC-V (Sv39) | 4 KB | 2 MB | 1 GB |

---

## 11.7 Huge Pages and TLB Pressure

::: definition
**Definition 11.20 (Huge Page).** A *huge page* is a page larger than the architecture's standard page size (e.g., 2 MB or 1 GB on x86-64 instead of 4 KB). Huge pages reduce TLB pressure by covering more virtual address space per TLB entry.
:::

The benefit is dramatic. A TLB with 1024 entries covers:

- With 4 KB pages: $1024 \times 4 \text{ KB} = 4$ MB
- With 2 MB pages: $1024 \times 2 \text{ MB} = 2$ GB
- With 1 GB pages: $1024 \times 1 \text{ GB} = 1$ TB

::: example
**Example 11.22 (TLB Miss Rate Reduction).** A database server has a 16 GB working set. TLB: 1024 entries.

With 4 KB pages: working set requires $16 \text{ GB} / 4 \text{ KB} = 4{,}194{,}304$ pages. TLB can hold 1024. Coverage: $4 \text{ MB} / 16 \text{ GB} = 0.024\%$. Frequent TLB misses.

With 2 MB pages: working set requires $16 \text{ GB} / 2 \text{ MB} = 8{,}192$ pages. TLB can hold 1024. Coverage: $2 \text{ GB} / 16 \text{ GB} = 12.5\%$. Significant reduction in misses.

With 1 GB pages: working set requires 16 pages. TLB can hold all 16. Coverage: 100%. Near-zero TLB misses.
:::

The cost of huge pages is increased internal fragmentation. A 2 MB page wastes, on average, 1 MB per allocation. This is acceptable only for large, long-lived allocations.

Huge pages also reduce the number of page table levels traversed on a TLB miss: a 2 MB page eliminates the PT level (translation stops at the PD level), and a 1 GB page eliminates both PT and PD levels.

> **Note:** Linux supports huge pages in two forms: (1) *explicit huge pages* via `hugetlbfs`, configured at boot time with a fixed pool of huge pages, and (2) *Transparent Huge Pages* (THP), where the kernel automatically promotes contiguous 4 KB page regions to 2 MB pages when possible. THP is enabled by default on most Linux distributions but can cause latency spikes during promotion/demotion. Database vendors (PostgreSQL, Redis) often recommend disabling THP due to these latency concerns. We cover THP in detail in Chapter 13.

---

## 11.8 Virtual Memory in Kernel Space

On x86-64 Linux, the virtual address space is split:

- **User space:** 0x0000000000000000 -- 0x00007FFFFFFFFFFF (128 TB)
- **Non-canonical gap:** 0x0000800000000000 -- 0xFFFF7FFFFFFFFFFF
- **Kernel space:** 0xFFFF800000000000 -- 0xFFFFFFFFFFFFFFFF (128 TB)

The kernel maps all of physical memory starting at 0xFFFF888000000000 (the "direct map" or "physmap"). This allows the kernel to access any physical address by simply adding a fixed offset:

$$\text{kernel virtual address} = \text{physical address} + 0\text{xFFFF888000000000}$$

::: definition
**Definition 11.21 (Direct Map).** The *direct map* (or *physmap*) is a region of kernel virtual address space that maps all of physical memory contiguously, with a fixed offset. This allows the kernel to access any physical frame by computing a simple addition, without consulting page tables (beyond the initial translation, which is always cached in the TLB).
:::

The kernel's page tables are shared across all processes: every process's PML4 table has the same entries for the upper half of the address space (indices 256--511). When any process makes a system call and enters kernel mode, the kernel can access its own data structures and any process's physical memory through the direct map.

---

## 11.9 Summary

Virtual memory transforms the rigid, contiguous, limited physical memory into a flexible, vast, per-process logical address space:

- **Demand paging** loads pages only when needed, keeping the page fault rate low to maintain acceptable performance. The EAT formula quantifies the relationship between page fault rate and performance.

- **Page tables** (single-level, multi-level, inverted) map virtual page numbers to physical frame numbers. Modern systems use 4-level or 5-level hierarchical tables to handle 48--57-bit address spaces efficiently. Multi-level tables exploit sparsity to reduce memory consumption dramatically.

- **The TLB** caches recent translations, turning the multi-step page table walk into a single fast lookup for the common case. TLB hit ratios above 99% are typical for well-behaved workloads. ASIDs (PCIDs) eliminate TLB flushes on context switches.

- **Page table entries** carry present, dirty, accessed, protection, and NX bits that the OS uses for demand paging, replacement decisions, and security enforcement.

- **Shared pages** and **copy-on-write** enable efficient memory sharing between processes and fast `fork()` implementation.

- **Page size trade-offs** balance internal fragmentation against page table size and TLB pressure. Huge pages (2 MB, 1 GB) dramatically reduce TLB misses for large working sets.

Chapter 12 addresses the question that demand paging inevitably raises: when physical memory is full and a page must be loaded, which existing page should be evicted? The answer --- page replacement algorithms --- determines whether the system hums along or collapses into thrashing.

---

::: exercises
**Exercise 11.1.** A system has a 48-bit virtual address space, a 40-bit physical address space, and 4 KB pages. (a) How many bits are in the VPN and the page offset? (b) How many entries does a single-level page table require? (c) If each PTE is 8 bytes, what is the total size of the page table? (d) Why is this infeasible, and what is the solution?

**Exercise 11.2.** Consider a two-level page table for a 32-bit address space with 4 KB pages. The Page Directory has 1024 entries and each Page Table has 1024 entries. A process maps the following virtual address ranges: 0x00000000--0x00400000 (code, 4 MB), 0x10000000--0x10100000 (data, 1 MB), 0xBFE00000--0xC0000000 (stack, 2 MB). (a) How many Page Directory entries are valid? (b) How many Page Tables are allocated? (c) What is the total memory consumed by page tables? (d) Compare this to a single-level page table.

**Exercise 11.3.** A TLB has 256 entries and the page size is 4 KB. The TLB hit ratio is 0.98 and the memory access time is 80 ns. The system uses a 4-level page table. (a) Calculate the EAT. (b) What TLB hit ratio is needed for the EAT to be within 5% of the memory access time? (c) If the page size is increased to 2 MB (and the TLB still has 256 entries), what is the new TLB coverage? Discuss qualitatively how this affects the hit ratio for a process with a 32 MB working set.

**Exercise 11.4.** An x86-64 system uses a 4-level page table. A virtual address is 0x00007F0012345678. (a) Extract the PML4 index, PDPT index, PD index, PT index, and page offset. Show your work in binary or hexadecimal. (b) How many memory accesses are needed to translate this address, assuming a TLB miss? (c) If the TLB hit ratio is 0.995, what is the average number of memory accesses per address translation (including the final data access)?

**Exercise 11.5.** Prove that for a $k$-level page table with branching factor $b$ (entries per table), the maximum number of table pages is:

$$\sum_{i=0}^{k-1} b^i = \frac{b^k - 1}{b - 1}$$

For $k = 4$ and $b = 512$ (x86-64), compute this value. Explain why this worst-case is never reached in practice.

**Exercise 11.6.** A process calls `fork()` in a system with copy-on-write. The parent has 8000 pages mapped: 2000 pages of code (read-only), 3000 pages of heap (read-write), 1000 pages of stack (read-write), and 2000 pages of shared library (read-only, shared). After `fork()`, the child modifies 500 heap pages and 200 stack pages. (a) How many physical page copies are made by CoW faults? (b) What is the total number of distinct physical frames used by both parent and child after the child's modifications? (c) If CoW were not used, how many frames would be needed?

**Exercise 11.7.** Derive the optimal page size formula $P^* = \sqrt{2se}$ from the overhead function $f(P) = se/P + P/2$. Then calculate $P^*$ for: (a) $s = 256$ KB, $e = 4$ bytes, (b) $s = 4$ MB, $e = 8$ bytes, (c) $s = 1$ GB, $e = 8$ bytes. Comment on why real systems do not use the optimal page size for case (c) and what mechanism addresses the TLB issue instead.
:::
