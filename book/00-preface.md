# Preface

An operating system is the most intimate piece of software your programs will ever encounter. Every process you launch, every byte you allocate, every file you open, every network packet you send --- all of it passes through the operating system. Yet most programmers treat it as a black box, invoking system calls without understanding the machinery behind them. This book opens the box.

*Operating Systems Theory* is the twenty-first volume in the Dr.H series. It sits at the intersection of hardware and software, drawing on the foundations established in *Computer Architecture* (Book 19) and *Algorithms and Data Structures* (Book 11). Where those books gave you the machine and the abstractions, this book gives you the layer that connects them: the operating system.

## What This Book Covers

The book is organised into six parts spanning twenty chapters:

- **Part I: Foundations** (Chapters 1--3) establishes what an operating system is, surveys the major architectural patterns (monolithic, microkernel, hybrid, exokernel, unikernel), and examines the hardware--software interface that makes kernel-mode operation possible.

- **Part II: Processes and Scheduling** (Chapters 4--6) covers the process and thread abstractions, CPU scheduling theory (with proofs of optimality for key algorithms), and inter-process communication mechanisms from pipes to RPC.

- **Part III: Concurrency** (Chapters 7--9) tackles the hardest problems in systems programming: synchronisation primitives, deadlock theory (including the Banker's Algorithm), and modern lock-free and wait-free data structures.

- **Part IV: Memory** (Chapters 10--13) progresses from basic memory management through virtual memory and page replacement to advanced topics including NUMA, huge pages, slab allocators, and the Go runtime's memory allocator.

- **Part V: Storage and I/O** (Chapters 14--16) covers file system design (from ext4 to ZFS), I/O subsystem architecture (including io_uring), and storage reliability (RAID, checksums, wear levelling).

- **Part VI: Protection and Modern Topics** (Chapters 17--20) addresses OS security (access control, Spectre/Meltdown, sandboxing), virtualisation (hypervisors, containers, Podman), distributed OS concepts (consensus, CAP theorem), and the future of operating systems (eBPF, unikernels, capability hardware, Rust in the kernel).

## The Programmer's Perspective

Throughout the book, you will find **Programmer's Perspective** callout boxes. These bridge the gap between theory and practice, showing how the concepts materialise in real systems --- primarily Linux, Go, and C. When we discuss virtual memory, you will see how Go's runtime manages its heap. When we cover scheduling, you will trace through the GMP model that powers goroutines. When we examine containers, you will see the Linux namespace and cgroup primitives that make them work.

The goal is not to teach you to use an OS, but to understand one deeply enough that you could build one.

## Callout Boxes Used in This Book

::: definition
**Definitions** introduce formal terminology and precise statements that you should internalise.
:::

::: theorem
**Theorems** state and prove important results. Proofs are included where they illuminate the underlying ideas.
:::

::: example
**Examples** work through concrete scenarios, calculations, or code to ground the theory in practice.
:::

::: programmer
**Programmer's Perspective** boxes connect OS theory to real-world systems programming in Go, C, and Linux.
:::

::: exercises
**Exercises** appear at the end of every chapter --- seven per chapter, progressing from comprehension to analysis to design.
:::

## Prerequisites

This book assumes familiarity with:

- **C programming** --- you should be comfortable reading and writing C, including pointers, structs, and basic systems programming.
- **Computer Architecture** (Book 19) --- CPU pipelines, caches, virtual addressing, privilege levels.
- **Algorithms** (Book 11) --- asymptotic analysis, trees, graphs, hash tables.
- **Discrete Mathematics** (Book 7) --- sets, relations, proof techniques.

No prior operating systems coursework is required. We build from first principles.

## Acknowledgements

This book was written as part of the Dr.H project --- a self-directed journey through theoretical computer science. The debt to Silberschatz, Galvin, and Gagne (*Operating System Concepts*), Tanenbaum and Bos (*Modern Operating Systems*), and Love (*Linux Kernel Development*) is evident throughout. Any errors that remain are mine alone.

\begin{flushright}
Achraf SOLTANI\\
April 2026
\end{flushright}
