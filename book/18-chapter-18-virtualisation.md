# Chapter 18: Virtualisation

*"Any problem in computer science can be solved by another level of indirection, except the problem of too many levels of indirection."*
--- David Wheeler (attributed)

---

Virtualisation is the art of presenting a convincing illusion: making one physical machine appear as many, or making many physical machines appear as one. The operating system itself is a virtualiser --- it virtualises the CPU (processes), memory (virtual address spaces), and storage (files). This chapter studies the techniques for virtualising the **entire machine**, allowing multiple operating systems to run simultaneously on the same hardware, and the lighter-weight alternatives that virtualise only the operating system's view of its environment.

We begin with the theoretical foundation --- the Popek-Goldberg theorem that defines when hardware is virtualisable --- then progress through the two families of hypervisors, the mechanisms for virtualising CPU, memory, and I/O, and finally the container revolution that replaced full machine virtualisation for most workloads.

## 18.1 Why Virtualise?

The motivations for virtualisation have evolved since IBM's CP-40 in 1967:

- **Server consolidation**: run multiple workloads on a single physical server, improving utilisation from the typical 5--15% to 60--80%. A company that ran 20 physical servers at 10% utilisation each can consolidate to 3 servers at 70% utilisation.

- **Isolation**: bugs or security compromises in one guest do not affect others, because each guest has its own kernel. This is stronger than process isolation, which shares a kernel (and therefore its vulnerabilities).

- **Development and testing**: run multiple OS versions and configurations without dedicated hardware. A developer can test against Ubuntu 22.04, RHEL 9, and Windows Server 2022 simultaneously on a single workstation.

- **Migration**: move running workloads between physical hosts for load balancing and maintenance (**live migration**). The VM's memory is copied to the destination host while it continues running, with a brief pause at the end (typically < 50 ms) to transfer the final dirty pages.

- **Snapshotting and cloning**: capture the complete state of a VM (memory, disk, CPU registers) and restore it later, or clone it to create identical copies. This enables rapid disaster recovery and reproducible testing environments.

- **Cloud computing**: the entire public cloud model rests on virtualisation --- a cloud provider sells virtual machines to tenants who share the same physical infrastructure. Without virtualisation, multi-tenancy would require each tenant to have dedicated hardware.

## 18.2 Full Virtualisation vs Paravirtualisation

The two fundamental approaches to virtualisation differ in whether the guest OS knows it is virtualised.

::: definition
**Full Virtualisation.** A virtualisation technique in which the guest operating system runs unmodified, believing it is executing on bare hardware. The hypervisor intercepts privileged operations and emulates them transparently. The guest's binary is identical to what would run on physical hardware.
:::

::: definition
**Paravirtualisation.** A virtualisation technique in which the guest operating system is modified to be aware that it is running in a virtual machine. Instead of executing privileged instructions that must be trapped and emulated, the guest makes explicit **hypercalls** to the hypervisor --- analogous to system calls, but from the guest kernel to the hypervisor.
:::

| Aspect | Full Virtualisation | Paravirtualisation |
|---|---|---|
| Guest modification | None required | Guest kernel must be modified |
| Performance | Overhead from trapping and emulating | Near-native (hypercalls are efficient) |
| Hardware support | Requires VT-x/AMD-V (or binary translation) | Can work without hardware support |
| Guest OS support | Any OS | Only modified kernels |
| Complexity | Hypervisor handles transparency | Shared between hypervisor and guest |
| Example | KVM, VMware ESXi | Xen PV, virtio drivers |

In practice, modern systems use a **hybrid**: the CPU and memory are fully virtualised using hardware support (VT-x/AMD-V, EPT/NPT), while I/O uses paravirtualised drivers (virtio) for performance. This gives the best of both worlds: unmodified guest kernels with near-native I/O performance.

## 18.3 The Popek-Goldberg Theorem

In 1974, Popek and Goldberg formalised the requirements for a virtualisation-capable architecture. Their result is the theoretical foundation of all hardware-assisted virtualisation.

::: definition
**Instruction Classification.** Instructions on a processor can be classified as:

1. **Privileged instructions**: those that trap (cause a processor exception) when executed in user mode. Examples: `HLT`, `LIDT`, `MOV to CR3`.

2. **Sensitive instructions**: those whose behaviour depends on the processor mode (user vs supervisor) or that can alter the machine's configuration. Sensitive instructions are further divided into:
   - **Control-sensitive**: can change the configuration of resources (e.g., load page table base, set interrupt mask).
   - **Behaviour-sensitive**: have different effects depending on the current processor mode (e.g., `POPF` on x86 silently ignores the interrupt flag in user mode but modifies it in kernel mode).
:::

::: theorem
**Theorem 18.1 (Popek-Goldberg Virtualisation Theorem, 1974).** A computer architecture is **efficiently virtualisable** if the set of sensitive instructions is a subset of the set of privileged instructions.

$$\text{Sensitive Instructions} \subseteq \text{Privileged Instructions}$$

If every sensitive instruction is also privileged, then the hypervisor can run guest code directly in user mode and rely on hardware traps to intercept all sensitive operations. No instruction can silently change system state without the hypervisor's knowledge.

*Proof.* Consider a hypervisor $H$ that runs a guest OS $G$ in user mode on the bare hardware. $H$ maintains a virtual machine state (virtual registers, virtual memory map, virtual interrupt state) for $G$.

(1) Any non-sensitive instruction executed by $G$ has the same effect in user mode as it would in kernel mode. $H$ need not intervene --- the instruction executes at native speed.

(2) Any sensitive instruction executed by $G$ must be intercepted by $H$, because if it were not, the instruction could either reveal the true machine state (violating equivalence) or alter it (violating resource control). By assumption, every sensitive instruction is privileged, so it traps when executed in user mode. $H$ catches the trap, examines the instruction, emulates its effect on the virtual machine state, and resumes $G$.

(3) Non-sensitive instructions execute at native speed (no overhead), and sensitive instructions are trapped and emulated. The guest's behaviour is **equivalent** to execution on bare hardware, and the hypervisor maintains **control** over all resources. $\square$
:::

The x86 architecture famously violated this theorem: several sensitive instructions were not privileged. This is why x86 virtualisation required either binary translation or hardware extensions.

::: example
**Example 18.1 (Sensitive but Non-Privileged Instructions on x86).** The x86 ISA contains 17 instructions that are sensitive but not privileged. The most notable:

| Instruction | Sensitivity | Why Problematic |
|---|---|---|
| `SGDT` | Reveals GDTR (host state) | Does not trap in user mode |
| `SIDT` | Reveals IDTR (host state) | Does not trap in user mode |
| `SLDT` | Reveals LDTR | Does not trap in user mode |
| `SMSW` | Reveals CR0 bits | Does not trap in user mode |
| `PUSHF`/`POPF` | Reveals/sets EFLAGS.IF | Silently ignores IF in user mode |
| `LAR`/`LSL` | Reveals segment permissions | Does not trap in user mode |

`SGDT` (Store Global Descriptor Table Register) reads the GDTR register and stores its contents in memory. It is sensitive because the value of GDTR differs between the host and the guest (each has its own GDT). However, on classic x86, `SGDT` is not privileged --- it executes without trapping in user mode, revealing the host's GDTR value to the guest.

`POPF` is behaviour-sensitive: in kernel mode, it modifies the interrupt flag (EFLAGS.IF); in user mode, it silently ignores the IF bit. A guest kernel that uses `POPF` to enable interrupts would fail silently.

**Solutions:**
- **VMware (1999)**: binary translation. The hypervisor scanned the guest's instruction stream and replaced sensitive-but-non-privileged instructions with calls to emulation routines.
- **Xen (2003)**: paravirtualisation. The guest kernel was modified to use hypercalls instead of sensitive instructions.
- **Intel VT-x (2005) / AMD-V (2006)**: hardware extensions that make all sensitive instructions cause VM exits, regardless of privilege level.
:::

## 18.4 Type-1 Hypervisors

A **Type-1** (bare-metal) hypervisor runs directly on the hardware, with no host operating system beneath it. It is the most common architecture for server virtualisation.

::: definition
**Type-1 Hypervisor (Bare-Metal).** A hypervisor that runs directly on the physical hardware, managing all hardware resources and presenting virtual machines to guest operating systems. The hypervisor is the first software to execute after the bootloader. It has direct access to hardware and does not rely on a host OS for device drivers or scheduling.
:::

### 18.4.1 Xen

Xen (developed at the University of Cambridge, first released 2003) pioneered paravirtualisation on x86. Its architecture is distinctive:

- **Domain 0 (Dom0)**: a privileged guest (typically a Linux kernel) that has direct access to hardware and runs the management toolstack. Dom0 is trusted --- it can create, destroy, and configure other domains.
- **Domain U (DomU)**: unprivileged guests that access hardware only through Xen's paravirtualised interfaces or hardware pass-through.
- **Xen hypervisor**: a thin layer (approximately 150,000 lines of code) that handles scheduling, memory management, and trap forwarding.

```text
┌─────────────────────────────────────────────────────────────┐
│                    Hardware                                   │
├─────────────────────────────────────────────────────────────┤
│                 Xen Hypervisor                               │
│  Scheduling | Memory Management | Trap Forwarding            │
├───────────────┬──────────────┬──────────────────────────────┤
│   Domain 0    │   Domain U1  │   Domain U2                  │
│   (Linux)     │   (Linux PV) │   (Windows HVM)              │
│               │              │                              │
│ Device drivers│  PV drivers  │  Emulated + PV drivers       │
│ Management    │  (front-end) │  (front-end)                 │
│ toolstack     │              │                              │
│               │              │                              │
│ PV backends   │              │                              │
│ (netback,     │              │                              │
│  blkback)     │              │                              │
└───────────────┴──────────────┴──────────────────────────────┘
```

Paravirtualised Xen guests replace privileged operations with **hypercalls**:

```c
/* Xen paravirtualised guest: requesting a page table update.
   Instead of directly writing to a page table entry (privileged),
   the guest issues a hypercall to Xen. */
#include <xen/xen.h>

static inline int xen_update_pte(pte_t *ptep, pte_t pte) {
    struct mmu_update update;
    update.ptr = virt_to_machine(ptep).maddr;
    update.val = pte_val(pte);
    return HYPERVISOR_mmu_update(&update, 1, NULL, DOMID_SELF);
}

/* Similarly, setting the interrupt flag becomes: */
static inline void xen_safe_halt(void) {
    /* Instead of STI; HLT (privileged), call Xen: */
    HYPERVISOR_sched_op(SCHEDOP_block, NULL);
}
```

The hypercall interface is essentially a system call to the hypervisor, using the `HYPERCALL` instruction (or `INT 0x82` on older Xen) instead of `SYSCALL`/`INT 0x80`.

With the introduction of VT-x/AMD-V, Xen added **HVM** (Hardware Virtual Machine) mode, allowing unmodified guests. Modern Xen uses a hybrid: HVM for CPU virtualisation, PV drivers (virtio-style) for I/O.

### 18.4.2 KVM

**Kernel-based Virtual Machine** (KVM), merged into the Linux kernel in 2007, takes a radically different approach: it turns the Linux kernel itself into a Type-1 hypervisor.

KVM leverages the existing Linux kernel for scheduling, memory management, and device drivers, adding only the virtualisation-specific code as a kernel module. The module exposes the `/dev/kvm` device, through which user-space processes (typically QEMU) manage virtual machines.

KVM requires hardware virtualisation support (VT-x or AMD-V). The architecture has three execution modes:

1. **Host kernel mode**: the Linux kernel with KVM loaded, managing physical hardware.
2. **Host user mode**: QEMU (or Firecracker, Cloud Hypervisor, etc.), which handles device emulation and VM management.
3. **Guest mode**: the virtual machine's code, running directly on the CPU in a hardware-isolated context (VMCS on Intel, VMCB on AMD).

The KVM approach has several advantages:

- **Code reuse**: KVM inherits Linux's mature scheduler, memory manager, device drivers, and networking stack. This represents millions of lines of tested code that a from-scratch hypervisor would have to reimplement.
- **Ecosystem**: any Linux tool (cgroups, namespaces, perf, ftrace) works with KVM VMs.
- **Maintenance**: KVM is maintained as part of the Linux kernel, benefiting from the kernel's development process and security updates.

::: example
**Example 18.2 (KVM Execution Flow).** When a guest executes a sensitive instruction:

1. The CPU exits guest mode (**VM exit**) and returns to the host kernel (KVM).
2. KVM examines the exit reason (stored in the VMCS exit reason field). Common exit reasons include: I/O port access, MSR read/write, EPT violation (page fault), CPUID, HLT, and external interrupt.
3. If KVM can handle the exit in-kernel (e.g., a simple MSR read, an EPT violation that just requires mapping a page), it emulates the instruction, updates the VMCS guest state, and resumes the guest (**VM entry** via `VMRESUME`).
4. If the exit requires complex device emulation (e.g., a disk write to an emulated virtio-blk device), KVM returns to QEMU in user space via the `KVM_RUN` ioctl. QEMU emulates the device, then calls `KVM_RUN` again to resume the guest.

The performance-critical path is entirely in-kernel: a VM exit that KVM handles directly costs approximately 1--3 microseconds (the cost of saving/restoring guest state and executing the emulation logic). Exits that require QEMU add the overhead of a user-kernel round trip (approximately 5--10 microseconds).

Typical VM exit rates vary from hundreds per second (compute-intensive workloads) to hundreds of thousands per second (I/O-intensive workloads). Reducing VM exit frequency is the primary goal of virtualisation optimisations (virtio, EPT, posted interrupts).
:::

### 18.4.3 VMware ESXi

VMware ESXi is a proprietary Type-1 hypervisor optimised for enterprise server virtualisation. It boots its own microkernel (vmkernel) that provides scheduling, memory management, and a storage stack. Unlike KVM, ESXi does not use a general-purpose OS kernel --- the hypervisor is purpose-built, with a minimal attack surface.

VMware pioneered **binary translation** for x86 virtualisation before hardware support existed. The binary translator scanned blocks of guest code, identified sensitive instructions, and replaced them with safe equivalents stored in a translation cache. Translated blocks were cached, so the translation cost was amortised over repeated execution. Today, ESXi uses VT-x/AMD-V with optimisations for large-scale deployments (distributed resource scheduling, fault tolerance, live migration across shared storage).

### 18.4.4 Trap-and-Emulate with Hardware Assistance

Intel VT-x introduces a new execution mode with two root/non-root levels:

::: definition
**VT-x (Intel Virtualisation Technology).** A set of CPU extensions that add **VMX root** and **VMX non-root** execution modes. The hypervisor runs in VMX root mode; guests run in VMX non-root mode. Sensitive instructions executed in VMX non-root mode cause **VM exits** (traps to the hypervisor), regardless of whether they are privileged in the classical sense. This satisfies the Popek-Goldberg condition by hardware design.
:::

The key data structure is the **Virtual Machine Control Structure (VMCS)**, a hardware-managed region that stores:

- **Guest state area**: general-purpose registers, segment registers, control registers (CR0, CR3, CR4), IDTR, GDTR, EFLAGS, RIP, RSP, and interrupt state.
- **Host state area**: hypervisor's register values to restore on VM exit.
- **VM execution control fields**: which events cause VM exits (bitmap of I/O ports, MSR accesses, specific exceptions, interrupt types). These can be configured per-VM for performance --- for example, the hypervisor might not trap CPUID if it does not need to hide CPU features.
- **VM exit information fields**: the reason for the most recent VM exit, the qualifying data (e.g., which I/O port was accessed, what address caused an EPT violation), and the guest's instruction pointer at the time of exit.
- **VM entry control fields**: what to inject on entry (e.g., a pending interrupt).

```text
VM Entry (VMLAUNCH / VMRESUME)
┌──────────────────────────────────────┐
│  VMX Root Mode (Hypervisor)          │
│                                      │
│  1. Configure VMCS                   │
│  2. VMLAUNCH ──────────────────────┐ │
│                                    │ │
│  4. Handle VM exit                 │ │
│  5. VMRESUME ──────────────────────┤ │
│                                    │ │
└────────────────────────────────────│─┘
                                     │
┌────────────────────────────────────│─┐
│  VMX Non-Root Mode (Guest)         │ │
│                                    ▼ │
│  3. Guest executes                   │
│     - Non-sensitive: native speed    │
│     - Sensitive: VM exit to host     │
│     - VM exit costs ~1-3 us          │
│                                      │
└──────────────────────────────────────┘
```

AMD-V provides an equivalent mechanism with the **VMCB** (Virtual Machine Control Block) and the `VMRUN`/`#VMEXIT` instructions. The VMCB is a 4 KB structure with similar guest state, host state, and control fields. AMD-V also introduced **Nested Page Tables (NPT)** before Intel's EPT, giving AMD an early advantage in memory virtualisation performance.

::: programmer
**Programmer's Perspective: The KVM API in C.**
KVM is controlled through ioctl calls on `/dev/kvm`. The following C program creates a minimal virtual machine that executes a few instructions in 16-bit real mode and then halts:

```c
#include <fcntl.h>
#include <linux/kvm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    /* Step 1: Open the KVM device */
    int kvm_fd = open("/dev/kvm", O_RDWR);
    if (kvm_fd < 0) { perror("open /dev/kvm"); return 1; }

    /* Step 2: Check API version (must be 12) */
    int api_ver = ioctl(kvm_fd, KVM_GET_API_VERSION, 0);
    printf("KVM API version: %d\n", api_ver);

    /* Step 3: Create a VM (returns a VM file descriptor) */
    int vm_fd = ioctl(kvm_fd, KVM_CREATE_VM, 0);
    if (vm_fd < 0) { perror("KVM_CREATE_VM"); return 1; }

    /* Step 4: Allocate guest physical memory (4 KB page) */
    size_t mem_size = 0x1000;
    void *mem = mmap(NULL, mem_size, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

    /* Guest code (16-bit real mode):
       mov al, 0x42       ; load 0x42 into al
       out 0x01, al        ; write al to I/O port 1 (VM exit)
       mov al, 0x43        ; load 0x43
       out 0x01, al        ; write again (VM exit)
       hlt                  ; halt (VM exit) */
    unsigned char code[] = {
        0xB0, 0x42,       /* mov al, 0x42 */
        0xE6, 0x01,       /* out 0x01, al */
        0xB0, 0x43,       /* mov al, 0x43 */
        0xE6, 0x01,       /* out 0x01, al */
        0xF4,             /* hlt           */
    };
    memcpy(mem, code, sizeof(code));

    /* Step 5: Map guest memory at physical address 0 */
    struct kvm_userspace_memory_region region = {
        .slot = 0,
        .guest_phys_addr = 0,
        .memory_size = mem_size,
        .userspace_addr = (unsigned long)mem,
    };
    ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, &region);

    /* Step 6: Create a vCPU */
    int vcpu_fd = ioctl(vm_fd, KVM_CREATE_VCPU, 0);

    /* Step 7: Map the vCPU's kvm_run structure (shared with kernel) */
    size_t run_size = ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
    struct kvm_run *run = mmap(NULL, run_size, PROT_READ | PROT_WRITE,
                               MAP_SHARED, vcpu_fd, 0);

    /* Step 8: Set initial segment registers (16-bit real mode) */
    struct kvm_sregs sregs;
    ioctl(vcpu_fd, KVM_GET_SREGS, &sregs);
    sregs.cs.base = 0;
    sregs.cs.selector = 0;
    ioctl(vcpu_fd, KVM_SET_SREGS, &sregs);

    /* Step 9: Set initial general-purpose registers */
    struct kvm_regs regs = { .rip = 0, .rflags = 0x2 };
    ioctl(vcpu_fd, KVM_SET_REGS, &regs);

    /* Step 10: Run the vCPU in a loop */
    for (;;) {
        ioctl(vcpu_fd, KVM_RUN, 0);
        switch (run->exit_reason) {
        case KVM_EXIT_IO:
            if (run->io.port == 0x01 &&
                run->io.direction == KVM_EXIT_IO_OUT) {
                char val = *(char *)((char *)run + run->io.data_offset);
                printf("Guest wrote 0x%02X to port 0x01\n", val);
            }
            break;
        case KVM_EXIT_HLT:
            printf("Guest halted.\n");
            goto done;
        default:
            printf("Unexpected exit reason: %d\n", run->exit_reason);
            goto done;
        }
    }
done:
    close(vcpu_fd);
    close(vm_fd);
    close(kvm_fd);
    munmap(mem, mem_size);
    return 0;
}
```

This program demonstrates the complete KVM lifecycle: create a VM, allocate guest memory, create a vCPU, set registers, and run. The guest code writes two bytes to I/O port 1 (each causing a VM exit that the host handles) and then halts (another VM exit). This is the foundation on which QEMU, Firecracker, Cloud Hypervisor, and crosvm are built.

To compile and run: `gcc -o kvm_demo kvm_demo.c && sudo ./kvm_demo` (requires `/dev/kvm` access, typically via the `kvm` group).
:::

## 18.5 Type-2 Hypervisors

A **Type-2** hypervisor runs as an application on a host operating system.

::: definition
**Type-2 Hypervisor (Hosted).** A hypervisor that runs on top of a conventional host operating system, using the host's process and memory management facilities. The hypervisor is a regular user-space application, and VMs are host processes.
:::

### 18.5.1 VirtualBox

Oracle VirtualBox is a popular Type-2 hypervisor for desktop use. It runs as a user-space application on Linux, Windows, and macOS, using hardware virtualisation (VT-x/AMD-V) when available and falling back to software techniques otherwise. VirtualBox provides a GUI for VM management, shared folders between host and guest, and seamless mode (guest windows appear alongside host windows).

### 18.5.2 QEMU

**QEMU** (Quick Emulator) is a versatile machine emulator and virtualiser that operates in multiple modes:

- **Full system emulation**: QEMU can emulate an entire machine (CPU, memory, devices), allowing a guest of one architecture (e.g., ARM) to run on a host of another (e.g., x86). This uses **Tiny Code Generator (TCG)**, a JIT compiler that translates guest instructions to host instructions at runtime.

- **Hardware-accelerated virtualisation**: when paired with KVM (on Linux), Xen, or macOS Hypervisor.framework, QEMU delegates CPU execution to hardware and provides device emulation. In this mode, QEMU is the user-space component of a Type-1 hypervisor.

- **User-mode emulation**: QEMU can emulate individual Linux binaries of a foreign architecture (e.g., running an ARM binary on x86) by translating system calls and CPU instructions without emulating hardware devices.

The distinction between Type-1 and Type-2 blurs: QEMU/KVM is technically Type-1 (KVM is in the kernel), but the user interacts with QEMU, which runs in user space. The architecture is best described as **split-model**: the CPU and memory are virtualised by the kernel (KVM), while device emulation and VM management are handled by user space (QEMU).

## 18.6 Binary Translation vs Hardware-Assisted Virtualisation

Before VT-x and AMD-V, full virtualisation on x86 required **binary translation**: the hypervisor scanned the guest's instruction stream, identified sensitive instructions, and replaced them with safe equivalents.

::: definition
**Binary Translation.** A virtualisation technique in which the hypervisor translates blocks of guest code at runtime, replacing sensitive or privileged instructions with calls to emulation routines. The translated blocks are cached for reuse in a **translation cache**.
:::

The translation process works on **basic blocks** (sequences of instructions ending at a branch):

1. **Fetch**: read a basic block from the guest's instruction stream.
2. **Scan**: identify sensitive or privileged instructions within the block.
3. **Translate**: replace sensitive instructions with safe equivalents (e.g., replace `SGDT` with a load from a virtual GDTR variable; replace `POPF` with a routine that correctly emulates IF-sensitive behaviour).
4. **Cache**: store the translated block in the translation cache, indexed by guest address.
5. **Execute**: jump to the translated block. Subsequent executions of the same guest code use the cached translation.

::: example
**Example 18.3 (Binary Translation of POPF).** The guest kernel executes:

```text
Guest code:         Translated code:
  pushf               pushf
  popf                call __emulate_popf
                      ;; __emulate_popf reads the pushed flags,
                      ;; updates the virtual IF in the VMM state,
                      ;; and returns with flags modified appropriately
```

The translation replaces `popf` with a call to an emulation function that correctly handles the interrupt flag. The guest sees the expected behaviour; the host's real interrupt flag is never modified.
:::

| Aspect | Binary Translation | Hardware-Assisted |
|---|---|---|
| Mechanism | JIT rewriting of guest code | CPU modes (VMX root/non-root) |
| First-execution cost | Translation overhead | None (direct execution) |
| Steady-state cost | Near-native (cached translations) | VM exit/entry overhead per trap |
| Cross-architecture | Yes (QEMU TCG: ARM on x86) | No (guest must match host ISA) |
| Guest modification | None required | None required |
| Historical use | VMware (1999--2008), QEMU TCG | VT-x (2006+), AMD-V (2006+) |

Hardware-assisted virtualisation is now dominant for same-architecture guests. Binary translation remains essential for cross-architecture emulation (e.g., Apple's Rosetta 2 translating x86 binaries on ARM, QEMU TCG for development and testing of embedded ARM software on x86 desktops).

## 18.7 Memory Virtualisation

The guest OS manages its own page tables, mapping guest virtual addresses (GVA) to guest physical addresses (GPA). But GPAs are not real physical addresses --- they must be translated to host physical addresses (HPA). Memory virtualisation solves this two-level translation problem.

::: definition
**Two-Level Address Translation.** In a virtualised system, a memory access requires translating:

1. **GVA to GPA**: the guest's page table maps guest virtual addresses to guest physical addresses (managed by the guest OS).

2. **GPA to HPA**: the hypervisor's mapping translates guest physical addresses to host physical addresses (managed by the hypervisor).

The composition GVA $\rightarrow$ GPA $\rightarrow$ HPA produces the final hardware address.
:::

### 18.7.1 Shadow Page Tables

Before hardware support, hypervisors maintained **shadow page tables** that directly mapped GVA to HPA, short-circuiting the two-level translation.

::: definition
**Shadow Page Tables.** A software technique in which the hypervisor maintains a set of page tables (the "shadow") that map guest virtual addresses directly to host physical addresses. The CPU's MMU uses the shadow tables, not the guest's tables. The guest's page tables exist only as a data structure in guest memory that the hypervisor monitors.
:::

The hypervisor intercepts all guest page table modifications (by write-protecting guest page table pages and trapping on writes). When the guest modifies its page tables, the hypervisor updates the shadow tables to reflect the guest's intended GVA-to-GPA mapping composed with the hypervisor's GPA-to-HPA mapping.

::: example
**Example 18.4 (Shadow Page Table Walk).** Consider a guest accessing virtual address `0x7F00_1000`:

**Without virtualisation:** The MMU walks the guest's page table hierarchy (PML4 $\rightarrow$ PDPT $\rightarrow$ PD $\rightarrow$ PT), finds that GVA `0x7F00_1000` maps to physical address `0x4000`, and accesses the memory at `0x4000`.

**With shadow page tables:** The hypervisor has constructed a shadow page table that maps GVA `0x7F00_1000` directly to HPA `0xA000`. This mapping reflects the composition: the guest's GPA `0x4000` is backed by HPA `0xA000` in the hypervisor's memory allocation. The MMU walks the shadow table and accesses HPA `0xA000`. The guest never sees the shadow table --- it sees its own page tables, which appear to map `0x7F00_1000` to `0x4000`.

The overhead arises when the guest modifies its page tables: every page table write causes a page fault (because the hypervisor write-protected the guest's page table pages), triggering a VM exit. The hypervisor then computes the new GVA-to-HPA mapping and updates the shadow table. On a context switch-heavy workload, the guest might modify hundreds of page table entries per millisecond, each causing a VM exit.
:::

Shadow page tables are correct but expensive: every guest page table modification causes a VM exit costing 1--3 microseconds. For workloads with frequent page table changes (e.g., process creation, context switches, memory mapping), the overhead can be 10--30% of total CPU time.

### 18.7.2 Extended Page Tables (EPT / NPT)

**Extended Page Tables** (EPT on Intel, Nested Page Tables / NPT on AMD) add a second level of hardware-managed address translation, eliminating the need for shadow page tables.

::: definition
**Extended Page Tables (EPT).** A hardware feature that adds a second page table hierarchy, managed by the hypervisor, that translates guest physical addresses (GPA) to host physical addresses (HPA). The CPU's MMU performs a **nested page walk**:

1. Walk the guest's page table to translate GVA to GPA.
2. At each step of the guest walk, walk the EPT to translate the physical address of the guest page table entry from GPA to HPA.
3. After completing the guest walk, walk the EPT one final time to translate the target GPA to HPA.

The guest can modify its own page tables freely without causing VM exits.
:::

The nested walk increases the worst-case memory accesses per TLB miss. With 4-level paging on both the guest and the EPT:

- Each level of the guest page walk requires an EPT walk to find the physical location of the next guest page table page.
- Each EPT walk itself traverses 4 levels.
- Total worst case: $4 \text{ guest levels} \times 4 \text{ EPT levels} + 4 \text{ EPT levels for final GPA} = 20$ memory accesses.

::: example
**Example 18.5 (EPT Nested Walk Cost).** Translating GVA `0x7F00_1000` with 4-level paging:

```text
Guest Page Walk:                    EPT Walks:
  PML4[i] at GPA g1                  g1 -> HPA: 4 memory accesses
  PDPT[j] at GPA g2                  g2 -> HPA: 4 memory accesses
  PD[k]   at GPA g3                  g3 -> HPA: 4 memory accesses
  PT[l]   at GPA g4                  g4 -> HPA: 4 memory accesses
  Data    at GPA g5                  g5 -> HPA: 4 memory accesses

Total worst-case memory accesses: 5 * 4 = 20
(or 4 * 4 + 4 = 20, depending on counting convention)
```

Despite this cost, EPT outperforms shadow page tables for most workloads because it completely eliminates VM exits on guest page table modifications. The TLB caches both guest and EPT translations (using tagged TLB entries with a VPID --- Virtual Processor ID), so the 20-access worst case is rare in practice. TLB hit rates are typically > 99% for well-behaved workloads.
:::

::: theorem
**Theorem 18.2 (EPT vs Shadow Page Table Trade-off).** Let $E_{\text{shadow}}$ be the exit rate due to guest page table modifications (exits/second) with shadow page tables, $C_{\text{exit}}$ be the cost per VM exit, $M_{\text{EPT}}$ be the rate of TLB misses, and $C_{\text{nested}}$ be the additional cost per TLB miss due to the nested walk. Then:

- Shadow page table overhead: $E_{\text{shadow}} \cdot C_{\text{exit}}$
- EPT overhead: $M_{\text{EPT}} \cdot C_{\text{nested}}$

EPT is preferred when $M_{\text{EPT}} \cdot C_{\text{nested}} < E_{\text{shadow}} \cdot C_{\text{exit}}$, which holds for virtually all server workloads because TLB misses are much less frequent than page table modifications, and $C_{\text{nested}}$ (a few hundred nanoseconds) is much less than $C_{\text{exit}}$ (1--3 microseconds).
:::

## 18.8 I/O Virtualisation

I/O is the most challenging aspect of virtualisation: devices are diverse, stateful, and performance-sensitive. The three approaches --- emulation, paravirtualisation, and pass-through --- form a spectrum of complexity, compatibility, and performance.

### 18.8.1 Emulated Devices

The simplest approach: the hypervisor presents a virtual device that mimics a real hardware device (e.g., an emulated Intel e1000 NIC or an emulated IDE disk controller). The guest uses standard drivers for these devices, and the hypervisor translates the guest's I/O operations into operations on the real hardware.

This approach is compatible with unmodified guests (they already have drivers for e1000) but slow: every I/O register access causes a VM exit, and the emulation logic in the hypervisor must faithfully replicate the device's behaviour.

### 18.8.2 Virtio

**Virtio** is a standard for paravirtualised I/O devices, designed for efficiency in virtualised environments.

::: definition
**Virtio.** A standardised interface for paravirtualised devices, consisting of:

1. **Virtqueues**: shared-memory ring buffers between the guest and the host. Each virtqueue has three regions:
   - **Descriptor table**: an array of descriptors, each pointing to a guest memory buffer.
   - **Available ring**: guest writes descriptor indices here to submit I/O requests.
   - **Used ring**: host writes descriptor indices here to report completions.

2. **Feature negotiation**: the guest and host negotiate which optional features they both support at device initialisation.

3. **Device types**: virtio-net (networking), virtio-blk (block storage), virtio-scsi (SCSI), virtio-fs (filesystem sharing), virtio-gpu (graphics), virtio-vsock (host-guest communication), and others.
:::

The virtqueue design minimises VM exits by **batching**: the guest can queue multiple I/O requests (filling the available ring) before notifying the host (a single VM exit via a PCI register write or `VMCALL`), and the host can complete multiple requests before notifying the guest (a single interrupt injection).

```text
Guest (virtio driver)                      Host (virtio backend)
┌──────────────────────┐                  ┌──────────────────────┐
│                      │                  │                      │
│  1. Allocate buffers │                  │                      │
│     in guest memory  │                  │                      │
│                      │   Shared Memory  │                      │
│  2. Write descriptor │   (descriptor    │                      │
│     indices to       │    table, avail  │  4. Read indices from│
│     available ring ──┼──  ring, used  ──┼──>  available ring   │
│                      │    ring)         │                      │
│  3. Notify host   ───┼── VM exit ───────┼──> 5. Process I/O    │
│     (kick)           │                  │     (read/write disk,│
│                      │                  │      send/recv pkt)  │
│                      │                  │                      │
│  7. Process          │                  │  6. Write indices to │
│     completions  <───┼──────────────────┼──── used ring +      │
│     from used ring   │                  │     inject IRQ       │
│                      │                  │                      │
└──────────────────────┘                  └──────────────────────┘
```

::: example
**Example 18.6 (Virtio Batching Performance).** Consider a guest sending 1000 network packets:

**Emulated e1000:** Each packet requires multiple I/O register writes (transmit descriptor, doorbell), each causing a VM exit. Total: approximately 2000--3000 VM exits for 1000 packets.

**Virtio-net:** The guest fills the available ring with 1000 descriptor indices, then kicks once. Total: 1 VM exit for 1000 packets (the host processes all pending descriptors in a single batch). With notification suppression (`VRING_AVAIL_F_NO_INTERRUPT`), even the completion interrupt can be suppressed until the guest polls.
:::

### 18.8.3 SR-IOV and VFIO

For near-native I/O performance, hardware can be passed directly to a guest.

**SR-IOV (Single Root I/O Virtualisation)** is a PCI Express standard that allows a single physical device (a **Physical Function**, PF) to present multiple **Virtual Functions** (VFs), each of which can be assigned to a different VM. Each VF has its own PCI configuration space, BAR (Base Address Register) space, and DMA engine, but shares the physical hardware (e.g., the same NIC ports).

::: definition
**SR-IOV.** A hardware standard that allows a PCIe device to create multiple lightweight virtual instances (Virtual Functions) that can be directly assigned to VMs. Each VF has its own I/O path, data plane, and DMA engine. The hypervisor is not involved in the data path --- packets flow directly between the guest and the VF hardware.
:::

**VFIO (Virtual Function I/O)** is the Linux framework for assigning PCI devices (or SR-IOV VFs) directly to VMs. VFIO uses the **IOMMU** (VT-d on Intel, AMD-Vi on AMD) to isolate DMA: the assigned device can only DMA to the guest's memory, not to the host or other guests. Without IOMMU protection, a malicious guest could program the device to DMA into arbitrary host memory.

```text
Without IOMMU:                     With IOMMU (VT-d/AMD-Vi):
Device DMA -> Physical Memory      Device DMA -> IOMMU -> Physical Memory
(any address!)                     (only guest's pages!)

                  ┌──────────────────────────────────┐
                  │          Physical NIC (SR-IOV)    │
                  │                                   │
                  │   PF (host driver manages)        │
                  │   ├── VF0 ──> VM1 (via VFIO)     │
                  │   ├── VF1 ──> VM2 (via VFIO)     │
                  │   └── VF2 ──> VM3 (via VFIO)     │
                  │                                   │
                  └──────────────────────────────────┘
                            │ DMA protected by IOMMU
```

| Method | Latency | Throughput | Guest Modification | VM Migration |
|---|---|---|---|---|
| Emulated device | High (~100 $\mu$s) | Low | None | Easy (virtual hardware) |
| Virtio | Medium (~10 $\mu$s) | High | Virtio driver needed | Easy (standard interface) |
| SR-IOV / VFIO | Very low (~1 $\mu$s) | Near-native | VF driver needed | Difficult (hardware state) |

## 18.9 Containers

Containers provide **OS-level virtualisation**: instead of virtualising the hardware, they virtualise the operating system's view of itself. All containers share the host kernel but have isolated views of processes, filesystems, networks, and resource limits.

### 18.9.1 Linux Namespaces

::: definition
**Linux Namespace.** A kernel feature that partitions system resources so that processes in one namespace cannot see or affect processes in another. Each namespace type isolates a different class of system resource.
:::

Linux provides eight namespace types:

| Namespace | Flag | Isolates | Introduced |
|---|---|---|---|
| Mount | `CLONE_NEWNS` | Filesystem mount points | Linux 2.4.19 |
| UTS | `CLONE_NEWUTS` | Hostname and domain name | Linux 2.6.19 |
| IPC | `CLONE_NEWIPC` | System V IPC, POSIX message queues | Linux 2.6.19 |
| PID | `CLONE_NEWPID` | Process IDs | Linux 2.6.24 |
| Network | `CLONE_NEWNET` | Network interfaces, routing, iptables | Linux 2.6.29 |
| User | `CLONE_NEWUSER` | UIDs/GIDs | Linux 3.8 |
| Cgroup | `CLONE_NEWCGROUP` | Cgroup root directory | Linux 4.6 |
| Time | `CLONE_NEWTIME` | CLOCK_MONOTONIC, CLOCK_BOOTTIME | Linux 5.6 |

Namespaces are created via `clone()` with the appropriate flags, or via `unshare()` for an existing process, or via `setns()` to join an existing namespace. Each namespace type has its own semantics:

**PID namespace:** The first process in a new PID namespace becomes PID 1 (the init process of that namespace). It cannot see processes in the parent namespace or other PID namespaces. The parent namespace, however, can see the container's processes (with different PIDs).

**Mount namespace:** Each container has its own mount table. Mounting or unmounting a filesystem inside a container does not affect the host or other containers. This is the foundation of container filesystem isolation.

**User namespace:** UIDs and GIDs inside the container are mapped to different UIDs/GIDs on the host. A process that appears as root (UID 0) inside the container might be mapped to UID 100000 on the host, meaning it has no special privileges on the host system.

::: example
**Example 18.7 (Namespace Isolation Demonstration).** On the host, running `ps aux` shows all processes. Inside a PID namespace:

```text
# On host:
$ ps aux | wc -l
347

# Inside container (new PID namespace):
$ ps aux
USER   PID %CPU %MEM    VSZ   RSS TTY  STAT START TIME COMMAND
root     1  0.0  0.0   4628  3512 pts/0 Ss  12:00 0:00 /bin/sh
root     5  0.0  0.0   7060  1604 pts/0 R+  12:00 0:00 ps aux

# The container sees only its own processes.
# Host sees container's PID 1 as PID 28547 (or similar).
```

The UTS namespace demonstrates hostname isolation:

```text
# On host:
$ hostname
production-server

# Inside container:
$ hostname mycontainer
$ hostname
mycontainer

# Back on host:
$ hostname
production-server    # unchanged
```
:::

### 18.9.2 Cgroups v2

**Control groups** (cgroups) limit, account for, and isolate the resource usage of process groups. Cgroups v2 (unified hierarchy, the default since Linux 5.0) organises all resource controllers under a single tree.

::: definition
**Cgroups v2.** The unified cgroup hierarchy in Linux, which provides per-group resource limits and accounting. Each cgroup (a directory in `/sys/fs/cgroup/`) can have limits set for:

- `cpu.max`: maximum CPU bandwidth (format: `$QUOTA $PERIOD`; e.g., `50000 100000` means 50% of one CPU).
- `cpu.weight`: proportional CPU share (1--10000, default 100).
- `memory.max`: hard memory limit in bytes.
- `memory.high`: soft memory limit (the kernel applies back-pressure via throttling).
- `io.max`: maximum I/O bandwidth per device.
- `pids.max`: maximum number of processes (prevents fork bombs).
:::

```text
# Create a cgroup with 50% CPU and 256 MB memory limit
mkdir /sys/fs/cgroup/mycontainer
echo "50000 100000" > /sys/fs/cgroup/mycontainer/cpu.max
echo "268435456" > /sys/fs/cgroup/mycontainer/memory.max
echo "100" > /sys/fs/cgroup/mycontainer/pids.max

# Move a process into the cgroup
echo $PID > /sys/fs/cgroup/mycontainer/cgroup.procs

# The kernel now enforces:
# - Process can use at most 50% of one CPU core
# - Total memory usage (RSS + cache) cannot exceed 256 MB
# - Cannot create more than 100 processes
```

If the processes in the cgroup exceed the memory limit, the kernel's OOM killer targets processes **within the cgroup**, not the host system. If they exceed the CPU limit, the scheduler throttles them (pauses execution until the next period).

### 18.9.3 OCI Runtime Specification and runc

The **Open Container Initiative (OCI)** defines two specifications:

1. **Runtime Specification**: how to run a container given a root filesystem (a directory tree) and a configuration file (`config.json`). The configuration specifies namespaces, cgroups, mounts, capabilities, seccomp filters, user mappings, and other isolation parameters.

2. **Image Specification**: how container images are structured --- as layers of filesystem changes (tarballs), with manifests and digests for content-addressable storage.

**runc** is the reference implementation of the OCI runtime specification. It is a standalone binary that creates and runs containers:

```text
$ mkdir -p mycontainer/rootfs
$ tar -C mycontainer/rootfs -xf alpine-rootfs.tar
$ cd mycontainer
$ runc spec                    # Generate default config.json
$ runc create mybox            # Create (namespaces, cgroups, mounts)
$ runc start mybox             # Start the container's init process
$ runc list                    # List running containers
$ runc exec mybox /bin/echo hi # Execute a command inside
$ runc delete mybox            # Clean up
```

Container runtimes like containerd and CRI-O use runc (or a compatible runtime like **crun** in C, or **youki** in Rust) as the low-level component that actually creates the container. The higher-level runtime manages image pulling, storage, networking, and lifecycle.

### 18.9.4 Podman vs Docker

Both Podman and Docker create and manage OCI containers, but their architectures differ fundamentally:

| Aspect | Docker | Podman |
|---|---|---|
| Architecture | Client-server: `docker` CLI talks to `dockerd` daemon via socket | Daemonless: `podman` CLI forks containers directly |
| Root requirement | `dockerd` runs as root (rootless mode added later) | Rootless by default (uses user namespaces) |
| Process model | All containers are children of `dockerd` PID | Each container is a child of the invoking process |
| Daemon dependency | If `dockerd` crashes, all containers lose their parent | No single point of failure |
| Systemd integration | Requires separate systemd unit for dockerd | `podman generate systemd` creates per-container units |
| Socket exposure | `/var/run/docker.sock` (root-owned, major security risk) | No system-wide socket by default |
| Compose | docker-compose (v1: Python, v2: Go plugin) | podman-compose (compatible wrapper) |
| OCI compliance | containerd + runc | conmon (monitor) + runc (or crun) |
| Pod support | No native pod concept (added via Compose) | Native pod support (shared namespaces) |

::: example
**Example 18.8 (Rootless Container with Podman).** Running a container as an unprivileged user:

```text
$ id
uid=1000(alice) gid=1000(alice)

$ podman run --rm -it alpine sh
/ # id
uid=0(root) gid=0(root)
/ # cat /proc/self/uid_map
         0       1000          1
         1     100000      65536
/ # exit

$ podman run --rm alpine cat /etc/hostname
f7a3b2c1d4e5
```

Inside the container, Alice appears as root (UID 0) thanks to user namespace mapping: the container's UID 0 is mapped to Alice's host UID 1000. UIDs 1--65536 in the container are mapped to subordinate UIDs 100000--165535 on the host (configured in `/etc/subuid`).

No daemon, no root privileges, no socket exposure. If Alice's account is compromised, the attacker is confined to Alice's user namespace --- they cannot escalate to real root.
:::

The daemonless architecture of Podman eliminates a critical attack surface: Docker's daemon runs as root and listens on a Unix socket (`/var/run/docker.sock`). Any process with access to that socket effectively has root access to the host (it can mount the host filesystem, run privileged containers, and more). Podman's direct-fork model means there is no single process whose compromise grants system-wide control.

::: programmer
**Programmer's Perspective: Building a Container Runtime in Go.**
Go is the dominant language for container infrastructure. Docker, containerd, runc, CRI-O, and Podman are all written in Go. The key system calls are `clone` (with namespace flags), `pivot_root`, `mount`, and `prctl`.

```go
package main

import (
    "fmt"
    "os"
    "os/exec"
    "syscall"
)

func main() {
    switch os.Args[1] {
    case "run":
        run()
    case "child":
        child()
    default:
        fmt.Println("Usage: container run <cmd> [args...]")
    }
}

func run() {
    // Re-exec ourselves as "child" in new namespaces.
    // This two-step approach is necessary because some namespaces
    // (e.g., PID) only take effect for child processes, not the
    // calling process.
    cmd := exec.Command("/proc/self/exe",
        append([]string{"child"}, os.Args[2:]...)...)
    cmd.Stdin = os.Stdin
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr
    cmd.SysProcAttr = &syscall.SysProcAttr{
        Cloneflags: syscall.CLONE_NEWUTS |
            syscall.CLONE_NEWPID |
            syscall.CLONE_NEWNS,
        // For rootless: add CLONE_NEWUSER and UidMappings/GidMappings
    }
    if err := cmd.Run(); err != nil {
        fmt.Fprintf(os.Stderr, "run error: %v\n", err)
        os.Exit(1)
    }
}

func child() {
    // We are now in new namespaces. In the PID namespace,
    // we are PID 1 (the init process).
    fmt.Printf("Container PID: %d\n", os.Getpid())

    // Set a container hostname (UTS namespace)
    syscall.Sethostname([]byte("container"))

    // Change root filesystem (requires a prepared rootfs)
    syscall.Chroot("/var/lib/containers/rootfs")
    syscall.Chdir("/")

    // Mount /proc for the new PID namespace
    // (without this, ps/top will show host processes)
    syscall.Mount("proc", "/proc", "proc", 0, "")

    // Execute the requested command
    cmd := exec.Command(os.Args[2], os.Args[3:]...)
    cmd.Stdin = os.Stdin
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr
    if err := cmd.Run(); err != nil {
        fmt.Fprintf(os.Stderr, "child error: %v\n", err)
    }

    // Clean up
    syscall.Unmount("/proc", 0)
}
```

This simplified runtime creates new UTS, PID, and mount namespaces, sets a hostname, pivots to a root filesystem, mounts `/proc`, and executes a command. A production runtime (runc, crun) adds: user namespaces with UID/GID mapping, cgroup configuration, seccomp filter installation, capability dropping, AppArmor/SELinux profile loading, proper `pivot_root` (not just `chroot`), console/PTY setup, and signal forwarding.

The Go standard library's `os/exec` and `syscall` packages provide clean abstractions for these operations. The `SysProcAttr` struct maps directly to the `clone()` flags, making Go a natural choice for container runtime development.
:::

## 18.10 The Virtualisation Spectrum

The techniques discussed in this chapter form a spectrum from heavyweight isolation (full VMs) to lightweight sharing (processes):

```text
  More isolation                                       Less isolation
  More overhead                                        Less overhead
  ◄──────────────────────────────────────────────────────────────────►

  Full VM          Lightweight VM      Container         Process
  (KVM+QEMU)       (Firecracker)      (Podman/runc)     (fork+exec)
  │                 │                  │                  │
  │ Own kernel      │ Own kernel       │ Shared kernel    │ Shared kernel
  │ Own devices     │ Minimal devices  │ Namespace        │ No namespace
  │ Full hardware   │ Reduced attack   │  isolation       │  isolation
  │  emulation      │  surface         │ Cgroup limits    │ ulimit only
  │                 │                  │                  │
  │ ~2-30 s boot    │ ~125 ms boot     │ ~50-500 ms boot  │ ~1 ms fork
  │ ~200 MB base    │ ~5 MB base       │ ~1-10 MB base    │ ~0 overhead
```

**Firecracker** (developed by Amazon for Lambda and Fargate) is a lightweight VMM built on KVM that boots a **microVM** in approximately 125 ms with ~5 MB of memory overhead. It provides the security of hardware virtualisation (each function or container gets its own kernel) with near-container startup times. Firecracker achieves this by eliminating most device emulation --- it provides only a virtio-net, virtio-blk, and a serial console. No USB, no GPU, no sound, no PCI bus enumeration.

**gVisor** (Google) takes yet another approach: it implements a user-space kernel (Sentry) that intercepts guest system calls and re-implements them safely. gVisor provides stronger isolation than containers (the host kernel is not directly exposed) with lower overhead than full VMs (no hardware virtualisation).

::: programmer
**Programmer's Perspective: Choosing the Right Isolation Level.**
The choice between VMs and containers is fundamentally a security/performance trade-off:

- **Multi-tenant cloud** (AWS, GCP): use VMs (KVM/Firecracker) for strong isolation between tenants. A kernel vulnerability in a container could let Tenant A access Tenant B's data. AWS Lambda uses Firecracker microVMs --- each function invocation gets its own VM.

- **Single-tenant deployment** (your own servers running your own code): containers (Podman) provide sufficient isolation with better density and faster startup.

- **Serverless functions** (AWS Lambda, Cloudflare Workers): Firecracker microVMs or V8 isolates (WebAssembly sandboxes) combine fast startup with hardware-level or language-level isolation.

- **Development and CI/CD**: containers are overwhelmingly preferred for their fast iteration cycle, reproducibility, and ecosystem (registries, Compose files, Kubernetes).

In Go, container orchestration is managed through the `containerd/containerd` client library. For KVM-level virtualisation from Go, the `firecracker-microvm/firecracker-go-sdk` provides a Go API to the Firecracker VMM.
:::

---

::: exercises
1. **Popek-Goldberg Classification.** The ARM architecture (pre-ARMv7) included the `MRS` instruction, which reads the CPSR (Current Program Status Register) without trapping when executed in user mode. Explain why this violates the Popek-Goldberg theorem (classify the instruction as sensitive, and show that it is not privileged). How does ARMv8 (AArch64) address this? What about RISC-V --- does it satisfy the Popek-Goldberg requirements natively?

2. **Shadow Page Table Cost Analysis.** Consider a guest with a working set of 1,000 pages. The guest modifies 50 page table entries per millisecond (due to page faults, context switches, etc.). Each page table modification causes a VM exit costing 2 microseconds. (a) Calculate the overhead of shadow page tables as a percentage of elapsed time per second. (b) Now suppose EPT is used instead, eliminating these VM exits but increasing each TLB miss cost from 4 memory accesses to 20 memory accesses. If TLB misses occur at a rate of 10,000 per second and each memory access takes 100 ns, calculate the EPT overhead per second. (c) Which approach is more efficient for this workload, and by how much?

3. **Virtio Ring Buffer Design.** The virtio specification uses a split virtqueue with three regions: descriptor table, available ring, and used ring. (a) Explain why a single shared ring buffer would be insufficient. (b) What concurrency issues does the split design address? (c) How does the available ring's `idx` field enable lock-free operation between guest and host? (d) Explain the role of the `VRING_USED_F_NO_NOTIFY` flag in reducing VM exit frequency.

4. **Namespace Composition.** A process creates a new PID namespace and a new network namespace but does **not** create a new mount namespace. The process then runs `ps aux` and `ip addr show` inside the new namespaces. (a) What does each command show? (b) Why might failing to create a new mount namespace cause `ps` to show unexpected results? (c) What happens if the process tries to mount a new `/proc` without a mount namespace?

5. **Container Escape Analysis.** Describe a concrete scenario in which a container escapes its isolation and gains host-level access. Your answer should specify: (a) which namespace or cgroup boundary is breached, (b) what kernel vulnerability or misconfiguration enables the escape, (c) what mitigation (from Chapter 17 or this chapter) would have prevented it, and (d) why this escape would not be possible from a KVM virtual machine.

6. **Hypervisor Scheduling.** A Type-1 hypervisor hosts four VMs, each with two vCPUs, on a host with four physical CPUs. Design a scheduling algorithm that ensures: (a) no vCPU starvation, (b) co-scheduling of vCPUs belonging to the same VM when the VM performs inter-vCPU synchronisation (e.g., spinlocks), and (c) fair CPU time distribution across VMs. Discuss the trade-offs between gang scheduling, relaxed co-scheduling, and independent vCPU scheduling. What pathology occurs when a VM's vCPUs are not co-scheduled and the guest uses spinlocks?

7. **Rootless Containers.** Explain the complete mechanism by which Podman runs containers without root privileges. Your answer should cover: (a) user namespace UID/GID mapping and how `/etc/subuid` and `/etc/subgid` are used, (b) how `newuidmap`/`newgidmap` setuid helpers bridge the gap between user namespaces and subordinate ID allocation, (c) what operations are still impossible in a rootless container (and why), (d) how rootless networking works (slirp4netns or pasta), and (e) the security implications compared to Docker's root-daemon model.
:::
