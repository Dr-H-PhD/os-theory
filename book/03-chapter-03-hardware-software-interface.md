# Chapter 3: Hardware-Software Interface

The operating system does not float above the hardware as an independent entity. It is welded to the machine at dozens of contact points: privilege rings, interrupt lines, exception vectors, DMA channels, memory-mapped device registers, and timer circuits. Understanding these mechanisms at the hardware level is essential because the OS kernel is, at its core, a program that responds to hardware events. Every context switch, every page fault, every packet received from the network -- all begin with a hardware signal that the kernel must handle correctly, quickly, and without losing any information. This chapter traces each of these mechanisms from the electrical signal to the kernel code that processes it.

We cover six major hardware mechanisms: CPU privilege rings that enforce the kernel/user boundary, interrupts that notify the CPU of external events, exceptions that handle synchronous error conditions, DMA that offloads bulk data transfers from the CPU, I/O buses that connect devices to the system, and timer hardware that drives preemptive scheduling. For each mechanism, we examine the hardware design, the software interface, and the OS design patterns that exploit them.

## CPU Privilege Rings

### The Need for Hardware-Enforced Privilege

Chapter 1 introduced the distinction between kernel mode and user mode. This section examines the hardware mechanisms that enforce it. The fundamental requirement is simple: user-space code must not be able to execute certain instructions (those that modify page tables, disable interrupts, or halt the processor), and any attempt to do so must be trapped by the hardware and reported to the kernel.

Without hardware enforcement, the OS would have to rely on software checks before every privileged operation -- an approach that is both slow (every instruction would need validation) and insecure (a malicious program could jump directly to kernel code, bypassing the checks). Hardware enforcement is automatic, zero-cost on the common path (instructions that are permitted execute at full speed), and inescapable (there is no software trick that can bypass it).

The hardware mechanisms for privilege enforcement vary across processor architectures, but all share the same fundamental design: a processor status register encodes the current privilege level, and the instruction execution logic checks this level before executing any privileged operation.

### x86 Protection Rings

The x86 architecture defines four privilege levels, numbered 0 (most privileged) through 3 (least privileged). These are encoded in the *Current Privilege Level* (CPL) field, which occupies the low two bits of the code segment register (CS).

```text
 x86 PROTECTION RINGS
 ─────────────────────────────────────────────────────────────

            ┌───────────────────────────────┐
            │         Ring 3 (CPL=3)         │
            │      User Applications         │
            │                                │
            │   ┌───────────────────────┐    │
            │   │     Ring 2 (CPL=2)     │    │
            │   │   Device Drivers (*)   │    │
            │   │                        │    │
            │   │  ┌─────────────────┐   │    │
            │   │  │  Ring 1 (CPL=1) │   │    │
            │   │  │  OS Services (*) │   │    │
            │   │  │                  │   │    │
            │   │  │ ┌────────────┐  │   │    │
            │   │  │ │Ring 0      │  │   │    │
            │   │  │ │Kernel      │  │   │    │
            │   │  │ └────────────┘  │   │    │
            │   │  └─────────────────┘   │    │
            │   └───────────────────────┘    │
            └───────────────────────────────┘

  (*) Rings 1 and 2 are defined by the hardware but
      unused by all major operating systems.
      Linux and Windows use only Ring 0 and Ring 3.
 ─────────────────────────────────────────────────────────────
```

In practice, all major x86 operating systems use only two rings:

- **Ring 0** -- kernel mode. The OS kernel, including all drivers and kernel modules, runs here.

- **Ring 3** -- user mode. All user-space applications run here.

Rings 1 and 2 were intended for OS services and device drivers respectively, providing a graduated trust model. However, no mainstream OS uses them for three reasons:

1. The overhead of ring transitions (similar to system call overhead) made the fine-grained ring model impractical. Two ring transitions per driver call (ring 3 $\to$ ring 1 $\to$ ring 0 and back) are more expensive than one (ring 3 $\to$ ring 0).

2. The x86-64 long mode simplifies the privilege model: the segment-based protection mechanisms of rings 1 and 2 are less relevant when paging provides the primary memory protection.

3. Virtualisation extensions (VT-x) added a separate "ring -1" (VMX root mode) for hypervisors, further reducing the need for intermediate rings.

The CPL is checked by the hardware on every memory access and instruction execution:

- If the CPL is 3 and the instruction is privileged (e.g., `CLI` to disable interrupts, `STI` to enable them, `HLT` to halt the processor, `LGDT` to load the GDT, `MOV CR3` to change page tables, `WRMSR` to write model-specific registers), the CPU raises a general protection fault (#GP, vector 13).

- If the CPL is 3 and the memory access targets a page marked as supervisor-only (the U/S bit in the page table entry is 0), the CPU raises a page fault (#PF, vector 14).

- If the CPL is 0, all instructions and all memory addresses are accessible.

> **Note:** **Current Privilege Level (CPL).** The CPL is a 2-bit field stored in the low two bits of the CS (Code Segment) and SS (Stack Segment) registers. It indicates the privilege level of the currently executing code. On x86-64, CPL is 0 for kernel mode and 3 for user mode. The CPL is set by the hardware during ring transitions (system calls, interrupts, exception returns) and cannot be modified directly by software. The hardware also checks the Descriptor Privilege Level (DPL) of segment descriptors and the Requested Privilege Level (RPL) of segment selectors, but these are less relevant in long mode where segmentation is largely disabled.

### The Global Descriptor Table (GDT)

On x86-64, the GDT defines the memory segments used by the OS. Although x86-64 uses a flat memory model (all segments have base 0 and cover the entire address space), the GDT is still required for:

- Defining the kernel code segment (ring 0) and user code segment (ring 3)
- Defining the kernel data segment and user data segment
- Holding the Task State Segment (TSS) descriptor, which points to the kernel stack for each CPU

A minimal GDT for a 64-bit kernel:

```c
/* Minimal x86-64 GDT structure */
struct gdt_entry {
    uint16_t limit_low;
    uint16_t base_low;
    uint8_t  base_mid;
    uint8_t  access;      /* Type, DPL, present bit */
    uint8_t  flags_limit;  /* Flags + limit high nibble */
    uint8_t  base_high;
} __attribute__((packed));

/* 64-bit GDT entries (simplified) */
struct gdt_entry gdt[] = {
    {0},                          /* 0x00: Null descriptor (required) */
    {0, 0, 0, 0x9A, 0x20, 0},   /* 0x08: Kernel code (ring 0, 64-bit) */
    {0, 0, 0, 0x92, 0x00, 0},   /* 0x10: Kernel data (ring 0) */
    {0, 0, 0, 0xFA, 0x20, 0},   /* 0x18: User code (ring 3, 64-bit) */
    {0, 0, 0, 0xF2, 0x00, 0},   /* 0x20: User data (ring 3) */
    /* TSS descriptor follows (16 bytes in 64-bit mode) */
};
```

The access byte encodes the DPL: `0x9A` has DPL=0 (kernel), `0xFA` has DPL=3 (user). When the CPU executes a `SYSCALL` instruction, it loads the kernel CS selector (0x08), setting CPL to 0. When it executes `SYSRET`, it loads the user CS selector (0x18), setting CPL to 3.

### ARM Exception Levels

ARM processors (ARMv8-A and later) use a four-level hierarchy called *Exception Levels* (EL0 through EL3), where higher numbers indicate greater privilege -- the opposite convention from x86.

```text
 ARM EXCEPTION LEVELS
 ─────────────────────────────────────────────────────────────

  EL3: Secure Monitor
       (ARM Trusted Firmware, secure world transitions)
       ┌─────────────────────────────────────────────────┐
       │  Manages transitions between Secure and         │
       │  Non-secure worlds. Runs secure monitor code.   │
       │  Controls which physical addresses are visible   │
       │  to the Normal world.                            │
       └─────────────────────────────────────────────────┘

  EL2: Hypervisor
       (KVM, Xen, or bare-metal hypervisor)
       ┌─────────────────────────────────────────────────┐
       │  Manages virtual machines. Controls stage-2     │
       │  address translation (IPA to PA). Traps         │
       │  sensitive guest operations. Manages virtual    │
       │  interrupts for guests.                          │
       └─────────────────────────────────────────────────┘

  EL1: OS Kernel
       (Linux, Windows, or guest OS)
       ┌─────────────────────────────────────────────────┐
       │  Full OS kernel. Manages processes, memory,     │
       │  devices, file systems. Controls stage-1        │
       │  page tables (VA to IPA or PA).                 │
       └─────────────────────────────────────────────────┘

  EL0: User Applications
       (all unprivileged code)
       ┌─────────────────────────────────────────────────┐
       │  Cannot access system registers. Cannot         │
       │  execute privileged instructions. Restricted    │
       │  to its own virtual address space.              │
       └─────────────────────────────────────────────────┘

  Privilege increases ─────────────────────────────────▶
  EL0         EL1          EL2          EL3
 ─────────────────────────────────────────────────────────────
```

ARM's exception level model is cleaner than x86's ring model for several reasons:

1. **Dedicated hypervisor level (EL2).** Virtualisation is a first-class concept in the architecture, not retrofitted. The hypervisor has its own system registers, its own page table (stage 2 translation), and its own exception handlers, all architecturally distinct from the OS kernel at EL1.

2. **Dedicated secure monitor level (EL3).** The ARM TrustZone architecture provides hardware-enforced isolation between a "secure world" (running trusted firmware, cryptographic operations, DRM) and a "normal world" (running the OS and applications), with EL3 controlling transitions between them. This is used on billions of smartphones for secure boot, key storage, and payment processing.

3. **Clean exception routing.** Each exception level has a dedicated exception vector table (accessed via the VBAR_ELn register), and exceptions are routed to the appropriate level based on their type and the current execution level.

Transitions between exception levels occur through exceptions (interrupts, system calls, faults) and exception returns. The `SVC` instruction (Supervisor Call) transitions from EL0 to EL1 -- the ARM equivalent of x86's `SYSCALL`. The `HVC` instruction (Hypervisor Call) transitions from EL1 to EL2. The `SMC` instruction (Secure Monitor Call) transitions from EL1 or EL2 to EL3. The `ERET` instruction (Exception Return) transitions from a higher EL to a lower one.

Each exception level has its own dedicated system registers:

- `SCTLR_ELn` -- system control register (enables/disables caches, MMU, alignment checks)
- `TTBR0_ELn`, `TTBR1_ELn` -- translation table base registers (page table pointers)
- `VBAR_ELn` -- vector base address register (exception vector table location)
- `SP_ELn` -- stack pointer for exception level $n$

This per-level register bank means that transitioning between exception levels does not require saving and restoring registers to memory -- the hardware provides separate storage at each level.

### RISC-V Privilege Modes

RISC-V, the open-source instruction set architecture, defines three privilege modes:

| Mode | Abbreviation | Typical Use |
|---|---|---|
| Machine mode (M-mode) | M | Firmware, bootloader, most trusted code |
| Supervisor mode (S-mode) | S | OS kernel |
| User mode (U-mode) | U | Applications |

M-mode is always present and has unrestricted access to the hardware. S-mode and U-mode are optional (embedded systems may implement only M-mode). The key architectural features are:

- **Control and Status Registers (CSRs).** Each privilege mode has its own set of CSRs. Attempts to access a CSR belonging to a higher privilege mode trap to that mode. CSRs are accessed via dedicated instructions (`csrrw`, `csrrs`, `csrrc`).

- **Physical Memory Protection (PMP).** M-mode can configure PMP entries that restrict which physical address ranges are accessible in S-mode and U-mode. This provides a coarse-grained protection mechanism that is simpler than paging.

- **Sv39/Sv48 page tables.** S-mode uses a page table format (Sv39 with 39-bit virtual addresses, or Sv48 with 48-bit virtual addresses) that the MMU walks on every memory access, providing fine-grained virtual memory and protection.

- **Trap delegation.** M-mode can delegate specific exception types to S-mode using the `medeleg` and `mideleg` CSRs. For example, page faults can be delegated to S-mode (the OS kernel) while machine timer interrupts are handled in M-mode (firmware).

RISC-V's clean, minimal privilege model makes it attractive for research and for building formally verified systems. Several verified RISC-V processors and OS kernels are under active development.

## Interrupts

### What is an Interrupt?

An interrupt is a hardware signal that asynchronously notifies the CPU that an external event requires attention. When an interrupt arrives, the CPU suspends its current activity, saves minimal state, and transfers control to a predefined handler function.

Interrupts are the heartbeat of an operating system. Without them, the kernel would have to continuously poll every device to check whether it has data ready -- wasting enormous amounts of CPU time. With interrupts, the CPU can execute user programs and be notified only when a device actually needs attention.

> **Note:** **Interrupt.** An asynchronous signal from a hardware device to the CPU, indicating that the device requires service. The CPU responds by suspending the current execution context, saving its state, and transferring control to an interrupt handler (also called an Interrupt Service Routine, or ISR). After the handler completes, the CPU restores the saved state and resumes the interrupted execution. The key property is *asynchrony*: interrupts can arrive between any two instructions, at any time, regardless of what the CPU is currently doing.

### Polling vs Interrupts

Before examining interrupt hardware, it is instructive to understand the alternative: *polling*. In a polled I/O system, the CPU periodically checks each device's status register to see if data is available:

```c
/* Polling loop -- wasteful but simple */
while (1) {
    if (serial_status_reg & DATA_READY) {
        char c = serial_data_reg;
        process_char(c);
    }
    if (disk_status_reg & TRANSFER_COMPLETE) {
        handle_disk_completion();
    }
    if (nic_status_reg & PACKET_RECEIVED) {
        handle_packet();
    }
    /* ... check every device ... */
}
```

Polling has two fundamental problems:

1. **CPU waste.** The CPU spends most of its time checking devices that have nothing to report. On a system with 50 devices where each is active 1% of the time, 98% of polling cycles are wasted.

2. **Latency.** If the polling loop takes 1 ms to cycle through all devices, the worst-case response time to any event is 1 ms. Reducing this by polling more frequently wastes even more CPU time.

Interrupts solve both problems: the CPU does productive work until a device actively signals that it needs attention, and the response latency is bounded by the interrupt delivery time (typically 1--5 $\mu$s), not by a polling cycle.

However, interrupts have their own cost: each interrupt requires saving and restoring CPU state, transitioning to kernel mode, and executing the handler. For very high-rate events (millions of network packets per second), the interrupt overhead can overwhelm the CPU. This is why high-performance systems often use a *hybrid* approach: interrupts for low-rate events, polling for high-rate events. Linux's NAPI (New API) for network drivers uses this strategy: it starts with interrupt-driven reception and switches to polling when the packet rate exceeds a threshold.

### Hardware Interrupt Mechanism

The hardware interrupt delivery path involves multiple components:

```text
 INTERRUPT DELIVERY PATH
 ─────────────────────────────────────────────────────────────

  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
  │  Disk    │  │ Network  │  │ Keyboard │  │  Timer   │
  │Controller│  │  Card    │  │Controller│  │  Chip    │
  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘
       │ IRQ         │ IRQ         │ IRQ         │ IRQ
       │             │             │             │
  ┌────▼─────────────▼─────────────▼─────────────▼─────┐
  │           INTERRUPT CONTROLLER                      │
  │     (APIC on x86, GIC on ARM, PLIC on RISC-V)     │
  │                                                     │
  │  Prioritises interrupts, masks/unmasks lines,       │
  │  routes interrupts to specific CPU cores             │
  └──────────────────────┬──────────────────────────────┘
                         │ INT signal
                         ▼
  ┌──────────────────────────────────────────────────────┐
  │                     CPU CORE                          │
  │                                                       │
  │  1. Finish current instruction                        │
  │  2. Check IF (Interrupt Flag) in RFLAGS              │
  │  3. If IF=1: save RIP, RFLAGS, CS, SS on stack      │
  │  4. Clear IF to mask further interrupts              │
  │  5. Read vector number from interrupt controller     │
  │  6. Look up handler address in IDT[vector]           │
  │  7. Jump to handler (ring 0)                         │
  └──────────────────────────────────────────────────────┘
 ─────────────────────────────────────────────────────────────
```

On x86 systems, the *Advanced Programmable Interrupt Controller* (APIC) manages interrupt delivery. The APIC architecture has two components:

- **Local APIC (LAPIC).** Each CPU core has its own LAPIC, which receives interrupts from the I/O APIC, from other CPUs (inter-processor interrupts, IPIs), and from its own timer. The LAPIC is accessed through memory-mapped registers at a fixed physical address (typically 0xFEE00000).

- **I/O APIC.** One or more I/O APICs aggregate interrupt lines from external devices. Each I/O APIC has a *redirection table* that maps device interrupt lines to specific vectors and target CPU cores. The OS configures the redirection table to balance interrupt load across cores.

Each interrupt is assigned a *vector number* (0--255 on x86). Vectors 0--31 are reserved for CPU exceptions (page faults, division by zero, etc.). Vectors 32--255 are available for hardware interrupts. The vector number indexes into the *Interrupt Descriptor Table* (IDT), which maps each vector to a handler address.

### The Interrupt Descriptor Table (IDT)

The IDT is an array of 256 *gate descriptors*, each specifying:

- The address of the handler function (64 bits in long mode, split across three fields)
- The code segment selector (which determines the privilege level for the handler)
- The gate type: interrupt gate (clears IF, preventing nested interrupts) or trap gate (leaves IF unchanged)
- The IST (Interrupt Stack Table) index: if non-zero, the CPU switches to a dedicated stack before invoking the handler, providing a known-good stack even when the interrupted task's stack is corrupted

The IDT base address and limit are stored in the IDTR register, which is loaded by the `LIDT` instruction (a privileged instruction, executable only in ring 0).

```c
/* x86-64 IDT entry structure */
struct idt_entry {
    uint16_t offset_low;      /* Handler address bits 0-15 */
    uint16_t segment_sel;     /* Code segment selector (0x08 for kernel) */
    uint8_t  ist;             /* Interrupt Stack Table index (0-7) */
    uint8_t  type_attr;       /* Type (0xE=interrupt gate, 0xF=trap gate) */
                              /* + DPL (0=kernel, 3=user) + Present bit */
    uint16_t offset_mid;      /* Handler address bits 16-31 */
    uint32_t offset_high;     /* Handler address bits 32-63 */
    uint32_t reserved;        /* Must be zero */
} __attribute__((packed));

/* Set up an IDT entry */
void set_idt_entry(struct idt_entry *idt, int vector,
                   void (*handler)(void), uint8_t ist,
                   uint8_t type, uint8_t dpl) {
    uint64_t addr = (uint64_t)handler;
    idt[vector].offset_low  = addr & 0xFFFF;
    idt[vector].segment_sel = 0x08;  /* Kernel code segment */
    idt[vector].ist         = ist;
    idt[vector].type_attr   = type | (dpl << 5) | 0x80; /* Present=1 */
    idt[vector].offset_mid  = (addr >> 16) & 0xFFFF;
    idt[vector].offset_high = (addr >> 32) & 0xFFFFFFFF;
    idt[vector].reserved    = 0;
}

/* Install IDT */
struct {
    uint16_t limit;
    uint64_t base;
} __attribute__((packed)) idtr;

void install_idt(struct idt_entry *idt) {
    idtr.limit = sizeof(struct idt_entry) * 256 - 1;
    idtr.base  = (uint64_t)idt;
    asm volatile("lidt %0" : : "m"(idtr));
}
```

### Interrupt Handling Flow

When a hardware interrupt arrives at vector $n$, the CPU performs the following sequence atomically (i.e., it cannot be interrupted mid-sequence):

1. **Save context.** Push the current values of SS, RSP, RFLAGS, CS, and RIP onto the *kernel stack* (pointed to by the TSS -- Task State Segment, or an IST stack if specified).

2. **Disable interrupts.** If the IDT entry is an interrupt gate, clear the IF (Interrupt Flag) in RFLAGS, preventing nested interrupts.

3. **Load handler.** Read `IDT[n]` to obtain the handler address and segment selector.

4. **Transfer control.** Set CS and RIP from the IDT entry, switching to ring 0 if not already there. If the CPL changed (from 3 to 0), the CPU also switches to the kernel stack.

The handler then executes. When it finishes, it executes `IRETQ` (Interrupt Return), which atomically restores SS, RSP, RFLAGS, CS, and RIP from the stack, returning to the interrupted code (and ring 3 if appropriate).

The total number of CPU cycles consumed by an interrupt entry and return (without the handler itself) is approximately 200--500 cycles on a modern x86-64 processor, depending on whether a privilege level change occurs and whether the TLB must be flushed (KPTI).

> **Info:** The distinction between *interrupt gates* and *trap gates* in the IDT concerns whether interrupts are automatically disabled upon entry. An interrupt gate clears the IF flag, preventing nested interrupts. A trap gate leaves IF unchanged, allowing other interrupts to preempt the handler. Hardware interrupt handlers typically use interrupt gates (to prevent re-entrant interrupt handling that could corrupt shared data structures), while system call handlers and breakpoint handlers may use trap gates (to allow interrupts during long-running operations). The choice affects both correctness (preventing re-entrancy bugs) and latency (interrupt masking duration).

### Message Signalled Interrupts (MSI/MSI-X)

Traditional interrupts use dedicated physical interrupt lines (wires) between devices and the interrupt controller. MSI (Message Signalled Interrupts), introduced with PCI 2.2 and extended by MSI-X, replaces physical lines with *memory writes*: to signal an interrupt, the device writes a specific value to a specific address (both configured by the OS). The memory write is routed by the system's memory address decoder to the LAPIC, which interprets it as an interrupt.

MSI-X advantages:

- **More vectors.** MSI-X supports up to 2048 interrupt vectors per device, vs 4 for MSI and 24 for legacy I/O APIC lines. This allows a modern NVMe SSD with 128 queues to have a dedicated interrupt vector per queue, one per CPU core.

- **No sharing.** Each MSI-X vector is unique to a device, eliminating the need for interrupt sharing (where the handler must poll all devices sharing the same line to find which one interrupted).

- **Better performance.** MSI-X interrupts can target specific CPU cores directly, without routing through the I/O APIC, reducing delivery latency.

### Software Interrupts (Traps)

In addition to hardware interrupts generated by devices, the CPU can generate *software interrupts* through explicit instructions:

- `INT n` -- invoke interrupt handler at vector $n$. Used historically for system calls on 32-bit Linux (`INT 0x80`).

- `SYSCALL` / `SYSENTER` -- optimised system call instructions that bypass the IDT entirely, using dedicated MSRs for the handler address. `SYSCALL` stores the return address in RCX and RFLAGS in R11, avoiding memory accesses.

- `SVC` (ARM) -- Supervisor Call, the ARM equivalent of x86's `SYSCALL`.

- `ECALL` (RISC-V) -- Environment Call, transitions from U-mode to S-mode (or from S-mode to M-mode).

Software interrupts have the same effect as hardware interrupts: they save state and transfer control to a handler in kernel mode. The difference is that software interrupts are *synchronous* -- they occur at a specific point in the instruction stream, predictably -- while hardware interrupts are *asynchronous*.

> **Programmer:** On Linux, you can examine the interrupt counts for every vector on every CPU core by reading `/proc/interrupts`. Run `watch -n 1 cat /proc/interrupts` on a Linux system and you will see the counters incrementing in real time. The `LOC` (Local timer) row shows the scheduler timer interrupts -- typically 250--1000 per second per core, depending on the kernel's `CONFIG_HZ` setting and whether the tickless mode is active. The `RES` (Rescheduling) row shows inter-processor interrupts (IPIs) used by the scheduler to wake up idle cores when new work arrives. The `NMI` (Non-Maskable Interrupt) row shows interrupts that cannot be disabled by software -- used for watchdog timers and performance monitoring. Monitoring `/proc/interrupts` over time reveals the interrupt load distribution across cores and can diagnose performance issues like "interrupt storms" (one device flooding the CPU with interrupts) or unbalanced interrupt routing (one core handling all network interrupts while others are idle). On a server handling heavy network traffic, you can use `irqbalance` to distribute interrupt load, or manually configure IRQ affinity via `/proc/irq/N/smp_affinity`.

### Top-Half and Bottom-Half Processing

Hardware interrupt handlers face a fundamental tension: they must complete quickly (because interrupts are disabled during the handler, blocking other devices from being serviced) but some interrupt processing requires significant work (e.g., reassembling a fragmented network packet, updating file system metadata after a disk write, processing USB enumeration events).

Linux resolves this with a *split interrupt handling* model:

**Top half (hardirq).** The interrupt handler runs in *interrupt context* with interrupts disabled on the current CPU. It does the absolute minimum: acknowledge the device (clear its interrupt status register), copy data from device registers or DMA buffers to kernel memory, and schedule deferred work. The top half must not sleep, must not allocate memory with `GFP_KERNEL`, and must not take any sleeping lock (mutex). It may only take spinlocks.

**Bottom half (softirq / tasklet / workqueue).** Deferred processing runs later, with interrupts re-enabled. It performs the expensive work: network protocol processing (TCP reassembly, checksum verification), buffer management, and waking up waiting processes.

```text
 SPLIT INTERRUPT HANDLING
 ─────────────────────────────────────────────────────────────

  Hardware interrupt arrives
        │
        ▼
  ┌──────────────────────────┐
  │     TOP HALF (hardirq)    │  Interrupts DISABLED
  │                           │  Must be fast (<100 us)
  │  - Acknowledge device     │  Cannot sleep
  │  - Read device registers  │  Cannot allocate (GFP_KERNEL)
  │  - Copy DMA data          │  Can only take spinlocks
  │  - Schedule bottom half   │
  └────────────┬──────────────┘
               │
        IRETQ (interrupts re-enabled)
               │
               ▼
  ┌──────────────────────────┐
  │   BOTTOM HALF (softirq)   │  Interrupts ENABLED
  │                           │  Can do substantial work
  │  - Protocol processing    │  Can allocate memory
  │  - Reassemble packets     │  Runs in softirq context
  │  - Wake waiting processes │  (still cannot sleep)
  └──────────────────────────┘
 ─────────────────────────────────────────────────────────────
```

Linux provides three bottom-half mechanisms, in order of increasing flexibility:

| Mechanism | Context | Can Sleep? | Serialisation | Typical Use |
|---|---|---|---|---|
| Softirq | Interrupt (softirq) | No | Per-CPU (same softirq can run on different CPUs) | Network RX/TX, block I/O, timer callbacks |
| Tasklet | Interrupt (softirq) | No | Per-tasklet (same tasklet never runs on two CPUs) | Simple deferred work for a specific device |
| Workqueue | Process (kworker) | Yes | Configurable | Complex work requiring memory allocation or sleeping |

Softirqs are the most performance-critical: Linux defines exactly 10 softirq types (including `NET_RX_SOFTIRQ`, `NET_TX_SOFTIRQ`, `BLOCK_SOFTIRQ`, `TIMER_SOFTIRQ`), each processing work for all devices of that type on the current CPU. Softirqs are checked and executed at strategic points: after interrupt handlers return, after system calls, and by the `ksoftirqd` kernel thread when the softirq load is heavy.

The `kworker` threads that execute workqueue items are visible in `ps` output. Each CPU has its own `kworker/N:M` threads, plus system-wide `kworker/u:N` threads for unbound work items. When you see `kworker` threads consuming CPU in `top`, they are executing deferred interrupt processing or other asynchronous kernel work.

## Exceptions: Faults, Traps, and Aborts

### Exception Classification

Exceptions are synchronous events generated by the CPU during instruction execution. Unlike interrupts (which are asynchronous and external), exceptions are caused by the currently executing instruction and are deterministic: the same instruction in the same state always produces the same exception.

The x86 architecture classifies exceptions into three categories:

**Faults.** The exception is reported *before* the faulting instruction completes (or after partial execution that can be rolled back). The saved instruction pointer (RIP) points to the faulting instruction, so the handler can fix the problem and re-execute the instruction. The canonical example is a page fault: the MMU detects that a page is not present, the page fault handler loads the page from disk, and the faulting instruction is re-executed -- this time successfully.

**Traps.** The exception is reported *after* the trapping instruction completes. The saved RIP points to the *next* instruction. Traps are used for debugging (the `INT3` breakpoint instruction, which is a single-byte opcode `0xCC`) and system calls (the `SYSCALL` instruction on x86-64).

**Aborts.** The exception indicates an unrecoverable error (hardware failure, inconsistent internal state). The faulting instruction cannot be identified or restarted. Aborts typically result in system termination. The canonical example is a machine check exception (#MC, vector 18), which indicates a hardware error such as an uncorrectable memory ECC failure or a CPU microcode bug.

> **Note:** **Page Fault.** A page fault (vector 14 on x86) occurs when the CPU attempts to access a virtual address that is either not mapped in the page table, mapped with insufficient permissions, or marked as not present. The page fault handler examines the faulting address (stored in the CR2 register on x86) and the error code (pushed onto the stack by the CPU) to determine the cause and take appropriate action: load the page from disk, allocate a new page, send SIGSEGV to the process, or trigger a kernel panic.

### x86 Exception Vectors

The first 32 IDT vectors (0--31) are reserved for CPU exceptions:

| Vector | Mnemonic | Type | Cause |
|---|---|---|---|
| 0 | #DE | Fault | Division by zero or division overflow |
| 1 | #DB | Fault/Trap | Debug (hardware breakpoint, single-step) |
| 2 | NMI | Interrupt | Non-Maskable Interrupt (hardware failure, watchdog) |
| 3 | #BP | Trap | Breakpoint (`INT3`, single-byte `0xCC`) |
| 6 | #UD | Fault | Undefined/invalid opcode |
| 8 | #DF | Abort | Double fault (exception during exception handling) |
| 10 | #TS | Fault | Invalid TSS |
| 11 | #NP | Fault | Segment not present |
| 12 | #SS | Fault | Stack-segment fault |
| 13 | #GP | Fault | General protection (privilege violation, bad selector) |
| 14 | #PF | Fault | Page fault |
| 18 | #MC | Abort | Machine check (uncorrectable hardware error) |
| 19 | #XM | Fault | SIMD floating-point exception |

### The Page Fault Handler in Detail

The page fault is the most important exception in a modern OS because it is the mechanism that implements demand paging, copy-on-write, memory-mapped files, and lazy allocation. When a page fault occurs, the CPU provides two pieces of information:

1. **The faulting address** -- stored in the CR2 register (x86) or the FAR_ELn register (ARM). This is the virtual address that the instruction tried to access.

2. **The error code** -- pushed onto the stack (x86), with bit flags:
   - Bit 0 (P): 0 = page not present, 1 = protection violation
   - Bit 1 (W): 0 = read access, 1 = write access
   - Bit 2 (U): 0 = kernel mode, 1 = user mode
   - Bit 3 (RSVD): 1 = reserved bit violation in page table
   - Bit 4 (I): 1 = instruction fetch (NX violation)

The kernel's page fault handler then classifies the fault:

```text
 PAGE FAULT CLASSIFICATION
 ─────────────────────────────────────────────────────────────

  Page fault at address A, error code E
        │
        ├── Is A in the process's valid VMA (vm_area_struct)?
        │   │
        │   ├── NO
        │   │   ├── Is A just below the stack VMA?
        │   │   │   ├── YES ──▶ Stack growth
        │   │   │   │          (expand VMA, allocate page)
        │   │   │   └── NO ──▶ SEGFAULT (send SIGSEGV)
        │   │   │
        │   └── YES
        │       │
        │       ├── P=0 (page not present)
        │       │   ├── Anonymous mapping ──▶ Allocate zero page
        │       │   ├── File mapping ──▶ Read page from file
        │       │   └── Swapped out ──▶ Read page from swap
        │       │
        │       ├── P=1, W=1 (write to read-only page)
        │       │   ├── COW page ──▶ Copy page, mark writable
        │       │   └── Truly read-only ──▶ SEGFAULT
        │       │
        │       └── P=1, I=1 (exec on NX page) ──▶ SEGFAULT
 ─────────────────────────────────────────────────────────────
```

A simplified page fault handler:

```c
/* Simplified page fault handler (conceptual) */
void page_fault_handler(struct interrupt_frame *frame,
                        uint64_t error_code) {
    uint64_t fault_addr;
    asm volatile("mov %%cr2, %0" : "=r"(fault_addr));

    struct process *proc = current_process();
    struct vm_area *vma = find_vma(proc->mm, fault_addr);

    /* Check if the address is in a valid VMA */
    if (vma == NULL) {
        /* Maybe stack growth? */
        if (fault_addr >= proc->mm->stack_vma->start - PAGE_SIZE
            && fault_addr < proc->mm->stack_vma->start) {
            expand_stack(proc->mm, fault_addr);
            return;  /* Re-execute faulting instruction */
        }
        send_signal(proc, SIGSEGV);
        return;
    }

    /* Permission check */
    if (error_code & PF_WRITE) {
        if (!(vma->prot & PROT_WRITE)) {
            send_signal(proc, SIGSEGV);
            return;
        }
    }

    /* Page not present -- determine type */
    struct page *new_page;

    if (vma->flags & VM_COW && (error_code & PF_WRITE)) {
        /* Copy-on-write fault */
        struct page *old_page = get_page_at(proc->mm, fault_addr);
        new_page = alloc_page(GFP_USER);
        memcpy(page_to_virt(new_page),
               page_to_virt(old_page), PAGE_SIZE);
        map_page(proc->mm->pgd, fault_addr,
                 new_page, vma->prot);
        put_page(old_page);  /* Decrement reference count */
    } else if (vma->flags & VM_FILE) {
        /* Memory-mapped file */
        new_page = alloc_page(GFP_USER);
        read_page_from_file(vma->file,
                           fault_addr - vma->start,
                           new_page);
        map_page(proc->mm->pgd, fault_addr,
                 new_page, vma->prot);
    } else {
        /* Anonymous mapping -- zero-fill */
        new_page = alloc_page(GFP_USER | __GFP_ZERO);
        map_page(proc->mm->pgd, fault_addr,
                 new_page, vma->prot);
    }
    /* Return from handler; CPU re-executes faulting instruction */
}
```

> **Programmer:** Page faults are not errors -- they are a normal part of program execution. When you start a Go program, the binary is memory-mapped into the process's address space via `mmap()`, but no pages are actually loaded into RAM. As the program executes, each new code page triggers a page fault, and the kernel loads it from disk on demand. You can observe this with `perf stat -e page-faults ./myprogram` -- even a simple "Hello, World" program generates hundreds of page faults. The Go runtime's memory allocator (`runtime.mallocgc`) allocates virtual address space liberally using `mmap` with `MAP_ANONYMOUS`, but physical pages are not committed until the program actually writes to them. This means a Go program's virtual memory size (VIRT in `top`) can be much larger than its resident set size (RES) -- the difference is pages that are mapped but have not yet been faulted in. Understanding this distinction is crucial for capacity planning: a Go program showing 1 GB of VIRT but 50 MB of RES is using 50 MB of physical RAM, not 1 GB. The `MADV_DONTNEED` advice via `madvise()` tells the kernel to drop specific pages from RAM, and the Go runtime uses this aggressively to return unused heap memory to the OS.

### Double Faults and Triple Faults

A *double fault* (#DF, vector 8) occurs when the CPU encounters an exception while trying to invoke the handler for a prior exception. Specifically, a double fault is raised when:

- A page fault occurs while trying to deliver a page fault, general protection fault, or invalid TSS exception.
- A general protection fault occurs while trying to deliver a page fault, general protection fault, or invalid TSS exception.

For example, if a page fault occurs, the CPU tries to invoke the page fault handler at the address in `IDT[14]`. If that handler's code page is itself not present (another page fault), or if the kernel stack is corrupted (a stack segment fault), the CPU raises a double fault instead.

A *triple fault* occurs when an exception occurs during the double fault handler itself. The CPU's response to a triple fault is architectural: the processor resets, effectively rebooting the machine. Triple faults are the x86's mechanism of last resort when the exception handling infrastructure itself is broken.

To prevent double faults from causing triple faults, the x86-64 architecture provides the *Interrupt Stack Table* (IST). The IST is a set of up to 7 dedicated stack pointers stored in the TSS. Each IDT entry can specify an IST index; when the corresponding exception occurs, the CPU switches to the IST-specified stack before pushing the exception frame. The double fault handler is always configured to use an IST stack, ensuring it has a valid stack even when the normal kernel stack is corrupted or exhausted.

Linux configures IST stacks for:

- Double fault (#DF) -- IST 1
- NMI -- IST 2 (NMIs can arrive at any time, including during other exception handlers)
- Machine check (#MC) -- IST 3
- Debug (#DB) -- IST 4

## Direct Memory Access (DMA)

### The Problem: CPU-Mediated I/O

Without DMA, every byte transferred between a device and memory must pass through the CPU. The CPU executes a loop: read a byte from the device's data register (a memory-mapped I/O address), write it to memory, increment the pointer, check whether the transfer is complete. This is called *Programmed I/O* (PIO).

For a simple keyboard, PIO is adequate -- keystrokes arrive at most a few hundred times per second, and each transfer is a single byte. But for a disk transferring megabytes per second or a network card processing millions of packets, PIO wastes enormous amounts of CPU time on mindless data copying.

```text
 PROGRAMMED I/O (PIO) vs DMA
 ─────────────────────────────────────────────────────────────

 PIO: CPU copies every byte

  Device ───byte──▶ CPU ───byte──▶ Memory
  Device ───byte──▶ CPU ───byte──▶ Memory
  Device ───byte──▶ CPU ───byte──▶ Memory
  ... (thousands of iterations for one disk block)

  CPU utilisation: 100% during transfer.
  Cannot execute user programs.
  For a 1 GB/s SSD: CPU would spend entire time copying.

 DMA: Device writes directly to memory

  CPU: "Transfer 4096 bytes from disk to address 0x1A3C000"
       │ (one MMIO write to program DMA controller)
       │
       │ CPU is FREE to run user programs
       │
       ▼
  DMA Controller ───────────────────────▶ Memory
  (autonomous transfer over memory bus)
       │
       ▼
  Interrupt: "Transfer complete"
       │
       ▼
  CPU: Process transferred data
 ─────────────────────────────────────────────────────────────
```

The performance difference is dramatic. Consider copying 4 KB from a device to memory:

- **PIO**: 4096 `inb`/`outb` operations at ~100 ns each = 410 $\mu$s, CPU busy the entire time.
- **DMA**: 1 MMIO write to start transfer (~200 ns) + transfer time over bus (~1 $\mu$s at PCIe speed) + 1 interrupt (~2 $\mu$s) = ~3 $\mu$s total, CPU free during the transfer.

DMA reduces the CPU overhead of a 4 KB transfer by approximately 100x.

### How DMA Works

DMA allows hardware devices to read from and write to main memory *without CPU intervention*. The CPU initiates the transfer by programming the DMA controller with:

1. **Source address** -- the device register (for device-to-memory reads) or memory address (for memory-to-device writes).
2. **Destination address** -- the memory address (for reads) or device register (for writes).
3. **Transfer length** -- the number of bytes to transfer.
4. **Direction** -- device-to-memory (read) or memory-to-device (write).
5. **Transfer mode** -- single-cycle (one word per bus request), burst (multiple words in a continuous burst), or block (entire transfer without releasing the bus).

Once programmed, the DMA controller takes ownership of the memory bus and performs the transfer autonomously. The CPU can execute other instructions concurrently, as long as they do not require the memory bus. When the transfer completes, the controller raises an interrupt to notify the CPU.

### DMA and Cache Coherence

DMA introduces a subtle but critical problem: the DMA controller writes directly to physical memory, bypassing the CPU's cache hierarchy. If the CPU has cached a copy of the memory region being written by DMA, the cached copy becomes stale -- a *cache coherence* problem.

Consider the sequence:

1. CPU reads address $A$ -- value 42 is loaded into the L1 cache.
2. DMA writes value 99 to address $A$ in physical memory.
3. CPU reads address $A$ again -- gets 42 from cache, not 99 from memory.

$$
\text{If } \text{cache}[A] \neq \text{memory}[A] \text{ after DMA write, the CPU reads stale data.}
$$

Two solutions exist:

**Cache-coherent DMA.** On systems with hardware cache coherence for DMA (most modern x86 systems and ARM systems with coherent interconnects like ACE/CCI), the DMA controller participates in the cache coherence protocol. DMA writes snoop the CPU caches and invalidate corresponding cache lines, ensuring the CPU always sees fresh data. This is transparent to software but requires hardware support in the interconnect fabric.

**Non-coherent DMA.** On systems without hardware DMA coherence (some ARM SoCs, many embedded systems), the OS must manually manage coherence through cache maintenance operations:

- Before a device-to-memory DMA read: *invalidate* the CPU cache lines covering the target memory region, forcing the CPU to re-read from memory after the transfer.
- Before a memory-to-device DMA write: *flush* (clean) the CPU cache lines covering the source region, writing modified data from cache back to memory so the device reads current data.

The Linux DMA API abstracts these operations:

```c
/* Allocate DMA-coherent memory (always consistent, no manual sync) */
void *buf = dma_alloc_coherent(dev, 4096, &dma_handle, GFP_KERNEL);
/* buf:        kernel virtual address
 * dma_handle: physical address for programming the device */

/* Alternatively, map existing memory for DMA (streaming) */
dma_addr_t dma_addr = dma_map_single(dev, kbuf, len,
                                     DMA_FROM_DEVICE);
/* ... device performs DMA ... */
dma_unmap_single(dev, dma_addr, len, DMA_FROM_DEVICE);
/* After unmap, cache is synchronised and CPU can read the data */
```

> **Tip:** The `dma-buf` subsystem in Linux allows DMA buffers to be shared between devices -- for example, a camera can capture a frame into a DMA buffer that is then handed directly to a GPU for processing, then to a display controller for rendering, all without the CPU ever copying the pixel data. This *zero-copy* pipeline is essential for real-time video processing and is used extensively on Android devices.

### Scatter-Gather DMA

Simple DMA transfers a contiguous block of physical memory. But real data is often scattered across non-contiguous physical pages (because the OS uses paging, and virtual memory is contiguous but physical memory is not).

*Scatter-gather DMA* allows the DMA controller to process a list of (address, length) pairs -- called a *scatter-gather list* (SGL) -- in a single operation:

```text
 SCATTER-GATHER DMA
 ─────────────────────────────────────────────────────────────

  SGL (array of {phys_addr, length} entries):

  [0] addr=0x1A000  len=4096  ──▶ Physical page at frame 0x1A
  [1] addr=0x2B000  len=4096  ──▶ Physical page at frame 0x2B
  [2] addr=0x0F000  len=2048  ──▶ Physical page at frame 0x0F

  DMA controller processes all entries sequentially,
  assembling contiguous device data from scattered pages.

  Total transfer: 10,240 bytes across 3 non-contiguous pages.
  Without scatter-gather: 3 separate DMA operations required.
 ─────────────────────────────────────────────────────────────
```

Scatter-gather is critical for performance: without it, the OS would need to either allocate physically contiguous memory for every DMA buffer (expensive, fragmentation-prone, and sometimes impossible on systems with fragmented physical memory) or perform multiple DMA transfers (one per page), each requiring a separate interrupt.

### IOMMUs: DMA with Protection

On a system without an IOMMU (I/O Memory Management Unit), a device performing DMA can read from or write to *any* physical memory address. A malicious or buggy device (or driver) could corrupt kernel data, read other processes' memory, or inject code into the kernel.

The IOMMU (Intel VT-d, AMD-Vi, ARM SMMU) provides address translation and access control for DMA, analogous to how the CPU's MMU provides address translation for CPU memory accesses:

```text
 IOMMU OPERATION
 ─────────────────────────────────────────────────────────────

  Without IOMMU:
  Device ──DMA addr──▶ Physical Memory (any address!)

  With IOMMU:
  Device ──DMA addr──▶ IOMMU ──translated──▶ Physical Memory
                        │
                   I/O Page Table
                   (configured by OS,
                    restricts device access
                    to authorised regions)
 ─────────────────────────────────────────────────────────────
```

IOMMUs are essential for:

- **Device isolation in virtualisation.** Each virtual machine is assigned specific devices via PCI passthrough (VFIO), and the IOMMU ensures the device can only access that VM's memory, not the hypervisor's or other VMs' memory.

- **Driver bug containment.** A buggy driver that programs incorrect DMA addresses is confined to its IOMMU domain. The DMA transaction faults at the IOMMU, generating an IOMMU fault report, rather than corrupting arbitrary memory.

- **User-space device drivers.** Frameworks like DPDK and SPDK allow user-space programs to directly control PCIe devices. The IOMMU ensures these programs cannot corrupt kernel or other processes' memory via DMA -- only the pages explicitly mapped into the IOMMU domain are accessible.

## I/O Buses and Device Communication

### The Modern Bus Hierarchy

Modern computer systems organise I/O devices into a hierarchy of buses, each with different bandwidth, latency, and protocol characteristics:

```text
 MODERN BUS HIERARCHY (x86 Desktop/Server)
 ─────────────────────────────────────────────────────────────

  ┌───────────┐                    ┌───────────┐
  │   CPU 0   │────────────────────│   CPU 1   │
  └─────┬─────┘   UPI / Infinity  └─────┬─────┘
        │         Fabric (CPU link)       │
        │                                 │
  ┌─────┴─────────────────────────────────┴─────┐
  │            PCIe Root Complex                  │
  │    (integrated in CPU die)                    │
  └───┬──────┬──────┬──────┬──────┬─────────────┘
      │      │      │      │      │
  ┌───┴──┐┌──┴──┐┌──┴──┐┌──┴──┐┌──┴──────────┐
  │ GPU  ││NVMe ││ NIC ││NVMe ││   Chipset   │
  │PCIe  ││ SSD ││10GbE││ SSD ││   (PCH)     │
  │ x16  ││ x4  ││ x4  ││ x4  │└──┬──┬──┬────┘
  └──────┘└─────┘└─────┘└─────┘   │  │  │
                                   │  │  └── SATA (HDD/SSD)
                                   │  │
                                   │  └── USB 3.x Hub
                                   │       ├── Keyboard
                                   │       ├── Mouse
                                   │       └── External Drive
                                   │
                                   └── Low-speed buses
                                        (SPI, LPC, SMBus)
                                        ├── BIOS Flash
                                        ├── TPM
                                        └── Fan/Temp sensors
 ─────────────────────────────────────────────────────────────
```

### PCI Express (PCIe)

PCIe is the primary high-speed bus in modern computers. Unlike older parallel buses (PCI, ISA), PCIe uses *serial point-to-point links*, where each device has a dedicated connection to a PCIe switch or the root complex.

Key characteristics:

- **Lanes.** Each PCIe link consists of one or more lanes (x1, x2, x4, x8, x16). Each lane is a pair of differential signal pairs (one for transmit, one for receive), providing full-duplex communication.

- **Bandwidth per lane by generation:**

| Generation | Per-lane bandwidth (each direction) | x16 total |
|---|---|---|
| PCIe 3.0 | 1 GB/s | 16 GB/s |
| PCIe 4.0 | 2 GB/s | 32 GB/s |
| PCIe 5.0 | 4 GB/s | 64 GB/s |
| PCIe 6.0 | 8 GB/s | 128 GB/s |

- **Transaction layer.** PCIe uses a packet-based protocol with three layers: Transaction Layer (TLP -- Transaction Layer Packets for memory reads/writes, I/O, configuration), Data Link Layer (CRC error detection, flow control, retry), and Physical Layer (electrical signalling, encoding).

- **Enumeration.** At boot time, the firmware and/or OS scans the PCIe bus tree by reading configuration space registers at each possible device address (bus:device:function). The `lspci` command on Linux displays this tree, showing every discovered device with its vendor ID, device ID, and resource allocations.

### NVMe: A Modern Storage Interface

NVMe (Non-Volatile Memory Express) is a storage protocol designed specifically for PCIe-attached SSDs, replacing the legacy AHCI protocol designed for spinning disks.

NVMe achieves high performance through:

- **Massive parallelism.** NVMe supports up to 65,535 I/O queues, each with up to 65,536 entries. This allows different CPU cores to submit I/O independently, without any locking or synchronisation.

- **Submission/completion model.** The OS writes I/O commands to submission queues and reads completions from completion queues. Both are ring buffers in host memory, accessed by the device via DMA. The only synchronisation points are doorbell writes (host to device, via MMIO) to notify the device of new commands, and completion entries (device to host, via DMA) to report results.

```text
 NVMe COMMAND SUBMISSION FLOW
 ─────────────────────────────────────────────────────────────

  Host Memory:
  ┌───────────────────────────────────────────┐
  │ Submission Queue 0 (Admin)                │
  │ [cmd][cmd][   ][   ][   ][   ]            │
  └───────────────────────────────────────────┘

  ┌───────────────────────────────────────────┐
  │ Submission Queue 1 (I/O, CPU core 0)      │
  │ [cmd][cmd][cmd][   ][   ][   ]            │──▶ DMA read
  └───────────────────────────────────────────┘    by NVMe SSD
                                                       │
  ┌───────────────────────────────────────────┐        │
  │ Completion Queue 1                        │        │
  │ [cpl][   ][   ][   ][   ][   ]            │◀── DMA write
  └───────────────────────────────────────────┘    by NVMe SSD

  1. Host writes command to SQ tail
  2. Host writes SQ tail doorbell (MMIO)
  3. Device reads command via DMA
  4. Device processes I/O
  5. Device writes completion to CQ via DMA
  6. Device raises MSI-X interrupt
  7. Host reads completion, processes result
  8. Host writes CQ head doorbell (MMIO)
 ─────────────────────────────────────────────────────────────
```

- **Minimal CPU involvement.** Each I/O command requires exactly: one memory write (the command, 64 bytes), one MMIO write (the doorbell, 4 bytes), and one memory read (the completion, 16 bytes). Compare this to AHCI, which requires reading and writing multiple device registers per command.

The result: a modern NVMe SSD can sustain millions of IOPS (I/O operations per second) with queue depths of hundreds, while AHCI is limited to 32 outstanding commands per port and achieves at most a few hundred thousand IOPS even on fast SSDs.

### USB Architecture

USB (Universal Serial Bus) uses a tiered-star topology where the host controller manages all communication. USB is relevant to OS design because of its complexity:

- **Enumeration and configuration.** When a device is connected, the host controller detects the voltage change on the data lines, resets the device, assigns it a unique address (1--127), reads its descriptors (device, configuration, interface, endpoint), and notifies the OS to load the appropriate driver.

- **Transfer types.** USB defines four transfer types optimised for different workloads:

| Type | Bandwidth Guarantee | Error Recovery | Use Case |
|---|---|---|---|
| Control | Low, guaranteed | Yes (retry) | Configuration, device setup |
| Bulk | High, best-effort | Yes (retry) | Storage, printers |
| Interrupt | Low, guaranteed latency | Yes (retry) | Keyboard, mouse, gamepad |
| Isochronous | Guaranteed bandwidth | No retry | Audio, video streaming |

- **Hot-plugging.** USB devices can be connected and disconnected at any time. The OS must handle sudden device removal gracefully: cancel pending I/O operations, release resources, notify user-space applications. A poorly written driver that does not handle surprise removal can cause kernel crashes.

## Memory-Mapped I/O vs Port-Mapped I/O

### Two Approaches to Device Communication

The CPU communicates with hardware devices by reading and writing device *registers* -- small memory-like locations on the device controller. There are two mechanisms for accessing these registers:

**Port-Mapped I/O (PMIO).** The CPU has a separate I/O address space, accessed via special instructions (`IN` and `OUT` on x86). The I/O address space is 16 bits wide (65,536 ports). Legacy x86 devices use specific port addresses by convention.

```c
/* Port-mapped I/O: reading from a serial port (x86 legacy) */
static inline uint8_t inb(uint16_t port) {
    uint8_t value;
    asm volatile("inb %1, %0" : "=a"(value) : "Nd"(port));
    return value;
}

static inline void outb(uint16_t port, uint8_t value) {
    asm volatile("outb %0, %1" : : "a"(value), "Nd"(port));
}

/* Read from COM1 serial port */
uint8_t data   = inb(0x3F8);  /* Data register */
uint8_t status = inb(0x3FD);  /* Line status register */
```

**Memory-Mapped I/O (MMIO).** Device registers are mapped into the CPU's physical address space. The CPU accesses them using ordinary load and store instructions. The memory controller routes accesses to specific physical address ranges to the appropriate device instead of to RAM.

```c
/* Memory-mapped I/O: accessing a modern device (e.g., NVMe, LAPIC) */

/* The device's BAR (Base Address Register) specifies the MMIO region.
 * On Linux, the kernel maps this into virtual address space. */
volatile uint32_t *regs = ioremap(pci_resource_start(pdev, 0),
                                  pci_resource_len(pdev, 0));

/* Read the device's capabilities register (offset 0x00) */
uint32_t caps = readl(&regs[0]);

/* Write to the device's command register (offset 0x04) */
writel(0x01, &regs[1]);

/* NVMe: write submission queue tail doorbell */
writel(new_tail, &regs[0x1000 / 4 + queue_id * 2]);
```

### Comparison

| Property | Port-Mapped I/O | Memory-Mapped I/O |
|---|---|---|
| Instruction type | Special (`IN`/`OUT`) | Normal load/store (`MOV`) |
| Address space | Separate 16-bit I/O space | Shared with memory (64-bit) |
| Address range | 65,536 ports max | Full physical address space |
| Architecture support | x86 only | All architectures |
| Protection | Ring 0 only (or IOPL bits) | Standard page table permissions |
| Compiler visibility | Always volatile (special insn) | Requires `volatile` keyword |
| Cacheability | Always uncacheable | Configurable (must be UC for devices) |
| Modern usage | Legacy devices only | All modern devices (PCIe, USB, etc.) |

> **Note:** MMIO has essentially won the architectural competition. All modern device interfaces (PCIe BARs, USB controller registers, GPU command channels) use memory-mapped I/O exclusively. Port-mapped I/O survives only for legacy x86 devices: the 8042 keyboard controller (ports 0x60, 0x64), the PIC (ports 0x20, 0xA0), the serial ports (0x3F8--0x3FF), and the PIT timer (port 0x40). New device specifications universally mandate MMIO.

### The `volatile` Keyword and Memory Ordering

In MMIO code, the C compiler must not optimise away or reorder device register accesses. Two issues arise:

**1. Optimisation.** Without `volatile`, the compiler may cache a device register read in a CPU register and not re-read it:

```c
/* Without volatile -- DANGEROUS for MMIO */
uint32_t *status = (uint32_t *)0xFE000000;
while (*status & BUSY_BIT) { /* spin */ }
/* Compiler may load *status once and loop forever */
```

The `volatile` keyword forces the compiler to emit a load instruction for every read:

```c
/* With volatile -- compiler will re-read on each iteration */
volatile uint32_t *status = (volatile uint32_t *)0xFE000000;
while (*status & BUSY_BIT) { /* spin */ }
```

> **Info:** **Volatile Semantics in C.** The C standard (C11, section 6.7.3) specifies that accesses to `volatile`-qualified objects are "side effects" that the compiler must not optimise away, reorder with respect to other volatile accesses, or coalesce. Every read of a `volatile` object must result in an actual load instruction, and every write must result in an actual store instruction, in the order specified by the abstract machine. However, `volatile` only controls the *compiler* -- it does not emit hardware memory barriers. On weakly-ordered architectures (ARM, RISC-V, POWER), additional barriers may be required to prevent the *CPU* from reordering accesses at the hardware level.

**2. Memory ordering.** Even with `volatile`, the CPU hardware may reorder memory accesses for performance. On x86, stores to device registers are not reordered with respect to other stores (x86 has a strong memory model), but on ARM and RISC-V, explicit memory barriers are needed:

```c
/* ARM: write command then write doorbell -- must be in order */
writel(command, &regs->cmd_reg);
wmb();  /* Write memory barrier -- ensures cmd_reg is visible
           to the device before the doorbell write */
writel(1, &regs->doorbell);
```

The Linux kernel provides architecture-abstracted I/O accessor functions (`readl`, `writel`, `readq`, `writeq`) that include the appropriate memory barriers for the target architecture.

## Timer Hardware and Preemptive Scheduling

### The Role of the Timer

Preemptive scheduling -- the ability of the OS to forcibly take the CPU away from a running process -- requires a hardware mechanism that generates periodic interrupts. Without a timer, a process that enters an infinite loop would monopolise the CPU forever, because nothing would trigger a kernel entry to invoke the scheduler.

The timer interrupt is the OS scheduler's heartbeat. On each tick, the kernel's timer interrupt handler:

1. Updates the system clock and per-process CPU time accounting.
2. Decrements the running process's remaining quantum.
3. Checks if the quantum has expired.
4. If so, sets a "need reschedule" flag.
5. On return from the interrupt handler, the kernel checks the flag and, if set, invokes the scheduler to select the next process.

### x86 Timer Hardware

x86 systems have multiple timer devices, reflecting decades of backward compatibility:

**PIT (Programmable Interval Timer, Intel 8253/8254).** The original PC timer, generating interrupts at a programmable frequency (the base oscillator runs at 1.193182 MHz). Accessed via I/O ports 0x40--0x43. The PIT can generate interrupts at rates from approximately 18.2 Hz to 1.193 MHz. Still present for legacy compatibility but rarely used as the primary timer on modern systems.

**LAPIC Timer.** Each CPU core has a Local APIC with a built-in timer that can operate in one-shot or periodic mode. This is the primary timer used by Linux on modern hardware because:
- Each core has its own independent timer (essential for per-core scheduling on SMP systems).
- The timer frequency is derived from the CPU bus clock, providing high resolution.
- The LAPIC is accessed via MMIO (no slow I/O port instructions).

**HPET (High Precision Event Timer).** A memory-mapped timer with at least 10 MHz resolution and multiple comparators. Used as a fallback on systems where the TSC is unreliable. The HPET can generate interrupts on up to 32 independent comparators, each programmable to fire at a specific time.

**TSC (Time Stamp Counter).** A 64-bit counter that increments at the CPU's reference clock frequency (typically the base clock, e.g., 100 MHz or the crystal oscillator frequency). The TSC is read via the `RDTSC` or `RDTSCP` instruction in approximately 10--25 cycles. It is not a timer (it does not generate interrupts), but it is the highest-resolution time source available, used for timestamps, performance measurement, and fine-grained delays.

The TSC frequency is constant on modern CPUs (`constant_tsc` flag in `/proc/cpuinfo`), meaning it does not vary with CPU frequency scaling. On multi-socket systems, the `nonstop_tsc` flag indicates the TSC continues counting during deep sleep states.

### The Tick Rate and Tickless Kernels

Traditionally, the timer interrupt fires at a fixed rate -- the *tick rate*. Linux historically used `CONFIG_HZ=100` (10 ms per tick), later increasing to `CONFIG_HZ=250` (4 ms) or `CONFIG_HZ=1000` (1 ms) for lower-latency scheduling.

The problem with a fixed tick rate is that timer interrupts fire even when the system is idle -- waking the CPU from power-saving states (C-states), consuming energy, and generating unnecessary overhead. On a modern laptop, each unnecessary wakeup costs approximately 1 mW of power; at 1000 Hz, that is 1 W of wasted power just for timer interrupts on idle cores.

Linux's *tickless* (or *dynamic tick*, `CONFIG_NO_HZ_IDLE` and `CONFIG_NO_HZ_FULL`) mode addresses this:

- **`NO_HZ_IDLE`**: When a CPU core has no runnable processes, it disables the periodic timer interrupt entirely. The core enters a deep sleep state and is woken only by device interrupts or IPIs from other cores that have work to schedule. When the core has runnable processes, the periodic tick resumes.

- **`NO_HZ_FULL`**: Goes further -- even when a core has a single runnable process, the tick is suppressed. The process runs without any timer interrupts until another process becomes runnable or a timer event occurs. This is useful for latency-sensitive workloads (HPC, real-time) that need to avoid all kernel interference.

The energy savings are significant:

$$
E_{\text{fixed}} = f_{\text{tick}} \times t_{\text{idle}} \times E_{\text{wakeup}}
$$

$$
E_{\text{tickless}} = n_{\text{events}} \times E_{\text{wakeup}} \quad \text{where } n_{\text{events}} \ll f_{\text{tick}} \times t_{\text{idle}}
$$

On a server with 64 cores, each idle 80% of the time, at `HZ=1000`, the fixed tick generates $64 \times 0.8 \times 1000 = 51,200$ unnecessary wakeups per second. Tickless mode eliminates all of them.

### Implementing a Timer Interrupt Handler

The following C code shows a simplified timer interrupt handler that implements round-robin scheduling:

```c
/* Simplified timer interrupt handler (conceptual) */
#include <stdint.h>

struct task_context {
    uint64_t rax, rbx, rcx, rdx;
    uint64_t rsi, rdi, rbp, rsp;
    uint64_t r8, r9, r10, r11;
    uint64_t r12, r13, r14, r15;
    uint64_t rip, rflags;
    uint64_t cr3;  /* page table base */
};

struct task {
    struct task_context ctx;
    int    pid;
    int    quantum_remaining;  /* ticks left in current quantum */
    enum { RUNNING, READY, BLOCKED } state;
    struct task *next;         /* run queue linked list */
};

#define QUANTUM_TICKS 10  /* 10 ms quantum at HZ=1000 */

static struct task *current_task;
static struct task *run_queue_head;
static uint64_t    system_ticks;

/* Called by low-level assembly stub after saving registers */
void timer_interrupt_handler(struct task_context *saved) {
    /* 1. Save interrupted task's register state */
    current_task->ctx = *saved;

    /* 2. Acknowledge timer interrupt (LAPIC End-Of-Interrupt) */
    *((volatile uint32_t *)0xFEE000B0) = 0;  /* LAPIC EOI */

    /* 3. Update system time */
    system_ticks++;

    /* 4. Decrement quantum */
    current_task->quantum_remaining--;

    if (current_task->quantum_remaining > 0) {
        /* Quantum not expired -- resume current task */
        return;
    }

    /* 5. Quantum expired -- round-robin reschedule */
    current_task->quantum_remaining = QUANTUM_TICKS;
    current_task->state = READY;

    /* Move current task to end of run queue */
    append_to_run_queue(current_task);

    /* Select next task from head of run queue */
    struct task *next = dequeue_from_run_queue();
    if (next == current_task) {
        current_task->state = RUNNING;
        return;  /* Only one runnable task */
    }

    /* 6. Context switch */
    next->state = RUNNING;
    current_task = next;

    /* Switch page tables if necessary */
    if (saved->cr3 != next->ctx.cr3) {
        asm volatile("mov %0, %%cr3" : : "r"(next->ctx.cr3)
                     : "memory");
        /* CR3 write flushes TLB */
    }

    /* Restore next task's registers (via assembly stub) */
    *saved = next->ctx;
}
```

> **Programmer:** In Go, you almost never interact with timer hardware directly, but the timer profoundly affects your program's behaviour. Go's goroutine scheduler uses a combination of OS timer signals and cooperative preemption. Before Go 1.14, goroutines were only preempted at function call boundaries -- a tight loop with no function calls (`for { i++ }`) could not be preempted, starving other goroutines. Go 1.14 introduced *asynchronous preemption*: the runtime sends `SIGURG` to goroutines that have been running too long, forcing them to yield. This is a user-space analogue of the kernel's timer-based preemptive scheduling. You can observe it: `strace -e signal ./myprogram` shows the preemption signals. Understanding that Go's scheduler sits *on top of* the OS scheduler helps explain subtle behaviour: goroutines are multiplexed onto OS threads (`M`s in Go runtime terminology), which are scheduled by the kernel. A goroutine blocked on a system call causes its OS thread to block, potentially triggering the Go runtime to create a new OS thread -- which is why `runtime.NumGoroutine()` can be vastly larger than the `GOMAXPROCS` setting, and why `strace` shows `clone()` calls during heavy I/O.

### Preemption Latency

The time between a preemption-triggering event (e.g., a higher-priority process becoming runnable) and the actual context switch to that process is called *preemption latency*:

$$
T_{\text{preempt}} = T_{\text{interrupt}} + T_{\text{handler}} + T_{\text{scheduler}} + T_{\text{switch}}
$$

Where:

- $T_{\text{interrupt}}$: interrupt delivery latency (hardware), typically 1--5 $\mu$s.
- $T_{\text{handler}}$: time to execute the interrupt handler, typically 1--10 $\mu$s.
- $T_{\text{scheduler}}$: time to select the next task, O(1) for Linux CFS in the common case.
- $T_{\text{switch}}$: time to perform the context switch (save/restore registers, switch page tables, flush TLB), typically 2--10 $\mu$s.

For general-purpose Linux (`CONFIG_PREEMPT_VOLUNTARY`), the total preemption latency is typically 10--100 $\mu$s. For fully preemptible Linux (`CONFIG_PREEMPT`), the target is under 50 $\mu$s. For real-time Linux (PREEMPT_RT patchset), the target is under 10--50 $\mu$s worst-case, achieved by:

- Converting all spinlocks to sleeping (priority-inheriting) mutexes
- Threading all interrupt handlers (running them as kernel threads that can be preempted)
- Minimising the time that interrupts are disabled

### Real-Time Scheduling Constraints

A *hard real-time* system must guarantee that tasks meet their deadlines. The timer resolution and interrupt latency set fundamental bounds on schedulability.

> **Info:** **Rate Monotonic Scheduling (RMS) Bound.** For a set of $n$ independent periodic tasks with periods $T_i$ and worst-case execution times $C_i$, the tasks are schedulable under the Rate Monotonic (fixed priority, shorter period = higher priority) algorithm if:

$$
U = \sum_{i=1}^{n} \frac{C_i}{T_i} \leq n(2^{1/n} - 1)
$$

The bound $n(2^{1/n} - 1)$ converges to $\ln 2 \approx 0.693$ as $n \to \infty$. For small $n$:

| $n$ | $n(2^{1/n} - 1)$ |
|---|---|
| 1 | 1.000 |
| 2 | 0.828 |
| 3 | 0.780 |
| 5 | 0.743 |
| 10 | 0.718 |
| $\infty$ | 0.693 |

This means a CPU utilisation above 69.3% cannot be guaranteed schedulable for arbitrary task sets under RMS. For specific *harmonic* task sets (where periods are exact multiples of each other), utilisation up to 100% is achievable.

## Summary

The hardware-software interface is the foundation upon which all OS functionality is built. CPU privilege rings (x86 rings 0--3, ARM exception levels EL0--EL3, RISC-V M/S/U modes) enforce the boundary between trusted and untrusted code. Interrupts provide the asynchronous notification mechanism that lets the OS respond to hardware events without wasting CPU cycles on polling. Exceptions (faults, traps, aborts) provide synchronous notification of error conditions and are the mechanism behind demand paging, copy-on-write, and debugging. DMA offloads bulk data transfers from the CPU, with IOMMUs providing protection against rogue DMA accesses. I/O buses (PCIe, USB, NVMe) connect devices to the system and determine the available bandwidth and command interfaces. Memory-mapped I/O has supplanted port-mapped I/O as the universal device communication mechanism. Timer hardware provides the periodic interrupts that drive preemptive scheduling, with tickless kernels eliminating unnecessary overhead on idle and single-task cores. Every kernel operation -- from scheduling a process to reading a file to receiving a network packet -- ultimately reduces to these hardware mechanisms.

## Exercises

### Exercise 3.1: Privilege Level Analysis

Consider the following sequence of events on an x86-64 system running Linux:

a) A user program calls `getpid()`. Trace the CPL changes through the entire sequence, from the C library wrapper through the `SYSCALL` instruction, through the kernel handler, and back through `SYSRET`. At each step, state the CPL value and which instruction causes it to change.

b) While the `getpid()` handler is executing in the kernel, a network card raises an MSI-X interrupt. Trace the CPL changes as the CPU transitions from the system call handler to the interrupt handler and back. Does the CPL change?

c) The `SYSCALL` instruction on x86-64 does not automatically switch stacks -- the kernel must switch to the kernel stack in software (reading the stack pointer from the per-CPU TSS). Explain why this is a security concern and how Linux addresses it. What would happen if a user program set RSP to point to kernel memory before executing `SYSCALL`?

d) Explain why the x86-64 `SYSCALL` instruction is faster than the older `INT 0x80` mechanism. Specifically, identify which hardware operations `SYSCALL` skips that `INT 0x80` performs.

### Exercise 3.2: Interrupt Latency Measurement

Design an experiment to measure the interrupt latency of a Linux system.

a) Describe the hardware setup: which timer would you use, how would you programme it, and how would you measure the time between the expected interrupt arrival and the actual start of the handler?

b) Write pseudocode for the timer setup function and the interrupt handler, using `RDTSCP` for timestamp capture.

c) Identify at least four sources of variability in your measurements (factors that cause the measured latency to vary from one interrupt to the next).

d) Explain how each of the following Linux configurations affects your measurement: `CONFIG_HZ`, `CONFIG_PREEMPT`, `CONFIG_NO_HZ_FULL`, `isolcpus` kernel parameter.

e) How would you distinguish between interrupt *delivery* latency (hardware) and interrupt *handling* latency (software)? Can you separate these two components with TSC measurements alone?

### Exercise 3.3: DMA Buffer Management

A network card receives packets via DMA into a ring buffer of 256 entries, each 2048 bytes. The driver pre-allocates all 256 buffers at initialisation time.

a) Calculate the total physical memory consumed by the ring buffer. Should the buffers be allocated with `dma_alloc_coherent()` (always cache-coherent) or `dma_map_single()` (streaming, with explicit sync points)? Justify your choice considering the access pattern (device writes, CPU reads, then device reuses).

b) Explain why the buffers must be DMA-addressable. What constraint does a 32-bit DMA-capable device impose on the physical addresses? How does the `GFP_DMA32` flag address this?

c) The driver must refill empty ring buffer entries after the kernel has processed the received packets. Design a refill strategy that minimises the window during which the ring buffer is full (and packets are dropped). Should the driver refill in the interrupt handler (top half) or in a NAPI poll function (bottom half)? Justify.

d) On a non-cache-coherent ARM platform, specify the exact cache maintenance operations the driver must perform: (i) after DMA writes a received packet to the buffer, and (ii) before returning the buffer to the device for the next receive.

### Exercise 3.4: Page Fault Handler Design

Implement a page fault handler (in pseudocode or C) that correctly handles all of the following cases:

a) **Demand paging for anonymous memory**: a process accesses a page that was allocated with `mmap(MAP_ANONYMOUS)` but never written to.

b) **Demand paging for memory-mapped files**: a process accesses a page in a region created by `mmap(fd, ...)` that has not yet been loaded from disk.

c) **Copy-on-write**: a child process (created by `fork()`) writes to a page that is shared with the parent.

d) **Stack growth**: a process accesses an address just below the current stack boundary.

e) **Segmentation fault**: a process accesses an address that is not in any valid mapping.

For each case, specify the exact condition (error code bits, VMA lookup result) that distinguishes it from the others. Prove that your handler is *complete* -- that every possible page fault is classified into exactly one of these categories.

### Exercise 3.5: NVMe vs AHCI Quantitative Comparison

Compare the NVMe and AHCI storage interfaces:

a) AHCI supports 1 command queue per port with 32 entries maximum. NVMe supports up to 65,535 I/O queues with up to 65,536 entries each. Calculate the maximum number of outstanding I/O commands for each interface. On a 64-core system where each core submits I/O independently, which interface is the bottleneck?

b) For a single random 4 KB read: count the exact number of MMIO register writes required to submit the command on each interface. For AHCI, include: writing the command FIS, setting the command issue bit, and reading the status register. For NVMe, include: writing the SQE and the doorbell.

c) AHCI uses a single interrupt (or MSI vector) per port; NVMe supports MSI-X with up to 2048 vectors. Explain the performance implications on a multi-core system. What happens when all 64 cores must synchronise on a single interrupt vector?

### Exercise 3.6: Timer Analysis

A system uses a LAPIC timer with a base frequency of 100 MHz programmed to fire every 1 ms (100,000 cycles).

a) Calculate the scheduling overhead (fraction of CPU time consumed by timer processing) if the timer interrupt handler takes 5 $\mu$s and the context switch takes 3 $\mu$s.

b) Repeat the calculation for a 10 ms quantum. Express the overhead ratio ($\text{overhead}_{1\text{ms}} / \text{overhead}_{10\text{ms}}$).

c) A tickless kernel on an idle core avoids all timer interrupts. If the system has 32 cores, each idle 70% of the time, and `HZ=1000`, how many unnecessary timer interrupts are eliminated per second?

d) Derive a formula for the minimum quantum length $Q_{\min}$ such that scheduling overhead is less than a fraction $\alpha$ of CPU time, given handler time $T_h$ and context switch time $T_s$:

$$
Q_{\min} > \frac{T_h + T_s}{\alpha}
$$

For $T_h = 5$ $\mu$s, $T_s = 3$ $\mu$s, $\alpha = 0.01$ (1% overhead), calculate $Q_{\min}$.

### Exercise 3.7: Writing an Interrupt Handler

Write a complete, compilable Linux kernel module that:

a) Creates a workqueue and schedules periodic work items that simulate interrupt bottom-half processing.

b) Each work item records the current timestamp (using `ktime_get_ns()`) into a circular buffer of 64 entries.

c) Exposes the recorded timestamps through a `/proc/irq_timestamps` file. When the file is read, it should display all timestamps in the buffer with nanosecond precision.

d) Properly cleans up all resources (cancel pending work, destroy workqueue, remove `/proc` entry) when the module is unloaded.

Provide the complete C source code and `Makefile`. Explain the difference between running deferred work in hardirq context (softirq/tasklet) versus process context (workqueue), and justify why a workqueue is appropriate for this exercise.
