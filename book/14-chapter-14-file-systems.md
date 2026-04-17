# Chapter 14: File Systems

*"A file system is not just a way to store data --- it is a contract between the operating system and the user, promising that bits entrusted to storage today will be faithfully returned tomorrow."*
--- Marshall Kirk McKusick, architect of the Berkeley Fast File System

---

## 14.1 The File Abstraction

Every modern operating system provides a **file** as the fundamental unit of persistent storage. At the hardware level, storage devices deal in sectors, blocks, and flash pages. The file abstraction hides this complexity, presenting users and applications with a uniform, named container for data.

::: definition
**File.** A file is a named collection of related information recorded on secondary storage. From the operating system's perspective, a file is the smallest allotment of logical secondary storage --- data cannot be written to secondary storage unless they are within a file.
:::

### 14.1.1 File Attributes

Every file carries metadata that describes its properties beyond the raw data content. The specific attributes vary across file systems, but a common set includes:

| Attribute | Description |
|-----------|-------------|
| Name | Human-readable symbolic name |
| Identifier | Unique numeric tag (inode number in Unix) |
| Type | Regular file, directory, symbolic link, device, socket, pipe |
| Location | Pointer to the data blocks on the storage device |
| Size | Current size in bytes (and possibly in blocks) |
| Protection | Access control information (owner, group, permissions, ACLs) |
| Timestamps | Creation time, last modification time, last access time |
| Link count | Number of hard links referencing this file |

On Unix-like systems, the **inode** stores all attributes except the file name. The name-to-inode mapping is maintained by the directory that contains the file. This separation is fundamental: it allows multiple names (hard links) to reference the same underlying file.

::: example
**Example 14.1 (Inode Metadata on Linux).** On an ext4 file system, each inode is a 256-byte structure containing the file's mode, owner UID, group GID, size, timestamps (atime, ctime, mtime, crtime), link count, block count, and pointers to data blocks. The `stat` system call retrieves this information:

```c
#include <sys/stat.h>
#include <stdio.h>
#include <time.h>

int main(void) {
    struct stat sb;
    if (stat("/etc/passwd", &sb) == -1) {
        perror("stat");
        return 1;
    }
    printf("Inode:       %lu\n", (unsigned long)sb.st_ino);
    printf("Size:        %lld bytes\n", (long long)sb.st_size);
    printf("Blocks:      %lld\n", (long long)sb.st_blocks);
    printf("Links:       %lu\n", (unsigned long)sb.st_nlink);
    printf("Permissions: %o\n", sb.st_mode & 07777);
    printf("Modified:    %s", ctime(&sb.st_mtime));
    return 0;
}
```
:::

### 14.1.2 File Operations

The operating system provides a set of system calls for manipulating files. These operations form the **file API** --- the contract between applications and the file system.

The fundamental file operations are:

1. **Create:** Allocate space in the file system for a new file, create a directory entry, and initialise metadata.

2. **Open:** Search the directory structure, verify permissions, load metadata into an in-memory structure (the open file table entry), and return a file descriptor.

3. **Read:** Transfer data from the file into a user-space buffer. The current file-position pointer determines where reading begins.

4. **Write:** Transfer data from a user-space buffer to the file at the current file-position pointer. The file may grow if writing past the current end.

5. **Seek (Reposition):** Adjust the file-position pointer without performing any I/O. Only meaningful for direct-access files.

6. **Close:** Release the open file table entry, flush any buffered writes, and update metadata (such as access time).

7. **Delete (Unlink):** Remove a directory entry. If the link count drops to zero and no process holds the file open, the file's data blocks and inode are freed.

8. **Truncate:** Release the data blocks of a file while keeping its attributes intact, resetting the file size to zero.

::: definition
**Open File Table.** The operating system maintains two levels of open file tables. The **system-wide open file table** contains one entry per open file, holding the inode information, current file size, and access counts. The **per-process open file table** contains one entry per file descriptor in the process, holding the current file-position pointer and a reference to the system-wide entry.
:::

When a process calls `open()`, the kernel searches for an existing entry in the system-wide table. If found, it creates a new per-process entry pointing to it and increments the reference count. This is why two processes that open the same file independently have separate file-position pointers but share the underlying inode data.

### 14.1.3 File Access Methods

The manner in which data within a file is accessed defines its **access method**. The three fundamental access methods are sequential, direct, and indexed.

**Sequential Access.** This is the simplest and most common access method. Data is read or written in order, one record after another. The file-position pointer advances automatically after each operation. Rewinding is possible, but random jumps are not part of the basic model.

$$\text{read\_next}() \to \text{record}_{i}, \quad \text{position} \leftarrow \text{position} + 1$$

Sequential access is natural for text files, log files, and streaming data. Magnetic tape, the original storage medium, supported only sequential access.

**Direct (Random) Access.** The file is viewed as a numbered sequence of fixed-length blocks. Any block can be read or written independently by specifying its block number. The file-position pointer can be set to any position before performing I/O.

$$\text{read}(n) \to \text{block}_n, \quad \text{position} \leftarrow n$$

Direct access is essential for databases, where individual records must be retrieved without scanning the entire file.

**Indexed Access.** An index structure maps keys to block positions within the file. To find a record, the system first searches the index, then uses direct access to fetch the target block. The index itself may be organised as a B-tree, hash table, or multi-level index.

::: example
**Example 14.2 (Access Method Comparison).** Consider a file of 1,000,000 records. To find a specific record:

- **Sequential access:** On average, scan 500,000 records. Time complexity: $O(n)$.

- **Direct access:** If the record number is known, access in $O(1)$ time (one disk seek plus one block read).

- **Indexed access (B-tree):** With a branching factor of 100, the index has depth $\lceil \log_{100}(1{,}000{,}000) \rceil = 3$. Three index lookups plus one data block read: $O(\log_B n)$ where $B$ is the branching factor.
:::

---

## 14.2 Directory Structure

A **directory** is a special file that contains a mapping from human-readable file names to file metadata (or, more precisely, to inodes). The organisation of directories profoundly affects how users navigate the file system and how the system resolves path names.

### 14.2.1 Single-Level Directory

The simplest directory structure is a single flat list of all files in the system. Every file must have a unique name.

```text
Single-Level Directory
+------+------+------+------+------+------+------+
| cat  | mail | prog | data | test | lib  | memo |
+------+------+------+------+------+------+------+
```

This approach was used in early systems (CP/M). It is impractical for modern use because:

- Name collisions become inevitable as the number of files grows.

- No logical grouping is possible --- a user's documents, system binaries, and temporary files all share one namespace.

- Multi-user systems are impossible without some form of isolation.

### 14.2.2 Two-Level Directory

A two-level directory adds one level of hierarchy: each user has their own private directory, all of which sit beneath a **master file directory** (MFD).

```text
Master File Directory
+----------+----------+----------+
| user_a   | user_b   | user_c   |
+----+-----+----+-----+----+-----+
     |          |          |
 +---+---+  +--+---+  +---+---+
 |cat|prog|  |data|cat|  |test|lib|
 +---+----+  +---+----+  +---+---+
```

This solves the multi-user isolation problem: user A and user B can both have a file named `cat` without collision. However, it provides no grouping within a user's files, and sharing files between users requires special mechanisms (such as path names that include the user name).

### 14.2.3 Tree-Structured Directory

Modern file systems use a **tree** (or hierarchical) directory structure. Each directory can contain both files and subdirectories, creating an arbitrarily deep hierarchy.

```text
/
+-- bin/
|   +-- ls
|   +-- cat
+-- home/
|   +-- alice/
|   |   +-- documents/
|   |   |   +-- report.tex
|   |   +-- code/
|   |       +-- main.go
|   +-- bob/
|       +-- notes.txt
+-- etc/
    +-- passwd
    +-- fstab
```

Every process maintains a **current working directory**, enabling the use of relative path names. An **absolute path** begins at the root `/` and specifies the complete path through the tree.

::: definition
**Path Name Resolution.** Given a path `/home/alice/code/main.go`, the kernel resolves it as follows:
1. Start at the root directory inode (inode 2 on ext4).
2. Search the root directory for the entry `home`, obtaining its inode number.
3. Read the `home` directory and search for `alice`.
4. Read the `alice` directory and search for `code`.
5. Read the `code` directory and search for `main.go`.
6. Return the inode of `main.go`.

Each step requires reading a directory from disk (unless cached), making deep paths more expensive to resolve.
:::

### 14.2.4 Acyclic-Graph Directory

A **tree** forbids sharing: a file can exist in exactly one directory. An **acyclic-graph** directory structure allows a file or subdirectory to appear in multiple directories through **hard links** or **symbolic (soft) links**.

::: definition
**Hard Link.** A hard link is an additional directory entry that maps a (possibly different) name to the same inode. Hard links cannot span file system boundaries (because inodes are local to a file system), and they cannot point to directories (to prevent cycles in the graph).
:::

::: definition
**Symbolic Link.** A symbolic link (symlink) is a special file whose content is the path name of another file. When the kernel encounters a symlink during path resolution, it substitutes the symlink's content and continues resolution from that path. Symlinks can cross file system boundaries and can point to directories.
:::

```c
#include <unistd.h>
#include <stdio.h>

int main(void) {
    /* Create a hard link: "backup.txt" points to the same inode as "data.txt" */
    if (link("data.txt", "backup.txt") == -1) {
        perror("link");
        return 1;
    }

    /* Create a symbolic link: "shortcut" contains the string "/home/alice/data.txt" */
    if (symlink("/home/alice/data.txt", "shortcut") == -1) {
        perror("symlink");
        return 1;
    }

    printf("Hard link and symbolic link created.\n");
    return 0;
}
```

The key difference is visible upon deletion. If the original file `data.txt` is deleted:

- The hard link `backup.txt` still works --- it references the same inode, and the inode is not freed until all hard links are removed (link count reaches zero).

- The symbolic link `shortcut` becomes a **dangling symlink** --- the path it contains no longer resolves to a valid file.

### 14.2.5 General Graph Directory

If we allow arbitrary links, including cycles, the directory structure becomes a general graph. Cycles create serious problems:

- **Infinite traversal:** A recursive directory listing (`find /`, `ls -R`) may loop forever.

- **Deletion complexity:** When can storage be reclaimed if there are circular references?

To handle cycles, file systems may use:

- **Garbage collection:** Traverse all reachable files from the root; anything unreachable is freed. This is expensive and rarely used.

- **Cycle prevention:** Prohibit hard links to directories (as Linux does). Symlinks can technically create apparent cycles, but since symlinks are resolved at access time, they do not create true reference cycles in the inode graph.

- **Reference counting with cycle detection:** Maintain link counts but supplement with periodic cycle checks.

---

## 14.3 File System Mounting and VFS

### 14.3.1 Mounting

A storage device contains a **file system** --- a self-contained structure with its own root directory, free-space metadata, and allocation tables. Before the files on a device can be accessed, the file system must be **mounted** onto the existing directory tree at a designated **mount point**.

::: definition
**Mount Point.** A mount point is an existing directory in the file system hierarchy where a new file system is attached. After mounting, accessing the mount point directory transparently redirects to the root of the mounted file system.
:::

```text
Before mounting /dev/sdb1 on /mnt/usb:
/
+-- mnt/
|   +-- usb/        (empty directory)
+-- home/

After mounting:
/
+-- mnt/
|   +-- usb/        (now shows contents of /dev/sdb1)
|       +-- photos/
|       +-- music/
+-- home/
```

On Linux, the `mount` system call attaches a file system:

```c
#include <sys/mount.h>

/* Mount an ext4 file system from /dev/sdb1 onto /mnt/usb */
int ret = mount("/dev/sdb1", "/mnt/usb", "ext4", MS_RDONLY, NULL);
```

The kernel maintains a **mount table** that maps mount points to the corresponding superblock structures. During path name resolution, whenever the kernel crosses a mount point, it switches to the mounted file system's root directory.

### 14.3.2 The Virtual File System (VFS) Layer

A modern operating system must support multiple file system types simultaneously: ext4 for the root partition, FAT32 for a USB drive, NFS for a network share, procfs for process information. The **Virtual File System** (VFS) layer provides a uniform interface that abstracts the differences between file system implementations.

::: definition
**Virtual File System (VFS).** The VFS is a kernel subsystem that provides a common interface for file system operations. It defines a set of abstract operations (open, read, write, lookup, mkdir, etc.) that every concrete file system must implement. User-space applications interact only with the VFS; the VFS dispatches calls to the appropriate file system driver.
:::

The VFS defines four principal object types:

1. **Superblock object:** Represents a mounted file system. Contains metadata about the file system (block size, maximum file size, file system type) and a pointer to the root inode.

2. **Inode object:** Represents a file (in the broad sense: regular file, directory, symlink, device). Contains all metadata except the file name.

3. **Dentry (directory entry) object:** Represents a single component of a path. The dentry cache (dcache) accelerates path name resolution by caching recently resolved name-to-inode mappings.

4. **File object:** Represents an open file. Contains the file-position pointer and a pointer to the file operations structure.

Each object type has an associated **operations structure** --- a table of function pointers that the concrete file system fills in:

```c
/* Simplified VFS inode operations (Linux kernel) */
struct inode_operations {
    struct dentry * (*lookup)(struct inode *, struct dentry *, unsigned int);
    int (*create)(struct inode *, struct dentry *, umode_t, bool);
    int (*link)(struct dentry *, struct inode *, struct dentry *);
    int (*unlink)(struct inode *, struct dentry *);
    int (*symlink)(struct inode *, struct dentry *, const char *);
    int (*mkdir)(struct inode *, struct dentry *, umode_t);
    int (*rmdir)(struct inode *, struct dentry *);
    int (*rename)(struct inode *, struct dentry *,
                  struct inode *, struct dentry *, unsigned int);
    /* ... many more operations ... */
};

/* Simplified VFS file operations */
struct file_operations {
    ssize_t (*read)(struct file *, char __user *, size_t, loff_t *);
    ssize_t (*write)(struct file *, const char __user *, size_t, loff_t *);
    loff_t  (*llseek)(struct file *, loff_t, int);
    int     (*open)(struct inode *, struct file *);
    int     (*release)(struct inode *, struct file *);
    int     (*mmap)(struct file *, struct vm_area_struct *);
    long    (*ioctl)(struct file *, unsigned int, unsigned long);
    /* ... */
};
```

When ext4 registers with the VFS, it provides its own implementations of these function pointers:

```c
const struct inode_operations ext4_dir_inode_operations = {
    .create     = ext4_create,
    .lookup     = ext4_lookup,
    .link       = ext4_link,
    .unlink     = ext4_unlink,
    .symlink    = ext4_symlink,
    .mkdir      = ext4_mkdir,
    .rmdir      = ext4_rmdir,
    .rename     = ext4_rename2,
    /* ... */
};
```

This is the **strategy pattern** applied at the operating system level: the VFS defines the interface, and each file system provides its own strategy.

::: programmer
**Programmer's Perspective: VFS and Go's `io/fs` Package.**
The Linux VFS architecture has a direct parallel in Go's `io/fs` package (introduced in Go 1.16). The `fs.FS` interface defines the minimal contract for a file system:

```go
package fs

type FS interface {
    Open(name string) (File, error)
}

type File interface {
    Stat() (FileInfo, error)
    Read([]byte) (int, error)
    Close() error
}
```

Just as the Linux VFS allows any file system to plug in by implementing the `inode_operations` and `file_operations` structures, Go allows any type to act as a file system by implementing `fs.FS`. The `os.DirFS()` function wraps a real directory, `embed.FS` serves embedded files, and `testing/fstest.MapFS` provides an in-memory file system for tests --- all through the same interface.

The `fs.WalkDir()` function traverses any `fs.FS` implementation, just as the kernel's `path_walk()` traverses any VFS-compliant file system. When writing Go applications, designing around `fs.FS` instead of direct `os` calls makes code testable (swap in `MapFS` for tests) and portable (swap `os.DirFS` for `embed.FS` when deploying as a single binary).

```go
package main

import (
    "fmt"
    "io/fs"
    "os"
)

func countFiles(fsys fs.FS) (int, error) {
    count := 0
    err := fs.WalkDir(fsys, ".", func(path string, d fs.DirEntry, err error) error {
        if err != nil {
            return err
        }
        if !d.IsDir() {
            count++
        }
        return nil
    })
    return count, err
}

func main() {
    fsys := os.DirFS("/etc")
    n, err := countFiles(fsys)
    if err != nil {
        fmt.Fprintf(os.Stderr, "error: %v\n", err)
        os.Exit(1)
    }
    fmt.Printf("Files under /etc: %d\n", n)
}
```
:::

---

## 14.4 Allocation Methods

When a file is created and data is written to it, the file system must decide which disk blocks to allocate. The allocation strategy profoundly affects both performance (sequential read speed, random access time, fragmentation) and the complexity of the metadata structures.

### 14.4.1 Contiguous Allocation

In contiguous allocation, each file occupies a set of **contiguous blocks** on the disk. The directory entry records the starting block and the length (number of blocks).

::: definition
**Contiguous Allocation.** A file of $n$ blocks is stored in blocks $b, b+1, b+2, \ldots, b+n-1$. The directory entry stores the pair $(b, n)$.
:::

**Advantages:**

- Sequential access is maximally efficient: the disk head (on a rotational drive) makes no seeks.

- Direct access is trivial: block $i$ of the file is at disk block $b + i$.

- Minimal metadata: only two numbers per file.

**Disadvantages:**

- **External fragmentation:** Over time, free space becomes fragmented into small holes that cannot accommodate new files. This is the same problem that plagues contiguous memory allocation.

- **File growth is difficult:** If the blocks after a file are occupied, the file cannot grow in place and must be relocated --- an expensive operation.

- **Pre-allocation requires knowing the final size:** The user must declare the file size at creation time, or the system must over-allocate.

The fragmentation problem is quantified by:

$$\text{Fragmentation ratio} = 1 - \frac{\text{largest free extent}}{\text{total free space}}$$

A ratio near 1 indicates severe fragmentation: plenty of total free space exists, but no single contiguous region is large enough.

::: example
**Example 14.3 (Contiguous Allocation Fragmentation).** A disk has 100 blocks. Files A (10 blocks), B (20 blocks), C (15 blocks) are allocated contiguously. Then B is deleted, freeing blocks 10--29. Now the free space is: blocks 10--29 (20 blocks) and blocks 45--99 (55 blocks). Total free space: 75 blocks. Largest free extent: 55 blocks.

$$\text{Fragmentation ratio} = 1 - \frac{55}{75} = 1 - 0.733 = 0.267$$

If we then need to allocate a file of 60 blocks, neither free extent is large enough, even though 75 blocks are free in total.
:::

Contiguous allocation is still used in limited contexts: CD-ROM file systems (ISO 9660) use it because the media is write-once and the file sizes are known at mastering time. Some real-time systems use contiguous extents for predictable access times.

### 14.4.2 Linked Allocation

In linked allocation, each file is a **linked list of disk blocks**. Each block contains a pointer to the next block in the chain. The directory entry stores the pointer to the first block.

::: definition
**Linked Allocation.** Each disk block contains data and a pointer to the next block. The directory entry stores the first and last block pointers. The last block's pointer is `NULL` (or a sentinel value).
:::

**Advantages:**

- No external fragmentation: any free block can be used, regardless of its position.

- Files can grow dynamically by appending new blocks to the chain.

- No need to pre-declare file sizes.

**Disadvantages:**

- **Sequential access only:** To read block $i$, the system must follow $i$ pointers from the start of the chain. Direct access requires $O(n)$ time.

- **Pointer overhead:** Each block loses space to the pointer. With 512-byte blocks and 4-byte pointers, 0.78\% of space is wasted. With 4 KB blocks, the overhead drops to 0.1\%.

- **Fragility:** If a single pointer is corrupted (due to a bad sector or software bug), the remainder of the file is lost.

- **Poor locality:** Blocks may be scattered across the disk, causing excessive seek operations.

**The File Allocation Table (FAT).** MS-DOS and its successors (Windows 95/98) improved upon basic linked allocation by moving all the pointers into a separate table: the **File Allocation Table**. Instead of embedding the next-block pointer in each data block, the FAT stores one entry per block. Entry $i$ contains the number of the block that follows block $i$ in the chain.

```text
FAT (File Allocation Table)
Block:  0    1    2    3    4    5    6    7    8    9
Entry: [3]  [7]  [-]  [4]  [6]  [-]  [EOF] [EOF] [-]  [-]

File A starts at block 0: 0 -> 3 -> 4 -> 6 -> EOF
File B starts at block 1: 1 -> 7 -> EOF
```

The FAT is small enough to cache entirely in memory, which restores $O(1)$ direct access (search the FAT chain in memory without disk I/O). However, the FAT itself becomes a critical structure: if it is corrupted, the entire file system is lost. FAT file systems therefore maintain two copies of the FAT.

### 14.4.3 Indexed Allocation (The Inode)

Indexed allocation solves linked allocation's direct access problem by gathering all block pointers into a single **index block** (or **inode**) for each file.

::: definition
**Indexed Allocation.** Each file has an index block that contains an array of disk block pointers. The $i$-th entry in the index block points to the $i$-th data block of the file. The directory entry points to the index block.
:::

For small files, a single index block suffices. For large files, the index block would need to be very large. Unix file systems solve this with a **multi-level index** scheme:

- **Direct pointers:** The inode contains 12 direct pointers, each pointing to a data block. For a 4 KB block size, this covers files up to $12 \times 4\,\text{KB} = 48\,\text{KB}$.

- **Single indirect pointer:** Points to a block that itself contains pointers to data blocks. With 4-byte pointers and 4 KB blocks, one indirect block holds $4096 / 4 = 1024$ pointers, covering an additional $1024 \times 4\,\text{KB} = 4\,\text{MB}$.

- **Double indirect pointer:** Points to a block of single-indirect pointers. Coverage: $1024^2 \times 4\,\text{KB} = 4\,\text{GB}$.

- **Triple indirect pointer:** Points to a block of double-indirect pointers. Coverage: $1024^3 \times 4\,\text{KB} = 4\,\text{TB}$.

::: theorem
**Theorem 14.1 (Maximum File Size with Multi-Level Indexing).** Given a block size of $B$ bytes and pointer size of $P$ bytes, the maximum file size with the Unix inode scheme (12 direct, 1 single-indirect, 1 double-indirect, 1 triple-indirect) is:

$$S_{\max} = \left(12 + \frac{B}{P} + \left(\frac{B}{P}\right)^2 + \left(\frac{B}{P}\right)^3\right) \times B$$

For $B = 4096$ and $P = 4$: $S_{\max} = (12 + 1024 + 1024^2 + 1024^3) \times 4096 \approx 4\,\text{TB}$.

For $B = 4096$ and $P = 8$ (64-bit pointers): $S_{\max} = (12 + 512 + 512^2 + 512^3) \times 4096 \approx 512\,\text{GB}$.
:::

::: example
**Example 14.4 (Block Access Cost).** To read byte 50,000 of a file on a 4 KB block system with 4-byte pointers:

1. Byte 50,000 is in logical block $\lfloor 50000 / 4096 \rfloor = 12$.

2. Block 12 is beyond the 12 direct pointers (blocks 0--11), so it is the first block addressed by the single-indirect pointer.

3. The kernel reads the inode (1 disk access), then the indirect block (1 disk access), then the data block (1 disk access) --- 3 accesses total.

For a byte at position $5{,}000{,}000$ (logical block 1220), which falls in the double-indirect range: the kernel reads the inode, the double-indirect block, the appropriate single-indirect block, and the data block --- 4 accesses total.
:::

**Extent-Based Allocation.** Modern file systems like ext4, XFS, and Btrfs use **extents** rather than individual block pointers. An extent is described by a triple: (logical block, physical block, length). A 100 MB contiguous file requires a single extent descriptor instead of 25,600 individual block pointers (with 4 KB blocks).

```text
Ext4 Extent:
+------------------+---------------------+--------+
| Logical block: 0 | Physical block: 500 | Len: 25600 |
+------------------+---------------------+--------+
   => Blocks 0-25599 of the file map to disk blocks 500-26099
```

Ext4 uses an extent tree (a B-tree variant) stored in the inode for files with many extents, and stores up to four extents directly in the inode for small files.

---

## 14.5 Free-Space Management

The file system must track which blocks are free and which are allocated. The choice of free-space management method affects allocation speed, fragmentation, and the overhead of metadata storage.

### 14.5.1 Bitmap (Bit Vector)

A **bitmap** uses one bit per block: 1 for free, 0 for allocated (or vice versa). The bitmap for a disk with $n$ blocks requires $\lceil n/8 \rceil$ bytes.

::: definition
**Free-Space Bitmap.** A bit vector $B[0 \ldots n-1]$ where $B[i] = 1$ if block $i$ is free and $B[i] = 0$ if block $i$ is allocated.
:::

::: example
**Example 14.5 (Bitmap Size).** A 1 TB disk with 4 KB blocks has $1{,}099{,}511{,}627{,}776 / 4096 = 268{,}435{,}456$ blocks. The bitmap requires $268{,}435{,}456 / 8 = 33{,}554{,}432$ bytes $= 32$ MB. This is 0.003\% of the disk capacity --- a very modest overhead.
:::

**Finding free blocks** is efficient with a bitmap. To find the first free block, scan the bitmap for the first word that is not all zeros, then use bit manipulation (e.g., `__builtin_ctz` or `ffs`) to find the first set bit:

```c
#include <stdint.h>
#include <string.h>

#define BLOCKS_PER_GROUP 32768
#define WORDS (BLOCKS_PER_GROUP / 64)

/* Find the first free block in a bitmap group */
int find_free_block(uint64_t bitmap[WORDS]) {
    for (int i = 0; i < WORDS; i++) {
        if (bitmap[i] != 0) {
            int bit = __builtin_ctzll(bitmap[i]); /* count trailing zeros */
            return i * 64 + bit;
        }
    }
    return -1; /* no free block */
}

/* Allocate a block (clear the bit) */
void alloc_block(uint64_t bitmap[WORDS], int block) {
    bitmap[block / 64] &= ~(1ULL << (block % 64));
}

/* Free a block (set the bit) */
void free_block(uint64_t bitmap[WORDS], int block) {
    bitmap[block / 64] |= (1ULL << (block % 64));
}
```

Finding a **contiguous** run of $k$ free blocks is more expensive but still practical with word-level operations.

**Advantages:** Efficient for finding contiguous free space (important for reducing fragmentation). The entire bitmap can fit in memory for moderate-sized disks.

**Disadvantages:** For very large disks, even the bitmap can be large. Scanning the bitmap is $O(n / w)$ where $w$ is the machine word size.

### 14.5.2 Linked List

A **free list** links all free blocks together. The head of the list is stored in a known location (e.g., the superblock). Each free block contains a pointer to the next free block.

**Advantages:** Simple to implement. Allocation is $O(1)$ (take the head of the list).

**Disadvantages:** To allocate $k$ contiguous blocks, the system must traverse the list looking for adjacent blocks --- this is $O(n)$ in the worst case. The free list cannot be cached efficiently because it is scattered across the disk.

### 14.5.3 Grouping

An optimisation of the free list: the first free block stores the addresses of $n$ free blocks. The last of these $n$ addresses points to a block that stores the next $n$ free addresses, and so on.

This reduces the number of disk reads needed to find free blocks: one read of a group block yields $n - 1$ usable free blocks and a pointer to the next group.

### 14.5.4 Counting

Since free blocks often occur in contiguous runs (especially after a fresh format or defragmentation), the **counting** method stores each free extent as a pair: (starting block, count). A list of such pairs is maintained, often sorted by starting block.

::: example
**Example 14.6 (Counting vs. Bitmap).** A freshly formatted 1 TB disk with 4 KB blocks has one free extent: (0, 268435456). The counting method needs just one entry (8 bytes), compared to the bitmap's 32 MB. After heavy use with many small allocations and deletions, the counting list may grow large, but it remains much smaller than the bitmap as long as the number of free extents is small relative to the total block count.
:::

Ext4 uses a hybrid approach: it maintains both a **block bitmap** and an **extent-based free space cache** that tracks free extents for fast allocation.

---

## 14.6 Journaling File Systems

A file system update often involves multiple writes to different locations: modifying data blocks, updating the inode, adjusting the bitmap, and updating the directory entry. If the system crashes (power failure, kernel panic) in the middle of this multi-step update, the file system can be left in an **inconsistent state**.

::: definition
**File System Consistency.** A file system is consistent if all of its metadata structures (superblock, bitmaps, inodes, directory entries) agree with one another. Inconsistency arises when a crash interrupts a multi-step update, leaving some structures modified and others not.
:::

### 14.6.1 The Consistency Problem

Consider creating a new file, which requires:

1. Allocate an inode (mark it as used in the inode bitmap).
2. Initialise the inode with the file's metadata.
3. Allocate data blocks (mark them as used in the block bitmap).
4. Write data to the allocated blocks.
5. Add a directory entry mapping the file name to the inode.

If the system crashes after step 1 but before step 5, the inode is allocated but no directory entry points to it --- an **orphaned inode** that wastes space. If the crash occurs after step 5 but before step 1 completes, the directory points to an uninitialised inode --- potentially catastrophic.

Before journaling, the solution was `fsck` (file system check): a program that scans the entire file system at boot time, checking every inode, every block pointer, every bitmap entry, and every directory entry for consistency. For a large file system, `fsck` can take **hours**.

### 14.6.2 Write-Ahead Logging

**Journaling** (also called write-ahead logging) solves the consistency problem by recording intended changes in a sequential **log** (or **journal**) before applying them to the file system. The protocol is:

1. **Journal write:** Write a description of all the changes (the **transaction**) to the journal.

2. **Journal commit:** Write a commit record marking the transaction as complete.

3. **Checkpoint:** Apply the changes to their actual locations in the file system.

4. **Journal free:** Mark the journal space as reusable.

If a crash occurs:

- Before the commit record is written: the transaction is incomplete and is simply discarded. The file system remains in its pre-transaction state.

- After the commit but before the checkpoint completes: the recovery process **replays** the journal, re-applying the committed transaction to bring the file system to a consistent state.

The critical insight is that the journal is written **sequentially**, which is fast on both rotational and solid-state drives, and the commit record is a single atomic write (or is made atomic via a checksum).

### 14.6.3 Journaling Modes

File systems offer different journaling modes that trade recovery completeness against performance:

**Journal (Full Data Journaling).** Both metadata and data blocks are written to the journal before being checkpointed to their final locations. This provides the strongest consistency guarantee --- after a crash, both metadata and file contents are recoverable. However, every block of data is written **twice** (once to the journal, once to the final location), halving the effective write bandwidth.

**Ordered (Metadata-Only with Ordering).** Only metadata is journaled. However, the file system guarantees that data blocks are written to their final locations **before** the metadata transaction is committed. After a crash, metadata is consistent, and data blocks pointed to by committed metadata contain the intended data (not garbage from a previous file). This is the default mode for ext4.

**Writeback (Metadata-Only without Ordering).** Only metadata is journaled, and no ordering is enforced between data and metadata writes. This is the fastest mode but can result in files containing stale data after a crash (the inode points to blocks that have not yet been written with the new data).

::: example
**Example 14.7 (Journaling Overhead Comparison).** Consider appending 1 MB to a file on ext4 with a 4 KB block size:

- **Writeback mode:** 256 data block writes + metadata journal writes (approximately 1--2 blocks for the transaction). Total: approximately 258 block writes.

- **Ordered mode:** Same as writeback, but the data blocks must complete before the journal commit. The total number of writes is the same, but the ordering constraint may reduce parallelism.

- **Journal mode:** 256 data block writes to the journal + journal metadata + commit record, then 256 data block writes to the final location + metadata writes. Total: approximately 514 block writes --- nearly double.
:::

::: theorem
**Theorem 14.2 (Journal Recovery Correctness).** If each journal transaction has a valid commit record (verified by checksum), then replaying that transaction from the journal produces the same file system state as if the original operation had completed without interruption. Transactions without valid commit records are safely discarded.

*Proof sketch.* The journal contains a complete description of all blocks to be written. The commit record's checksum verifies the integrity of the transaction. Replaying the transaction writes exactly the intended blocks to their intended locations, which is idempotent (replaying the same transaction multiple times produces the same result). Therefore, recovery produces the intended final state regardless of how many times the crash interrupted the checkpoint phase. $\square$
:::

### 14.6.4 ext4 Journaling Implementation

The ext4 file system uses the **JBD2** (Journaling Block Device 2) layer, which implements a circular log:

```text
Journal Structure (circular):
+--------+--------+--------+--------+--------+--------+
| TXN 1  | TXN 2  | TXN 3  | TXN 4  |  FREE  |  FREE |
+--------+--------+--------+--------+--------+--------+
^                           ^                  ^
|                           |                  |
Journal start              Journal head        Journal end
(oldest committed)         (next write)
```

The journal is a fixed-size region (typically 128 MB by default). When it fills up, the system must checkpoint old transactions (write them to their final locations) before reclaiming journal space. If the journal fills up completely, the system stalls until checkpointing frees space.

Mount options control the journaling mode:

```text
# Full journaling (safest, slowest)
mount -o data=journal /dev/sda1 /mnt

# Ordered mode (default, good balance)
mount -o data=ordered /dev/sda1 /mnt

# Writeback mode (fastest, least safe)
mount -o data=writeback /dev/sda1 /mnt
```

### 14.6.5 XFS Journaling

XFS, originally developed by Silicon Graphics (SGI), uses a similar write-ahead log but with several innovations:

- **Log-space reservation:** Before beginning a transaction, XFS reserves sufficient log space, preventing log-full stalls.

- **Delayed allocation:** XFS delays the assignment of physical blocks until data is flushed from the page cache, allowing better allocation decisions (larger extents, less fragmentation).

- **Allocation groups:** XFS divides the file system into allocation groups, each with its own inode and free-space structures. This enables parallel allocation across multiple threads.

---

## 14.7 Log-Structured File Systems

Journaling file systems use the log only for crash recovery --- the actual data lives in fixed locations on disk. **Log-structured file systems** take the logging concept to its logical extreme: the log IS the file system. All writes --- both data and metadata --- are appended sequentially to the log.

### 14.7.1 The LFS Concept

The Log-structured File System (LFS) was proposed by Rosenblum and Ousterhout in 1992. Their key observation was that as memory sizes grew, read performance was increasingly dominated by the buffer cache (most reads are cache hits), while **write performance remained limited by disk seek time**. By converting all writes to sequential appends, LFS eliminates write-time seeks entirely.

::: definition
**Log-Structured File System.** A file system in which all data and metadata are written sequentially to a log. The log is divided into fixed-size **segments** (typically 512 KB to several MB). Within each segment, data blocks, inodes, and inode maps are packed sequentially. An **inode map** maintains the current disk address of each inode, since inodes move with each update.
:::

The write path is simple: buffer writes in memory until a full segment is accumulated, then write the entire segment sequentially. This maximises disk bandwidth and minimises seek overhead.

The read path uses the **inode map** (a small, mostly cached structure) to locate the current version of any inode, then follows the inode's block pointers as usual.

### 14.7.2 Garbage Collection

The fundamental challenge of LFS is **garbage collection**. When a file is modified, the new version is appended to the log, but the old version remains in its previous segment, now occupying dead space. Over time, segments become a mixture of live and dead blocks.

The **segment cleaner** reclaims space by:

1. Selecting a segment to clean (typically one with a high proportion of dead blocks).
2. Identifying the live blocks in that segment (using a **segment summary** block).
3. Copying the live blocks to the head of the log.
4. Marking the cleaned segment as free.

The cleaning policy critically affects performance. The **cost-benefit** policy considers both the proportion of dead blocks and the age of the segment:

$$\text{cost-benefit} = \frac{\text{free space generated} \times \text{age of youngest block}}{\text{cost of cleaning}} = \frac{(1 - u) \times \text{age}}{1 + u}$$

where $u$ is the utilisation (fraction of live blocks) of the segment. This policy prefers to clean segments that are mostly dead (high $1 - u$) and whose live data is old (unlikely to be overwritten soon).

### 14.7.3 F2FS: Flash-Friendly File System

**F2FS** (Flash-Friendly File System), developed by Samsung and merged into the Linux kernel in 2012, is a modern log-structured file system designed specifically for flash storage (SSDs, eMMC, SD cards).

F2FS addresses several flash-specific concerns:

- **Write amplification:** Flash devices can only erase in large units (erase blocks, typically 256 KB--1 MB) but write in smaller units (pages, typically 4--16 KB). Rewriting a single page may require erasing an entire block. LFS's sequential write pattern aligns well with flash: new data is always written to clean space, and the garbage collector consolidates live data.

- **Hot/cold data separation:** F2FS classifies data into six temperature levels (hot/warm/cold for both data and metadata) and writes each category to separate zones. This improves garbage collection efficiency because segments containing only cold data will have high liveness for a long time (fewer live blocks need to be copied).

- **Multi-head logging:** F2FS maintains six active log segments (one per temperature), enabling concurrent writes to different zones without mixing data temperatures.

- **NAT (Node Address Table):** F2FS's version of the inode map. The NAT translates node IDs to physical addresses and is updated lazily to reduce write amplification.

---

## 14.8 Copy-on-Write File Systems

Copy-on-write (CoW) file systems take a radically different approach to consistency: instead of overwriting data in place, every modification creates a **new copy** of the modified blocks, and the metadata tree is updated from the leaves to the root to point to the new copies.

### 14.8.1 The CoW Principle

::: definition
**Copy-on-Write (CoW) File System.** A file system in which no block is ever overwritten in place. When data is modified, the new data is written to a new location, the parent metadata block is updated to point to the new data (itself written to a new location), and this propagation continues up to the root of the metadata tree. The root pointer is then atomically updated to point to the new tree.
:::

The key insight is that the atomic update of a single root pointer transitions the entire file system from one consistent state to another. There is no window of inconsistency, and **no journal is needed**.

```text
Before modification:          After CoW modification:
      [Root]                       [Root'] (new)
      /    \                       /    \
   [A]    [B]                   [A]    [B'] (new)
   / \    / \                   / \    / \
 [1] [2] [3] [4]             [1] [2] [3'] [4]
                                        (new)
                              Old [Root], [B], [3] are now
                              unreferenced and can be freed.
```

### 14.8.2 Btrfs

**Btrfs** (B-tree File System, pronounced "butter FS"), initially developed by Oracle and merged into the Linux kernel in 2009, is a CoW file system designed for enterprise and desktop Linux.

**B-tree structure.** Btrfs organises all data and metadata in a set of B-trees. The key trees are:

- **FS tree:** Contains inodes, directory entries, and extent data references.
- **Extent allocation tree:** Tracks which extents are allocated and their reference counts.
- **Checksum tree:** Contains CRC32C checksums for every data extent.
- **Chunk tree:** Maps logical addresses to physical addresses (supporting multi-device configurations).

**Snapshots.** Because CoW never modifies existing blocks, creating a snapshot is nearly instantaneous: simply create a new root pointer that references the same tree. The snapshot and the original share all blocks initially. As modifications occur to either the snapshot or the original, CoW causes the modified paths to diverge while unchanged blocks remain shared.

```text
Snapshot creation (O(1)):
[Original Root] -----> [Tree of shared blocks]
[Snapshot Root] -----/
```

**Checksums.** Btrfs computes CRC32C checksums for every data block and metadata block. Checksums are stored in the checksum tree, separate from the data they protect. On every read, Btrfs verifies the checksum and reports (or automatically repairs, on redundant configurations) any corruption.

### 14.8.3 ZFS

**ZFS** (Zettabyte File System), originally developed by Sun Microsystems and now maintained by the OpenZFS project, is the most feature-rich CoW file system. ZFS integrates the file system and volume manager into a single layer.

**Storage pool.** ZFS manages storage as a **pool** (zpool) of physical devices. File systems (datasets) are created within the pool and share its storage dynamically --- no fixed partitions.

**Merkle tree checksumming.** ZFS stores the checksum of each block in its **parent** block, forming a Merkle tree rooted at the **uberblock** (the root of the pool's metadata). This provides end-to-end data integrity verification: every read can be verified from the data block up through the metadata tree to the root.

::: definition
**Merkle Tree.** A hash tree in which every leaf node contains the hash of a data block, and every non-leaf node contains the hash of its children's hashes. Verification of any single leaf requires $O(\log n)$ hash checks along the path from the leaf to the root.
:::

::: example
**Example 14.8 (ZFS Merkle Tree Verification).** A ZFS file system with 4 levels of indirect blocks stores a data block $D$ with checksum $H(D)$ in its parent indirect block $I_1$. Block $I_1$ has checksum $H(I_1)$ stored in $I_2$, and so on up to the uberblock:

$$\text{uberblock} \xrightarrow{H(I_3)} I_3 \xrightarrow{H(I_2)} I_2 \xrightarrow{H(I_1)} I_1 \xrightarrow{H(D)} D$$

If data block $D$ is silently corrupted (a bit flip in storage), then $H(D)$ will not match the checksum stored in $I_1$, and ZFS will detect the corruption immediately upon read. If the pool has redundancy (mirror or RAID-Z), ZFS will automatically fetch the correct copy from another device and repair the corrupted copy.
:::

**ZFS key features:**

- **Snapshots and clones:** Zero-cost snapshots (as with all CoW file systems). Clones are writable snapshots.

- **Built-in RAID:** RAID-Z1 (single parity), RAID-Z2 (double parity), RAID-Z3 (triple parity), mirrors.

- **Compression:** Transparent LZ4 or ZSTD compression at the block level.

- **Deduplication:** Optional block-level deduplication using a dedup table (DDT) with SHA-256 checksums.

- **Send/receive:** Efficient incremental replication by sending the delta between two snapshots.

::: programmer
**Programmer's Perspective: Working with File Systems from Go.**
Go provides multiple layers of file system interaction. The `os` package wraps POSIX system calls, while the `io/fs` package provides an abstraction layer.

For direct file operations, Go's `os` package maps closely to the system calls discussed in this chapter:

```go
package main

import (
    "fmt"
    "os"
    "syscall"
)

func main() {
    // Create a file (equivalent to open() with O_CREAT)
    f, err := os.Create("example.txt")
    if err != nil {
        fmt.Fprintf(os.Stderr, "create: %v\n", err)
        os.Exit(1)
    }

    // Write data (the write() system call)
    _, err = f.WriteString("Hello, file systems!\n")
    if err != nil {
        fmt.Fprintf(os.Stderr, "write: %v\n", err)
        os.Exit(1)
    }

    // Sync to disk (the fsync() system call --- forces write-back from
    // the page cache to the storage device)
    err = f.Sync()
    if err != nil {
        fmt.Fprintf(os.Stderr, "sync: %v\n", err)
        os.Exit(1)
    }

    // Stat the file (the stat() system call --- retrieves inode metadata)
    info, err := f.Stat()
    if err != nil {
        fmt.Fprintf(os.Stderr, "stat: %v\n", err)
        os.Exit(1)
    }
    fmt.Printf("Size: %d bytes\n", info.Size())
    fmt.Printf("Mode: %s\n", info.Mode())

    // Access underlying system info (Linux-specific)
    if sys, ok := info.Sys().(*syscall.Stat_t); ok {
        fmt.Printf("Inode: %d\n", sys.Ino)
        fmt.Printf("Links: %d\n", sys.Nlink)
        fmt.Printf("Block size: %d\n", sys.Blksize)
        fmt.Printf("Blocks (512-byte): %d\n", sys.Blocks)
    }

    f.Close()

    // Create a hard link
    err = os.Link("example.txt", "example_link.txt")
    if err != nil {
        fmt.Fprintf(os.Stderr, "link: %v\n", err)
    }

    // Create a symbolic link
    err = os.Symlink("example.txt", "example_symlink.txt")
    if err != nil {
        fmt.Fprintf(os.Stderr, "symlink: %v\n", err)
    }
}
```

Note the `f.Sync()` call. Without it, data may linger in the kernel's page cache and be lost on a crash. This is the application-level equivalent of the journaling discussion: your application must decide what consistency guarantees it needs. Databases call `fsync()` after every transaction commit. Log-append workloads may accept the risk of losing the most recent entries in exchange for higher throughput.
:::

---

## 14.9 Crash Recovery Analysis

Understanding crash recovery requires analysing exactly what can go wrong at each step of a multi-block update. This section formalises the crash recovery guarantees provided by different file system architectures.

### 14.9.1 The Crash Consistency Model

::: definition
**Crash Consistency.** A file system provides crash consistency if, after a crash and recovery, the file system is in some **valid state** --- either the state before the operation or the state after the operation, but never an intermediate state where metadata is inconsistent with data.
:::

Consider the operation of appending a block to a file. This requires three writes:

1. **D:** Write the new data block.
2. **I:** Update the inode (increment size, add block pointer).
3. **B:** Update the block bitmap (mark the new block as allocated).

Without any consistency mechanism, six crash scenarios are possible (each subset of {D, I, B} that reaches disk):

| Writes completed | Outcome |
|------------------|---------|
| None | Safe: old state preserved |
| D only | Data written but unreferenced (orphaned block). Block bitmap says free, no pointer. Minor space leak. |
| I only | Inode points to an unallocated block that may contain old data. **Dangerous:** reading the file returns garbage. |
| B only | Block marked allocated but no inode references it. Space leak. |
| D + I | Inode points to new data, but bitmap says the block is free. Another file could be allocated the same block. **Data corruption risk.** |
| D + B | Block allocated and written, but inode does not reference it. Space leak, data inaccessible. |
| I + B | Inode references the block and bitmap marks it allocated, but the data was not written. **File contains garbage.** |
| D + I + B | Complete: correct new state. |

::: theorem
**Theorem 14.3 (Journaling Reduces Crash States).** With metadata journaling (ordered mode), the only possible post-crash states are:

1. The operation was not committed (journal has no commit record): the file system is in the pre-operation state. No data corruption.

2. The operation was committed: recovery replays the journal, bringing metadata to the post-operation state. Because ordered mode ensures D was written before the commit, the data block contains valid data.

No intermediate or inconsistent state is possible. The number of reachable crash states is reduced from $2^n - 1$ (where $n$ is the number of writes) to exactly 2 (before or after).
:::

### 14.9.2 fsck: The Pre-Journaling Approach

Before journaling, the `fsck` (file system check) utility scanned the entire file system at boot time to detect and repair inconsistencies. The checks include:

1. **Superblock validation:** Is the magic number correct? Are the block counts consistent?

2. **Inode scan:** For each allocated inode, verify that all block pointers point to valid blocks within the file system boundaries.

3. **Block allocation cross-check:** Verify that the block bitmap agrees with the block pointers in all inodes. Blocks referenced by inodes should be marked allocated; blocks not referenced by any inode should be marked free.

4. **Directory structure validation:** Every directory entry should point to a valid inode. The `.` entry should point to the directory itself; `..` should point to the parent.

5. **Link count verification:** The link count in each inode should match the number of directory entries pointing to it.

6. **Orphaned inode recovery:** Inodes with zero link count but non-zero reference count (open by a process at crash time) are placed in the `/lost+found` directory.

::: example
**Example 14.12 (fsck Time Estimate).** A 10 TB ext3 file system with 4 KB blocks has $10 \times 10^{12} / 4096 \approx 2.44 \times 10^9$ blocks and approximately $10^8$ inodes (at the default bytes-per-inode ratio). At a scan rate of 100 MB/s (sequential read of all metadata), `fsck` needs to read:

- All inode tables: $10^8 \times 128\,\text{bytes} = 12.8\,\text{GB}$
- All block and inode bitmaps: approximately 600 MB
- All directory data for directory structure validation

Total metadata: approximately 15--20 GB. At 100 MB/s: approximately 150--200 seconds. However, `fsck` also performs random I/O for cross-referencing, making the actual time 10--60 minutes for a 10 TB file system.

With journaling, recovery reads only the journal (128 MB by default) and replays uncommitted transactions: approximately 1--5 seconds regardless of file system size.
:::

---

## 14.10 Performance and Caching

### 14.9.1 The Buffer Cache (Page Cache)

The kernel maintains a **page cache** --- a region of main memory that caches recently accessed disk blocks. All file I/O passes through the page cache:

- **Read:** If the requested block is in the cache (a **cache hit**), the data is copied to the user buffer without any disk I/O. On a **cache miss**, the block is read from disk, stored in the cache, and then copied to the user buffer.

- **Write:** Data is written to the page cache and the corresponding page is marked **dirty**. The actual disk write is deferred. The kernel's **writeback** mechanism flushes dirty pages to disk periodically (typically every 5 seconds on Linux) or when memory pressure rises.

The page cache is extremely effective because of temporal and spatial locality in file access patterns. On a typical Linux server, cache hit rates of 90--99\% are common for read-heavy workloads.

**Page cache eviction.** When memory pressure rises and free pages are scarce, the kernel must evict pages from the cache. Linux uses a **two-list LRU** (Least Recently Used) algorithm:

- **Active list:** Pages that have been accessed at least twice recently. These are considered "hot" and are protected from eviction.

- **Inactive list:** Pages that have been accessed only once or have aged out from the active list. Pages are evicted from the tail of the inactive list.

Pages enter the inactive list when first loaded. If accessed again while on the inactive list, they are promoted to the active list. This two-list scheme avoids the problem of a single large sequential scan (e.g., `cp` of a multi-gigabyte file) evicting all cached pages: the scanned pages enter the inactive list and are quickly evicted without displacing frequently-accessed pages on the active list.

::: example
**Example 14.13 (Page Cache Effectiveness).** A database server has 128 GB of RAM, of which 100 GB is available for the page cache (after kernel and process memory). The database's hot working set is 80 GB (the frequently-accessed indices and recent data). The total database is 2 TB.

Cache hit rate for the hot working set: approximately 100\% (fully cached). Cache hit rate for cold queries: approximately 0\% (must read from disk). If 90\% of queries access the hot working set:

$$\text{Average hit rate} = 0.90 \times 1.0 + 0.10 \times 0.0 = 0.90 = 90\%$$

The effective I/O latency is:
$$L_{\text{eff}} = 0.90 \times 100\,\text{ns} + 0.10 \times 100\,\mu\text{s} = 90\,\text{ns} + 10{,}000\,\text{ns} = 10.09\,\mu\text{s}$$

This is approximately 10x faster than if every access went to the SSD ($100\,\mu$s) and 500x faster than HDD ($5\,$ms).
:::

### 14.9.2 Memory-Mapped File I/O

The `mmap()` system call maps a file (or a portion of it) directly into the process's virtual address space. After mapping, the file's contents can be accessed using ordinary pointer dereferences --- no `read()` or `write()` system calls are needed.

```c
#include <sys/mman.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    int fd = open("data.bin", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    /* Get file size */
    off_t size = lseek(fd, 0, SEEK_END);

    /* Map the entire file into memory */
    char *map = mmap(NULL, size, PROT_READ | PROT_WRITE,
                      MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }

    /* Access file contents directly via pointer arithmetic */
    printf("First 10 bytes: %.10s\n", map);

    /* Modify the file by writing to the mapped region */
    memcpy(map, "MODIFIED!", 9);

    /* Sync changes to disk (optional --- kernel will flush eventually) */
    msync(map, size, MS_SYNC);

    munmap(map, size);
    close(fd);
    return 0;
}
```

::: definition
**Memory-Mapped I/O (`mmap`).** A mechanism that maps a file's contents into a process's virtual address space. The file's pages are loaded on demand via **page faults**: accessing an unmapped page triggers a fault, the kernel reads the page from disk into the page cache, and updates the page table to map the virtual address to the cached page. Subsequent accesses to the same page are direct memory references with no kernel involvement.
:::

**Advantages of mmap:**

- **Zero-copy reads:** Data goes directly from the page cache to the process's address space (via page table mapping). No `copy_to_user()` overhead.

- **Lazy loading:** Only pages that are actually accessed are read from disk. A process that `mmap()`s a 1 GB file but accesses only 10 pages reads only 40 KB from disk.

- **Shared memory:** Multiple processes that `mmap()` the same file share the same physical pages, enabling efficient inter-process communication.

**Disadvantages of mmap:**

- **Page fault overhead:** Each first access to a page triggers a page fault (approximately 2--10 $\mu$s), which is more expensive than a single large `read()` that brings in many pages at once.

- **No error handling:** A disk error during a page fault results in a `SIGBUS` signal, which is difficult to handle gracefully compared to checking the return value of `read()`.

- **TLB pressure:** Mapping large files consumes TLB entries. With 4 KB pages, a 1 GB mapping requires 262,144 page table entries.

### 14.9.3 The Dentry Cache

Path name resolution is one of the most frequent operations in the kernel. The **dentry cache** (dcache) caches the results of name-to-inode lookups. After resolving `/home/alice/code/main.go`, the dcache stores entries for each component: `/`, `home`, `alice`, `code`, `main.go`. Subsequent accesses to any file under `/home/alice/` will find partial dcache hits, reducing the number of directory reads.

### 14.9.3 Read-Ahead

When the kernel detects sequential access patterns, it performs **read-ahead**: proactively reading blocks beyond what the application has requested, in anticipation that they will be needed soon. Linux's read-ahead algorithm adapts dynamically:

- Initial read-ahead window: 128 KB (32 pages with 4 KB pages).
- The window grows up to a configurable maximum (typically 256 KB) if sequential access continues.
- Read-ahead is disabled for random access patterns.

### 14.9.4 Write Ordering and Barriers

On modern storage stacks, writes may be reordered by the kernel's I/O scheduler, the device driver, or the drive's own write cache. This reordering improves throughput but can violate the ordering assumptions of journaling file systems.

A **write barrier** (or **flush**) forces all previously submitted writes to reach persistent storage before any subsequent writes. The ext4 journal issues a barrier after writing the commit record, ensuring that the commit record is not persisted before the transaction data.

Since Linux 2.6.37, barriers are implemented via the **REQ_PREFLUSH** and **REQ_FUA** (Force Unit Access) flags:

- **REQ_PREFLUSH:** Flush the device's write cache before writing this block.
- **REQ_FUA:** Write this specific block directly to persistent media, bypassing the device's write cache.

---

## 14.10 File System Comparison

The following table summarises the key characteristics of the file systems discussed in this chapter:

| Feature | ext4 | XFS | Btrfs | ZFS | F2FS |
|---------|------|-----|-------|-----|------|
| Architecture | Journaling | Journaling | CoW B-tree | CoW Merkle | Log-structured |
| Max file size | 16 TB | 8 EB | 16 EB | 16 EB | 3.94 TB |
| Max volume size | 1 EB | 8 EB | 16 EB | 256 ZB | 16 TB |
| Checksums | Metadata only | Metadata only | CRC32C (data + metadata) | SHA-256/fletcher4 | CRC32 (metadata) |
| Snapshots | No | No | Yes (CoW) | Yes (CoW) | No |
| Compression | No | No | LZO, ZLIB, ZSTD | LZ4, ZSTD | LZO, LZ4, ZSTD |
| Best use case | General-purpose | Large files, databases | Desktop, NAS | Enterprise, NAS | Flash storage |

::: programmer
**Programmer's Perspective: Choosing a File System for Your Application.**
The choice of file system affects application behaviour in ways that developers often overlook:

- **Database workloads (PostgreSQL, MySQL):** ext4 with `data=ordered` or XFS. Both provide good `fsync()` performance. Avoid Btrfs for databases that use `O_DIRECT` (direct I/O) --- Btrfs's CoW semantics interact poorly with database-managed page caches.

- **Container storage:** Btrfs or ZFS. Both support snapshots, which container runtimes (Podman, Docker) use to implement layered images efficiently.

- **Embedded/mobile (Android, IoT):** F2FS. Its log-structured design minimises write amplification on flash storage, extending device lifespan.

- **Data integrity requirements:** ZFS. End-to-end checksumming with automatic repair on redundant pools. For Linux systems where ZFS licensing is a concern, Btrfs provides similar (though less mature) checksumming.

When writing applications that must survive crashes, remember these rules:
1. Always `fsync()` files that must persist (transaction logs, database WAL files).
2. `fsync()` the parent directory after creating a new file --- the directory entry update needs to be flushed too.
3. Use `rename()` for atomic file replacement: write to a temporary file, `fsync()` it, then `rename()` over the target. This leverages the file system's guarantee that `rename()` is atomic.

```go
package main

import (
    "os"
    "path/filepath"
)

// AtomicWriteFile writes data to filename atomically using rename.
func AtomicWriteFile(filename string, data []byte, perm os.FileMode) error {
    dir := filepath.Dir(filename)
    tmp, err := os.CreateTemp(dir, ".tmp-*")
    if err != nil {
        return err
    }
    tmpName := tmp.Name()

    // Clean up on failure
    success := false
    defer func() {
        if !success {
            tmp.Close()
            os.Remove(tmpName)
        }
    }()

    // Write data
    if _, err := tmp.Write(data); err != nil {
        return err
    }

    // Sync file content to disk
    if err := tmp.Sync(); err != nil {
        return err
    }

    // Set permissions
    if err := tmp.Chmod(perm); err != nil {
        return err
    }

    if err := tmp.Close(); err != nil {
        return err
    }

    // Atomic rename
    if err := os.Rename(tmpName, filename); err != nil {
        return err
    }

    // Sync parent directory to persist the directory entry
    d, err := os.Open(dir)
    if err != nil {
        return err
    }
    defer d.Close()
    if err := d.Sync(); err != nil {
        return err
    }

    success = true
    return nil
}
```
:::

---

## 14.11 File Locking

Concurrent access to shared files is a common source of data corruption. Two processes writing to the same file simultaneously can interleave their writes, producing a garbled result. File locking provides a mechanism for processes to coordinate access.

### 14.11.1 Advisory vs Mandatory Locking

::: definition
**Advisory Lock.** A lock that is enforced only by cooperation among processes. A process that does not attempt to acquire the lock before accessing the file can bypass the lock entirely. Advisory locking is the default on Unix systems and is used by well-behaved applications (databases, editors) that follow a locking protocol.

**Mandatory Lock.** A lock enforced by the kernel. Any process that attempts to read or write a locked region is blocked (or receives an error) regardless of whether it requested the lock. Mandatory locking was historically available on System V Unix and Linux (via the `sgid` bit with group-execute cleared), but it is deprecated in modern Linux kernels (removed in Linux 5.15) due to complexity and performance issues.
:::

### 14.11.2 POSIX File Locking

The `fcntl()` system call provides POSIX record locking, which can lock **byte ranges** within a file:

```c
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int lock_region(int fd, off_t start, off_t len, int type) {
    struct flock fl = {
        .l_type   = type,      /* F_RDLCK, F_WRLCK, F_UNLCK */
        .l_whence = SEEK_SET,
        .l_start  = start,     /* Starting offset */
        .l_len    = len,       /* Length; 0 = to end of file */
    };
    return fcntl(fd, F_SETLKW, &fl);  /* F_SETLKW: blocking */
}

int main(void) {
    int fd = open("shared.dat", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    /* Acquire an exclusive lock on bytes 0-99 */
    printf("Acquiring lock...\n");
    if (lock_region(fd, 0, 100, F_WRLCK) == -1) {
        perror("lock");
        return 1;
    }
    printf("Lock acquired. Writing data...\n");

    /* Critical section: write to the locked region */
    lseek(fd, 0, SEEK_SET);
    write(fd, "Hello, locked world!\n", 21);

    /* Release the lock */
    lock_region(fd, 0, 100, F_UNLCK);
    printf("Lock released.\n");

    close(fd);
    return 0;
}
```

Lock types follow reader-writer semantics:

- **Shared lock (`F_RDLCK`):** Multiple processes can hold shared locks on the same region simultaneously. Prevents exclusive locks from being acquired.

- **Exclusive lock (`F_WRLCK`):** Only one process can hold an exclusive lock on a region. Prevents all other locks (shared and exclusive) from being acquired.

- **Unlock (`F_UNLCK`):** Releases the lock on the specified region.

::: example
**Example 14.9 (Deadlock with File Locks).** Process A locks bytes 0--99, then requests bytes 100--199. Process B locks bytes 100--199, then requests bytes 0--99. Both processes block indefinitely --- a classic deadlock. POSIX `fcntl` locking detects this cycle and returns `EDEADLK` to one of the processes, breaking the deadlock.
:::

### 14.11.3 Open File Description Locks (OFD Locks)

Traditional POSIX locks are associated with the **process**, not the file descriptor. This causes surprising behaviour: closing **any** file descriptor to a file releases **all** locks held by the process on that file, even locks acquired through a different file descriptor. Additionally, locks are not inherited across `fork()`.

Linux provides **Open File Description (OFD) locks** (since Linux 3.15) that are associated with the open file description rather than the process. OFD locks use the same `struct flock` but with commands `F_OFD_SETLK`, `F_OFD_SETLKW`, and `F_OFD_GETLK`:

```c
struct flock fl = {
    .l_type   = F_WRLCK,
    .l_whence = SEEK_SET,
    .l_start  = 0,
    .l_len    = 0,    /* Entire file */
    .l_pid    = 0,    /* Must be 0 for OFD locks */
};
/* OFD lock: associated with this file descriptor, not the process */
fcntl(fd, F_OFD_SETLKW, &fl);
```

OFD locks are the correct choice for multi-threaded applications and for any code that manages multiple file descriptors to the same file.

---

## 14.12 The ext4 On-Disk Format

Understanding a concrete file system implementation solidifies the abstract concepts discussed earlier. ext4, the default file system on most Linux distributions, is a direct descendant of ext2 (1993) and ext3 (2001).

### 14.12.1 Block Groups

ext4 divides the disk into **block groups**, each containing a fixed number of blocks (32,768 blocks = 128 MB for 4 KB blocks). Each block group contains:

```text
Block Group Layout:
+--------+--------+---------+--------+--------+---...---+
| Super  | Group  | Block   | Inode  | Inode  | Data    |
| Block  | Desc.  | Bitmap  | Bitmap | Table  | Blocks  |
| (copy) | Table  | (1 blk) | (1 blk)| (N blk)|         |
+--------+--------+---------+--------+--------+---...---+
```

- **Superblock:** Contains global file system parameters (total blocks, total inodes, block size, magic number). Copies are stored in select block groups for redundancy.

- **Group Descriptor Table:** Contains the locations of the bitmaps and inode table for each block group.

- **Block Bitmap:** One bit per block in the group. 1 = allocated, 0 = free.

- **Inode Bitmap:** One bit per inode slot. 1 = in use, 0 = free.

- **Inode Table:** An array of inode structures. Each inode is 256 bytes in ext4.

- **Data Blocks:** The actual file and directory data.

### 14.12.2 The ext4 Inode Structure

The ext4 inode is 256 bytes and contains:

```text
ext4 Inode (256 bytes):
Offset  Size  Field
------  ----  -----
0x00    2     i_mode (file type + permissions)
0x02    2     i_uid (owner, low 16 bits)
0x04    4     i_size_lo (file size, low 32 bits)
0x08    4     i_atime (last access time)
0x0C    4     i_ctime (inode change time)
0x10    4     i_mtime (last modification time)
0x14    4     i_dtime (deletion time)
0x18    2     i_gid (group, low 16 bits)
0x1A    2     i_links_count (hard link count)
0x1C    4     i_blocks_lo (block count, low 32 bits)
0x20    4     i_flags (EXT4_EXTENTS_FL, etc.)
0x28    60    i_block (12 direct + 3 indirect, or extent tree)
0x64    4     i_generation (NFS generation number)
0x68    4     i_file_acl_lo (extended attributes block)
0x6C    4     i_size_high (file size, high 32 bits)
...
0x80    4     i_extra_isize (size of extra inode fields)
0x84    4     i_ctime_extra (nanosecond precision)
0x88    4     i_mtime_extra
0x8C    4     i_atime_extra
0x90    4     i_crtime (creation time)
0x94    4     i_crtime_extra
```

The 60-byte `i_block` field is overloaded: for files using the traditional indirect block scheme, it stores 12 direct pointers + 3 indirect pointers. For files using extents (the default in ext4), it stores an **extent header** followed by up to 4 extent entries.

### 14.12.3 Directory Entries

ext4 directories use a **hash tree** (HTree) structure for fast lookups. The HTree is a B-tree variant that hashes file names and uses the hash to direct the search to the correct directory block.

For small directories (fewer than one block), ext4 uses a simple linear list of directory entries:

```text
ext4 Directory Entry:
+----------+-----------+----------+---------+-----------+
| inode    | rec_len   | name_len | type    | name      |
| (4 bytes)| (2 bytes) | (1 byte) | (1 byte)| (variable)|
+----------+-----------+----------+---------+-----------+
```

The `rec_len` field spans from this entry to the next, allowing entries to be of variable length (padded to 4-byte boundaries). Deletion is handled by adjusting the previous entry's `rec_len` to skip the deleted entry.

::: example
**Example 14.10 (ext4 Directory Lookup Performance).** A directory contains 100,000 files. Without HTree, a linear scan requires checking up to 100,000 entries (average 50,000). With HTree (using a half-MD4 hash), the search is $O(\log n)$: the hash directs the lookup to the correct block in approximately 2--3 block reads, regardless of the directory size. This is why `ls` in a directory with 100,000 files is fast on ext4 but was painfully slow on ext2 (which lacked HTree).
:::

---

## 14.13 Special File Systems

Linux employs several **virtual file systems** that do not store data on disk but instead provide interfaces to kernel data structures or runtime information.

### 14.13.1 procfs (`/proc`)

The **proc file system** exposes process information and kernel parameters as a hierarchy of virtual files:

- `/proc/[pid]/status` --- Process state, memory usage, UID/GID
- `/proc/[pid]/maps` --- Memory mappings of the process
- `/proc/[pid]/fd/` --- Symbolic links to open file descriptors
- `/proc/meminfo` --- System-wide memory statistics
- `/proc/cpuinfo` --- CPU information
- `/proc/sys/` --- Tunable kernel parameters (writable)

These files are generated on the fly when read; no disk I/O occurs. The `proc` file system is the primary mechanism for monitoring system state from user space.

### 14.13.2 sysfs (`/sys`)

The **sysfs** file system (mounted at `/sys`) exports the kernel's device model to user space. Every device, driver, bus, and class in the kernel has a corresponding directory in sysfs:

```text
/sys/
+-- block/           (block devices)
|   +-- sda/
|       +-- queue/   (I/O scheduler parameters)
|       +-- stat     (I/O statistics)
+-- bus/             (bus types: pci, usb, i2c, ...)
+-- class/           (device classes: net, input, tty, ...)
+-- devices/         (the device tree)
+-- fs/              (file system parameters)
+-- kernel/          (kernel subsystems)
+-- module/          (loaded kernel modules)
```

### 14.13.3 tmpfs

**tmpfs** is a RAM-based file system that uses the kernel's page cache and swap space. Files in tmpfs exist only in memory (and potentially swap); they are lost on reboot.

```text
# Mount a 1 GB tmpfs
mount -t tmpfs -o size=1G tmpfs /mnt/ramdisk
```

tmpfs is used for `/tmp` (temporary files), `/run` (runtime data), and `/dev/shm` (POSIX shared memory). Because it operates entirely in RAM, tmpfs provides extremely low latency --- there is no disk I/O for reads or writes (unless the system swaps).

::: definition
**tmpfs.** A memory-backed file system that stores data in the kernel's page cache. Unlike a ramdisk (`/dev/ram0`), tmpfs dynamically grows and shrinks as files are created and deleted, using only as much memory as its contents require. It also supports swapping: if memory pressure is high, tmpfs pages can be evicted to swap space and brought back on demand.
:::

### 14.13.4 devtmpfs (`/dev`)

**devtmpfs** is a special tmpfs used for the device node directory `/dev`. The kernel automatically creates device nodes in devtmpfs when devices are detected, and `udev` (the user-space device manager) applies rules to set ownership, permissions, and create symlinks.

---

## 14.14 File System Performance Tuning

### 14.14.1 Block Size Selection

The block size affects both performance and space efficiency:

| Block Size | Internal Fragmentation | Metadata Overhead | Sequential Throughput |
|-----------|----------------------|-------------------|---------------------|
| 1 KB | Low (avg. 512 B wasted per file) | High (many block pointers) | Low (many small I/Os) |
| 4 KB | Moderate (avg. 2 KB wasted per file) | Moderate | Good |
| 64 KB | High (avg. 32 KB wasted per file) | Low | Excellent |

::: definition
**Internal Fragmentation.** The wasted space within the last block of a file. For a file of size $S$ bytes and block size $B$ bytes, the wasted space is $B - (S \bmod B)$ if $S \bmod B \neq 0$, or $0$ if $S$ is a multiple of $B$. On average, each file wastes $B/2$ bytes.
:::

::: example
**Example 14.11 (Block Size Trade-Off).** A file system stores 1 million files with an average size of 8 KB.

With 4 KB blocks:
- Average internal fragmentation per file: 2 KB
- Total wasted space: $10^6 \times 2\,\text{KB} = 2\,\text{GB}$
- Blocks per average file: 2
- Block pointers needed: 2 per file (direct pointers)

With 64 KB blocks:
- Average internal fragmentation per file: 32 KB
- Total wasted space: $10^6 \times 32\,\text{KB} = 32\,\text{GB}$
- Blocks per average file: 1
- But 56 KB wasted in that single block!

The 4 KB block size wastes 2 GB; the 64 KB block size wastes 32 GB --- a 16x difference. For many small files, smaller blocks are strongly preferred.
:::

### 14.14.2 Inode Density

The number of inodes on an ext4 file system is fixed at creation time. The `bytes-per-inode` ratio (default: 16 KB per inode) determines how many inodes are created. If the file system will store many small files, a lower ratio (e.g., 4 KB per inode) is needed to avoid running out of inodes while free space remains.

```text
# Create ext4 with more inodes (for many small files)
mkfs.ext4 -i 4096 /dev/sda1

# Check inode usage
df -i /
# Filesystem     Inodes   IUsed   IFree  IUse%  Mounted on
# /dev/sda1     65536000  142000 65394000   1%   /
```

### 14.14.3 Mount Options for Performance

Key ext4 mount options that affect performance:

- `noatime` --- Do not update the access time on reads. This eliminates a write (to update the inode) for every read operation. Recommended for almost all workloads.

- `lazytime` --- Buffer inode timestamp updates in memory and write them only when the inode is updated for other reasons. Provides the benefits of `noatime` while still recording access times for applications that need them.

- `barrier=0` --- Disable write barriers. Improves write throughput but risks data loss on power failure if the drive has a volatile write cache. Only safe if the drive has a battery-backed cache or if data loss is acceptable.

- `commit=N` --- Set the journal commit interval to $N$ seconds (default 5). Higher values reduce journal traffic but increase the window of data at risk.

---

## Exercises

**Exercise 14.1.** An ext4 file system uses 4 KB blocks and 4-byte block pointers. Each inode has 12 direct pointers, 1 single-indirect pointer, 1 double-indirect pointer, and 1 triple-indirect pointer. (a) Calculate the maximum file size. (b) How many disk block reads are needed to access the very last byte of a maximum-size file? (c) If the pointer size is increased to 8 bytes (to support larger disks), how does the maximum file size change?

**Exercise 14.2.** A file system uses a bitmap for free-space management on a 2 TB disk with 4 KB blocks. (a) How many bits does the bitmap contain? (b) How much space does the bitmap occupy? (c) If the system can scan the bitmap at memory speed (10 GB/s), how long does it take to find a free block in the worst case? (d) Describe how you would optimise the search using a **summary bitmap** (one bit per group of 64 blocks, indicating whether the group has any free blocks).

**Exercise 14.3.** Compare the three ext4 journaling modes (journal, ordered, writeback) for the following scenario: a process appends 100 MB to an existing file, then calls `fsync()`. For each mode, describe (a) the total number of bytes written to the storage device, (b) the ordering constraints on those writes, and (c) the state of the file after a crash that occurs immediately after the `fsync()` returns. Assume a 4 KB block size and a 128 MB journal.

**Exercise 14.4.** A log-structured file system has segments of size 1 MB. The file system is 70\% full. The segment cleaner uses the cost-benefit policy: $\text{score}(s) = \frac{(1 - u(s)) \times \text{age}(s)}{1 + u(s)}$ where $u(s)$ is the fraction of live blocks in segment $s$ and $\text{age}(s)$ is the time since the segment was last written. Two candidate segments have: (a) $u = 0.3$, age $= 100$ seconds; (b) $u = 0.8$, age $= 10{,}000$ seconds. Compute the score for each and determine which segment should be cleaned first. Explain intuitively why the policy might prefer a mostly-live segment if it is very old.

**Exercise 14.5.** ZFS uses a Merkle tree for data integrity. A ZFS pool has 5 levels of indirect blocks and uses SHA-256 (32-byte digests). (a) If a single bit flips in a data block, at which point during a read operation is the corruption detected? (b) How many hash comparisons are needed to verify a single data block read? (c) ZFS stores the checksum of each block in its parent. Explain why this is more robust than storing each block's checksum alongside the block itself (as a traditional CRC would).

**Exercise 14.6.** Consider a file system that uses extent-based allocation. A file is written in three phases: first, 64 KB is written sequentially; then the application seeks to offset 1 MB and writes 32 KB; finally, it returns to offset 64 KB and writes 16 KB. Assuming the file system can allocate contiguous space for each write, draw the extent tree for this file. How many extents are needed? Compare the metadata overhead to a traditional block-pointer inode (4 KB blocks, 4-byte pointers).

**Exercise 14.7.** Btrfs supports snapshots via CoW. Explain with a concrete example how a snapshot is created, how subsequent writes to the original file system cause the snapshot and the original to diverge, and how blocks are freed when a snapshot is deleted. Specifically: (a) draw the block tree before the snapshot, (b) draw it after the snapshot, (c) draw it after modifying a file in the original, and (d) describe the reference counting mechanism that determines when a shared block can be freed.
