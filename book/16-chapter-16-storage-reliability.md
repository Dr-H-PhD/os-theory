# Chapter 16: Storage Reliability

*"There are two kinds of hard drives: those that have failed, and those that will fail."*
--- Storage engineering proverb

---

## 16.1 Disk Structure and Geometry

Before analysing reliability, we must understand the physical structure of storage devices. Although modern drives abstract their internal geometry behind a Logical Block Addressing (LBA) interface, knowledge of the underlying structure is essential for understanding failure modes, RAID design, and performance characteristics.

### 16.1.1 Hard Disk Drive (HDD) Anatomy

A hard disk drive consists of one or more rotating **platters** coated with a magnetic material. Data is read and written by **heads** that float on a thin air cushion above the platter surface (the flying height is approximately 3--5 nanometres --- less than the diameter of a smoke particle).

::: definition
**Disk Geometry Terms.**

- **Platter:** A circular disk coated with magnetic material. Each platter has two **surfaces** (top and bottom).

- **Track:** A concentric ring of data on a single surface. A typical modern drive has hundreds of thousands of tracks per surface.

- **Sector:** The smallest unit of data that can be read or written. Traditional sector size is 512 bytes; modern drives use 4 KB **Advanced Format** sectors.

- **Cylinder:** The set of tracks at the same radial position across all platters. All tracks in a cylinder can be accessed without moving the disk arm.

- **Head:** The read/write transducer. One head per surface. All heads are mounted on a single **actuator arm** and move together.
:::

```text
Hard Disk Drive Structure (side view):

    Actuator arm
    +===========+
    |  Head 0 --+------->  Surface 0 (Platter 1, top)
    |  Head 1 --+------->  Surface 1 (Platter 1, bottom)
    |  Head 2 --+------->  Surface 2 (Platter 2, top)
    |  Head 3 --+------->  Surface 3 (Platter 2, bottom)
    +===========+
         |
    Pivot point        Spindle motor
                       (7200/10000/15000 RPM)


Top view (single platter):

    +------- Track 0 (outermost) --------+
    |   +---- Track 1 ----+              |
    |   |  +- Track 2 -+  |              |
    |   |  |            |  |              |
    |   |  |  Spindle   |  |              |
    |   |  |     *      |  |              |
    |   |  |            |  |              |
    |   |  +------------+  |              |
    |   +------------------+              |
    +-------------------------------------+

    Each track is divided into sectors:
    Sector 0, Sector 1, ..., Sector N
```

### 16.1.2 Logical Block Addressing (LBA)

Modern drives present a simple linear array of logical blocks (LBA 0, LBA 1, ..., LBA $n-1$) to the operating system. The drive's firmware maps each LBA to the appropriate physical location (platter, track, sector), handling complexities such as:

- **Zone Bit Recording (ZBR):** Outer tracks are physically longer and contain more sectors than inner tracks. The drive's firmware accounts for the varying number of sectors per track.

- **Spare sectors:** The drive reserves spare sectors to transparently remap sectors that develop defects (via the **grown defect list**).

- **Track skew and cylinder skew:** Sectors are staggered across adjacent tracks and cylinders to account for head switching and seek time, allowing sequential reads to proceed without missing a revolution.

::: definition
**Logical Block Addressing (LBA).** A addressing scheme in which each sector on the drive is assigned a sequential integer address from 0 to $n-1$, where $n$ is the total number of sectors. The drive's firmware translates LBAs to physical locations. This abstraction decouples the operating system from the drive's physical geometry.
:::

### 16.1.3 Solid-State Drive (SSD) Structure

An SSD replaces the mechanical components of an HDD with NAND flash memory. The internal structure is hierarchical:

```text
SSD Internal Structure:

Controller (ARM/RISC processor)
    |
    +--- Channel 0          Channel 1       ...  Channel N
         |                   |
         +--- Die 0         +--- Die 0
         |    +--- Plane 0  |    +--- Plane 0
         |    |    +- Block  |    |    +- Block
         |    |    |  +Page  |    |    |  +Page (4-16 KB)
         |    |    |  +Page  |    |    |  +Page
         |    |    |  +Page  |    |    |  ...
         |    |    +- Block  |    |    +- Block
         |    +--- Plane 1  |    +--- Plane 1
         +--- Die 1         +--- Die 1
```

::: definition
**NAND Flash Hierarchy.**

- **Page:** The smallest unit of read and write (4--16 KB). Data can only be written to a **clean** (erased) page.

- **Block:** A group of pages (64--512 pages, i.e., 256 KB -- 8 MB). The smallest unit of **erasure**. An entire block must be erased before any of its pages can be rewritten.

- **Die:** Contains multiple planes. Each plane has its own page buffer, enabling parallel operations.

- **Channel:** A communication bus between the controller and one or more dies. Independent channels enable concurrent access.
:::

The asymmetry between write granularity (page) and erase granularity (block) is the fundamental source of complexity in SSD design, giving rise to write amplification, garbage collection, and wear levelling --- topics we address later in this chapter.

### 16.1.4 NAND Cell Types and Reliability

NAND flash cells store data by trapping electrons in a floating gate (or charge trap). The number of bits per cell determines the cell type and directly affects both capacity and reliability:

::: definition
**NAND Cell Types.**

- **SLC (Single-Level Cell):** 1 bit per cell. Two voltage levels (0/1). Highest endurance (50,000--100,000 P/E cycles), fastest read/write, but lowest density and highest cost per bit.

- **MLC (Multi-Level Cell):** 2 bits per cell. Four voltage levels (00/01/10/11). Endurance: 3,000--10,000 P/E cycles. Good balance of cost and performance.

- **TLC (Triple-Level Cell):** 3 bits per cell. Eight voltage levels. Endurance: 500--3,000 P/E cycles. Most common in consumer SSDs.

- **QLC (Quad-Level Cell):** 4 bits per cell. Sixteen voltage levels. Endurance: 100--1,000 P/E cycles. Lowest cost per bit, suitable for read-heavy workloads.
:::

The reliability challenge increases with each additional bit per cell because the voltage margins between adjacent levels shrink:

::: example
**Example 16.19 (Voltage Margin Comparison).** Suppose the NAND cell operates with a voltage range of 0--4 V:

- **SLC:** 2 levels. Voltage margin between levels: $4 / 2 = 2\,\text{V}$. Large margin, easy to distinguish.

- **MLC:** 4 levels. Margin: $4 / 4 = 1\,\text{V}$.

- **TLC:** 8 levels. Margin: $4 / 8 = 0.5\,\text{V}$.

- **QLC:** 16 levels. Margin: $4 / 16 = 0.25\,\text{V}$.

As the margin shrinks, the cell becomes more susceptible to noise, charge leakage, and read disturb errors. This is why QLC NAND requires more sophisticated ECC (LDPC codes correcting hundreds of errors per page) compared to SLC (simple BCH codes correcting a few errors).
:::

The read latency also increases with cell density because the controller must use more precise (and slower) voltage sensing:

| Cell Type | Read Latency | Write Latency | Erase Latency |
|-----------|-------------|---------------|---------------|
| SLC | 25 $\mu$s | 200 $\mu$s | 1.5 ms |
| MLC | 50 $\mu$s | 600 $\mu$s | 3 ms |
| TLC | 75 $\mu$s | 1.5 ms | 5 ms |
| QLC | 100--150 $\mu$s | 5 ms | 10 ms |

Modern SSDs use **SLC caching**: a portion of the NAND is operated in SLC mode (writing only 1 bit per cell) to absorb burst writes at high speed. When the SLC cache fills, data is folded into the TLC/QLC region in the background. This is why SSD write speed often drops sharply after writing continuously for several tens of gigabytes --- the SLC cache has been exhausted.

---

## 16.2 RAID: Redundant Arrays of Independent Disks

Individual drives fail. Enterprise environments require storage that survives drive failures without data loss or significant downtime. **RAID** provides this by combining multiple drives into an array that appears as a single logical volume, with built-in redundancy to tolerate failures.

::: definition
**RAID (Redundant Array of Independent Disks).** A technique for combining multiple physical disk drives into a logical unit for the purpose of improved performance, reliability, or both. Originally defined by Patterson, Gibson, and Katz at UC Berkeley in 1988, RAID distributes data and redundancy information across the member drives according to a specific **RAID level**.
:::

### 16.2.1 RAID 0: Striping

RAID 0 distributes data across $N$ drives in fixed-size **stripes** without any redundancy.

```text
RAID 0 (4 drives, stripe size = 64 KB):

         Drive 0    Drive 1    Drive 2    Drive 3
Block 0  [Stripe 0] [Stripe 1] [Stripe 2] [Stripe 3]
Block 1  [Stripe 4] [Stripe 5] [Stripe 6] [Stripe 7]
Block 2  [Stripe 8] [Stripe 9] [Stripe 10][Stripe 11]
...
```

**Capacity:** $N \times C$ where $C$ is the capacity of the smallest drive.

**Performance:** Read and write throughput scales linearly with $N$, since I/O operations can be parallelised across all drives.

**Reliability:** Worse than a single drive. If **any** drive fails, all data is lost.

::: theorem
**Theorem 16.1 (RAID 0 Reliability).** For $N$ independent drives, each with failure probability $p$ over a given time period, the probability that a RAID 0 array survives the period is:

$$P(\text{RAID 0 survives}) = (1 - p)^N$$

For $N = 4$ drives with annual failure rate $p = 0.02$ (2\%):
$$P(\text{survives 1 year}) = (0.98)^4 = 0.922$$

The probability of data loss in one year is $1 - 0.922 = 7.8\%$, nearly four times the single-drive failure rate.
:::

RAID 0 is appropriate only for data that can be easily regenerated (temporary files, caches, scratch space) and where performance is paramount.

### 16.2.2 RAID 1: Mirroring

RAID 1 maintains identical copies of all data on two (or more) drives. Every write is performed on all drives simultaneously.

```text
RAID 1 (2 drives):

         Drive 0    Drive 1
Block 0  [Data A]   [Data A]    <- identical copies
Block 1  [Data B]   [Data B]
Block 2  [Data C]   [Data C]
...
```

**Capacity:** $C$ (the capacity of one drive) regardless of how many mirrors exist. Usable capacity is $C \times N / 2$ for $N$-drive mirrors, but typically $N = 2$.

**Performance:** Read throughput can be doubled (different reads go to different drives). Write throughput is limited by the slowest drive (both must complete).

**Reliability:** The array survives the failure of any one drive (or $N - 1$ drives in an $N$-way mirror).

::: theorem
**Theorem 16.2 (RAID 1 Reliability).** For a two-drive mirror with independent failure probability $p$:

$$P(\text{data loss}) = p^2$$

For $p = 0.02$: $P(\text{data loss}) = 0.0004 = 0.04\%$ per year.

More precisely, considering that the second drive can fail **during the rebuild period** after the first failure:

$$P(\text{data loss}) = p \times \frac{T_{\text{rebuild}}}{\text{MTBF}_2} = p \times \frac{T_{\text{rebuild}} \times p_2}{T_{\text{period}}}$$

where $T_{\text{rebuild}}$ is the time to rebuild onto a replacement drive and $\text{MTBF}_2$ is the mean time between failures of the second drive.
:::

### 16.2.3 RAID 5: Distributed Parity

RAID 5 stripes data and parity across $N \geq 3$ drives. For each stripe, one drive holds the **parity** block (the XOR of the corresponding data blocks on the other drives). The parity role rotates across drives to distribute the parity write load.

```text
RAID 5 (4 drives):

         Drive 0    Drive 1    Drive 2    Drive 3
Row 0    [D0]       [D1]       [D2]       [P0]       P0 = D0 XOR D1 XOR D2
Row 1    [D3]       [D4]       [P1]       [D5]       P1 = D3 XOR D4 XOR D5
Row 2    [D6]       [P2]       [D7]       [D8]       P2 = D6 XOR D7 XOR D8
Row 3    [P3]       [D9]       [D10]      [D11]      P3 = D9 XOR D10 XOR D11
```

**Capacity:** $(N - 1) \times C$. One drive's worth of capacity is consumed by parity.

**Parity calculation.** The parity block is the bitwise XOR of all data blocks in the stripe:

$$P = D_0 \oplus D_1 \oplus D_2 \oplus \cdots \oplus D_{N-2}$$

If drive $k$ fails, its data can be reconstructed by XORing the remaining data and parity:

$$D_k = D_0 \oplus \cdots \oplus D_{k-1} \oplus D_{k+1} \oplus \cdots \oplus D_{N-2} \oplus P$$

This works because XOR is its own inverse: $x \oplus x = 0$ and $x \oplus 0 = x$.

::: example
**Example 16.1 (RAID 5 Parity Reconstruction).** Three data blocks (4 bits each):

$D_0 = 1010$, $D_1 = 1100$, $D_2 = 0111$

Parity: $P = 1010 \oplus 1100 \oplus 0111 = 0001$

If $D_1$ fails, reconstruct: $D_1 = D_0 \oplus D_2 \oplus P = 1010 \oplus 0111 \oplus 0001 = 1100$. This matches the original value of $D_1$.
:::

::: example
**Example 16.2 (RAID 5 Write Penalty).** Updating a single data block $D_k$ on RAID 5 requires:

1. Read the old value of $D_k$ (1 read).
2. Read the old parity $P$ (1 read).
3. Compute new parity: $P' = P \oplus D_k^{\text{old}} \oplus D_k^{\text{new}}$ (CPU operation).
4. Write the new $D_k$ (1 write).
5. Write the new $P'$ (1 write).

Total: 2 reads + 2 writes = **4 I/O operations** for a single logical write. This is the **RAID 5 write penalty**.

An alternative **reconstruct write** reads all other data blocks in the stripe and computes the parity from scratch: $(N - 2)$ reads + 2 writes. For small $N$, the read-modify-write approach (4 I/O) is cheaper.
:::

### 16.2.4 RAID 6: Double Parity

RAID 6 extends RAID 5 with a second, independent parity block, allowing the array to survive any **two** simultaneous drive failures.

```text
RAID 6 (5 drives):

         Drive 0    Drive 1    Drive 2    Drive 3    Drive 4
Row 0    [D0]       [D1]       [D2]       [P]        [Q]
Row 1    [D3]       [D4]       [P]        [Q]        [D5]
...

P = XOR parity (same as RAID 5)
Q = Reed-Solomon parity (using Galois Field GF(2^8) arithmetic)
```

The second parity $Q$ uses a different mathematical function from $P$. Typically, $Q$ is computed using multiplication in Galois Field $GF(2^8)$:

$$Q = g^0 \cdot D_0 \oplus g^1 \cdot D_1 \oplus g^2 \cdot D_2 \oplus \cdots$$

where $g$ is a generator of the field and $\oplus$ denotes XOR. This ensures that $P$ and $Q$ provide two independent equations, sufficient to solve for two unknowns (two failed drives).

**Capacity:** $(N - 2) \times C$.

**Reliability:** Survives any two drive failures. This is increasingly important as drive capacities grow, because rebuild times lengthen (a 16 TB drive takes 10--20 hours to rebuild), and the probability of a second failure during rebuild is non-negligible.

### 16.2.5 RAID 10: Mirrored Stripes

RAID 10 combines RAID 1 (mirroring) and RAID 0 (striping). Data is first mirrored (RAID 1), and the mirrors are then striped (RAID 0). This requires $N \geq 4$ drives (always an even number).

```text
RAID 10 (4 drives):

         Drive 0    Drive 1    Drive 2    Drive 3
         Mirror 0   Mirror 0   Mirror 1   Mirror 1
Block 0  [Stripe 0] [Stripe 0] [Stripe 1] [Stripe 1]
Block 1  [Stripe 2] [Stripe 2] [Stripe 3] [Stripe 3]
...
```

**Capacity:** $N/2 \times C$ (50\% usable).

**Performance:** Excellent for both reads (up to $N \times$ throughput) and writes (up to $N/2 \times$ throughput, since each write goes to two drives).

**Reliability:** Survives any single drive failure. Can survive multiple failures as long as no mirror pair loses both drives simultaneously.

### 16.2.6 RAID Level Comparison

| Level | Min Drives | Capacity | Read Speed | Write Speed | Fault Tolerance |
|-------|-----------|----------|------------|-------------|-----------------|
| 0 | 2 | $NC$ | $N\times$ | $N\times$ | None |
| 1 | 2 | $C$ | $2\times$ | $1\times$ | 1 drive |
| 5 | 3 | $(N-1)C$ | $(N-1)\times$ | Reduced (write penalty) | 1 drive |
| 6 | 4 | $(N-2)C$ | $(N-2)\times$ | Reduced (higher penalty) | 2 drives |
| 10 | 4 | $NC/2$ | $N\times$ | $N/2\times$ | 1 per mirror |

::: programmer
**Programmer's Perspective: mdadm RAID Management on Linux.**
Linux provides software RAID through the `md` (multiple devices) subsystem, managed with the `mdadm` utility. Here is how to create and manage RAID arrays from the command line:

```bash
# Create a RAID 5 array with 4 drives
mdadm --create /dev/md0 --level=5 --raid-devices=4 \
    /dev/sdb /dev/sdc /dev/sdd /dev/sde

# Check array status
cat /proc/mdstat
# md0 : active raid5 sde[3] sdd[2] sdc[1] sdb[0]
#       3145728 blocks super 1.2 level 5, 512k chunk, algorithm 2 [4/4] [UUUU]

# View detailed array information
mdadm --detail /dev/md0

# If /dev/sdc fails, mark it and remove it
mdadm /dev/md0 --fail /dev/sdc
mdadm /dev/md0 --remove /dev/sdc

# Add a replacement drive and rebuild
mdadm /dev/md0 --add /dev/sdf
# Rebuild progress visible in /proc/mdstat

# Monitor the array for failures (sends email alerts)
mdadm --monitor --daemonise --mail=admin@example.com /dev/md0

# Save configuration for boot-time assembly
mdadm --detail --scan >> /etc/mdadm/mdadm.conf
```

For ZFS, which integrates the file system and volume manager:

```bash
# Create a RAID-Z1 pool (equivalent to RAID 5)
zpool create tank raidz1 /dev/sdb /dev/sdc /dev/sdd /dev/sde

# Create a RAID-Z2 pool (equivalent to RAID 6)
zpool create tank raidz2 /dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf

# Check pool status and health
zpool status tank
#   pool: tank
#  state: ONLINE
# config:
#     NAME        STATE     READ WRITE CKSUM
#     tank        ONLINE       0     0     0
#       raidz1-0  ONLINE       0     0     0
#         sdb     ONLINE       0     0     0
#         sdc     ONLINE       0     0     0
#         sdd     ONLINE       0     0     0
#         sde     ONLINE       0     0     0

# Replace a failed drive
zpool replace tank /dev/sdc /dev/sdf

# Run a scrub (verify all checksums, repair if possible)
zpool scrub tank

# Check scrub progress
zpool status tank
# scan: scrub in progress, 45.2% done
```

ZFS is preferable to mdadm + ext4/XFS for critical data because it provides end-to-end checksumming. With mdadm RAID, a silent corruption in one data block is indistinguishable from valid data --- the parity check passes because the parity was computed from the corrupted data. ZFS detects this through its independent checksums and can repair it from the redundant copy.
:::

---

## 16.3 Reliability Analysis

### 16.3.1 The Bathtub Curve

Drive failure rates are not constant over a drive's lifetime. They follow the well-known **bathtub curve**:

::: definition
**Bathtub Curve.** The failure rate function $h(t)$ of a population of drives typically exhibits three phases:

1. **Infant mortality (early life):** Elevated failure rate due to manufacturing defects, weak components, and firmware bugs. Duration: 0--6 months. Failures are screened out by manufacturer burn-in testing, but some escape to the field.

2. **Useful life (middle):** Approximately constant failure rate. The exponential distribution model ($h(t) = \lambda$) is valid during this phase. Duration: 6 months to 3--5 years.

3. **Wear-out (end of life):** Increasing failure rate due to mechanical wear (HDD bearing degradation, spindle motor failure) or NAND cell exhaustion (SSD). The Weibull distribution with shape parameter $\beta > 1$ models this phase.
:::

The Weibull reliability function captures all three phases:

$$R(t) = e^{-(t/\eta)^\beta}$$

where $\eta$ is the scale parameter (characteristic life) and $\beta$ is the shape parameter:

- $\beta < 1$: Decreasing failure rate (infant mortality)
- $\beta = 1$: Constant failure rate (exponential distribution, useful life)
- $\beta > 1$: Increasing failure rate (wear-out)

::: example
**Example 16.16 (Real-World Drive Failure Data).** Backblaze, a cloud storage provider, publishes quarterly drive failure statistics from its fleet of over 250,000 drives. Key findings from their data (2013--2025):

- The fleet-wide AFR averages 1.5--2.0\% across all drive models.
- Some models have AFR below 0.5\%; others exceed 5\%.
- Failure rates are highest in the first year (infant mortality) and after year 4 (wear-out).
- Drive failures are correlated: when one drive in a batch fails, others from the same batch are more likely to fail soon.
- Temperature has a measurable but modest effect on failure rate; vibration and workload have a stronger effect.

These observations challenge the assumption of independent, identically distributed failures that underlies simple MTTF calculations. In practice, correlated failures make RAID less reliable than the theoretical formulas predict.
:::

### 16.3.2 Mean Time To Failure (MTTF)

::: definition
**Mean Time To Failure (MTTF).** The expected time until a non-repairable component fails, assuming it starts in a working state. For a component with constant failure rate $\lambda$ (failures per unit time):

$$\text{MTTF} = \frac{1}{\lambda}$$

The **Annualised Failure Rate (AFR)** is the probability of failure within one year:

$$\text{AFR} \approx \frac{1}{\text{MTTF (in years)}}$$

for small failure probabilities (where the approximation $1 - e^{-\lambda t} \approx \lambda t$ holds).
:::

Manufacturers typically quote MTTF in hours. For example, an enterprise HDD with MTTF = 1,200,000 hours corresponds to:

$$\text{AFR} \approx \frac{8760}{1{,}200{,}000} = 0.73\%$$

::: example
**Example 16.3 (MTTF for a RAID Array).** A RAID 5 array has 4 drives, each with MTTF = 500,000 hours. The array has MTTF$_{\text{group}}$ for the first failure:

$$\text{MTTF}_{\text{first failure}} = \frac{\text{MTTF}_{\text{drive}}}{N} = \frac{500{,}000}{4} = 125{,}000 \text{ hours} \approx 14.3 \text{ years}$$

This is the expected time until the array enters a **degraded** state (one drive failed, parity providing data from the missing drive).
:::

### 16.3.3 Mean Time To Repair (MTTR)

::: definition
**Mean Time To Repair (MTTR).** The expected time from a component failure to full restoration of redundancy. For a RAID array, MTTR includes:

1. **Detection time:** How long until the failure is noticed (seconds for active monitoring, hours or days for unmonitored systems).

2. **Response time:** Time to obtain and install a replacement drive.

3. **Rebuild time:** Time to reconstruct the failed drive's data on the replacement.
:::

Rebuild time is a function of drive capacity and rebuild speed:

$$T_{\text{rebuild}} = \frac{\text{Drive capacity}}{\text{Rebuild speed}}$$

For a 16 TB drive at a rebuild speed of 200 MB/s (limited by the remaining drives' throughput):

$$T_{\text{rebuild}} = \frac{16 \times 10^{12}}{200 \times 10^6} = 80{,}000 \text{ seconds} \approx 22 \text{ hours}$$

### 16.3.4 RAID Reliability Calculation

::: theorem
**Theorem 16.3 (RAID 5 MTTF).** For a RAID 5 array with $N$ drives, each with failure rate $\lambda = 1/\text{MTTF}_{\text{drive}}$, the mean time to data loss is:

$$\text{MTTF}_{\text{RAID 5}} = \frac{\text{MTTF}_{\text{drive}}^2}{N \times (N-1) \times \text{MTTR}}$$

*Proof.* The first failure occurs at rate $N\lambda$ (any of $N$ drives). After the first failure, the array is in a degraded state for an expected duration of MTTR. During this period, if any of the remaining $N - 1$ drives fails, data is lost. The probability of a second failure during MTTR is approximately $(N-1) \times \lambda \times \text{MTTR}$. Therefore:

$$\text{MTTF}_{\text{RAID 5}} = \frac{1}{N \lambda} \times \frac{1}{(N-1) \lambda \times \text{MTTR}} = \frac{1}{N(N-1)\lambda^2 \times \text{MTTR}} = \frac{\text{MTTF}^2}{N(N-1) \times \text{MTTR}}$$

$\square$
:::

::: example
**Example 16.4 (RAID 5 vs. RAID 6 Reliability).** Consider an array of 6 drives, each with MTTF = 1,000,000 hours, and MTTR = 24 hours.

**RAID 5:**
$$\text{MTTF}_{\text{RAID 5}} = \frac{(10^6)^2}{6 \times 5 \times 24} = \frac{10^{12}}{720} \approx 1.39 \times 10^9 \text{ hours} \approx 158{,}000 \text{ years}$$

**RAID 6:**
$$\text{MTTF}_{\text{RAID 6}} = \frac{\text{MTTF}^3}{N \times (N-1) \times (N-2) \times \text{MTTR}^2}$$
$$= \frac{(10^6)^3}{6 \times 5 \times 4 \times 24^2} = \frac{10^{18}}{69{,}120} \approx 1.45 \times 10^{13} \text{ hours}$$

RAID 6 is approximately 10,000 times more reliable than RAID 5 in this configuration. As drive capacities increase (and MTTR lengthens), RAID 6 becomes increasingly important.
:::

::: example
**Example 16.5 (The Danger of Large Drives in RAID 5).** With 8 TB drives (MTTR = 16 hours), 8 drives, MTTF = 800,000 hours:

$$\text{MTTF}_{\text{RAID 5}} = \frac{(800{,}000)^2}{8 \times 7 \times 16} = \frac{6.4 \times 10^{11}}{896} \approx 714{,}285{,}714 \text{ hours} \approx 81{,}500 \text{ years}$$

This looks safe, but the calculation assumes independent failures. In practice, **correlated failures** (drives from the same batch, same age, same thermal environment) significantly reduce reliability. Studies by Google, Backblaze, and CMU have found that AFR for deployed drives is 2--8\%, much higher than manufacturer specifications.

With AFR = 5\% (MTTF = 175,200 hours) and MTTR = 24 hours:

$$\text{MTTF}_{\text{RAID 5}} = \frac{(175{,}200)^2}{8 \times 7 \times 24} = \frac{3.069 \times 10^{10}}{1344} \approx 22{,}838{,}000 \text{ hours} \approx 2{,}607 \text{ years}$$

For 1000 such arrays (a mid-sized data centre), the expected time to a first data loss event is 2.6 years --- well within planning horizons.
:::

::: example
**Example 16.6 (Markov Model for RAID 1).** A RAID 1 mirror with two drives can be modelled as a three-state continuous-time Markov chain:

- **State 0 (Normal):** Both drives operational. Transition rate to State 1: $2\lambda$ (either drive can fail).
- **State 1 (Degraded):** One drive has failed; the mirror is rebuilding. Transition rate to State 2 (data loss): $\lambda$ (the surviving drive fails before rebuild completes). Transition rate back to State 0: $\mu = 1/\text{MTTR}$ (rebuild completes).
- **State 2 (Data Loss):** Both drives have failed. Absorbing state.

```text
                 2*lambda           lambda
    [Normal] ----------> [Degraded] ----------> [Data Loss]
       ^                     |
       |        mu           |
       +---------------------+
       (rebuild completes)
```

The MTTF is the expected time to reach State 2 from State 0:

$$\text{MTTF}_{\text{RAID 1}} = \frac{1}{2\lambda} + \frac{1}{2\lambda} \times \frac{\mu}{\lambda + \mu} \times \text{MTTF}_{\text{RAID 1}}$$

Solving: $\text{MTTF}_{\text{RAID 1}} = \frac{\mu + \lambda}{2\lambda^2} \approx \frac{\mu}{2\lambda^2} = \frac{\text{MTTF}^2}{2 \times \text{MTTR}}$ for $\lambda \ll \mu$.

For drives with MTTF = 500,000 hours and MTTR = 8 hours:
$$\text{MTTF}_{\text{RAID 1}} = \frac{(500{,}000)^2}{2 \times 8} = \frac{2.5 \times 10^{11}}{16} \approx 1.56 \times 10^{10}\,\text{hours} \approx 1{,}785{,}000\,\text{years}$$
:::

### 16.3.5 Unrecoverable Read Errors (URE) During Rebuild

::: definition
**Unrecoverable Read Error (URE).** A read operation that the drive's internal ECC cannot correct. The drive reports a read error to the operating system. The URE rate is specified by the manufacturer:

- Consumer HDDs: $1$ in $10^{14}$ bits read ($\approx 1$ URE per 12.5 TB read)
- Enterprise HDDs: $1$ in $10^{15}$ bits read ($\approx 1$ URE per 125 TB read)
- Enterprise SSDs: $1$ in $10^{17}$ bits read ($\approx 1$ URE per 12.5 PB read)
:::

During a RAID rebuild, the system must read every sector from the surviving drives to reconstruct the failed drive's data. If a URE occurs on any surviving drive during this process, the affected stripe cannot be reconstructed --- data is lost even though only one drive has failed.

::: theorem
**Theorem 16.4 (URE Probability During Rebuild).** For a RAID 5 array with $N$ drives, each of capacity $C$ bits, and URE rate $p_{\text{URE}}$ (probability of URE per bit read), the probability of encountering at least one URE during rebuild is:

$$P(\text{URE during rebuild}) = 1 - (1 - p_{\text{URE}})^{(N-1) \times C} \approx (N - 1) \times C \times p_{\text{URE}}$$

for small $p_{\text{URE}}$.
:::

::: example
**Example 16.17 (URE Risk for Large Drives).** A RAID 5 array has 8 drives of 16 TB each, with consumer URE rate $1/10^{14}$ bits.

During rebuild, the system reads $(N - 1) \times C = 7 \times 16 \times 10^{12} \times 8 = 8.96 \times 10^{14}$ bits.

$$P(\text{URE during rebuild}) \approx \frac{8.96 \times 10^{14}}{10^{14}} = 8.96$$

Since the probability exceeds 1, a URE during rebuild is **virtually certain**. This means that for a RAID 5 array of 8 consumer 16 TB drives, a single drive failure will almost certainly result in data loss due to a URE during rebuild.

With enterprise drives (URE rate $1/10^{15}$):

$$P(\text{URE}) \approx \frac{8.96 \times 10^{14}}{10^{15}} = 0.896 \approx 90\%$$

Even with enterprise drives, the risk is unacceptably high. This is the primary reason that RAID 5 is considered obsolete for large-capacity drives. RAID 6 tolerates one URE during rebuild (because it has double parity), making it the minimum acceptable configuration for drives larger than 2--4 TB.
:::

---

## 16.4 Error Detection and Correction

Storage media are not perfectly reliable. Bits can be corrupted by physical defects, electromagnetic interference, cosmic rays, or firmware bugs. Multiple layers of error detection and correction protect against these errors.

### 16.4.1 Cyclic Redundancy Check (CRC)

::: definition
**Cyclic Redundancy Check (CRC).** A hash function based on polynomial division over $GF(2)$ (the field with two elements). The data is treated as a polynomial $D(x)$, divided by a generator polynomial $G(x)$ of degree $r$. The remainder $R(x) = D(x) \cdot x^r \mod G(x)$ is appended to the data as the CRC. The receiver divides the received data (with CRC) by $G(x)$; a non-zero remainder indicates an error.
:::

The CRC is not a general-purpose hash function; it is specifically designed to detect common error patterns:

- **All single-bit errors** (as long as $G(x)$ has more than one term).
- **All double-bit errors** (if $G(x)$ has a factor that does not divide $x^k + 1$ for any $k < n$).
- **All odd numbers of bit errors** (if $G(x)$ has the factor $x + 1$).
- **All burst errors of length $\leq r$** (where $r$ is the degree of $G(x)$).

::: example
**Example 16.6 (CRC-32 Calculation).** CRC-32 uses the generator polynomial:
$$G(x) = x^{32} + x^{26} + x^{23} + x^{22} + x^{16} + x^{12} + x^{11} + x^{10} + x^8 + x^7 + x^5 + x^4 + x^2 + x + 1$$

For a 4 KB data block, CRC-32 appends a 4-byte checksum. The probability that a random error pattern goes undetected is approximately $2^{-32} \approx 2.3 \times 10^{-10}$.

In practice, CRC-32 is used in Ethernet frames, ZIP files, PNG images, and the ext4 file system (for metadata checksums).
:::

### 16.4.2 Error-Correcting Codes (ECC)

While CRC detects errors, it cannot correct them. **Error-correcting codes** (ECC) add enough redundancy to both detect and correct a limited number of bit errors.

::: definition
**Error-Correcting Code (ECC).** A code that maps $k$ data bits to $n$ coded bits ($n > k$), with $n - k$ redundancy bits. The **Hamming distance** $d$ of the code determines its error-correcting capability:

- **Detect** up to $d - 1$ bit errors.
- **Correct** up to $\lfloor (d-1)/2 \rfloor$ bit errors.
:::

**ECC in DRAM.** Server-grade DRAM uses SEC-DED (Single Error Correcting, Double Error Detecting) Hamming codes. For a 64-bit data word, 8 parity bits are added (72 bits total), providing:

- Correction of any single-bit error.
- Detection of any double-bit error.

The encoding uses a parity-check matrix $H$ such that $H \cdot \mathbf{c}^T = \mathbf{0}$ for valid codewords $\mathbf{c}$. When a single bit $i$ is flipped, $H \cdot \mathbf{c'}^T = \mathbf{h}_i$ (the $i$-th column of $H$), which identifies the bit position.

**ECC in SSDs.** NAND flash has inherently higher bit error rates than magnetic media, especially as cells are programmed and erased repeatedly. Modern SSDs use sophisticated ECC:

- **BCH codes:** Correcting 40--70 bit errors per 1 KB page (for MLC NAND).
- **LDPC codes:** Correcting hundreds of bit errors per page (for TLC and QLC NAND). LDPC provides higher correction capability at the cost of greater decoder complexity and latency.

### 16.4.3 Checksums in ZFS and Btrfs

File systems that implement checksumming provide a layer of error detection above the drive's built-in ECC. This catches errors that ECC misses or cannot correct, as well as errors introduced by the controller, cable, or driver (the so-called **data path** errors).

**ZFS checksums.** By default, ZFS uses **fletcher4**, a fast checksum algorithm that computes four 64-bit accumulators. For maximum integrity, **SHA-256** can be selected. Checksums are stored in the parent block (forming a Merkle tree), ensuring that a corrupted checksum is itself detected by its parent's checksum.

**Btrfs checksums.** Btrfs uses **CRC32C** (the hardware-accelerated variant using the Castagnoli polynomial). Btrfs stores checksums in a dedicated checksum tree, separate from the data.

::: theorem
**Theorem 16.5 (End-to-End Checksum Coverage).** A storage system has $n$ components in the data path (controller, cable, driver, file system, page cache). Each component has an independent probability $p_i$ of introducing an undetected error. With per-component error checking, the probability of an undetected end-to-end error is:

$$P_{\text{undetected}} = 1 - \prod_{i=1}^{n}(1 - p_i) \approx \sum_{i=1}^{n} p_i$$

for small $p_i$. An **end-to-end checksum** computed at the source and verified at the destination reduces $P_{\text{undetected}}$ to the false-negative probability of the checksum itself (e.g., $2^{-256}$ for SHA-256), regardless of the number of intermediate components.
:::

---

## 16.5 The Flash Translation Layer (FTL)

The Flash Translation Layer is the firmware component that makes a NAND flash chip look like a block device. The FTL translates logical block addresses (LBAs) from the host into physical page addresses within the NAND, and it manages the complexities of flash: out-of-place writes, block erasure, garbage collection, and wear levelling.

### 16.5.1 FTL Address Mapping

::: definition
**Flash Translation Layer (FTL).** A firmware layer in the SSD controller that maintains a **mapping table** from host LBAs to physical NAND page addresses. When the host writes to LBA $x$, the FTL allocates a clean physical page $p$, writes the data to $p$, and updates the mapping: $\text{map}[x] \leftarrow p$. The old physical page (if any) is marked invalid.
:::

The mapping table can be organized at different granularities:

- **Page-level mapping:** One entry per 4 KB page. For a 1 TB SSD with 4 KB pages, the table has $256 \times 10^6$ entries $\times$ 4 bytes $= 1$ GB. This must be stored in the SSD's DRAM buffer.

- **Block-level mapping:** One entry per erase block (e.g., 256 pages). Much smaller table ($256 \times 10^6 / 256 = 10^6$ entries), but any write within a block requires copying the entire block (high write amplification).

- **Hybrid mapping:** A combination of page-level mapping for frequently-written data (in a log region) and block-level mapping for the rest. This balances mapping table size with write amplification.

::: example
**Example 16.18 (FTL Mapping Table Size).** A 4 TB enterprise NVMe SSD with 4 KB pages:

- Pages: $4 \times 10^{12} / 4096 = 976{,}562{,}500 \approx 10^9$
- Page-level mapping table: $10^9 \times 4\,\text{bytes} = 4\,\text{GB}$
- The SSD needs 4 GB of DRAM just for the mapping table.

This is why enterprise SSDs have substantial DRAM (4--8 GB for multi-TB drives) and why "DRAMless" consumer SSDs (which use host memory buffer, HMB, or reduced mapping tables) have lower random write performance.
:::

### 16.5.2 Over-Provisioning

::: definition
**Over-Provisioning (OP).** The difference between the SSD's raw NAND capacity and the user-accessible capacity. Over-provisioned space is invisible to the host and is used by the FTL for garbage collection, wear levelling, and bad block replacement.

$$\text{OP (\%)} = \frac{\text{NAND capacity} - \text{User capacity}}{\text{User capacity}} \times 100$$
:::

Consumer SSDs typically have 7--13\% over-provisioning (a "1 TB" SSD has approximately 1.07--1.13 TB of NAND). Enterprise SSDs may have 28--100\% over-provisioning for sustained write performance and longer lifespan.

Higher over-provisioning means more free blocks are available for garbage collection at any time, reducing write amplification. This is why enterprise SSDs sustain much higher random write IOPS than consumer SSDs of the same capacity.

---

## 16.6 Write Amplification and Wear Levelling

### 16.6.1 The Write Amplification Factor

::: definition
**Write Amplification Factor (WAF).** The ratio of the total amount of data physically written to the NAND flash to the amount of data logically written by the host:

$$\text{WAF} = \frac{\text{Data written to NAND}}{\text{Data written by host}}$$

A WAF of 1.0 means no amplification (ideal). In practice, WAF ranges from 1.1 (best case, sequential writes) to 10 or more (worst case, random small writes on a nearly full drive).
:::

Write amplification arises because:

1. **Page-level writes, block-level erases:** To overwrite a page, the SSD must:
   a. Read all valid pages from the block.
   b. Erase the entire block.
   c. Write back the valid pages plus the new data to a clean block.

2. **Garbage collection:** The SSD's FTL (Flash Translation Layer) must periodically reclaim blocks containing a mixture of valid and invalid pages, copying valid pages to new blocks before erasing.

3. **Wear levelling:** The FTL must distribute writes evenly across all blocks to prevent some blocks from wearing out prematurely, which may involve moving data from infrequently-written blocks.

::: example
**Example 16.7 (Write Amplification Calculation).** An SSD has blocks of 256 pages (each 4 KB, so 1 MB per block). A block is 75\% full of valid data (192 valid pages, 64 invalid pages).

Garbage collection: read 192 valid pages (768 KB read) and write them to a new block (768 KB written). The block is then erased. If the host wrote 256 KB of new data that triggered this GC:

$$\text{WAF} = \frac{768\,\text{KB (GC writes)} + 256\,\text{KB (host data)}}{256\,\text{KB (host data)}} = \frac{1024}{256} = 4.0$$

If over-provisioning (OP) is increased from 7\% to 28\%, the average block utilisation at GC time drops to 50\%, and WAF decreases to:

$$\text{WAF} = \frac{512 + 256}{256} = 3.0$$
:::

### 16.6.2 Wear Levelling

NAND flash cells have a limited number of program/erase (P/E) cycles before they become unreliable:

| NAND Type | P/E Cycles | Bits per Cell |
|-----------|-----------|---------------|
| SLC (Single) | 50,000--100,000 | 1 |
| MLC (Multi) | 3,000--10,000 | 2 |
| TLC (Triple) | 500--3,000 | 3 |
| QLC (Quad) | 100--1,000 | 4 |

::: definition
**Wear Levelling.** An algorithm implemented by the SSD's Flash Translation Layer (FTL) that distributes write and erase operations evenly across all NAND blocks to maximise the drive's lifespan.

- **Dynamic wear levelling:** Only considers blocks that are currently being written. Blocks containing static (cold) data are never moved and may receive disproportionately few erases.

- **Static wear levelling:** Periodically moves cold data to heavily-worn blocks and reassigns less-worn blocks to receive new writes. This ensures that all blocks approach the P/E limit at roughly the same rate, but adds write amplification from data migration.
:::

::: example
**Example 16.8 (SSD Lifespan Calculation).** A 1 TB TLC SSD has:

- Total NAND capacity: 1.15 TB (15\% over-provisioning)
- P/E cycle limit: 1500 cycles
- WAF: 2.0 (typical for mixed workloads)
- Host write rate: 50 GB/day

Total bytes writeable (TBW):

$$\text{TBW} = \frac{\text{NAND capacity} \times \text{P/E cycles}}{\text{WAF}} = \frac{1.15 \times 10^{12} \times 1500}{2.0} = 862.5 \text{ TB}$$

Drive lifespan:

$$\text{Lifespan} = \frac{\text{TBW}}{\text{Daily writes}} = \frac{862.5 \times 10^3\,\text{GB}}{50\,\text{GB/day}} = 17{,}250\,\text{days} \approx 47\,\text{years}$$

Even with conservative assumptions, the SSD will outlast its other components. However, at 500 GB/day (a busy database server), the lifespan drops to 4.7 years, which is within planning horizons.
:::

---

## 16.7 TRIM and Garbage Collection

### 16.7.1 The TRIM Command

When a file system deletes a file, it marks the blocks as free in its metadata (bitmap or extent tree) but does not inform the SSD. The SSD still considers those blocks as containing valid data, which degrades garbage collection efficiency.

::: definition
**TRIM (ATA DISCARD / NVMe Deallocate).** A command from the host to the SSD indicating that specific logical blocks are no longer in use and their contents may be discarded. The SSD's FTL marks the corresponding pages as invalid, improving garbage collection efficiency by increasing the proportion of invalid pages in each block.
:::

```c
/* Linux: issue TRIM via ioctl */
#include <linux/fs.h>
#include <sys/ioctl.h>

uint64_t range[2];
range[0] = start_byte;   /* Start of the range to discard */
range[1] = length_bytes;  /* Length of the range */

ioctl(fd, BLKDISCARD, range);
```

On Linux, TRIM is typically issued in two ways:

1. **Continuous TRIM:** The file system issues TRIM commands as files are deleted (`mount -o discard`). Simple but adds latency to every delete operation.

2. **Periodic TRIM:** A scheduled job runs `fstrim` to discard all unused blocks at once (e.g., weekly via `systemd` timer). This batches TRIM operations, reducing overhead.

### 16.7.2 Garbage Collection in SSDs

The SSD's internal garbage collector runs autonomously in the firmware:

```text
Garbage Collection Process:

Before GC:                          After GC:
+---+---+---+---+---+---+---+---+  +---+---+---+---+---+---+---+---+
| V | I | V | I | V | I | I | V |  |   |   |   |   |   |   |   |   |
+---+---+---+---+---+---+---+---+  +---+---+---+---+---+---+---+---+
Block A (4 valid, 4 invalid)         Block A (erased, free for writes)

                                    +---+---+---+---+---+---+---+---+
                                    | V | V | V | V |   |   |   |   |
                                    +---+---+---+---+---+---+---+---+
                                    Block B (4 valid pages copied here)

V = Valid page, I = Invalid page
```

The garbage collector must choose which blocks to clean. Common strategies:

- **Greedy:** Select the block with the most invalid pages. Minimises the number of valid pages to copy (lowest short-term write amplification).

- **Cost-benefit:** Similar to LFS (Chapter 14). Considers both the proportion of invalid pages and the age of valid pages. Old valid pages are less likely to be overwritten soon, so copying them is "cheaper" in terms of future work.

- **Wear-aware:** Factors in the erase count of each block. Blocks nearing their P/E limit are avoided for erasure.

---

## 16.8 Backup Strategies

RAID protects against drive failure but not against accidental deletion, software bugs, ransomware, or catastrophic events (fire, flood). **Backups** provide the last line of defence.

### 16.8.1 Backup Types

::: definition
**Backup Types.**

- **Full backup:** A complete copy of all data. Provides the simplest restoration (single copy) but requires the most time and storage.

- **Incremental backup:** Copies only the data that has changed since the **last backup** (full or incremental). Minimal time and storage for each backup, but restoration requires the last full backup plus all subsequent incrementals, applied in order.

- **Differential backup:** Copies all data that has changed since the **last full backup**. More storage than incremental but simpler restoration: only the last full backup plus the latest differential are needed.
:::

::: example
**Example 16.9 (Backup Storage Comparison).** A system has 1 TB of data. Each day, 20 GB changes.

Over a 7-day cycle (full on Sunday, daily backups Mon--Sat):

**Full only:** $7 \times 1\,\text{TB} = 7\,\text{TB}$

**Full + Incremental:**
- Sunday: 1 TB (full)
- Monday: 20 GB (changes since Sunday)
- Tuesday: 20 GB (changes since Monday)
- ...
- Saturday: 20 GB (changes since Friday)
- Total: $1\,\text{TB} + 6 \times 20\,\text{GB} = 1.12\,\text{TB}$

**Full + Differential:**
- Sunday: 1 TB (full)
- Monday: 20 GB (changes since Sunday)
- Tuesday: 40 GB (changes since Sunday)
- ...
- Saturday: 120 GB (changes since Sunday)
- Total: $1\,\text{TB} + (20 + 40 + 60 + 80 + 100 + 120)\,\text{GB} = 1.42\,\text{TB}$

Restoration of Saturday's state:
- **Full only:** Restore Saturday's full backup (1 TB).
- **Incremental:** Restore Sunday's full (1 TB) + Monday's incremental + ... + Saturday's incremental (6 restore operations).
- **Differential:** Restore Sunday's full (1 TB) + Saturday's differential (120 GB) (2 restore operations).
:::

### 16.8.2 The 3-2-1 Rule

::: definition
**The 3-2-1 Backup Rule.** A widely-adopted guideline for data protection:

- **3** copies of data (1 primary + 2 backups).
- **2** different storage media (e.g., local disk + tape, or local disk + cloud).
- **1** copy offsite (protects against localised disasters: fire, flood, theft).
:::

Modern extensions include **3-2-1-1-0:**

- **1** copy offline or air-gapped (protects against ransomware that encrypts all accessible storage).
- **0** errors (verified backups --- regularly test restoration).

### 16.8.3 Snapshot-Based Backups

Copy-on-write file systems (ZFS, Btrfs) enable **snapshot-based backups** that combine the speed of incremental backups with the simplicity of full backups:

```bash
# ZFS snapshot-based backup workflow

# Create a snapshot (instantaneous, zero I/O)
zfs snapshot tank/data@backup-2026-04-16

# Send the snapshot to a backup pool (full)
zfs send tank/data@backup-2026-04-16 | zfs receive backup/data

# Next day: create a new snapshot
zfs snapshot tank/data@backup-2026-04-17

# Send only the delta (incremental)
zfs send -i tank/data@backup-2026-04-16 tank/data@backup-2026-04-17 \
    | zfs receive backup/data

# Restore from a snapshot (rollback)
zfs rollback tank/data@backup-2026-04-16
```

The `zfs send -i` (incremental send) transmits only the blocks that changed between two snapshots. This is more efficient than traditional file-level incremental backups because it operates at the block level and captures all changes, including metadata modifications that file-level tools might miss.

---

## 16.9 Data Integrity and Silent Corruption

### 16.9.1 The Problem of Silent Corruption

Not all storage errors are immediately visible. A **silent corruption** (also called a **silent data error** or **bit rot**) occurs when stored data is altered without the storage system detecting or reporting the error.

::: definition
**Silent Data Corruption.** A data integrity violation where the stored data differs from what was written, but the storage device reports a successful read. The device's own error detection (ECC) either fails to detect the error or was bypassed by the error (e.g., a firmware bug writes data to the wrong location).
:::

Sources of silent corruption include:

- **Misdirected writes:** The drive's firmware writes data to the wrong LBA. The data at the intended LBA is now stale, and the data at the unintended LBA is overwritten.

- **Lost writes:** The drive acknowledges a write that never reaches persistent storage (e.g., a power failure before the drive's volatile write cache is flushed).

- **Bit decay:** Gradual degradation of magnetic or charge-based storage over time. Affects both HDDs (magnetic domain decay) and SSDs (charge leakage in NAND cells).

- **Firmware bugs:** The drive's firmware has thousands of lines of code. Bugs in error handling, wear levelling, or garbage collection can corrupt data.

- **Cosmic rays:** High-energy particles can flip bits in both DRAM and NAND flash. At sea level, the rate is approximately $10^{-15}$ bit flips per bit per hour for DRAM.

Studies by CERN (2007) and NetApp (2008) found that silent corruption occurs at rates of approximately 1 in $10^{14}$ to $10^{16}$ bits read --- rare on a per-bit basis but significant at scale. For a data centre reading 1 PB per day, the expected number of silent corruptions is:

$$\frac{10^{15} \times 8}{10^{15}} = 8 \text{ corrupted bytes per day}$$

### 16.9.2 Scrubbing

::: definition
**Scrubbing.** A proactive data integrity verification process that reads all stored data, verifies checksums, and repairs any detected corruption from redundant copies. Scrubbing detects latent errors before they accumulate and cause data loss.
:::

RAID scrubbing reads every block in the array and verifies parity consistency. If a mismatch is found:

- In a RAID with checksums (ZFS, Btrfs): the checksum identifies which copy is correct, and the corrupted copy is repaired.
- In a traditional RAID (mdadm): the parity indicates a mismatch, but the system cannot determine which block is wrong. It logs the error but cannot automatically repair it.

```bash
# ZFS scrub: verify every block's checksum, repair from redundancy
zpool scrub tank

# Check scrub results
zpool status tank
#   scan: scrub repaired 0B in 2h30m with 0 errors on Wed Apr 16 03:00:00 2026
#   errors: No known data errors

# mdadm scrub: verify RAID parity consistency
echo check > /sys/block/md0/md/sync_action

# Monitor progress
cat /proc/mdstat
# md0 : active raid5 ...
#       [=====>...............]  check = 28.3% ...
```

::: example
**Example 16.10 (Scrub Schedule Calculation).** A ZFS pool has 20 TB of data. Scrub read speed is 500 MB/s (limited by the slowest drive). Scrub duration:

$$T_{\text{scrub}} = \frac{20 \times 10^{12}}{500 \times 10^6} = 40{,}000\,\text{s} \approx 11.1\,\text{hours}$$

Running a weekly scrub adds a read load of $11.1 / 168 = 6.6\%$ of total hours. This is a modest cost for comprehensive integrity verification. ZFS recommends monthly scrubs for most workloads and weekly scrubs for critical data.
:::

### 16.9.3 End-to-End Checksums

::: definition
**End-to-End Data Integrity.** A design principle where checksums are computed by the data producer and verified by the data consumer, with no intermediate component trusted to maintain integrity. Any corruption introduced anywhere in the data path --- by the drive, controller, cable, driver, file system, or page cache --- is detected at read time.
:::

The key insight is that checksums computed **by the drive** (its internal ECC) cannot protect against errors **above the drive**: firmware bugs, controller errors, cable corruption, or kernel bugs. Only checksums computed by the file system and verified by the file system provide true end-to-end protection.

This is why ZFS's and Btrfs's approach of storing checksums in the file system (rather than relying on the drive's ECC) is fundamentally more robust:

```text
Traditional storage stack:
Application -> File system -> Block layer -> Driver -> Controller -> Media
                                                        ^
                                                        |
                                                    ECC here only
                                                (protects media errors,
                                                 not path errors)

ZFS/Btrfs:
Application -> File system -> Block layer -> Driver -> Controller -> Media
                ^                                                      ^
                |                                                      |
            Checksum verified here                                 ECC here
            (protects ENTIRE path)                             (protects media)
```

::: programmer
**Programmer's Perspective: Monitoring Storage Health with `smartctl`.**
The Self-Monitoring, Analysis and Reporting Technology (SMART) system is built into every modern HDD and SSD. It tracks internal health metrics and can predict failures before they occur. The `smartctl` utility (from the `smartmontools` package) reads these metrics.

```bash
# View overall SMART health status
smartctl -H /dev/sda
# === START OF READ SMART DATA SECTION ===
# SMART overall-health self-assessment test result: PASSED

# View all SMART attributes
smartctl -A /dev/sda
# ID# ATTRIBUTE_NAME          FLAG  VALUE WORST THRESH TYPE     RAW_VALUE
#   1 Raw_Read_Error_Rate     0x002f  200   200   051   Pre-fail    0
#   5 Reallocated_Sector_Ct   0x0033  200   200   140   Pre-fail    0
#   9 Power_On_Hours          0x0032  095   095   000   Old_age     22847
# 197 Current_Pending_Sector  0x0032  200   200   000   Old_age     0
# 198 Offline_Uncorrectable   0x0030  200   200   000   Old_age     0

# Critical attributes to monitor:
# 5   Reallocated_Sector_Ct  - sectors remapped due to defects (rising = failing)
# 197 Current_Pending_Sector - sectors awaiting reallocation (instability)
# 198 Offline_Uncorrectable  - sectors that failed ECC during offline scan

# For NVMe SSDs:
smartctl -a /dev/nvme0n1
# Critical NVMe attributes:
# Percentage Used:         3%         (of rated lifespan)
# Data Units Written:      12,345,678 (units of 512 KB = 6.3 TB)
# Media and Data Integrity Errors:  0
# Error Information Log Entries:    0

# Run a long self-test
smartctl -t long /dev/sda
# (takes several hours, scans entire surface)

# Check test results
smartctl -l selftest /dev/sda
```

For production systems, configure `smartd` (the SMART daemon) to monitor all drives and alert on critical attribute changes:

```bash
# /etc/smartd.conf
# Monitor all drives, alert on any attribute change, email on failure
/dev/sda -a -o on -S on -s (S/../.././02|L/../../7/03) \
    -m admin@example.com -M exec /usr/share/smartmontools/smartd_warning.sh
/dev/sdb -a -o on -S on -s (S/../.././02|L/../../7/03) \
    -m admin@example.com -M exec /usr/share/smartmontools/smartd_warning.sh
```

A robust monitoring setup combines SMART monitoring, ZFS scrub schedules, and `mdadm` monitoring:

```go
package main

import (
    "fmt"
    "os"
    "os/exec"
    "strings"
)

// CheckSMARTHealth runs smartctl and checks for critical warnings.
func CheckSMARTHealth(device string) error {
    cmd := exec.Command("smartctl", "-H", device)
    out, err := cmd.Output()
    if err != nil {
        // smartctl returns non-zero for failing drives
        if exitErr, ok := err.(*exec.ExitError); ok {
            if exitErr.ExitCode()&0x08 != 0 {
                return fmt.Errorf("SMART prefailure: %s", device)
            }
        }
        return fmt.Errorf("smartctl error for %s: %w", device, err)
    }
    if !strings.Contains(string(out), "PASSED") {
        return fmt.Errorf("SMART check did not pass for %s", device)
    }
    return nil
}

// CheckReallocatedSectors reads the reallocated sector count.
func CheckReallocatedSectors(device string) (int, error) {
    cmd := exec.Command("smartctl", "-A", device)
    out, err := cmd.Output()
    if err != nil {
        return -1, err
    }
    for _, line := range strings.Split(string(out), "\n") {
        if strings.Contains(line, "Reallocated_Sector_Ct") {
            fields := strings.Fields(line)
            if len(fields) >= 10 {
                var count int
                fmt.Sscanf(fields[9], "%d", &count)
                return count, nil
            }
        }
    }
    return 0, nil
}

func main() {
    devices := []string{"/dev/sda", "/dev/sdb", "/dev/sdc", "/dev/sdd"}
    for _, dev := range devices {
        if err := CheckSMARTHealth(dev); err != nil {
            fmt.Fprintf(os.Stderr, "WARNING: %v\n", err)
            continue
        }
        count, err := CheckReallocatedSectors(dev)
        if err != nil {
            fmt.Fprintf(os.Stderr, "Error reading SMART for %s: %v\n", dev, err)
            continue
        }
        if count > 0 {
            fmt.Fprintf(os.Stderr, "ALERT: %s has %d reallocated sectors\n", dev, count)
        } else {
            fmt.Printf("%s: healthy (0 reallocated sectors)\n", dev)
        }
    }
}
```

The key insight for programmers: do not trust storage. Every production system should verify its data. Use checksums in your application layer (not just the file system), test backups by actually restoring them, and monitor drive health proactively. The cost of verification is negligible compared to the cost of data loss.
:::

---

## 16.10 Putting It All Together: A Reliability Stack

A well-designed storage system employs defence in depth --- multiple independent mechanisms that protect against different failure modes:

| Layer | Mechanism | Protects Against |
|-------|-----------|-----------------|
| Application | Application-level checksums | Logic bugs, data corruption above file system |
| File system | ZFS/Btrfs checksums | Silent corruption, misdirected writes |
| File system | Journaling/CoW | Crash inconsistency |
| Volume manager | RAID 5/6/Z1/Z2 | Drive failure |
| Drive firmware | ECC (BCH/LDPC) | Bit errors in media |
| Drive firmware | Wear levelling | Premature cell death (SSD) |
| Drive firmware | SMART monitoring | Predictive failure detection |
| Operational | Scrubbing | Latent error accumulation |
| Operational | Backups (3-2-1) | All of the above + human error + disasters |

::: theorem
**Theorem 16.6 (Defence in Depth Reliability).** For a system with $n$ independent protection layers, each with effectiveness $e_i$ (probability of catching a given failure), the probability of an undetected failure is:

$$P_{\text{undetected}} = \prod_{i=1}^{n} (1 - e_i)$$

For example, with $n = 4$ layers each having 99\% effectiveness:
$$P_{\text{undetected}} = (0.01)^4 = 10^{-8}$$

The product of independent probabilities rapidly approaches zero, which is why layered defences are so effective even when no single layer is perfect.
:::

::: example
**Example 16.11 (Complete Storage Design).** An engineering team needs to store 50 TB of critical data with the following requirements:

- Survive any 2 simultaneous drive failures.
- Detect and repair silent corruption.
- Recover from accidental deletion within 30 days.
- Survive a site-wide disaster.

**Design:**

1. **Primary storage:** ZFS RAID-Z2 (6 $\times$ 16 TB drives). Usable capacity: $4 \times 16 = 64$ TB. Survives any 2 drive failures. End-to-end checksums detect silent corruption.

2. **Scrubbing:** Monthly ZFS scrub (approximately 28 hours at 500 MB/s). Detects and repairs latent errors before they accumulate.

3. **Snapshots:** Hourly snapshots retained for 48 hours, daily snapshots retained for 30 days. Enables recovery from accidental deletion without restoring from backup.

4. **Local backup:** ZFS send/receive to a second server (RAID-Z1, since the primary already has RAID-Z2). Incremental sends nightly.

5. **Offsite backup:** Weekly full ZFS send to cloud storage (encrypted). Monthly restore test.

6. **Monitoring:** `smartctl` checks every 12 hours, ZFS scrub errors trigger immediate alerts, RAID degradation triggers automatic ticket creation.

This design provides: $2 \times$ drive failure tolerance (RAID-Z2), silent corruption detection (checksums + scrub), 30-day recovery window (snapshots), local disaster recovery (second server), and offsite disaster recovery (cloud backup).
:::

---

## 16.11 Erasure Coding Beyond RAID

### 16.11.1 Limitations of Traditional RAID

Traditional RAID was designed for small arrays of disks (4--16 drives) in a single server. Modern distributed storage systems (cloud object stores, Hadoop HDFS, Ceph) manage thousands of drives across hundreds of servers. At this scale, traditional RAID has several limitations:

- **Rebuild bottleneck:** In a RAID array, only the surviving drives contribute to rebuilding a failed drive. For $N$ drives in a RAID 5 group, the rebuild speed is limited by the throughput of $N - 1$ drives. In a distributed system, hundreds of drives can participate in the rebuild.

- **Correlated failures:** Drives in the same server share power supply, cooling, and network connectivity. A server failure takes out all drives simultaneously. RAID within a server does not protect against server failure.

- **Fixed redundancy:** RAID levels provide fixed protection (1 or 2 drive failures). Erasure codes allow tunable redundancy.

### 16.11.2 Reed-Solomon Erasure Codes

::: definition
**Erasure Code.** An error-correcting code applied at the storage block level, where the locations of missing (erased) blocks are known (because the system knows which drives have failed). An $(n, k)$ erasure code encodes $k$ data blocks into $n$ coded blocks (where $n > k$) such that any $k$ of the $n$ blocks suffice to reconstruct the original data. The code tolerates up to $n - k$ simultaneous block losses.
:::

RAID 5 is an $(n, n-1)$ erasure code (XOR parity: one redundancy block). RAID 6 is an $(n, n-2)$ code (two redundancy blocks using Reed-Solomon in $GF(2^8)$). General Reed-Solomon codes support arbitrary values of $n$ and $k$.

::: example
**Example 16.12 (Erasure Code Storage Efficiency).** Consider storing 10 GB of data with tolerance for 2 failures:

**RAID 6 (8+2):** 10 data blocks + 2 parity blocks = 12 blocks. Storage overhead: $12/10 = 1.2\times$ (20\% overhead).

**3-way replication:** 3 copies of each block. Storage overhead: $3.0\times$ (200\% overhead).

**Reed-Solomon (10, 14):** 10 data blocks + 4 parity blocks = 14 blocks. Tolerates any 4 failures. Storage overhead: $14/10 = 1.4\times$ (40\% overhead for much greater protection).

Erasure coding provides far better storage efficiency than replication while maintaining configurable fault tolerance. This is why cloud storage systems (Google Colossus, Facebook f4, Azure LRC) use erasure codes rather than replication for cold data.
:::

::: theorem
**Theorem 16.7 (MDS Property).** A **Maximum Distance Separable** (MDS) code with parameters $(n, k)$ achieves the maximum possible minimum distance $d = n - k + 1$. Reed-Solomon codes are MDS: any $k$ of $n$ blocks suffice to reconstruct the data, and this is optimal --- no code with the same redundancy can tolerate more erasures.

*Proof sketch.* The Singleton bound states that for any $(n, k)$ code, $d \leq n - k + 1$. Reed-Solomon codes achieve this bound because their generator matrix is a Vandermonde matrix, which has the property that every $k \times k$ submatrix is invertible (non-zero determinant). Therefore, any $k$ received blocks form an invertible system that uniquely determines the $k$ data blocks. $\square$
:::

### 16.11.3 Locally Repairable Codes (LRC)

Reed-Solomon codes have a repair cost problem: reconstructing a single failed block requires reading $k$ other blocks. For a (14, 10) code, repairing one block requires reading 10 blocks from 10 different drives --- significant network and I/O overhead.

**Locally Repairable Codes** (LRCs), developed by Microsoft Research (2012), add **local parity** blocks that protect small groups of data blocks. A single failure within a group can be repaired by reading only the other blocks in that group (typically 3--5 blocks) rather than all $k$ data blocks.

::: definition
**Locally Repairable Code (LRC).** An erasure code where each data block has a **repair group** of size $r \ll k$. A single block failure is repaired by reading only the $r - 1$ other blocks in its repair group plus the local parity block, rather than all $k$ data blocks. The code also has global parity blocks for multi-failure tolerance.
:::

::: example
**Example 16.13 (Azure LRC).** Microsoft Azure Storage uses an LRC(12, 2, 2) code: 12 data blocks are divided into 2 groups of 6. Each group has 1 local parity block (computed as XOR of its 6 data blocks). Additionally, 2 global parity blocks (computed using Reed-Solomon over all 12 data blocks) provide multi-failure tolerance.

Total blocks: 12 (data) + 2 (local parity) + 2 (global parity) = 16. Storage overhead: $16/12 = 1.33\times$.

- **Single failure:** Repaired from the local group (read 6 blocks, not 12).
- **Two failures in different groups:** Each repaired from its local group independently.
- **Two failures in the same group:** Use the global parity (read 12 blocks).
- **Up to 4 failures:** Recoverable using the full code.
:::

Erasure codes are a strictly more general framework than traditional RAID. RAID 5 and RAID 6 are specific instances of erasure codes with $n - k = 1$ and $n - k = 2$ respectively. Modern distributed storage systems use erasure codes with higher redundancy and locality properties, reflecting the different failure modes and repair costs of large-scale networked storage versus local disk arrays.

---

## 16.12 Storage Tiering and Caching

### 16.12.1 The Storage Hierarchy

Modern storage systems often employ multiple tiers with different performance and cost characteristics:

| Tier | Technology | Latency | Cost per GB | Use Case |
|------|-----------|---------|-------------|----------|
| 0 | NVMe SSD | 10--20 $\mu$s | High | Hot data, databases |
| 1 | SATA SSD | 50--100 $\mu$s | Medium | Warm data, active files |
| 2 | HDD (10K RPM) | 3--5 ms | Low | Cold data, archives |
| 3 | Tape (LTO) | 10--60 s | Very low | Archival, compliance |
| Cloud | Object storage | 50--200 ms | Variable | Offsite, disaster recovery |

### 16.12.2 SSD Caching (bcache, dm-cache, ZFS L2ARC)

A common pattern is to use a small SSD as a read/write cache in front of a large HDD array:

::: definition
**SSD Cache.** A block-layer caching mechanism that intercepts I/O requests to a slow device (HDD) and serves frequently accessed blocks from a fast device (SSD). The cache operates transparently: the file system sees a single block device.

- **Read cache (write-around):** Only reads are cached. Writes go directly to the HDD. Simple and safe --- SSD failure does not lose data.
- **Write-back cache:** Both reads and writes are cached. Writes are buffered on the SSD and flushed to the HDD asynchronously. Higher performance but SSD failure can lose uncommitted writes.
- **Write-through cache:** Writes are cached on the SSD and simultaneously written to the HDD. Safe (no data loss on SSD failure) but no write acceleration.
:::

Linux provides several SSD caching mechanisms:

```text
# bcache: kernel block layer cache
# Back device: HDD, Cache device: SSD
make-bcache -B /dev/sda -C /dev/nvme0n1p1
# Set cache mode
echo writeback > /sys/block/bcache0/bcache/cache_mode

# dm-cache: device-mapper based cache
# Similar concept but uses device-mapper infrastructure

# ZFS L2ARC (Level 2 Adaptive Replacement Cache)
# Add an SSD as a read cache to a ZFS pool
zpool add tank cache /dev/nvme0n1p1
```

::: example
**Example 16.14 (Cache Hit Rate and Effective Latency).** A system uses an NVMe SSD cache (latency $= 15\,\mu$s) in front of an HDD array (latency $= 5\,\text{ms}$). The cache hit rate is $h = 0.95$ (95\%).

Effective average latency:
$$L_{\text{eff}} = h \times L_{\text{SSD}} + (1 - h) \times L_{\text{HDD}} = 0.95 \times 15\,\mu\text{s} + 0.05 \times 5000\,\mu\text{s}$$
$$= 14.25\,\mu\text{s} + 250\,\mu\text{s} = 264.25\,\mu\text{s}$$

This is 19x faster than the raw HDD latency. Even a modest cache hit rate of 80\% gives:
$$L_{\text{eff}} = 0.80 \times 15 + 0.20 \times 5000 = 12 + 1000 = 1012\,\mu\text{s} \approx 1\,\text{ms}$$

Still a 5x improvement over raw HDD access.
:::

---

## 16.13 Storage Protocols and Interfaces

### 16.13.1 Protocol Evolution

The evolution of storage interfaces reflects the increasing performance demands of storage media:

| Protocol | Interface | Max Bandwidth | Queue Depth | Year |
|----------|-----------|--------------|-------------|------|
| ATA/IDE | Parallel cable | 133 MB/s | 1 | 1986 |
| SATA I | Serial cable | 150 MB/s | 32 | 2003 |
| SATA III | Serial cable | 600 MB/s | 32 | 2009 |
| SAS-3 | Serial cable | 1200 MB/s | 254 | 2013 |
| NVMe (PCIe 3.0 x4) | PCIe | 3500 MB/s | 65535 | 2011 |
| NVMe (PCIe 4.0 x4) | PCIe | 7000 MB/s | 65535 | 2019 |
| NVMe (PCIe 5.0 x4) | PCIe | 14000 MB/s | 65535 | 2022 |

The key insight is that **protocol overhead**, not media speed, is often the bottleneck. SATA's single 32-command queue was designed for HDDs that could handle only one command at a time. When SSDs arrived with sub-millisecond latency and massive internal parallelism, SATA became the bottleneck. NVMe was designed specifically for flash storage, with 65,535 queues and zero legacy overhead.

### 16.13.2 Network-Attached Storage Protocols

For storage accessed over a network, additional protocols are involved:

::: definition
**Storage Protocols.**

- **NFS (Network File System):** A file-level protocol. The client mounts a remote directory and accesses files using normal file operations. The NFS server translates these into local file system operations. NFS is stateless (NFSv3) or stateful (NFSv4).

- **iSCSI (Internet SCSI):** A block-level protocol that encapsulates SCSI commands in TCP/IP packets. The remote storage appears as a local block device. The operating system sees `/dev/sda` but the actual storage is on a remote server.

- **NVMe-oF (NVMe over Fabrics):** NVMe commands transported over a network fabric (RDMA, TCP, or Fibre Channel). Provides near-local NVMe performance over the network by eliminating the SCSI translation layer.
:::

::: example
**Example 16.15 (Protocol Overhead Comparison).** Accessing a 4 KB block on a remote NVMe SSD:

**iSCSI over TCP:** SCSI command $\to$ iSCSI encapsulation $\to$ TCP segmentation $\to$ IP routing $\to$ Ethernet framing. Round-trip latency: 100--500 $\mu$s (dominated by TCP processing and network latency).

**NVMe-oF over RDMA:** NVMe command $\to$ RDMA send (kernel bypass, zero-copy). Round-trip latency: 10--30 $\mu$s. Approaches local NVMe latency because RDMA bypasses the kernel's network stack entirely.

**NFS:** File read request $\to$ RPC call $\to$ TCP/UDP $\to$ network. Server: VFS lookup $\to$ file system read $\to$ RPC response. Round-trip latency: 200--1000 $\mu$s (includes file system overhead on both client and server).
:::

---

## 16.14 Practical Drive Selection

### 16.14.1 HDD vs SSD Decision Matrix

The choice between HDD and SSD depends on workload characteristics:

| Factor | Choose HDD | Choose SSD |
|--------|-----------|-----------|
| Cost per TB | Under tight budget ($15--20/TB) | Performance justifies cost ($50--100/TB) |
| Access pattern | Sequential (streaming, backup, archival) | Random (databases, VMs, containers) |
| Capacity needed | Very large (50+ TB per drive) | Moderate (1--8 TB typical) |
| Latency requirement | Tolerant (> 5 ms acceptable) | Sensitive (< 1 ms required) |
| Write endurance | Infinite (within mechanical lifespan) | Limited (TBW rating) |
| Power per TB | Higher (6--12 W per drive) | Lower (2--5 W per drive) |
| Vibration sensitivity | Sensitive (affects adjacent drives) | Immune |

### 16.14.2 Enterprise vs Consumer Drives

Enterprise drives differ from consumer drives in several critical ways:

- **Vibration tolerance:** Enterprise HDDs include rotational vibration sensors that adjust the servo to compensate for vibrations from adjacent drives in a dense server chassis.

- **Power loss protection (PLP):** Enterprise SSDs include supercapacitors that provide enough power to flush the volatile write cache to NAND on sudden power loss. Consumer SSDs may lose cached writes.

- **Consistent latency:** Enterprise SSDs prioritise consistent latency (low P99) over peak throughput. Consumer SSDs may have occasional high-latency outliers during garbage collection.

- **Endurance rating:** Enterprise SSDs are rated for 1--10 DWPD (Drive Writes Per Day) over a 5-year warranty. Consumer SSDs are typically rated for 0.3--0.6 DWPD.

::: definition
**DWPD (Drive Writes Per Day).** A measure of SSD write endurance. A drive rated at 1 DWPD can sustain writing its entire capacity once per day for the warranty period.

For a 1 TB drive at 1 DWPD over 5 years:
$$\text{TBW} = 1\,\text{TB} \times 365\,\text{days} \times 5\,\text{years} = 1825\,\text{TB}$$
:::

::: example
**Example 16.21 (Drive Selection for a Database Server).** A PostgreSQL database server has the following requirements: 4 TB usable storage, write rate of 100 GB/day, P99 read latency below 1 ms, must survive 1 drive failure.

**Option A: 4 x 2 TB consumer SATA SSDs in RAID 10.**
- Usable capacity: $4 \times 2 / 2 = 4$ TB. Meets requirement.
- Endurance: Consumer TLC at 0.5 DWPD. TBW = $2000 \times 0.5 \times 365 \times 5 = 1{,}825$ TB. At 100 GB/day with WAF 2.0, daily NAND writes = 200 GB. Lifespan = $1825 \times 10^3 / 200 \approx 9{,}125$ days $\approx 25$ years. Adequate.
- Latency: SATA SSDs: P99 $\approx 0.5\text{--}2$ ms. Marginal --- may exceed 1 ms during GC.
- No power loss protection. Risk of data loss on power failure.

**Option B: 4 x 2 TB enterprise NVMe SSDs in RAID 10.**
- Usable capacity: 4 TB. Meets requirement.
- Endurance: Enterprise TLC at 3 DWPD. TBW = 10,950 TB. Lifespan = 54,750 days $\approx$ 150 years. More than adequate.
- Latency: NVMe P99 $\approx 0.1\text{--}0.3$ ms. Well within requirement.
- Power loss protection included. Safe for database use.
- Cost: approximately 3x higher than Option A.

For a production database, Option B is the correct choice. The enterprise NVMe drives provide the consistent latency, power loss protection, and endurance that a database demands. The consumer drives would work for development and testing but risk data loss and latency spikes in production.
:::

### 16.14.3 Drive Qualification and Testing

Before deploying drives in production, responsible operations teams perform **drive qualification** testing:

1. **Stress testing:** Sustained random write workloads at maximum queue depth for 24--72 hours. Monitors for latency outliers, error counts, and thermal throttling.

2. **Power cycle testing:** Repeated power cuts during active writes, followed by data integrity verification. This tests the drive's power loss protection mechanism.

3. **Firmware verification:** Confirm the firmware version and verify that it does not have known bugs (drive manufacturers publish firmware advisories).

4. **Compatibility testing:** Verify correct operation with the specific RAID controller, HBA (Host Bus Adapter), or software RAID stack in use. Driver and firmware interactions can cause subtle issues.

---

## 16.15 Long-Term Data Preservation

### 16.15.1 Media Longevity

Every storage medium has a finite lifespan, even when not in active use:

| Medium | Expected Data Retention | Failure Mode |
|--------|------------------------|-------------|
| HDD (powered off) | 3--5 years | Lubricant degradation, stiction |
| SSD (powered off) | 1--2 years (consumer), 3 months (enterprise at 40 C) | Charge leakage from NAND cells |
| Magnetic tape (LTO) | 15--30 years | Binder degradation, demagnetisation |
| Optical disc (M-DISC) | 100+ years (claimed) | Physical degradation of recording layer |
| Cloud storage | Indefinite (while paying) | Provider bankruptcy, policy change |

::: example
**Example 16.20 (SSD Data Retention).** NAND flash cells lose their charge over time. The retention period depends on the number of P/E cycles the cell has endured (more cycles = thinner oxide = faster leakage) and temperature:

- A fresh TLC cell (0 P/E cycles) retains data for approximately 10 years at 25 C.
- A worn TLC cell (1000 P/E cycles) retains data for approximately 1 year at 25 C.
- At 40 C (a warm shelf), retention halves approximately.

This is why enterprise SSD specifications distinguish between **active** retention (the drive is powered on periodically, allowing the controller to refresh weak cells) and **unpowered** retention. For archival storage, SSDs are a poor choice compared to tape or optical media.
:::

### 16.15.2 Format Longevity

Data preservation requires not only physical media longevity but also the ability to **read** the data decades later. This requires:

- **File format longevity:** Proprietary formats may become unreadable. Open standards (PDF/A, plain text, TIFF, SQLite) are safer bets for long-term archives.

- **File system longevity:** A backup on a Btrfs volume is useless if future systems cannot mount Btrfs. For archival backups, simple formats (tar archives on ext4, or ISO images) are preferable to sophisticated file systems.

- **Hardware interface longevity:** A backup on a SCSI tape is useless without a SCSI tape drive. Regular migration to current media (every 5--10 years) is essential.

The US Library of Congress recommends the **3-2-1 rule** combined with **format migration**: maintain data in open formats on current media, with periodic refreshes to new media and formats as technology evolves.

Storage reliability is ultimately a systems engineering problem: no single technology or technique provides absolute protection. Defence in depth --- combining RAID for drive failure, checksums for silent corruption, journaling for crash consistency, backups for human error and disasters, and periodic verification for latent errors --- is the only path to truly reliable storage.

---

## Exercises

**Exercise 16.1.** A data centre has 10,000 hard drives, each with an annual failure rate (AFR) of 3\%. (a) What is the expected number of drive failures per year? (b) What is the expected number of drive failures per day? (c) If drives are organised into RAID 5 arrays of 8 drives each, how many arrays are there, and what is the expected number of array failures (data loss events) per year? Assume MTTR = 24 hours and that failures are independent. (d) How does the answer change for RAID 6?

**Exercise 16.2.** Derive the formula for RAID 6 MTTF:
$$\text{MTTF}_{\text{RAID 6}} = \frac{\text{MTTF}_{\text{drive}}^3}{N \times (N-1) \times (N-2) \times \text{MTTR}^2}$$
Start from the three-state Markov model: Normal $\to$ Degraded (1 failure) $\to$ Critical (2 failures) $\to$ Data Loss (3 failures). Calculate the transition rates between states and the expected time to reach the Data Loss state.

**Exercise 16.3.** An SSD has the following specifications: 2 TB capacity, 1500 P/E cycle endurance (TLC NAND), 7\% over-provisioning. The drive is used in a database server that writes 200 GB of data per day. (a) Calculate the drive's total bytes written (TBW) rating assuming WAF = 1.5. (b) Estimate the drive's lifespan in years. (c) What WAF would reduce the lifespan below 3 years? (d) Describe two strategies the database administrator can use to reduce write amplification.

**Exercise 16.4.** Explain the difference between CRC-based error detection and ECC-based error correction. A storage system uses CRC-32 on 4 KB data blocks. (a) What is the probability that a random 4-byte corruption goes undetected? (b) What types of error patterns does CRC-32 guarantee to detect? (c) If the system additionally uses a SEC-DED Hamming code on each 64-bit word, which errors can be corrected automatically, and which require higher-level intervention (e.g., restoring from a RAID parity or backup)?

**Exercise 16.5.** A ZFS pool has 4 vdevs, each a RAID-Z1 group of 5 drives. Each drive has an MTTF of 1,000,000 hours and an unrecoverable read error rate of 1 in $10^{14}$ bits. (a) What is the probability of encountering an unrecoverable read error during the rebuild of a single 8 TB drive? (b) This is called a **URE during rebuild** scenario. Explain why this makes RAID 5 increasingly dangerous for large drives. (c) How does ZFS's checksum-based approach mitigate this risk compared to traditional mdadm RAID?

**Exercise 16.6.** Design a backup schedule for a 10 TB file server using the 3-2-1 rule. Specify: (a) the backup types (full, incremental, differential) and their frequency; (b) the retention policy; (c) the estimated total storage required for backups over 1 year; (d) the procedure for restoring data from 2 weeks ago. Assume 50 GB of data changes daily.

**Exercise 16.7.** A storage system uses the following integrity mechanisms: (1) CRC-32 on each 4 KB block, stored alongside the block; (2) SHA-256 checksum on each 1 MB extent, stored in a separate metadata tree; (3) RAID-Z2 parity across 6 drives. A cosmic ray flips a single bit in a data block. Trace the detection and repair process through all three layers. What would happen if layer (2) were absent? What if layer (3) were absent?
