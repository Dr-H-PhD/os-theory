# Chapter 15: I/O Systems

*"The I/O system is the part of the operating system that mediates between the chaos of the physical world and the orderly abstractions that software expects. It is, by necessity, the messiest part of any kernel."*
--- Robert Love, *Linux Kernel Development*

---

## 15.1 I/O Hardware Foundations

The I/O subsystem of an operating system must manage an extraordinary diversity of devices: keyboards that produce ten bytes per second, NVMe drives that sustain seven gigabytes per second, and network interfaces that must process millions of packets per second with microsecond latency. Despite this diversity, I/O hardware shares a common architectural pattern: a **controller** mediates between the device's physical mechanism and the system bus, presenting a set of **registers** that software can read and write.

### 15.1.1 Ports, Buses, and Controllers

A modern computer system connects devices through a hierarchy of **buses**:

```text
CPU <---> Memory Controller <---> DRAM
 |
 +---> PCIe Root Complex
        |
        +---> PCIe x16: GPU
        +---> PCIe x4:  NVMe SSD
        +---> PCIe x1:  Network card
        |
        +---> DMI/Chipset
               |
               +---> SATA Controller ---> SATA SSD/HDD
               +---> USB Controller  ---> USB devices
               +---> Audio Controller
               +---> LPC/eSPI ---> Keyboard, TPM
```

::: definition
**Device Controller.** A device controller is a hardware component that acts as the interface between the system bus and the device. It contains a set of registers (status, control, data-in, data-out) that the CPU reads and writes to communicate with the device. Complex controllers (SATA, NVMe, USB) contain their own microprocessors and firmware.
:::

Every device controller exposes at least three types of registers:

- **Status register:** Reports the current state of the device (busy, ready, error). The CPU reads this register to determine whether the device is ready for the next operation.

- **Control (command) register:** The CPU writes to this register to issue commands to the device (start transfer, reset, configure parameters).

- **Data registers:** Used to transfer data between the CPU and the device. Simple devices have a single data register; complex devices may have FIFO buffers.

### 15.1.2 Register Access: Port-Mapped vs Memory-Mapped I/O

The CPU can access device registers through two mechanisms:

**Port-Mapped I/O (PMIO).** The device registers occupy a separate address space from memory, accessed with dedicated I/O instructions. On x86, the `IN` and `OUT` instructions transfer data to/from 16-bit port addresses (0x0000--0xFFFF). The x86 I/O address space is limited to 64 KB.

```c
#include <stdint.h>

/* Port-mapped I/O: read a byte from a port */
static inline uint8_t inb(uint16_t port) {
    uint8_t val;
    __asm__ volatile ("inb %1, %0" : "=a"(val) : "Nd"(port));
    return val;
}

/* Port-mapped I/O: write a byte to a port */
static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile ("outb %0, %1" : : "a"(val), "Nd"(port));
}

/* Example: read the CMOS real-time clock seconds register */
uint8_t read_rtc_seconds(void) {
    outb(0x70, 0x00);     /* Select register 0 (seconds) */
    return inb(0x71);      /* Read the value */
}
```

**Memory-Mapped I/O (MMIO).** The device registers are mapped into the CPU's physical address space. Normal load/store instructions access the registers. The memory controller routes accesses to the appropriate device based on the physical address.

```c
#include <stdint.h>

/* Memory-mapped I/O: typical for ARM, PCIe devices, framebuffers */
#define UART_BASE  0x101F1000  /* PL011 UART on ARM Versatile */
#define UART_DR    (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UART_FR    (*(volatile uint32_t *)(UART_BASE + 0x18))
#define UART_FR_TXFF  (1 << 5)  /* Transmit FIFO full */

void uart_putchar(char c) {
    while (UART_FR & UART_FR_TXFF) {
        /* Spin until transmit FIFO has space */
    }
    UART_DR = c;
}
```

::: definition
**Volatile Access.** When accessing memory-mapped device registers, the `volatile` qualifier (in C/C++) tells the compiler that the value at this address may change at any time (due to hardware activity) and that accesses must not be optimised away, reordered, or cached in a CPU register. Without `volatile`, the compiler may eliminate "redundant" reads or defer writes, causing the driver to malfunction.
:::

::: example
**Example 15.1 (Why Volatile Matters).** Consider polling a status register:

```c
/* WITHOUT volatile --- compiler may optimise this to an infinite loop */
uint32_t *status = (uint32_t *)0x40001000;
while (*status & BUSY_FLAG) {
    /* wait */
}
/* The compiler sees no writes to *status in the loop body,
   concludes *status never changes, and hoists the read
   out of the loop. The loop either never executes or
   never terminates. */

/* WITH volatile --- each iteration re-reads from the hardware */
volatile uint32_t *status = (volatile uint32_t *)0x40001000;
while (*status & BUSY_FLAG) {
    /* wait --- each iteration reads the actual hardware register */
}
```
:::

Modern systems predominantly use MMIO. PCIe devices are always memory-mapped; legacy x86 devices (keyboard controller, serial ports, PIC) use port-mapped I/O.

---

## 15.2 I/O Communication Mechanisms

The CPU must coordinate with devices to transfer data and signal completion. Three mechanisms exist, each representing a different trade-off between CPU utilisation and latency.

### 15.2.1 Polling (Programmed I/O)

In polling, the CPU repeatedly reads the device's status register in a tight loop, waiting for the device to signal readiness. This is also called **busy waiting** or **spin waiting**.

```c
/* Polling-based serial port output */
#define SERIAL_PORT   0x3F8
#define LINE_STATUS   (SERIAL_PORT + 5)
#define THR_EMPTY     0x20

void serial_putchar_polling(char c) {
    /* Poll the line status register until the transmit
       holding register is empty */
    while ((inb(LINE_STATUS) & THR_EMPTY) == 0) {
        /* busy wait */
    }
    outb(SERIAL_PORT, c);
}
```

**Analysis:** Polling wastes CPU cycles during the wait. If the device responds in $t_{\text{device}}$ time and the CPU polls every $t_{\text{poll}}$ cycle, the CPU wastes up to $t_{\text{device}} / t_{\text{poll}}$ poll iterations. For a slow device (disk: $t_{\text{device}} \sim 5\,\text{ms}$) and a fast CPU ($t_{\text{poll}} \sim 1\,\text{ns}$), that is 5 million wasted iterations.

**When polling is appropriate:**

- The device responds extremely quickly (latency < 1 $\mu$s), making the overhead of an interrupt greater than the polling cost.

- The system is dedicated to a single task (embedded controller waiting for a sensor).

- High-throughput networking where the cost of interrupt processing exceeds the cost of polling (DPDK, kernel bypass).

### 15.2.2 Interrupt-Driven I/O

In interrupt-driven I/O, the device signals the CPU via a hardware **interrupt** when it requires attention. The CPU is free to execute other code between I/O operations.

::: definition
**Hardware Interrupt.** A signal from a device controller to the CPU indicating that the device requires attention (data is ready, transfer is complete, error occurred). The CPU suspends its current execution, saves state, and transfers control to an **interrupt handler** (also called an **interrupt service routine**, ISR) associated with the device.
:::

The interrupt mechanism involves:

1. **Interrupt request (IRQ):** The device asserts an interrupt line.

2. **Interrupt controller:** The Programmable Interrupt Controller (PIC) or Advanced Programmable Interrupt Controller (APIC) prioritises and routes the interrupt to the appropriate CPU.

3. **CPU response:** The CPU finishes the current instruction, pushes the return address and flags onto the stack, disables further interrupts (optionally), and jumps to the ISR via the **interrupt descriptor table** (IDT on x86).

4. **ISR execution:** The ISR handles the event (reads data from the device, acknowledges the interrupt, wakes up a waiting process).

5. **Return from interrupt:** The ISR restores state and returns control to the interrupted code.

```c
/* Simplified interrupt-driven serial driver (Linux kernel style) */
#include <linux/interrupt.h>

static irqreturn_t serial_isr(int irq, void *dev_id) {
    struct serial_port *port = dev_id;
    uint8_t status = inb(port->base + LINE_STATUS);

    if (status & DATA_READY) {
        uint8_t data = inb(port->base);
        /* Place data in a ring buffer for the reading process */
        ring_buffer_put(&port->rx_buf, data);
        /* Wake up any process waiting for data */
        wake_up_interruptible(&port->rx_wait);
        return IRQ_HANDLED;
    }
    return IRQ_NONE;  /* Not our interrupt */
}

/* During driver initialisation: */
int ret = request_irq(IRQ_SERIAL, serial_isr, IRQF_SHARED,
                       "serial", port);
```

**Message-Signalled Interrupts (MSI/MSI-X).** Traditional interrupt lines are physical wires shared among multiple devices (requiring the ISR to poll each device to determine which raised the interrupt). Modern PCIe devices use **Message-Signalled Interrupts** (MSI), where the device signals an interrupt by writing a specific value to a specific memory address.

::: definition
**MSI-X (Message Signalled Interrupts --- Extended).** An interrupt delivery mechanism where each device can have up to 2048 independent interrupt vectors. Each vector has its own message address and message data. The device writes the message data to the message address (a write to a special region of the LAPIC's address space), which the CPU treats as an interrupt. MSI-X eliminates shared interrupt lines, enables per-queue interrupts (critical for NVMe, which has thousands of queues), and allows interrupt steering to specific CPU cores.
:::

With MSI-X, an NVMe SSD can direct completion interrupts for each queue pair to the CPU core that submitted the request, eliminating cross-core interrupt forwarding and improving cache locality.

::: example
**Example 15.13 (Interrupt Routing with MSI-X).** An NVMe SSD has 8 I/O queue pairs. With MSI-X, each queue pair is assigned its own interrupt vector, routed to the CPU core that manages that queue:

| Queue Pair | MSI-X Vector | Target CPU |
|-----------|-------------|-----------|
| 0 | Vector 33 | CPU 0 |
| 1 | Vector 34 | CPU 1 |
| 2 | Vector 35 | CPU 2 |
| 3 | Vector 36 | CPU 3 |
| 4 | Vector 37 | CPU 4 |
| 5 | Vector 38 | CPU 5 |
| 6 | Vector 39 | CPU 6 |
| 7 | Vector 40 | CPU 7 |

When a completion arrives on queue pair 3, the NVMe controller writes to vector 36's message address, which the APIC routes to CPU 3. CPU 3 processes the completion without any inter-processor interrupt (IPI) or cross-core cache transfer.
:::

::: theorem
**Theorem 15.1 (Interrupt vs. Polling Break-Even).** Let $C_{\text{poll}}$ be the CPU cost of one poll iteration, $C_{\text{intr}}$ be the total CPU cost of servicing an interrupt (context save, ISR execution, context restore), and $T_{\text{device}}$ be the average device response time. Polling is more efficient than interrupts when:

$$\frac{T_{\text{device}}}{C_{\text{poll}}} < \frac{C_{\text{intr}}}{C_{\text{poll}}}$$

That is, when the number of poll iterations (wasted cycles) is less than the interrupt overhead measured in poll-equivalent cycles. With modern CPUs, $C_{\text{intr}} \approx 1{,}000\text{--}5{,}000$ cycles and $C_{\text{poll}} \approx 10\text{--}50$ cycles, so polling wins when the device responds in fewer than approximately 100--500 poll iterations ($\sim 1\text{--}5\,\mu$s).
:::

### 15.2.3 Direct Memory Access (DMA)

For bulk data transfers (disk I/O, network packets, GPU data), having the CPU copy data byte-by-byte between device registers and memory is grossly inefficient. **Direct Memory Access** (DMA) offloads the data transfer to a dedicated DMA controller, freeing the CPU for other work.

::: definition
**Direct Memory Access (DMA).** A mechanism by which a device controller transfers data directly between the device and main memory without CPU intervention. The CPU sets up the transfer (source address, destination address, byte count, direction) in the DMA controller's registers, then the DMA controller independently moves data over the system bus. When the transfer completes, the DMA controller raises an interrupt.
:::

The DMA transfer sequence is:

1. The CPU programs the DMA controller: memory address, byte count, direction (device-to-memory or memory-to-device), and device identifier.

2. The CPU issues a command to the device controller to begin the transfer.

3. The DMA controller arbitrates for the system bus and transfers data directly between the device and memory, one word or burst at a time.

4. Upon completion, the DMA controller raises an interrupt to notify the CPU.

```text
DMA Transfer:
                    1. CPU programs DMA
CPU ---[setup]---> DMA Controller ---[bus master]---> Memory
                        |                              ^
                        |         2. Data transfer     |
                    Device Controller -----------------+
                        |
                    3. Completion interrupt
                        +---> CPU (ISR)
```

**Bus mastering.** Modern DMA-capable devices (PCIe NVMe controllers, network cards) are **bus masters**: they can initiate transfers on the bus without needing a separate DMA controller chip. The device itself contains the DMA engine.

::: example
**Example 15.2 (DMA Throughput Advantage).** Reading a 4 KB block from disk via programmed I/O (PIO) versus DMA:

**PIO:** The CPU executes 1024 iterations of a 32-bit `IN` instruction (4 bytes per iteration). Each iteration takes approximately 100 ns (I/O bus latency). Total CPU time: $1024 \times 100\,\text{ns} = 102.4\,\mu$s. The CPU is 100\% busy during the transfer.

**DMA:** The CPU programs the DMA controller (approximately 500 ns), then is free. The DMA controller transfers 4 KB at bus speed (e.g., 3.2 GB/s for PCIe 3.0 x1): $4096 / 3.2 \times 10^9 \approx 1.3\,\mu$s. The CPU handles the completion interrupt (approximately 2 $\mu$s). Total CPU time: approximately 2.5 $\mu$s. The CPU is free for approximately 1.3 $\mu$s during the transfer.

For large transfers (1 MB), the advantage is dramatic: PIO ties up the CPU for 25.6 ms; DMA takes 312 $\mu$s of bus time with approximately 2.5 $\mu$s of CPU time.
:::

**Scatter-Gather DMA.** Modern DMA controllers support **scatter-gather lists**: a single DMA operation can transfer data between the device and multiple non-contiguous memory regions. This is essential for performance because:

- The operating system uses virtual memory, and a logically contiguous buffer may span multiple physical pages.

- Network packets have headers and payloads in different memory regions.

- File system buffers for a single read request may come from different pages in the page cache.

The scatter-gather list is an array of (physical address, length) pairs:

```c
struct scatterlist {
    unsigned long  page_link;    /* page pointer + flags */
    unsigned int   offset;       /* offset within the page */
    unsigned int   length;       /* transfer length */
    dma_addr_t     dma_address;  /* DMA (bus) address */
    unsigned int   dma_length;   /* DMA transfer length */
};
```

### 15.2.4 The IOMMU: Protecting DMA

DMA is powerful but dangerous: a misbehaving or compromised device could DMA to arbitrary physical memory, reading secrets from other processes or overwriting kernel data structures. The **IOMMU** (I/O Memory Management Unit) provides hardware-enforced isolation for DMA transfers.

::: definition
**IOMMU (I/O Memory Management Unit).** A hardware unit that translates device-visible addresses (I/O virtual addresses, or IOVA) to physical addresses, and enforces access control on DMA transactions. The IOMMU performs the same function for devices that the MMU performs for CPUs: address translation and protection.

On Intel platforms, the IOMMU is called **VT-d** (Virtualization Technology for Directed I/O). On AMD platforms, it is called **AMD-Vi**.
:::

Without an IOMMU, the kernel must give devices physical addresses for DMA buffers. Any device can read or write any physical address. This is problematic for:

- **Security:** A compromised device (malicious USB device, firmware-hacked NIC) can read kernel memory, exfiltrate data, or inject code.

- **Virtualisation:** To assign a device to a virtual machine (PCI passthrough), the hypervisor must ensure the device can only access the VM's memory, not the host's or other VMs' memory.

- **Error containment:** A buggy device driver that programs incorrect DMA addresses can corrupt arbitrary memory. With an IOMMU, the transaction is blocked and an error is reported.

The IOMMU maintains **I/O page tables** (similar to CPU page tables) that map IOVAs to physical addresses. The kernel configures these page tables when setting up DMA mappings:

```c
/* Linux DMA mapping API (simplified) */
#include <linux/dma-mapping.h>

/* Map a kernel buffer for DMA access by a device */
dma_addr_t dma_addr = dma_map_single(dev, buffer, size, DMA_TO_DEVICE);
if (dma_mapping_error(dev, dma_addr)) {
    /* Mapping failed */
    return -ENOMEM;
}

/* Give dma_addr to the device --- this is an IOVA, not a physical address */
write_device_register(dev, DMA_ADDR_REG, dma_addr);

/* After DMA completes, unmap */
dma_unmap_single(dev, dma_addr, size, DMA_TO_DEVICE);
```

::: example
**Example 15.12 (IOMMU Address Translation).** A process allocates a buffer at virtual address `0x7fff_0000_0000`, which maps to physical address `0x0000_0234_5000`. The kernel programs the IOMMU to map IOVA `0x0000_0100_0000` to physical `0x0000_0234_5000`. The device receives IOVA `0x0000_0100_0000` and initiates DMA.

The IOMMU translates: $\text{IOVA } \texttt{0x0100\_0000} \to \text{Physical } \texttt{0x0234\_5000}$

If the device attempts to DMA to IOVA `0x0000_0200_0000` (which has no mapping), the IOMMU blocks the transaction and raises an interrupt (DMAR fault on Intel, reported in `dmesg`).
:::

---

## 15.3 Kernel I/O Subsystem

The kernel's I/O subsystem provides services that are common across all device types, shielding device drivers from low-level details and applications from device diversity.

### 15.3.1 I/O Scheduling

When multiple processes issue I/O requests simultaneously, the kernel must decide the order in which to service them. The goals of I/O scheduling are:

- **Fairness:** No process should be starved of I/O service.
- **Throughput:** Maximise the number of I/O operations completed per second.
- **Latency:** Minimise the time between issuing a request and receiving a response.

These goals often conflict. For rotational disks, reordering requests to minimise seek distance improves throughput but may increase latency for some requests. The kernel's **I/O scheduler** (also called the **elevator**) mediates this trade-off.

### 15.3.2 Buffering

**Buffering** is the use of a memory area to temporarily store data being transferred between two entities (application and device, or two devices) that operate at different speeds or with different transfer granularities.

::: definition
**I/O Buffering.** The kernel uses buffers to decouple the production and consumption of data. Three levels of buffering are common:

1. **Single buffering:** One kernel buffer. The device fills the buffer; when full, the kernel copies data to the user buffer. Transfer and processing cannot overlap.

2. **Double buffering:** Two kernel buffers. While the device fills one buffer, the kernel processes (copies to user space) the other. Transfer and processing overlap.

3. **Circular (ring) buffering:** $n$ buffers arranged in a ring. The producer (device) fills the next empty buffer; the consumer (kernel/application) drains the next full buffer. This is the standard pattern for high-throughput I/O.
:::

::: example
**Example 15.3 (Double Buffering Throughput).** A device transfers data at rate $R_d$ and the CPU processes (copies) data at rate $R_c$. With single buffering, the total time for $n$ transfers is:

$$T_{\text{single}} = n \times (T_d + T_c) = n \times \left(\frac{B}{R_d} + \frac{B}{R_c}\right)$$

where $B$ is the buffer size. With double buffering, the transfer and copy overlap:

$$T_{\text{double}} = T_d + (n - 1) \times \max(T_d, T_c) + T_c$$

For $R_d = R_c$, single buffering gives throughput $R_d / 2$; double buffering gives throughput $R_d$ --- a twofold improvement.
:::

### 15.3.3 Caching

The **page cache** (discussed in Chapter 14) is the kernel's primary caching mechanism for block devices. Additionally, the kernel caches:

- **Dentry cache (dcache):** Name-to-inode translations.
- **Inode cache:** Recently accessed inode structures.
- **Buffer heads:** Metadata about cached disk blocks.

Caching and buffering are distinct concepts. A **cache** stores a copy of data that also exists elsewhere, trading memory for reduced I/O. A **buffer** holds the only copy of data that is in transit. The page cache serves both roles: it caches frequently read data and buffers dirty pages awaiting writeback.

### 15.3.4 Spooling

**Spooling** (Simultaneous Peripheral Operations On-Line) queues I/O operations for devices that can serve only one request at a time, such as printers. Instead of blocking a process while the printer is busy, the system copies the output to a spool directory on disk. A **spool daemon** dequeues jobs and sends them to the printer one at a time.

The print spooler is a classic example: `lp` on Unix copies the file to `/var/spool/cups/`, and the CUPS daemon manages the queue. This converts a non-sharable device into a shared resource.

---

## 15.4 Block Devices and Character Devices

The kernel classifies devices into two fundamental categories based on their data transfer characteristics.

::: definition
**Block Device.** A device that stores data in fixed-size blocks (typically 512 bytes or 4 KB) and supports random access. Each block has a unique address. Examples: hard disks, SSDs, USB flash drives, CD-ROMs.

**Character Device.** A device that produces or consumes a stream of bytes sequentially, without block structure or random access. Examples: serial ports, keyboards, mice, audio devices, printers.
:::

In Linux, the distinction is visible in the device file system:

```text
$ ls -l /dev/sda /dev/ttyS0
brw-rw---- 1 root disk  8, 0 Apr 16 10:00 /dev/sda      (block device)
crw-rw---- 1 root dialout 4, 64 Apr 16 10:00 /dev/ttyS0  (character device)
```

The leading `b` or `c` indicates the device type. The two numbers (8,0 and 4,64) are the **major** and **minor** device numbers: the major number identifies the driver, and the minor number identifies the specific device managed by that driver.

Block devices support an additional abstraction layer: the **request queue**. I/O requests to a block device are placed in a queue where the I/O scheduler can reorder and merge them before dispatching to the driver. Character devices have no such queue; requests are passed directly to the driver.

::: programmer
**Programmer's Perspective: Go's `io.Reader` and `io.Writer` as OS Abstractions.**
Go's `io.Reader` and `io.Writer` interfaces are the language-level equivalent of the kernel's block/character device abstraction. Every I/O source in Go implements one or both:

```go
type Reader interface {
    Read(p []byte) (n int, err error)
}

type Writer interface {
    Write(p []byte) (n int, err error)
}
```

This mirrors how the kernel presents devices to user space: everything is a file descriptor that supports `read()` and `write()`. The power of this abstraction is composition. Just as the kernel can stack a buffer cache on top of a block device, Go can stack `bufio.Reader` on top of any `io.Reader`:

```go
package main

import (
    "bufio"
    "compress/gzip"
    "fmt"
    "io"
    "os"
)

func processStream(r io.Reader) error {
    scanner := bufio.NewScanner(r)
    lines := 0
    for scanner.Scan() {
        lines++
    }
    if err := scanner.Err(); err != nil {
        return err
    }
    fmt.Printf("Processed %d lines\n", lines)
    return nil
}

func main() {
    // Open a gzip-compressed file
    f, err := os.Open("access.log.gz")
    if err != nil {
        fmt.Fprintf(os.Stderr, "open: %v\n", err)
        os.Exit(1)
    }
    defer f.Close()

    // Stack: file -> gzip decompressor -> line scanner
    // Each layer implements io.Reader
    gz, err := gzip.NewReader(f)
    if err != nil {
        fmt.Fprintf(os.Stderr, "gzip: %v\n", err)
        os.Exit(1)
    }
    defer gz.Close()

    // processStream works with ANY io.Reader:
    // a file, a network connection, a gzip stream, or a test stub
    if err := processStream(gz); err != nil {
        fmt.Fprintf(os.Stderr, "process: %v\n", err)
        os.Exit(1)
    }
}
```

This composability is directly analogous to the kernel's I/O stack. In the Linux kernel, a read from an encrypted file system on a RAID array passes through: VFS $\to$ ext4 $\to$ dm-crypt $\to$ md (RAID) $\to$ block layer $\to$ NVMe driver. Each layer implements the same `bio` (block I/O) interface. In Go, `f` (file) $\to$ `gz` (decompressor) $\to$ `scanner` (line buffer) --- each implements `io.Reader`.

The key design lesson: when you define I/O interfaces in your own code, accept `io.Reader` and `io.Writer` rather than concrete types. This makes your code testable (pass a `bytes.Buffer` in tests), composable (wrap with compression, encryption, buffering), and resilient to changes in the underlying I/O source.
:::

---

## 15.5 Disk Scheduling Algorithms

For rotational hard disk drives (HDDs), the time to service an I/O request has three components:

$$T_{\text{access}} = T_{\text{seek}} + T_{\text{rotation}} + T_{\text{transfer}}$$

where:

- $T_{\text{seek}}$ is the time to move the disk arm to the target track (0.5--10 ms, depending on distance).
- $T_{\text{rotation}}$ is the time to wait for the target sector to rotate under the head. On average, half a revolution: for a 7200 RPM drive, $T_{\text{rotation}} = \frac{1}{2} \times \frac{60}{7200} = 4.17\,\text{ms}$.
- $T_{\text{transfer}}$ is the time to read or write the data once the head is positioned (typically $< 0.1$ ms for a single sector).

Since seek time dominates, disk scheduling algorithms focus on **minimising total seek distance** across a set of pending requests.

### 15.5.1 FCFS (First-Come, First-Served)

Requests are serviced in the order they arrive. This is fair but can result in wildly inefficient head movement.

::: example
**Example 15.4 (FCFS Scheduling).** The disk has 200 tracks (0--199). The head starts at track 53. The request queue is: 98, 183, 37, 122, 14, 124, 65, 67.

Head movement: $53 \to 98 \to 183 \to 37 \to 122 \to 14 \to 124 \to 65 \to 67$

Total seek distance: $|53-98| + |98-183| + |183-37| + |37-122| + |122-14| + |14-124| + |124-65| + |65-67|$
$= 45 + 85 + 146 + 85 + 108 + 110 + 59 + 2 = 640$ tracks.
:::

### 15.5.2 SSTF (Shortest Seek Time First)

Select the request closest to the current head position. This is a greedy algorithm that minimises seek time locally.

::: example
**Example 15.5 (SSTF Scheduling).** Same setup as Example 15.4. Head at 53.

1. Closest to 53: 65 (distance 12). Move to 65.
2. Closest to 65: 67 (distance 2). Move to 67.
3. Closest to 67: 37 (distance 30). Move to 37.
4. Closest to 37: 14 (distance 23). Move to 14.
5. Closest to 14: 98 (distance 84). Move to 98.
6. Closest to 98: 122 (distance 24). Move to 122.
7. Closest to 122: 124 (distance 2). Move to 124.
8. Closest to 124: 183 (distance 59). Move to 183.

Total: $12 + 2 + 30 + 23 + 84 + 24 + 2 + 59 = 236$ tracks.
:::

SSTF significantly reduces total seek distance compared to FCFS. However, it can cause **starvation**: requests at the extremes of the disk may wait indefinitely if new requests keep arriving near the current head position.

::: theorem
**Theorem 15.2 (SSTF Optimality).** SSTF does not minimise total seek distance in general. The problem of minimising total seek distance for a set of pending requests is equivalent to the Travelling Salesman Problem on a line (1D TSP), which can be solved optimally in $O(n^2)$ time by dynamic programming. However, in an online setting where new requests arrive continuously, no algorithm can guarantee optimality.
:::

### 15.5.3 SCAN (Elevator Algorithm)

The SCAN algorithm moves the head in one direction, servicing all requests in its path, until it reaches the end of the disk. It then reverses direction and services requests on the return sweep.

::: example
**Example 15.6 (SCAN Scheduling).** Head at 53, moving towards 0.

Downward sweep: $53 \to 37 \to 14 \to 0$ (reverse at end)
Upward sweep: $0 \to 65 \to 67 \to 98 \to 122 \to 124 \to 183$

Total: $(53-37) + (37-14) + (14-0) + (0-0) + (65-0) + (67-65) + (98-67) + (122-98) + (124-122) + (183-124)$
$= 16 + 23 + 14 + 65 + 2 + 31 + 24 + 2 + 59 = 236$ tracks.

Note: SCAN always goes to the end of the disk (track 0) before reversing, even if no requests remain in that direction.
:::

SCAN provides a bounded waiting time: every request is serviced within at most two full sweeps of the disk. It avoids SSTF's starvation problem.

### 15.5.4 C-SCAN (Circular SCAN)

C-SCAN services requests only in one direction. When the head reaches the end of the disk, it **jumps back** to the beginning without servicing any requests on the return, then resumes scanning in the original direction.

This provides more **uniform waiting times**: the head does not service some requests on both the forward and backward sweeps (which SCAN does, giving a bias towards the middle tracks).

::: example
**Example 15.7 (C-SCAN Scheduling).** Head at 53, moving upward.

Forward sweep: $53 \to 65 \to 67 \to 98 \to 122 \to 124 \to 183 \to 199$ (end of disk)
Jump to 0 (no service during jump)
Forward sweep: $0 \to 14 \to 37$

Total seek distance (counting the jump): $12 + 2 + 31 + 24 + 2 + 59 + 16 + 199 + 14 + 23 = 382$ tracks.

Without counting the return jump (which is fast on real hardware): $12 + 2 + 31 + 24 + 2 + 59 + 16 + 14 + 23 = 183$ tracks.
:::

### 15.5.5 LOOK and C-LOOK

**LOOK** is a practical variant of SCAN: instead of going to the physical end of the disk, the head reverses when it reaches the **last request** in the current direction. **C-LOOK** is the corresponding variant of C-SCAN.

::: example
**Example 15.8 (C-LOOK Scheduling).** Head at 53, moving upward.

Forward sweep: $53 \to 65 \to 67 \to 98 \to 122 \to 124 \to 183$ (last request in this direction; jump to lowest pending request)
Jump to 14 (no service during jump)
Forward sweep: $14 \to 37$

Total (excluding jump): $12 + 2 + 31 + 24 + 2 + 59 + 23 = 153$ tracks.
:::

### 15.5.6 Comparison Summary

| Algorithm | Total Seek (Example) | Starvation | Variance |
|-----------|---------------------|------------|----------|
| FCFS | 640 | No | High |
| SSTF | 236 | Yes | Medium |
| SCAN | 236 | No | Medium |
| C-SCAN | 382 (183 effective) | No | Low |
| C-LOOK | 153 | No | Low |

In practice, the Linux kernel's default I/O scheduler for rotational disks is **mq-deadline**, which combines elements of SCAN with deadline-based request aging to prevent starvation.

### 15.5.7 Seek Time Modelling

The seek time function for a typical HDD is not linear. It has two components: the time to accelerate and decelerate the arm, and the time to traverse the distance. A common model is:

$$T_{\text{seek}}(d) = a + b \sqrt{d}$$

where $d$ is the seek distance in tracks, $a$ is the arm start/stop overhead (approximately 0.5--1 ms), and $b$ is a scaling constant that depends on the drive's actuator.

::: example
**Example 15.9 (Seek Time Estimation).** A drive has $a = 0.8\,\text{ms}$ and $b = 0.2\,\text{ms}/\sqrt{\text{track}}$. Track seek times:

| Seek Distance (tracks) | Seek Time |
|------------------------|-----------|
| 1 | $0.8 + 0.2 \times 1.0 = 1.0\,\text{ms}$ |
| 10 | $0.8 + 0.2 \times 3.16 = 1.43\,\text{ms}$ |
| 100 | $0.8 + 0.2 \times 10.0 = 2.8\,\text{ms}$ |
| 1,000 | $0.8 + 0.2 \times 31.6 = 7.12\,\text{ms}$ |
| 10,000 | $0.8 + 0.2 \times 100.0 = 20.8\,\text{ms}$ |

The square-root model captures the physics: most of the seek time is spent accelerating and decelerating the arm, with the middle portion of a long seek at maximum velocity. This is why reducing seek distance by reordering requests (SSTF, SCAN) yields significant latency reductions.
:::

::: theorem
**Theorem 15.3 (Expected Seek Distance Under Uniform Random Requests).** If the disk has $N$ tracks and requests arrive at uniformly random positions, the expected seek distance under FCFS scheduling is:

$$E[d] = \frac{N}{3}$$

*Proof.* The expected value of $|X - Y|$ where $X$ and $Y$ are independent uniform random variables on $[0, N]$ is:

$$E[|X - Y|] = \int_0^N \int_0^N \frac{|x - y|}{N^2}\, dx\, dy = \frac{N}{3}$$

The integral evaluates by splitting into regions $x > y$ and $x < y$, each contributing $N/6$. $\square$
:::

This result means that under random I/O, the average FCFS seek traverses one-third of the disk. For a 10,000-track disk, the expected seek distance is approximately 3,333 tracks --- explaining why random I/O is so much slower than sequential I/O on HDDs.

---

## 15.6 NVMe and Modern Storage

Solid-state drives (SSDs), particularly those using the **NVMe** (Non-Volatile Memory Express) protocol over PCIe, have fundamentally changed the I/O landscape. Traditional disk scheduling algorithms were designed to minimise mechanical seek time --- a concern that does not exist for SSDs.

### 15.6.1 NVMe Architecture

NVMe communicates directly over PCIe, bypassing the SATA/AHCI controller that was designed for rotational disks. Key architectural features:

::: definition
**NVMe Submission and Completion Queues.** NVMe uses a paired queue model. Each I/O path consists of a **Submission Queue (SQ)** where the host places commands, and a **Completion Queue (CQ)** where the device places completion entries. The host writes a **doorbell register** to notify the device of new submissions. The device writes to the CQ and optionally raises an interrupt.
:::

```text
NVMe Queue Architecture:
                                                  NVMe SSD
Host CPU                                     +----------------+
+------------------+                         |                |
| Application      |                         | Flash          |
+--------+---------+                         | Controller     |
         |                                   |                |
+--------v---------+    PCIe Bus            |  +----------+  |
| NVMe Driver      |<=====================>|  | SQ Parser |  |
| +---+ +---+ +---+|                       |  +----+-----+  |
| |SQ1| |SQ2| |SQn||  Submission Queues    |       |         |
| +---+ +---+ +---+|  (in host memory)     |  +----v-----+  |
| +---+ +---+ +---+|                       |  | Command   |  |
| |CQ1| |CQ2| |CQn||  Completion Queues    |  | Execution |  |
| +---+ +---+ +---+|  (in host memory)     |  +----+-----+  |
+------------------+                        |       |         |
                                            |  +----v-----+  |
                                            |  | CQ Writer |  |
                                            |  +----------+  |
                                            +----------------+
```

**NVMe supports up to 65,535 I/O queue pairs**, one per CPU core or more. This eliminates the single-queue bottleneck of SATA/AHCI (which supported only 1 command queue of depth 32). A modern NVMe SSD can handle 64,000+ outstanding commands across all queues.

### 15.6.2 Command Queues and Parallelism

Each NVMe submission queue entry is 64 bytes and describes a single command (read, write, flush, etc.). The queue is a circular buffer in host memory:

```c
/* Simplified NVMe submission queue entry */
struct nvme_sqe {
    uint8_t  opcode;         /* Read, Write, Flush, etc. */
    uint8_t  flags;
    uint16_t command_id;     /* Unique ID for matching completions */
    uint32_t nsid;           /* Namespace ID (like a partition) */
    uint64_t reserved;
    uint64_t metadata;       /* Metadata pointer */
    uint64_t prp1;           /* Physical Region Page 1 (data pointer) */
    uint64_t prp2;           /* PRP 2 or PRP List pointer */
    uint32_t cdw10;          /* Command-specific: start LBA (low) */
    uint32_t cdw11;          /* Command-specific: start LBA (high) */
    uint32_t cdw12;          /* Command-specific: block count */
    uint32_t cdw13;
    uint32_t cdw14;
    uint32_t cdw15;
};
```

The completion queue entry (16 bytes) reports the result:

```c
struct nvme_cqe {
    uint32_t result;         /* Command-specific result */
    uint32_t reserved;
    uint16_t sq_head;        /* SQ head pointer (consumed commands) */
    uint16_t sq_id;          /* SQ identifier */
    uint16_t command_id;     /* Matches the submission's command_id */
    uint16_t status;         /* Status field (success/error) */
};
```

### 15.6.3 Interrupt Coalescing

With SSDs capable of completing millions of I/O operations per second (IOPS), raising an interrupt for every completion would overwhelm the CPU. **Interrupt coalescing** batches multiple completions into a single interrupt:

- **Time-based:** The device raises an interrupt after a configurable time threshold (e.g., 100 $\mu$s) since the last interrupt.

- **Count-based:** The device raises an interrupt after a configurable number of completions (e.g., 16 completions) since the last interrupt.

- **Hybrid:** The first condition met triggers the interrupt.

The trade-off is latency (delay before the CPU learns of completions) versus CPU efficiency (fewer interrupts). For latency-sensitive workloads, coalescing is disabled.

### 15.6.4 No Mechanical Seek

Because SSDs have no moving parts, the traditional disk scheduling algorithms (FCFS, SSTF, SCAN) provide **no benefit**. Access time is independent of the address:

$$T_{\text{SSD}} \approx T_{\text{controller}} + T_{\text{flash}} \approx 10\text{--}100\,\mu\text{s}$$

The Linux kernel uses the **none** (noop) I/O scheduler for NVMe devices: requests are passed directly to the device in submission order, as the device's internal controller can optimise parallelism across flash channels better than the host.

---

## 15.7 Asynchronous I/O

Traditional Unix I/O is **synchronous**: `read()` and `write()` block the calling thread until the operation completes. For high-performance servers handling thousands of concurrent connections or I/O streams, this model is inadequate --- one thread per I/O source does not scale.

### 15.7.1 The Scalability Problem

Consider a web server handling 10,000 concurrent connections. With synchronous I/O, it needs 10,000 threads, each blocked in `read()` most of the time. The overhead of 10,000 thread stacks (each 1--8 MB), context switches, and scheduler pressure makes this approach impractical.

**Multiplexing** (`select()`, `poll()`, `epoll()`) partially solves this by allowing a single thread to monitor many file descriptors. But the actual I/O operations are still synchronous: after `epoll_wait()` returns, the thread must call `read()` for each ready descriptor, and each `read()` involves a system call (user-kernel transition).

### 15.7.2 POSIX AIO

POSIX Asynchronous I/O (`aio_read()`, `aio_write()`) was an early attempt at asynchronous I/O. The application submits an I/O request and continues execution; the kernel signals completion later.

```c
#include <aio.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    int fd = open("data.bin", O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }

    char buf[4096];
    struct aiocb cb;
    memset(&cb, 0, sizeof(cb));
    cb.aio_fildes = fd;
    cb.aio_buf = buf;
    cb.aio_nbytes = sizeof(buf);
    cb.aio_offset = 0;

    /* Submit asynchronous read */
    if (aio_read(&cb) == -1) {
        perror("aio_read");
        close(fd);
        return 1;
    }

    /* Do other work while I/O is in progress... */
    printf("I/O submitted, doing other work...\n");

    /* Wait for completion */
    while (aio_error(&cb) == EINPROGRESS) {
        /* Could do useful work here instead of busy-waiting */
        usleep(1000);
    }

    ssize_t n = aio_return(&cb);
    printf("Read %zd bytes\n", n);

    close(fd);
    return 0;
}
```

POSIX AIO has significant limitations on Linux: the glibc implementation uses a thread pool internally (each `aio_read` spawns or reuses a thread that calls synchronous `read()`), negating much of the performance benefit. The kernel's native AIO (`io_submit()`) works only with `O_DIRECT` files, limiting its applicability.

### 15.7.3 Event-Driven I/O: select, poll, epoll

Before io_uring, the dominant approach to handling many concurrent I/O sources was **event-driven** (or **multiplexed**) I/O. A single thread monitors many file descriptors and is notified when any becomes ready for reading or writing.

**`select()` (1983).** The original Unix mechanism. The caller provides three bitmasks (read, write, exception) of file descriptors to monitor. The kernel scans all file descriptors in each bitmask and returns which are ready. Limitations: maximum 1024 file descriptors (FD_SETSIZE), $O(n)$ kernel scan on every call, and the bitmasks must be rebuilt after each call.

**`poll()` (1986).** Replaces bitmasks with an array of `struct pollfd`, removing the 1024-descriptor limit. But the $O(n)$ kernel scan remains: the kernel must check every descriptor in the array, even if only one is ready.

**`epoll()` (Linux 2.5.44, 2002).** A scalable event notification mechanism that avoids the $O(n)$ scan:

::: definition
**epoll.** A Linux-specific I/O event notification facility. An `epoll` instance maintains a set of monitored file descriptors using a red-black tree. When a file descriptor becomes ready, the kernel adds it to a **ready list** via a callback. The `epoll_wait()` call returns only the ready descriptors, in $O(k)$ time where $k$ is the number of ready descriptors (not the total number monitored).
:::

```c
#include <sys/epoll.h>
#include <stdio.h>
#include <unistd.h>

#define MAX_EVENTS 64

int main(void) {
    /* Create an epoll instance */
    int epfd = epoll_create1(0);

    /* Add stdin (fd 0) to the interest list */
    struct epoll_event ev = {
        .events = EPOLLIN,   /* Interested in read readiness */
        .data.fd = 0         /* User data: the fd itself */
    };
    epoll_ctl(epfd, EPOLL_CTL_ADD, 0, &ev);

    /* Wait for events (blocking) */
    struct epoll_event events[MAX_EVENTS];
    int n = epoll_wait(epfd, events, MAX_EVENTS, -1);

    for (int i = 0; i < n; i++) {
        if (events[i].events & EPOLLIN) {
            char buf[256];
            ssize_t len = read(events[i].data.fd, buf, sizeof(buf));
            if (len > 0) {
                printf("Read %zd bytes from fd %d\n", len, events[i].data.fd);
            }
        }
    }

    close(epfd);
    return 0;
}
```

::: example
**Example 15.14 (Scalability of epoll vs select).** A server monitors 10,000 concurrent connections. On each call:

- **`select()`:** The kernel scans 10,000 bits in each of three bitmasks. Even if only 5 connections are ready, the scan takes $O(10{,}000)$ time. Additionally, the user must rebuild the bitmasks before each call, copying 3.75 KB to/from the kernel each time.

- **`epoll_wait()`:** The kernel returns only the 5 ready descriptors. Cost: $O(5)$, independent of the total number of monitored descriptors. The interest list is persistent (no rebuild needed).

For high-concurrency servers (10,000+ connections), epoll is 100x--1000x more efficient than select/poll. This is why every modern Linux network server (nginx, Node.js, Go's netpoll) uses epoll internally.
:::

Go's runtime uses `epoll` (on Linux) internally for all network I/O. When a goroutine calls `conn.Read()` on a network connection, the Go runtime registers the socket with the runtime's `epoll` instance, parks the goroutine, and wakes it when data arrives. From the programmer's perspective, the code looks synchronous, but the underlying I/O is fully event-driven. This is Go's "goroutines on multiplexed I/O" model --- the best of both worlds.

### 15.7.3 Linux io_uring

**io_uring**, introduced in Linux 5.1 (2019) by Jens Axboe, is a modern asynchronous I/O framework that addresses all the limitations of previous approaches. It is the most significant addition to the Linux I/O stack in over a decade.

::: definition
**io_uring.** An asynchronous I/O interface that uses two shared ring buffers between user space and the kernel: a **Submission Queue (SQ)** where the application places I/O requests, and a **Completion Queue (CQ)** where the kernel places results. The ring buffers are in shared memory, allowing both submission and completion to be performed without system calls in the fast path.
:::

```text
io_uring Architecture:
+-------------------------------------------------+
|                  User Space                      |
|                                                  |
|   Application                                    |
|   +----------+              +----------+         |
|   |  Submit  |              |  Reap    |         |
|   |  SQEs    |              |  CQEs    |         |
|   +----+-----+              +----+-----+         |
|        |                         ^               |
|        v                         |               |
|   +----+-------------------------+----+          |
|   |    Shared Memory Ring Buffers     |          |
|   | +----------+    +----------+      |          |
|   | |    SQ    |    |    CQ    |      |          |
|   | | (submit) |    | (complete)|     |          |
|   | +----+-----+    +-----+----+     |          |
|   +------|-----------------|----------+          |
+---------|-----------------|---------   ----------+
|   +-----v-----------------v-----+                |
|   |      Kernel I/O Engine      |                |
|   | (processes SQEs, posts CQEs)|                |
|   +-----------------------------+                |
|                Kernel Space                       |
+-------------------------------------------------+
```

The key innovation is that submission and completion are **lock-free** operations on shared memory. The application writes a Submission Queue Entry (SQE) to the SQ ring buffer and advances the tail pointer. The kernel reads from the head pointer. No system call is needed unless the kernel is sleeping and needs to be woken up (via `io_uring_enter()`).

```c
#include <liburing.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>

#define QUEUE_DEPTH 64
#define BLOCK_SIZE  4096

int main(void) {
    struct io_uring ring;
    int ret = io_uring_queue_init(QUEUE_DEPTH, &ring, 0);
    if (ret < 0) {
        fprintf(stderr, "io_uring_queue_init: %s\n", strerror(-ret));
        return 1;
    }

    int fd = open("data.bin", O_RDONLY | O_DIRECT);
    if (fd < 0) { perror("open"); return 1; }

    /* Allocate aligned buffer for O_DIRECT */
    void *buf;
    posix_memalign(&buf, BLOCK_SIZE, BLOCK_SIZE);

    /* Prepare a read SQE */
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqe, fd, buf, BLOCK_SIZE, 0);
    sqe->user_data = 42;  /* Tag for matching completions */

    /* Submit --- one system call for all pending SQEs */
    io_uring_submit(&ring);

    /* Wait for completion */
    struct io_uring_cqe *cqe;
    ret = io_uring_wait_cqe(&ring, &cqe);
    if (ret < 0) {
        fprintf(stderr, "io_uring_wait_cqe: %s\n", strerror(-ret));
        return 1;
    }

    if (cqe->res < 0) {
        fprintf(stderr, "I/O error: %s\n", strerror(-cqe->res));
    } else {
        printf("Read %d bytes (tag=%llu)\n", cqe->res,
               (unsigned long long)cqe->user_data);
    }

    /* Mark CQE as consumed */
    io_uring_cqe_seen(&ring, cqe);

    free(buf);
    close(fd);
    io_uring_queue_exit(&ring);
    return 0;
}
```

**io_uring key features:**

- **Batching:** Multiple SQEs can be submitted with a single `io_uring_submit()` call, amortising system call overhead.

- **SQ Polling (SQPOLL):** A kernel thread polls the SQ for new submissions, eliminating system calls entirely. The application just writes to shared memory. This mode achieves the highest possible IOPS.

- **Linked operations:** SQEs can be chained so that the next operation starts only after the previous one completes (e.g., read then write).

- **Fixed buffers and files:** Pre-registering buffers and file descriptors eliminates per-operation kernel lookups.

- **Beyond file I/O:** io_uring supports network operations (`accept`, `connect`, `send`, `recv`), timers, and even `open`/`close`/`stat` --- it is evolving into a general-purpose asynchronous syscall interface.

::: example
**Example 15.9 (io_uring Performance).** In benchmarks, io_uring achieves:

- **Random 4 KB reads:** Up to 1.7 million IOPS per core with SQPOLL (versus 400K IOPS with synchronous `read()` and `io_submit` with 700K IOPS).

- **System call overhead:** With SQPOLL, zero system calls in the submission path. Without SQPOLL, one `io_uring_enter()` per batch of submissions.

- **Latency:** P99 latency of 10--15 $\mu$s for NVMe reads, versus 20--40 $\mu$s for synchronous reads.
:::

---

## 15.8 Device Drivers

A **device driver** is a kernel module that implements the interface between the kernel's abstract I/O model and the specific hardware of a particular device. Drivers are the most common source of kernel code: in the Linux kernel, `drivers/` accounts for over 60\% of the total source code.

### 15.8.1 Driver Architecture

A Linux device driver typically consists of:

1. **Initialisation and cleanup functions:** `module_init()` and `module_exit()` register and deregister the driver.

2. **Operations structure:** A struct of function pointers (`file_operations`, `block_device_operations`, `net_device_ops`) that the kernel calls when applications perform I/O.

3. **Interrupt handler:** Services hardware interrupts from the device.

4. **Internal data structures:** Device-specific state, ring buffers, command queues.

```c
/* Minimal Linux character device driver skeleton */
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/uaccess.h>

#define DEVICE_NAME "mydev"
#define BUF_SIZE    4096

static dev_t dev_num;
static struct cdev my_cdev;
static struct class *my_class;
static char device_buffer[BUF_SIZE];
static int buffer_len;

static int mydev_open(struct inode *inode, struct file *filp) {
    pr_info("mydev: opened\n");
    return 0;
}

static ssize_t mydev_read(struct file *filp, char __user *buf,
                           size_t count, loff_t *f_pos) {
    int to_copy = min((int)count, buffer_len - (int)*f_pos);
    if (to_copy <= 0) return 0;
    if (copy_to_user(buf, device_buffer + *f_pos, to_copy))
        return -EFAULT;
    *f_pos += to_copy;
    return to_copy;
}

static ssize_t mydev_write(struct file *filp, const char __user *buf,
                            size_t count, loff_t *f_pos) {
    int to_copy = min((int)count, BUF_SIZE);
    if (copy_from_user(device_buffer, buf, to_copy))
        return -EFAULT;
    buffer_len = to_copy;
    return to_copy;
}

static int mydev_release(struct inode *inode, struct file *filp) {
    pr_info("mydev: closed\n");
    return 0;
}

static const struct file_operations mydev_fops = {
    .owner   = THIS_MODULE,
    .open    = mydev_open,
    .read    = mydev_read,
    .write   = mydev_write,
    .release = mydev_release,
};

static int __init mydev_init(void) {
    alloc_chrdev_region(&dev_num, 0, 1, DEVICE_NAME);
    cdev_init(&my_cdev, &mydev_fops);
    cdev_add(&my_cdev, dev_num, 1);
    my_class = class_create(DEVICE_NAME);
    device_create(my_class, NULL, dev_num, NULL, DEVICE_NAME);
    pr_info("mydev: registered as %d:%d\n", MAJOR(dev_num), MINOR(dev_num));
    return 0;
}

static void __exit mydev_exit(void) {
    device_destroy(my_class, dev_num);
    class_destroy(my_class);
    cdev_del(&my_cdev);
    unregister_chrdev_region(dev_num, 1);
    pr_info("mydev: unregistered\n");
}

module_init(mydev_init);
module_exit(mydev_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Minimal character device driver");
```

### 15.8.2 Top-Half and Bottom-Half Processing

Interrupt handlers must execute quickly because they run with interrupts disabled (or at elevated priority), blocking other interrupts and delaying process scheduling. However, many interrupt-triggered tasks require significant processing: assembling network packets, updating file system metadata, signalling waiting processes.

The solution is to split interrupt handling into two halves:

::: definition
**Top-Half (Hard IRQ Handler).** The function that runs immediately when the interrupt fires. It must be fast: acknowledge the interrupt, read essential device registers, and schedule deferred work. It runs in **interrupt context** (cannot sleep, cannot call blocking functions, cannot access user memory).

**Bottom-Half (Deferred Work).** Processing that can be deferred to a safer context. Bottom halves run with interrupts enabled and can perform more complex operations. Linux provides several mechanisms for bottom-half processing.
:::

**Linux bottom-half mechanisms:**

1. **Softirqs:** Fixed-number, statically defined deferred functions. Used by the networking stack (`NET_TX_SOFTIRQ`, `NET_RX_SOFTIRQ`) and block layer. Softirqs can run concurrently on multiple CPUs.

2. **Tasklets:** Built on softirqs but dynamically allocatable. A given tasklet is serialised (cannot run on two CPUs simultaneously), simplifying locking. Suitable for simple per-device deferred work.

3. **Workqueues:** Deferred work that runs in process context (a kernel thread). Workqueue handlers **can sleep**, making them suitable for complex operations that may need to allocate memory, acquire mutexes, or perform I/O. The default workqueue (`system_wq`) is shared; drivers can create dedicated workqueues for performance isolation.

4. **Threaded IRQs:** A modern alternative where the interrupt handler is split into a fast primary handler (top-half) and a threaded handler that runs as a kernel thread. The `IRQF_ONESHOT` flag keeps the interrupt line masked until the threaded handler completes.

```c
/* Example: threaded IRQ handler */
static irqreturn_t my_isr_primary(int irq, void *dev_id) {
    struct my_device *dev = dev_id;
    uint32_t status = readl(dev->regs + STATUS_REG);
    if (!(status & MY_IRQ_PENDING))
        return IRQ_NONE;
    /* Acknowledge the interrupt in hardware */
    writel(status, dev->regs + STATUS_REG);
    /* Save status for the threaded handler */
    dev->irq_status = status;
    return IRQ_WAKE_THREAD;  /* Wake the threaded handler */
}

static irqreturn_t my_isr_threaded(int irq, void *dev_id) {
    struct my_device *dev = dev_id;
    /* This runs in process context --- can sleep, allocate memory, etc. */
    if (dev->irq_status & DATA_READY) {
        process_incoming_data(dev);      /* May sleep */
        wake_up(&dev->wait_queue);       /* Wake user-space readers */
    }
    return IRQ_HANDLED;
}

/* Registration */
ret = request_threaded_irq(irq, my_isr_primary, my_isr_threaded,
                            IRQF_ONESHOT, "mydev", dev);
```

::: programmer
**Programmer's Perspective: The Linux Block Layer.**
When you call `read()` on a file, your request passes through a surprisingly deep stack before reaching the hardware:

```text
User space:     read(fd, buf, 4096)
                    |
Kernel VFS:     vfs_read() -> file->f_op->read_iter()
                    |
File system:    ext4_file_read_iter() -> generic_file_read_iter()
                    |
Page cache:     filemap_read() -> page not cached? ->
                    |
Block layer:    submit_bio() -> blk_mq_submit_bio()
                    |
I/O scheduler:  mq-deadline / bfq / none
                    |
Device driver:  nvme_queue_rq() -> writes SQE to NVMe submission queue
                    |
Hardware:       NVMe SSD processes command, DMAs data to host memory
                    |
Completion:     NVMe CQE -> nvme_irq() -> blk_mq_complete_request()
                -> end_bio() -> unlocks page -> wakes up reader
```

The block layer uses the `bio` (block I/O) structure to represent I/O requests:

```c
struct bio {
    struct block_device *bi_bdev;   /* Target device */
    unsigned int         bi_opf;    /* Operation (READ/WRITE) + flags */
    sector_t             bi_iter.bi_sector; /* Starting sector */
    struct bio_vec      *bi_io_vec; /* Scatter-gather list of pages */
    /* ... */
};
```

The `bio` structure is the universal currency of the block layer. File systems create `bio`s; the I/O scheduler reorders and merges them; device drivers consume them. This clean interface means that any file system works with any block device driver --- the block layer provides the abstraction boundary.

For Go programmers, the equivalent insight is that `io.Reader` is Go's `bio` --- the universal unit of data flow. Just as the Linux block layer can stack encryption (dm-crypt), RAID (md), and thin provisioning (dm-thin) between a file system and a device driver by transforming `bio` objects, Go programs stack `io.Reader` implementations for compression, buffering, and decryption.
:::

---

## 15.9 Performance Considerations

### 15.9.1 System Call Overhead

Every I/O operation that goes through the kernel requires at least one system call. On modern x86-64 Linux, a system call takes approximately 100--300 ns (the `syscall` instruction itself plus kernel entry/exit overhead). For a simple `read()` that hits the page cache, the system call overhead may dominate the actual work.

Strategies to reduce system call overhead:

- **Batching:** `readv()`/`writev()` (vectored I/O) perform multiple reads/writes in a single system call.

- **Memory mapping:** `mmap()` maps a file into the process's address space. Subsequent accesses are regular memory loads/stores --- no system calls. Page faults bring data from disk on demand.

- **io_uring:** As discussed, eliminates system calls in the fast path.

### 15.9.2 Zero-Copy I/O

Traditional I/O involves multiple data copies:

```text
Traditional file-to-network transfer:
1. read(file_fd, buf, n)     -> DMA: disk -> kernel buffer
                              -> CPU: kernel buffer -> user buffer
2. write(sock_fd, buf, n)    -> CPU: user buffer -> kernel buffer (socket)
                              -> DMA: kernel buffer -> NIC

Total: 4 copies, 2 system calls, 4 user-kernel transitions
```

**Zero-copy** techniques eliminate unnecessary copies:

- **`sendfile()`:** Transfers data directly from one file descriptor to another within the kernel:

```c
#include <sys/sendfile.h>

/* Send a file over a socket without copying to user space */
off_t offset = 0;
ssize_t sent = sendfile(sock_fd, file_fd, &offset, file_size);
/* Only 2 copies: disk -> kernel buffer (DMA), kernel buffer -> NIC (DMA) */
```

- **`splice()`:** More general than `sendfile()`; moves data between a file descriptor and a pipe without copying.

- **io_uring with fixed buffers:** Pre-registered buffers avoid per-operation mapping overhead.

### 15.9.3 I/O Latency Hierarchy

Understanding the latency hierarchy is essential for performance engineering:

| Operation | Latency | Relative |
|-----------|---------|----------|
| L1 cache hit | 1 ns | 1x |
| L2 cache hit | 4 ns | 4x |
| L3 cache hit | 10 ns | 10x |
| DRAM access | 60--100 ns | 100x |
| NVMe SSD read (4 KB) | 10--20 $\mu$s | 15,000x |
| SATA SSD read (4 KB) | 50--100 $\mu$s | 75,000x |
| HDD random read (4 KB) | 5--10 ms | 7,500,000x |
| Network round-trip (same DC) | 0.5 ms | 500,000x |
| Network round-trip (cross-continent) | 100 ms | 100,000,000x |

::: programmer
**Programmer's Perspective: Measuring I/O Performance in Go.**
Go provides excellent tools for benchmarking I/O performance. Here is a benchmark comparing buffered versus unbuffered reads:

```go
package iobench

import (
    "bufio"
    "io"
    "os"
    "testing"
)

func BenchmarkUnbufferedRead(b *testing.B) {
    f, err := os.Open("/dev/zero")
    if err != nil {
        b.Fatal(err)
    }
    defer f.Close()

    buf := make([]byte, 1)
    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        f.Read(buf) // One system call per byte
    }
}

func BenchmarkBufferedRead(b *testing.B) {
    f, err := os.Open("/dev/zero")
    if err != nil {
        b.Fatal(err)
    }
    defer f.Close()

    r := bufio.NewReaderSize(f, 4096) // Buffer 4 KB at a time
    buf := make([]byte, 1)
    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        r.Read(buf) // System call only every 4096 bytes
    }
}

func BenchmarkReadAll(b *testing.B) {
    for i := 0; i < b.N; i++ {
        f, err := os.Open("/dev/zero")
        if err != nil {
            b.Fatal(err)
        }
        // Read exactly 1 MB
        _, err = io.CopyN(io.Discard, f, 1024*1024)
        f.Close()
        if err != nil {
            b.Fatal(err)
        }
    }
}
```

Typical results on a modern system:

```text
BenchmarkUnbufferedRead    5000000    230 ns/op   (system call per byte)
BenchmarkBufferedRead     50000000     25 ns/op   (system call per 4096 bytes)
BenchmarkReadAll              2000   650000 ns/op  (1 MB via io.Copy)
```

The buffered read is approximately 10x faster per byte because it amortises system call overhead. This is why Go's `bufio` package exists: it is the user-space equivalent of the kernel's buffer cache. Always wrap raw `os.File` readers in `bufio.Reader` for byte-at-a-time or line-at-a-time processing.
:::

---

## 15.10 The Linux I/O Scheduler in Detail

### 15.10.1 Multi-Queue Block Layer (blk-mq)

Since Linux 3.13, the block layer uses the **multi-queue** (blk-mq) architecture, which replaces the single request queue of the legacy block layer with per-CPU software queues and per-hardware-queue dispatch queues:

```text
blk-mq Architecture:

CPU 0        CPU 1        CPU 2        CPU 3
  |            |            |            |
  v            v            v            v
[SW Queue 0] [SW Queue 1] [SW Queue 2] [SW Queue 3]
  |            |            |            |
  +-----+------+-----+------+-----+------+
        |            |            |
        v            v            v
   [HW Queue 0] [HW Queue 1] [HW Queue 2]
        |            |            |
        +------+-----+------+-----+
               |
        Device Driver
```

Software queues are per-CPU and lockless (each CPU enqueues requests to its own queue without contention). Hardware queues map to the device's actual command queues (e.g., NVMe submission queues). The I/O scheduler sits between the software and hardware queues.

### 15.10.2 Available I/O Schedulers

Linux provides three blk-mq I/O schedulers:

**`none` (noop).** Requests are passed directly from software queues to hardware queues in FIFO order. No reordering, no merging. This is the default for NVMe devices, where the device's internal parallelism handles optimisation better than the host.

**`mq-deadline`.** Maintains two sorted queues (one for reads, one for writes) and two deadline queues. Requests are normally dispatched in sector order (SCAN-like), but any request that has waited longer than a deadline (default: 500 ms for reads, 5 s for writes) is promoted. Reads are given priority over writes because reads are typically synchronous (a process is waiting) while writes are typically asynchronous (buffered by the page cache).

**`bfq` (Budget Fair Queueing).** A proportional-share scheduler that assigns each process a "budget" of sectors. Processes that perform sequential I/O get larger budgets (because sequential access is efficient). BFQ provides excellent interactive performance (low latency for desktop applications) but has higher CPU overhead than mq-deadline.

::: example
**Example 15.10 (Changing the I/O Scheduler).** The scheduler can be changed at runtime via sysfs:

```text
# View available and current scheduler for /dev/sda
cat /sys/block/sda/queue/scheduler
# [mq-deadline] bfq none

# Switch to BFQ
echo bfq > /sys/block/sda/queue/scheduler

# View scheduler parameters
ls /sys/block/sda/queue/iosched/
# fifo_expire_async  fifo_expire_sync  read_expire  write_expire  ...

# Tune mq-deadline: reduce read deadline to 100ms
echo 100 > /sys/block/sda/queue/iosched/read_expire
```
:::

### 15.10.3 I/O Priorities and cgroups

Linux supports I/O priorities through the `ionice` utility and the `ioprio_set()` system call. Three scheduling classes are available:

- **Real-time (class 1):** Highest priority. The process gets first access to the disk. Eight priority levels (0--7). Only available to root.

- **Best-effort (class 2):** Default class. Eight priority levels. Processes at the same level share the disk fairly.

- **Idle (class 3):** Lowest priority. The process gets disk time only when no other process needs it. Useful for background tasks (backup, indexing).

For containerised workloads, the **blkio cgroup** controller provides per-group I/O bandwidth limits and weight-based scheduling:

```text
# Limit a cgroup to 50 MB/s read and 20 MB/s write on /dev/sda
echo "8:0 rbps=52428800 wbps=20971520" > \
    /sys/fs/cgroup/my_container/io.max

# Set relative weight (100-10000, default 100)
echo "8:0 weight=500" > /sys/fs/cgroup/my_container/io.bfq.weight
```

---

## 15.11 Power Management and I/O

Modern I/O devices support multiple power states to reduce energy consumption:

### 15.11.1 Device Power States

::: definition
**Device Power States.** ACPI (Advanced Configuration and Power Interface) defines device power states D0 through D3:

- **D0:** Fully operational. Maximum power consumption, zero wake-up latency.
- **D1/D2:** Intermediate low-power states. Partial functionality preserved. Wake-up latency: microseconds to milliseconds.
- **D3hot:** Device powered but non-functional. Context may be preserved. Wake-up latency: milliseconds.
- **D3cold:** Device fully powered off. All context lost. Wake-up latency: seconds.
:::

For storage devices:

- **HDD standby:** The platters stop spinning. Saves 5--10 W but incurs a 5--15 second spin-up delay.

- **SSD power states:** NVMe defines power states PS0 (active) through PS4 (deepest sleep). PS0 consumes 5--25 W; PS4 consumes 2--5 mW. Transitions take microseconds to milliseconds. The **Autonomous Power State Transition (APST)** feature allows the drive to enter low-power states automatically after a configurable idle timeout.

### 15.11.2 I/O Impact on System Power

On a modern laptop, the storage subsystem accounts for 5--15\% of total power consumption during active use and can be the dominant consumer during idle periods (if the system fails to enter a low-power state). Key strategies:

- **Aggressive PM timeouts:** Spin down HDDs after 60--120 seconds of inactivity.
- **Write coalescing:** Buffer writes and flush in batches rather than writing individually (each write resets the idle timer).
- **Read-ahead tuning:** Aggressive read-ahead reduces the number of future I/O operations (and future wake-ups).
- **Avoid unnecessary I/O:** Mount with `noatime` to prevent read operations from triggering writes (access time updates).

::: example
**Example 15.11 (NVMe Power State Calculation).** An NVMe SSD supports 5 power states:

| State | Power | Entry Latency | Exit Latency |
|-------|-------|--------------|-------------|
| PS0 | 25 W | -- | -- |
| PS1 | 8 W | 5 $\mu$s | 10 $\mu$s |
| PS2 | 5 W | 50 $\mu$s | 100 $\mu$s |
| PS3 | 30 mW | 2 ms | 5 ms |
| PS4 | 4 mW | 10 ms | 25 ms |

With APST configured: idle $\to$ PS1 after 100 ms, PS1 $\to$ PS3 after 2 s, PS3 $\to$ PS4 after 30 s.

During a typical desktop workload (active 20\% of the time, idle 80\%), the average power is:

$$P_{\text{avg}} = 0.20 \times 25\,\text{W} + 0.10 \times 8\,\text{W} + 0.10 \times 5\,\text{W} + 0.30 \times 0.03\,\text{W} + 0.30 \times 0.004\,\text{W}$$
$$= 5.0 + 0.8 + 0.5 + 0.009 + 0.0012 \approx 6.31\,\text{W}$$

Without power management (always PS0): $P_{\text{avg}} = 25\,\text{W}$. APST reduces SSD power by 75\%.
:::

---

## 15.12 Error Handling in I/O

### 15.12.1 Error Classification

I/O errors fall into several categories that require different handling strategies:

- **Transient errors:** Temporary conditions that may succeed on retry (bus contention, CRC mismatch due to noise, timeout). The kernel automatically retries most transient errors (typically 3--5 times).

- **Media errors:** Permanent damage to the storage medium (bad sector on HDD, worn-out NAND page on SSD). The drive's firmware may transparently remap the sector to a spare area. If remapping fails, the error is reported to the kernel.

- **Protocol errors:** Violations of the communication protocol (malformed response, unexpected state). Often indicate a firmware bug or hardware failure. May require a device reset.

- **Path errors:** Failures in the communication path (cable, controller, bus). Multi-path configurations (common in enterprise storage) can route I/O through an alternate path.

### 15.12.2 Error Propagation

When a block device reports an error, the error propagates up the I/O stack:

```text
Error propagation:
NVMe controller -> NVMe driver -> block layer -> file system -> VFS -> user space

At each layer:
- NVMe driver:    Decode the NVMe status code, log the error,
                   retry if transient, report to block layer
- Block layer:    Mark the bio as failed, invoke the bio completion callback
- File system:    ext4 may attempt to read from a mirror or journal backup;
                   marks the file system as having errors (remount read-only if critical)
- VFS:            Returns -EIO to the user-space read()/write() call
- User space:     Application receives errno = EIO
```

::: definition
**I/O Error Handling Policy.** The file system's response to I/O errors is configurable. ext4 provides three error modes via mount options:

- `errors=continue` --- Log the error but continue operating. Risky: further operations may corrupt the file system.
- `errors=remount-ro` --- Remount the file system read-only. Prevents further damage but disrupts service. (Default for ext4.)
- `errors=panic` --- Halt the system immediately. Appropriate for critical servers where any inconsistency is unacceptable and a controlled restart is preferred.
:::

### 15.12.3 Timeout Handling

Every I/O operation must have a timeout. Without timeouts, a hung device can block a thread indefinitely, eventually exhausting system resources. The Linux block layer enforces a default timeout (typically 30 seconds for SCSI/SATA, configurable via sysfs):

```text
# View and set the timeout for /dev/sda (in seconds)
cat /sys/block/sda/device/timeout
# 30

# Increase timeout for slow devices (e.g., tape drives)
echo 120 > /sys/block/sda/device/timeout
```

When a timeout expires, the block layer invokes the driver's error handler, which may attempt a device reset, abort the command, or report the error to the upper layers. The NVMe specification defines a **Controller Fatal Status** bit; if set, the driver performs a full controller reset and replays all outstanding commands.

The I/O subsystem is the most hardware-dependent part of the operating system, yet its layered architecture --- from device registers and interrupts at the bottom, through DMA and the block layer in the middle, to the VFS and io_uring at the top --- provides clean abstractions that isolate complexity at each level. Understanding these layers is essential for diagnosing performance bottlenecks, writing device drivers, and designing high-throughput applications.

---

## Exercises

**Exercise 15.1.** A system has a device with a status register at port 0x300 and a data register at port 0x301. The status register's bit 0 is set when data is available. Write a polling-based C function that reads $n$ bytes from the device into a buffer. Then write an interrupt-driven version using a ring buffer and a wait queue. Compare the CPU utilisation of both approaches when the device produces data at a rate of 1000 bytes per second and the CPU runs at 3 GHz.

**Exercise 15.2.** A disk has 5000 cylinders (0--4999). The disk arm is currently at cylinder 2150, moving towards cylinder 0. The pending request queue is: 2069, 1212, 2296, 2800, 544, 1618, 356, 1523, 4965, 3681. Calculate the total seek distance for each of the following algorithms: (a) FCFS, (b) SSTF, (c) SCAN, (d) C-SCAN, (e) LOOK, (f) C-LOOK. Which algorithm gives the smallest total seek distance?

**Exercise 15.3.** Explain why DMA requires the use of **physical addresses** rather than virtual addresses. Describe the role of the **IOMMU** (I/O Memory Management Unit) in modern systems. What security vulnerability would exist if devices could DMA to arbitrary physical addresses without an IOMMU?

**Exercise 15.4.** An NVMe SSD has 8 I/O queue pairs, each with a queue depth of 1024. The SSD can sustain 500,000 random read IOPS at a queue depth of 32. (a) What is the maximum theoretical IOPS with all queues fully loaded? (b) Why does increasing queue depth beyond a certain point not increase IOPS? (c) Calculate the average I/O latency at 500,000 IOPS with queue depth 32 using Little's Law: $L = \lambda W$ where $L$ is the average number of requests in the system, $\lambda$ is the arrival rate, and $W$ is the average waiting time.

**Exercise 15.5.** io_uring uses shared ring buffers between user space and the kernel. (a) Explain how the SQ tail pointer and SQ head pointer coordinate between user space (producer) and kernel (consumer) without locks. (b) What happens if user space writes SQEs faster than the kernel can process them? (c) Why does io_uring's SQPOLL mode require elevated privileges (or `CAP_SYS_NICE`)?

**Exercise 15.6.** In the split interrupt model (top-half/bottom-half), a network card driver receives a packet. The top-half reads the packet from the device's DMA buffer and queues it. The bottom-half (softirq) runs the TCP/IP stack processing. (a) Why cannot the TCP/IP processing run in the top-half? (b) What happens if softirqs are deferred for too long? (c) Linux's NAPI (New API) mechanism switches between interrupt-driven and polling modes based on packet rate. Explain the rationale: when should the driver use interrupts, and when should it poll?

**Exercise 15.7.** Design a simple block I/O scheduler in pseudocode that implements the LOOK algorithm with **deadline-based aging**. The scheduler should maintain a sorted queue of requests and service them in LOOK order, but any request that has waited longer than a deadline $D$ milliseconds should be promoted to the front of the queue. Analyse the worst-case latency with and without the deadline mechanism.
