# Chapter 6: Inter-Process Communication

Processes, by design, are isolated from one another. Each lives in its own address space, unable to read or modify another process's memory. This isolation is a cornerstone of system security and stability --- a buggy process cannot corrupt another's data. But isolation creates a problem: processes that must cooperate need a way to exchange data and coordinate their actions. The mechanisms that enable this cooperation are collectively called **Inter-Process Communication** (IPC).

This chapter surveys the IPC landscape from low-level shared memory and pipes to high-level frameworks like gRPC and D-Bus. We examine the trade-offs between each mechanism --- latency, throughput, ease of programming, and safety --- and connect the theory to real system implementations on Linux.

## 6.1 Taxonomy of IPC Mechanisms

IPC mechanisms fall into two broad categories:

::: definition
**Definition 6.1 (Shared Memory IPC).** In shared memory IPC, two or more processes map the same region of physical memory into their respective virtual address spaces. Communication occurs by reading and writing to this shared region. The operating system is involved only in establishing the mapping; subsequent data transfer occurs without kernel intervention, making shared memory the fastest IPC mechanism.
:::

::: definition
**Definition 6.2 (Message Passing IPC).** In message passing IPC, processes exchange data by sending and receiving messages through a kernel-mediated channel (pipe, socket, message queue). The kernel copies data from the sender's address space to the receiver's (or to an intermediate buffer). Message passing is safer (no shared state to corrupt) but slower (each transfer requires at least one system call and one data copy).
:::

The following table summarises the primary IPC mechanisms on Unix-like systems:

| Mechanism | Type | Scope | Persistence | Typical Latency |
|---|---|---|---|---|
| Shared memory | Shared | Same machine | Kernel-managed | ~10-100 ns |
| Anonymous pipe | Message | Parent-child | Process lifetime | ~1-5 us |
| Named pipe (FIFO) | Message | Same machine | Filesystem | ~1-5 us |
| Unix domain socket | Message | Same machine | Filesystem | ~1-3 us |
| TCP/UDP socket | Message | Network-wide | Connection lifetime | ~10-100 us (local) |
| Signal | Notification | Same machine | Instantaneous | ~1-10 us |
| Message queue | Message | Same machine | Kernel-managed | ~2-5 us |
| Memory-mapped file | Shared | Same machine | Filesystem | ~10-100 ns |

## 6.2 Shared Memory

Shared memory is the highest-performance IPC mechanism because, after the initial setup, data transfer between processes involves no system calls and no kernel mediation. Processes simply read and write to ordinary memory addresses.

### 6.2.1 POSIX Shared Memory

The POSIX shared memory API provides a portable interface for creating and mapping shared memory regions:

```c
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SHM_NAME "/my_shared_mem"
#define SHM_SIZE 4096

/* Producer process */
int main(void) {
    /* Create shared memory object */
    int fd = shm_open(SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (fd == -1) {
        perror("shm_open");
        return 1;
    }
    
    /* Set size */
    if (ftruncate(fd, SHM_SIZE) == -1) {
        perror("ftruncate");
        return 1;
    }
    
    /* Map into address space */
    void *ptr = mmap(NULL, SHM_SIZE, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    
    /* Write data */
    const char *message = "Hello from the producer process!";
    memcpy(ptr, message, strlen(message) + 1);
    printf("Producer wrote: %s\n", message);
    
    /* Cleanup */
    munmap(ptr, SHM_SIZE);
    close(fd);
    
    /* Consumer will read; producer keeps the object alive */
    printf("Waiting for consumer... (press Enter)\n");
    getchar();
    
    /* Remove shared memory object */
    shm_unlink(SHM_NAME);
    
    return 0;
}
```

The consumer process:

```c
#include <fcntl.h>
#include <sys/mman.h>
#include <stdio.h>
#include <unistd.h>

#define SHM_NAME "/my_shared_mem"
#define SHM_SIZE 4096

/* Consumer process */
int main(void) {
    /* Open existing shared memory object */
    int fd = shm_open(SHM_NAME, O_RDONLY, 0);
    if (fd == -1) {
        perror("shm_open");
        return 1;
    }
    
    /* Map read-only */
    void *ptr = mmap(NULL, SHM_SIZE, PROT_READ,
                     MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    
    /* Read data */
    printf("Consumer read: %s\n", (char *)ptr);
    
    munmap(ptr, SHM_SIZE);
    close(fd);
    
    return 0;
}
```

Compile both with: `gcc -o producer producer.c -lrt` and `gcc -o consumer consumer.c -lrt`

### 6.2.2 mmap: Memory-Mapped Files

The `mmap()` system call maps a file (or anonymous memory) into a process's address space. When used with `MAP_SHARED`, modifications are visible to all processes mapping the same file, providing a form of shared memory backed by the filesystem.

::: definition
**Definition 6.3 (Memory-Mapped I/O).** Memory-mapped I/O via `mmap()` establishes a correspondence between a region of a process's virtual address space and a file (or device). Reads and writes to the mapped region translate to reads and writes of the file. The kernel's page cache handles the actual I/O, providing transparent caching and write-back.
:::

```c
#include <fcntl.h>
#include <sys/mman.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    int fd = open("/tmp/shared_data.bin", O_CREAT | O_RDWR, 0666);
    ftruncate(fd, 4096);
    
    /* MAP_SHARED: changes visible to other processes and written to file */
    int *data = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, 0);
    close(fd);
    
    /* Write structured data */
    data[0] = 42;      /* Sequence number */
    data[1] = 12345;   /* Payload */
    
    /* Force write to backing file (optional; happens lazily otherwise) */
    msync(data, 4096, MS_SYNC);
    
    printf("Wrote: seq=%d, payload=%d\n", data[0], data[1]);
    
    munmap(data, 4096);
    return 0;
}
```

### 6.2.3 Race Conditions in Shared Memory

The fundamental problem with shared memory is that concurrent access requires explicit synchronisation. Without it, processes can observe inconsistent data.

::: definition
**Definition 6.4 (Race Condition).** A race condition occurs when the behaviour of a program depends on the relative timing of events (e.g., the order in which two processes access shared memory). Race conditions lead to non-deterministic bugs that are difficult to reproduce and diagnose.
:::

::: example
**Example 6.1 (Shared Memory Race Condition).** Two processes share a counter in shared memory. Each process increments the counter 1,000,000 times. The increment operation `counter++` compiles to three machine instructions:

1. Load `counter` from memory into a register
2. Add 1 to the register
3. Store the register back to `counter`

If both processes execute these instructions concurrently, the following interleaving can occur:

```text
Process A                  Process B
─────────────────────────────────────────
LOAD counter (= 100)
                           LOAD counter (= 100)
ADD 1 (register = 101)
                           ADD 1 (register = 101)
STORE counter (= 101)
                           STORE counter (= 101)
```

Both processes read 100, increment to 101, and store 101. One increment is lost. After 2,000,000 increments, the counter may hold any value between 1,000,000 and 2,000,000, depending on how many increments are lost to races.
:::

Shared memory IPC must be paired with synchronisation primitives (mutexes, semaphores, atomic operations) to prevent race conditions. These are covered in detail in subsequent chapters on synchronisation.

## 6.3 Pipes

Pipes are the simplest and oldest Unix IPC mechanism. A pipe provides a unidirectional byte stream between two processes.

### 6.3.1 Anonymous Pipes

::: definition
**Definition 6.5 (Anonymous Pipe).** An anonymous pipe is a kernel buffer (typically 64 KB on Linux) that connects the standard output of one process to the standard input of another. It is created by the `pipe()` system call, which returns two file descriptors: one for the read end and one for the write end. Anonymous pipes can only be shared between related processes (parent-child or siblings), because the file descriptors are inherited through `fork()`.
:::

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

int main(void) {
    int pipefd[2];
    
    if (pipe(pipefd) == -1) {
        perror("pipe");
        return 1;
    }
    
    pid_t pid = fork();
    
    if (pid == 0) {
        /* Child: reads from pipe */
        close(pipefd[1]);  /* Close write end */
        
        char buffer[256];
        ssize_t n = read(pipefd[0], buffer, sizeof(buffer) - 1);
        if (n > 0) {
            buffer[n] = '\0';
            printf("Child received: %s\n", buffer);
        }
        
        close(pipefd[0]);
        _exit(0);
    } else {
        /* Parent: writes to pipe */
        close(pipefd[0]);  /* Close read end */
        
        const char *msg = "Hello from parent!";
        write(pipefd[1], msg, strlen(msg));
        
        close(pipefd[1]);  /* Signal EOF to child */
        wait(NULL);
    }
    
    return 0;
}
```

The shell pipe operator `|` creates anonymous pipes between commands:

```text
$ cat /var/log/syslog | grep error | wc -l
```

This creates two pipes: one connecting `cat`'s stdout to `grep`'s stdin, and another connecting `grep`'s stdout to `wc`'s stdin.

### 6.3.2 Pipe Semantics

Pipe operations have well-defined semantics that depend on the state of both ends:

| Operation | Both ends open | Write end closed | Read end closed |
|---|---|---|---|
| `read()` | Blocks if empty; returns data if available | Returns 0 (EOF) when buffer drained | N/A |
| `write()` | Blocks if full; writes data if space | N/A | `SIGPIPE` signal; `write()` returns $-1$ with `errno = EPIPE` |

::: theorem
**Theorem 6.1 (Pipe Atomicity).** On POSIX-compliant systems, writes to a pipe of `PIPE_BUF` bytes or fewer are guaranteed to be atomic: if two processes write to the same pipe simultaneously, and both writes are $\le$ `PIPE_BUF` bytes, the data from the two writes will not be interleaved. On Linux, `PIPE_BUF = 4096` bytes. Writes larger than `PIPE_BUF` are not atomic and may be interleaved with writes from other processes.
:::

### 6.3.3 Pipe Buffer Sizes

The kernel pipe buffer size has evolved over Linux kernel versions:

- **Linux 2.6.11 and earlier**: Single page (4 KB) buffer
- **Linux 2.6.11 to 2.6.35**: 64 KB buffer (16 pages in a circular buffer)
- **Linux 2.6.35+**: Configurable per-pipe via `fcntl(fd, F_SETPIPE_SZ, size)`, up to `/proc/sys/fs/pipe-max-size` (default 1 MB)

```c
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    int pipefd[2];
    pipe(pipefd);
    
    /* Query current pipe buffer size */
    int size = fcntl(pipefd[0], F_GETPIPE_SZ);
    printf("Default pipe buffer: %d bytes\n", size);
    
    /* Increase to 1 MB */
    int new_size = fcntl(pipefd[0], F_SETPIPE_SZ, 1024 * 1024);
    printf("New pipe buffer: %d bytes\n", new_size);
    
    close(pipefd[0]);
    close(pipefd[1]);
    return 0;
}
```

### 6.3.4 Named Pipes (FIFOs)

::: definition
**Definition 6.6 (Named Pipe / FIFO).** A named pipe (FIFO) is a pipe with a name in the filesystem. Unlike anonymous pipes, named pipes can be used between unrelated processes. A FIFO is created with `mkfifo()` and appears as a special file in the filesystem. Opening a FIFO for reading blocks until another process opens it for writing, and vice versa (unless `O_NONBLOCK` is used).
:::

```c
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Writer process */
int main(void) {
    const char *fifo_path = "/tmp/my_fifo";
    
    /* Create FIFO (if it doesn't exist) */
    mkfifo(fifo_path, 0666);
    
    /* Open for writing (blocks until a reader opens the other end) */
    printf("Waiting for reader...\n");
    int fd = open(fifo_path, O_WRONLY);
    
    const char *msg = "Hello via named pipe!";
    write(fd, msg, strlen(msg));
    printf("Wrote: %s\n", msg);
    
    close(fd);
    return 0;
}
```

Named pipes have the same semantics as anonymous pipes (unidirectional, byte stream, `PIPE_BUF` atomicity) but with filesystem persistence: the FIFO special file persists until explicitly removed with `unlink()`.

## 6.4 Signals

Signals are the oldest form of IPC in Unix. A signal is a software interrupt delivered to a process, notifying it of an asynchronous event.

::: definition
**Definition 6.7 (Signal).** A signal is an asynchronous notification sent to a process (or a specific thread within a process) to indicate that an event has occurred. Each signal has a number (1--64 on Linux), a name (e.g., `SIGTERM`, `SIGSEGV`), and a default disposition (terminate, ignore, stop, or core dump). A process can change the disposition of most signals by installing a signal handler.
:::

### 6.4.1 Signal Categories

The standard POSIX signals include:

| Signal | Number | Default Action | Cause |
|---|---|---|---|
| `SIGHUP` | 1 | Terminate | Terminal hangup |
| `SIGINT` | 2 | Terminate | Ctrl+C |
| `SIGQUIT` | 3 | Core dump | Ctrl+\\ |
| `SIGILL` | 4 | Core dump | Illegal instruction |
| `SIGABRT` | 6 | Core dump | `abort()` call |
| `SIGFPE` | 8 | Core dump | Arithmetic error (e.g., division by zero) |
| `SIGKILL` | 9 | Terminate | Uncatchable kill |
| `SIGSEGV` | 11 | Core dump | Segmentation fault |
| `SIGPIPE` | 13 | Terminate | Write to pipe with no reader |
| `SIGALRM` | 14 | Terminate | Timer expired |
| `SIGTERM` | 15 | Terminate | Polite termination request |
| `SIGCHLD` | 17 | Ignore | Child process terminated |
| `SIGSTOP` | 19 | Stop | Uncatchable stop |
| `SIGTSTP` | 20 | Stop | Ctrl+Z |
| `SIGURG` | 23 | Ignore | Used by Go runtime for goroutine preemption |

`SIGKILL` and `SIGSTOP` cannot be caught, blocked, or ignored. All other signals can have custom handlers installed.

### 6.4.2 Signal Handling

```c
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

volatile sig_atomic_t got_signal = 0;

void handler(int signum) {
    /* Only async-signal-safe functions here */
    got_signal = signum;
}

int main(void) {
    struct sigaction sa;
    sa.sa_handler = handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;  /* Restart interrupted system calls */
    
    /* Install handler for SIGINT (Ctrl+C) */
    if (sigaction(SIGINT, &sa, NULL) == -1) {
        perror("sigaction");
        return 1;
    }
    
    /* Install handler for SIGTERM */
    if (sigaction(SIGTERM, &sa, NULL) == -1) {
        perror("sigaction");
        return 1;
    }
    
    printf("PID %d waiting for signals (Ctrl+C or kill %d)...\n",
           getpid(), getpid());
    
    while (!got_signal) {
        pause();  /* Sleep until a signal is delivered */
    }
    
    printf("\nReceived signal %d, shutting down gracefully.\n", got_signal);
    
    return 0;
}
```

> **Programmer:** **Programmer's Perspective: Signal Safety and Go.** Signal handling in C is notoriously tricky. Inside a signal handler, only **async-signal-safe** functions may be called (about 100 functions listed in POSIX, including `write()`, `_exit()`, and `signal()` itself, but NOT `printf()`, `malloc()`, or `pthread_mutex_lock()`). The reason is that a signal can interrupt a non-reentrant function mid-execution; calling the same function from the handler would corrupt its internal state. The canonical pattern is to set a `volatile sig_atomic_t` flag in the handler and check it in the main loop.

> Go abstracts signals through the `os/signal` package, which delivers signals to channels:
>
> ```go
> package main
>
> import (
>     "fmt"
>     "os"
>     "os/signal"
>     "syscall"
> )
>
> func main() {
>     sigChan := make(chan os.Signal, 1)
>     signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
>
>     fmt.Println("Waiting for signal...")
>     sig := <-sigChan
>     fmt.Printf("Received %v, shutting down.\n", sig)
> }
> ```
>
> The Go runtime intercepts signals at the OS level and translates them into channel sends, which are safe to handle with arbitrary Go code (no async-signal-safety restrictions). The runtime reserves certain signals for internal use: `SIGURG` for goroutine preemption (since Go 1.14), `SIGPROF` for CPU profiling, and several others. User code should not catch these.

### 6.4.3 Signal Masks

Each thread has a **signal mask**: a bitmask specifying which signals are currently blocked (deferred). A blocked signal is held pending until it is unblocked.

```c
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    sigset_t mask, oldmask, pending;
    
    /* Block SIGINT */
    sigemptyset(&mask);
    sigaddset(&mask, SIGINT);
    sigprocmask(SIG_BLOCK, &mask, &oldmask);
    
    printf("SIGINT blocked. Press Ctrl+C (it will be held pending)...\n");
    sleep(5);
    
    /* Check for pending signals */
    sigpending(&pending);
    if (sigismember(&pending, SIGINT)) {
        printf("SIGINT is pending!\n");
    }
    
    /* Unblock SIGINT --- pending signal will be delivered immediately */
    printf("Unblocking SIGINT...\n");
    sigprocmask(SIG_SETMASK, &oldmask, NULL);
    
    /* If SIGINT was pending, default handler runs here (terminate) */
    printf("This line may not be reached if Ctrl+C was pressed.\n");
    
    return 0;
}
```

### 6.4.4 Real-Time Signals

Standard signals (1--31) have a significant limitation: they are not queued. If the same signal is sent multiple times while blocked, only one instance is delivered when the signal is unblocked. Real-time signals (32--64, accessed via `SIGRTMIN` to `SIGRTMAX`) address this:

::: definition
**Definition 6.8 (Real-Time Signals).** Real-time signals (numbers 32--64 on Linux) provide guaranteed delivery semantics:

1. **Queuing**: Multiple instances of the same real-time signal are queued and delivered individually
2. **Ordering**: Real-time signals are delivered in signal-number order (lower numbers first); multiple instances of the same signal are delivered in the order sent
3. **Data payload**: Real-time signals can carry an integer or pointer value via `sigqueue()`, enabling simple data transfer alongside the notification
:::

```c
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

void rt_handler(int sig, siginfo_t *info, void *ucontext) {
    printf("Received RT signal %d with value %d from PID %d\n",
           sig, info->si_value.sival_int, info->si_pid);
}

int main(void) {
    struct sigaction sa;
    sa.sa_sigaction = rt_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO;  /* Use sa_sigaction instead of sa_handler */
    
    sigaction(SIGRTMIN, &sa, NULL);
    
    /* Send a real-time signal to ourselves with a data payload */
    union sigval value;
    value.sival_int = 12345;
    sigqueue(getpid(), SIGRTMIN, value);
    
    /* Allow signal delivery */
    sleep(1);
    
    return 0;
}
```

## 6.5 Message Passing

Message passing provides structured communication between processes through explicit send and receive operations. Unlike shared memory, message passing does not require processes to share any memory; all data transfer is mediated by the kernel.

### 6.5.1 Synchronous vs Asynchronous Message Passing

::: definition
**Definition 6.9 (Synchronous Message Passing).** In synchronous (blocking) message passing:

- **Blocking send**: The sender blocks until the receiver has received the message
- **Blocking receive**: The receiver blocks until a message is available

Synchronous message passing provides a natural rendezvous point: when `send()` returns, the sender knows the message has been received. This simplifies reasoning about program correctness but can reduce concurrency (the sender is idle while waiting).
:::

::: definition
**Definition 6.10 (Asynchronous Message Passing).** In asynchronous (non-blocking) message passing:

- **Non-blocking send**: The sender places the message in a buffer and returns immediately, without waiting for the receiver
- **Non-blocking receive**: The receiver returns immediately with a message (if available) or an indication that no message is pending

Asynchronous message passing requires a buffer (mailbox) to hold messages between send and receive. It maximises concurrency but introduces complexity: the sender does not know when (or if) the message is received, and buffer overflow must be handled.
:::

### 6.5.2 POSIX Message Queues

POSIX message queues provide a kernel-managed message passing interface with priority support:

```c
#include <fcntl.h>
#include <mqueue.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define QUEUE_NAME  "/my_queue"
#define MAX_MSG_SIZE 256
#define MAX_MSGS     10

/* Sender */
int main(void) {
    struct mq_attr attr;
    attr.mq_flags = 0;
    attr.mq_maxmsg = MAX_MSGS;
    attr.mq_msgsize = MAX_MSG_SIZE;
    attr.mq_curmsgs = 0;
    
    mqd_t mq = mq_open(QUEUE_NAME, O_CREAT | O_WRONLY, 0666, &attr);
    if (mq == (mqd_t)-1) {
        perror("mq_open");
        return 1;
    }
    
    const char *messages[] = {
        "First message (priority 1)",
        "Second message (priority 5)",
        "Third message (priority 3)"
    };
    unsigned int priorities[] = {1, 5, 3};
    
    for (int i = 0; i < 3; i++) {
        if (mq_send(mq, messages[i], strlen(messages[i]) + 1,
                    priorities[i]) == -1) {
            perror("mq_send");
        } else {
            printf("Sent: %s (priority %u)\n", messages[i], priorities[i]);
        }
    }
    
    mq_close(mq);
    return 0;
}
```

The receiver retrieves messages in priority order (highest priority first):

```c
#include <fcntl.h>
#include <mqueue.h>
#include <stdio.h>
#include <stdlib.h>

#define QUEUE_NAME   "/my_queue"
#define MAX_MSG_SIZE 256

/* Receiver */
int main(void) {
    mqd_t mq = mq_open(QUEUE_NAME, O_RDONLY);
    if (mq == (mqd_t)-1) {
        perror("mq_open");
        return 1;
    }
    
    char buffer[MAX_MSG_SIZE + 1];
    unsigned int priority;
    
    for (int i = 0; i < 3; i++) {
        ssize_t n = mq_receive(mq, buffer, MAX_MSG_SIZE + 1, &priority);
        if (n >= 0) {
            buffer[n] = '\0';
            printf("Received (priority %u): %s\n", priority, buffer);
        }
    }
    
    mq_close(mq);
    mq_unlink(QUEUE_NAME);
    return 0;
}
```

Compile with: `gcc -o sender sender.c -lrt` and `gcc -o receiver receiver.c -lrt`

Output (note priority ordering):

```text
Received (priority 5): Second message (priority 5)
Received (priority 3): Third message (priority 3)
Received (priority 1): First message (priority 1)
```

### 6.5.3 Mailboxes and Ports

::: definition
**Definition 6.11 (Mailbox).** A mailbox (also called a port) is a kernel object that holds a queue of messages. Processes send messages to a mailbox and receive messages from a mailbox. Multiple processes can send to the same mailbox, and (depending on the implementation) multiple processes can receive from it. A mailbox decouples senders from receivers: neither needs to know the identity of the other.
:::

Mailbox semantics vary by operating system:

- **Mach** (macOS/iOS kernel): Ports are the fundamental IPC mechanism. Each task has a set of port rights (send rights, receive rights). Messages are sent to ports, and the kernel queues them until the receiver collects them. Mach messages can carry structured data, memory regions (via out-of-line memory), and port rights.

- **POSIX message queues**: Named kernel objects (as shown above) that act as mailboxes with priority ordering.

- **SysV message queues**: Older IPC mechanism using `msgget()`, `msgsnd()`, `msgrcv()`. Messages have a type field that allows selective reception (receive only messages of a specific type).

## 6.6 Unix Domain Sockets

Unix domain sockets provide bidirectional communication between processes on the same machine, using the familiar socket API. They are faster than TCP sockets for local communication because they bypass the network stack entirely.

::: definition
**Definition 6.12 (Unix Domain Socket).** A Unix domain socket is a socket that uses a filesystem path (or an abstract name in the Linux-specific abstract namespace) instead of an IP address and port. Communication occurs entirely within the kernel, without network protocol processing (no TCP/IP headers, no checksums, no routing). Unix domain sockets support both stream (SOCK_STREAM) and datagram (SOCK_DGRAM) communication.
:::

### 6.6.1 Stream Example

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define SOCKET_PATH "/tmp/my_socket"

/* Server */
int main(void) {
    int server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd == -1) {
        perror("socket");
        return 1;
    }
    
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);
    
    unlink(SOCKET_PATH);  /* Remove stale socket file */
    
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) == -1) {
        perror("bind");
        return 1;
    }
    
    if (listen(server_fd, 5) == -1) {
        perror("listen");
        return 1;
    }
    
    printf("Server listening on %s\n", SOCKET_PATH);
    
    int client_fd = accept(server_fd, NULL, NULL);
    if (client_fd == -1) {
        perror("accept");
        return 1;
    }
    
    char buffer[256];
    ssize_t n = read(client_fd, buffer, sizeof(buffer) - 1);
    if (n > 0) {
        buffer[n] = '\0';
        printf("Server received: %s\n", buffer);
        
        const char *reply = "Message received!";
        write(client_fd, reply, strlen(reply));
    }
    
    close(client_fd);
    close(server_fd);
    unlink(SOCKET_PATH);
    
    return 0;
}
```

### 6.6.2 Unix Domain Sockets vs TCP for Local IPC

::: example
**Example 6.2 (Performance Comparison: Unix Socket vs TCP Loopback).** On a typical Linux system, benchmarking request-response latency for small messages (64 bytes):

| Transport | Latency (median) | Throughput (messages/sec) |
|---|---|---|
| Unix domain socket (SOCK_STREAM) | ~5 us | ~200,000 |
| TCP loopback (127.0.0.1) | ~12 us | ~85,000 |
| Unix domain socket (SOCK_DGRAM) | ~4 us | ~250,000 |
| Shared memory + futex | ~0.5 us | ~2,000,000 |

Unix domain sockets are roughly 2--3x faster than TCP loopback because they avoid the TCP/IP protocol stack (no TCP segmentation, acknowledgment, congestion control, checksum computation). Shared memory with futex synchronisation is another order of magnitude faster but requires careful synchronisation.
:::

Unix domain sockets have a unique capability: they can transfer **file descriptors** between processes via `SCM_RIGHTS` ancillary messages. This is used by process managers (like systemd) to pass listening sockets to child processes, and by container runtimes to pass device file descriptors.

### 6.6.3 Passing File Descriptors

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* Send a file descriptor over a Unix domain socket */
int send_fd(int socket, int fd_to_send) {
    struct msghdr msg = {0};
    struct iovec iov;
    char buf[1] = {'F'};  /* Must send at least one byte of data */
    
    iov.iov_base = buf;
    iov.iov_len = 1;
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    
    /* Ancillary data carrying the file descriptor */
    char cmsg_buf[CMSG_SPACE(sizeof(int))];
    msg.msg_control = cmsg_buf;
    msg.msg_controllen = sizeof(cmsg_buf);
    
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd_to_send, sizeof(int));
    
    return sendmsg(socket, &msg, 0);
}
```

::: theorem
**Theorem 6.2 (File Descriptor Transfer Semantics).** When a file descriptor $f$ is transferred from process $A$ to process $B$ via `SCM_RIGHTS` over a Unix domain socket, process $B$ receives a new file descriptor number $f'$ (chosen by the kernel) that refers to the same underlying kernel file description (struct file) as $f$ in process $A$. The two file descriptors share the file offset, status flags, and access mode. Process $A$ and $B$ can independently close their respective file descriptors; the underlying file is closed only when all referring file descriptors are closed.
:::

## 6.7 D-Bus and Higher-Level IPC Frameworks

While pipes, sockets, and shared memory provide the building blocks of IPC, real-world desktop and server applications typically use higher-level frameworks that provide structured messaging, service discovery, and security.

### 6.7.1 D-Bus

::: definition
**Definition 6.13 (D-Bus).** D-Bus is a message bus system providing structured IPC for Linux desktop and system services. It defines a binary wire protocol and provides two standard bus instances:

- **System bus**: For communication between system services (one per machine)
- **Session bus**: For communication between user applications (one per login session)

D-Bus uses Unix domain sockets as its transport and provides service naming, interface discovery, signal broadcasting, and security policies.
:::

D-Bus messages are typed and structured. Each message contains:

- **Path**: Object path (e.g., `/org/freedesktop/NetworkManager`)
- **Interface**: Interface name (e.g., `org.freedesktop.NetworkManager`)
- **Member**: Method name or signal name (e.g., `GetDevices`)
- **Arguments**: Typed arguments following D-Bus type signatures

::: example
**Example 6.3 (D-Bus Architecture).** A typical D-Bus interaction for retrieving the battery level:

```text
Application                    D-Bus Daemon                 UPower Service
    │                              │                              │
    │  MethodCall:                 │                              │
    │  dest=org.freedesktop.UPower │                              │
    │  path=/org/freedesktop/      │                              │
    │       UPower/devices/bat0    │                              │
    │  iface=org.freedesktop.      │                              │
    │        DBus.Properties       │                              │
    │  method=Get                  │                              │
    │  args=("...Device",          │                              │
    │        "Percentage")         │                              │
    │─────────────────────────────►│  Forward to UPower           │
    │                              │─────────────────────────────►│
    │                              │                              │
    │                              │  MethodReturn:               │
    │                              │◄─────────────────────────────│
    │  Reply: Variant(85.0)        │                              │
    │◄─────────────────────────────│                              │
```

The D-Bus daemon acts as a message router, matching destination bus names to connected services. Services register well-known names (e.g., `org.freedesktop.UPower`) that clients use to address them.
:::

D-Bus is used extensively in the Linux desktop ecosystem:

- **systemd**: Service management via `org.freedesktop.systemd1`
- **NetworkManager**: Network configuration
- **PulseAudio/PipeWire**: Audio routing
- **Freedesktop notifications**: Desktop notification popups
- **GNOME/KDE services**: Settings, power management, screen locking

### 6.7.2 Alternatives to D-Bus

While D-Bus dominates the Linux desktop, other higher-level IPC frameworks exist:

- **Varlink**: A simpler alternative to D-Bus used by systemd for some interfaces, based on JSON over Unix domain sockets
- **kdbus / Bus1**: Kernel-based message bus proposals (kdbus was rejected from mainline Linux; Bus1 is an ongoing effort)
- **Binder**: Android's IPC mechanism, based on shared memory with kernel-mediated transaction semantics
- **XPC** (macOS): Apple's lightweight IPC framework for communication between launchd-managed services

## 6.8 Remote Procedure Call (RPC)

Remote Procedure Call is an IPC paradigm that makes invoking a function on a remote machine (or a different process) look syntactically identical to calling a local function. The RPC framework handles the messy details of serialisation, network communication, and error handling.

### 6.8.1 RPC Architecture

::: definition
**Definition 6.14 (Remote Procedure Call).** A Remote Procedure Call (RPC) is a communication protocol that allows a program to execute a procedure (function) on a remote server as if it were a local call. The RPC framework provides:

1. **Interface Definition Language (IDL)**: A language-neutral specification of the service's API
2. **Stubs**: Generated client and server code that handles marshalling/unmarshalling
3. **Marshalling** (serialisation): Converting function arguments from in-memory representation to a wire format
4. **Unmarshalling** (deserialisation): Converting wire format back to in-memory representation
5. **Transport**: The underlying communication channel (TCP, Unix socket, HTTP/2)
:::

The RPC call flow:

```text
Client Process                                      Server Process
┌──────────────────┐                         ┌──────────────────┐
│ Application Code │                         │ Application Code │
│                  │                         │                  │
│ result = Add(3,5)│                         │ func Add(a,b) {  │
│       │          │                         │   return a + b   │
│       ▼          │                         │ }                │
│ ┌──────────────┐ │                         │ ┌──────────────┐ │
│ │ Client Stub  │ │                         │ │ Server Stub  │ │
│ │ Marshal args │ │                         │ │ Unmarshal    │ │
│ └──────┬───────┘ │                         │ └──────▲───────┘ │
│        │         │                         │        │         │
│ ┌──────▼───────┐ │    Network / Socket     │ ┌──────┴───────┐ │
│ │  Transport   │─┼────────────────────────►│ │  Transport   │ │
│ └──────────────┘ │◄────────────────────────┼─│              │ │
└──────────────────┘     Response             └──────────────────┘
```

### 6.8.2 Marshalling and Wire Formats

Marshalling must handle:

- **Byte order**: Big-endian vs little-endian (network byte order is big-endian by convention)
- **Alignment and padding**: Different architectures have different alignment requirements
- **Pointer translation**: Pointers are meaningless across address spaces; pointer-based structures must be serialised into flat representations
- **Type safety**: The receiver must be able to reconstruct the original typed data

Common wire formats:

| Format | Type | Size | Speed | Human-readable |
|---|---|---|---|---|
| Protocol Buffers | Binary | Compact | Fast | No |
| FlatBuffers | Binary (zero-copy) | Compact | Fastest | No |
| JSON | Text | Verbose | Slow | Yes |
| MessagePack | Binary | Compact | Fast | No |
| XML | Text | Very verbose | Slow | Yes |
| Cap'n Proto | Binary (zero-copy) | Compact | Fastest | No |

### 6.8.3 gRPC

gRPC (Google Remote Procedure Call) is the dominant modern RPC framework. It uses HTTP/2 as its transport and Protocol Buffers (protobuf) as its IDL and serialisation format.

::: definition
**Definition 6.15 (gRPC).** gRPC is an open-source RPC framework that uses:

- **Protocol Buffers (protobuf)**: For defining service interfaces and message types
- **HTTP/2**: For transport, providing multiplexed streams, header compression, and bidirectional streaming
- **Code generation**: The `protoc` compiler generates client and server stubs in 12+ languages

gRPC supports four communication patterns:
1. **Unary RPC**: Single request, single response
2. **Server streaming**: Single request, stream of responses
3. **Client streaming**: Stream of requests, single response
4. **Bidirectional streaming**: Stream of requests and responses simultaneously
:::

::: example
**Example 6.4 (gRPC Service Definition and Go Implementation).** A simple calculator service:

```protobuf
// calculator.proto
syntax = "proto3";
package calculator;

option go_package = "calculator/pb";

service Calculator {
    rpc Add (AddRequest) returns (AddResponse);
    rpc SumStream (stream Number) returns (SumResponse);
}

message AddRequest {
    double a = 1;
    double b = 2;
}

message AddResponse {
    double result = 1;
}

message Number {
    double value = 1;
}

message SumResponse {
    double total = 1;
    int32 count = 2;
}
```

Server implementation in Go:

```go
package main

import (
    "context"
    "fmt"
    "io"
    "log"
    "net"

    pb "calculator/pb"

    "google.golang.org/grpc"
)

type server struct {
    pb.UnimplementedCalculatorServer
}

func (s *server) Add(ctx context.Context,
    req *pb.AddRequest) (*pb.AddResponse, error) {
    result := req.A + req.B
    return &pb.AddResponse{Result: result}, nil
}

func (s *server) SumStream(
    stream pb.Calculator_SumStreamServer) error {
    var total float64
    var count int32

    for {
        num, err := stream.Recv()
        if err == io.EOF {
            return stream.SendAndClose(&pb.SumResponse{
                Total: total,
                Count: count,
            })
        }
        if err != nil {
            return err
        }
        total += num.Value
        count++
    }
}

func main() {
    lis, err := net.Listen("tcp", ":50051")
    if err != nil {
        log.Fatalf("failed to listen: %v", err)
    }

    s := grpc.NewServer()
    pb.RegisterCalculatorServer(s, &server{})

    fmt.Println("gRPC server listening on :50051")
    if err := s.Serve(lis); err != nil {
        log.Fatalf("failed to serve: %v", err)
    }
}
```
:::

### 6.8.4 RPC Semantics

RPC must handle network failures, which do not exist in local function calls. The semantics of how failures are handled define three categories:

::: definition
**Definition 6.16 (RPC Failure Semantics).**

- **At-most-once**: The server executes the RPC at most one time. If the client does not receive a response (due to network failure), it does not know whether the server executed the call. This is the default in most RPC systems.
- **At-least-once**: The client retries the RPC until it receives a response. The server may execute the call multiple times. Safe only for **idempotent** operations (operations that produce the same result regardless of how many times they are executed, e.g., `SET key=value`).
- **Exactly-once**: The server executes the RPC exactly once, regardless of network failures. This requires persistent state on both client and server (transaction IDs, duplicate detection). Extremely difficult to implement in general; approximated by systems like Google Spanner.
:::

::: theorem
**Theorem 6.3 (Impossibility of Transparent RPC).** It is impossible to make remote procedure calls completely transparent (indistinguishable from local calls) due to the fundamental differences between local and remote execution:

1. **Partial failure**: A remote call can fail in ways a local call cannot (network partition, server crash). The caller must handle these failures explicitly.
2. **Latency**: Remote calls are orders of magnitude slower than local calls ($\sim$1 ms vs $\sim$10 ns). Treating them as local calls leads to severe performance problems.
3. **Memory access**: Remote calls cannot pass pointers (they are meaningless in the remote address space). All arguments must be serialised.

This was formalised by Waldo et al. in "A Note on Distributed Computing" (1994), arguing that distributed objects should not be treated as local objects.
:::

## 6.9 Comparing IPC Mechanisms

The choice of IPC mechanism depends on the specific requirements:

::: example
**Example 6.5 (IPC Selection Guide).**

**High throughput, low latency, same machine**: Use shared memory with lock-free data structures. Typical for high-frequency trading systems, real-time audio processing, and database engines (e.g., PostgreSQL shared buffers).

**Structured communication between services**: Use gRPC with Protocol Buffers. Provides type safety, code generation, streaming, and works across machines. Typical for microservice architectures.

**Shell-style process pipelines**: Use pipes. Simple, composable, and zero-configuration. The Unix philosophy of small tools connected by pipes.

**Desktop application integration**: Use D-Bus. Service discovery, security policies, and a well-established ecosystem of services on Linux desktops.

**Process supervision and file descriptor passing**: Use Unix domain sockets with `SCM_RIGHTS`. Used by systemd, container runtimes, and web server process managers.

**Simple notifications**: Use signals. No data transfer beyond the signal number (or a small payload with real-time signals). Used for process lifecycle management (SIGCHLD, SIGTERM).
:::

The following table provides a quantitative comparison on a typical Linux system (Intel Core i7, kernel 6.x):

| Mechanism | Latency (64B msg) | Throughput (64B msgs/s) | Setup Complexity | Cross-Machine |
|---|---|---|---|---|
| Shared memory + atomic | ~50 ns | ~20,000,000 | High | No |
| Unix domain socket | ~5 us | ~200,000 | Low | No |
| Pipe | ~3 us | ~300,000 | Very low | No |
| TCP loopback | ~12 us | ~85,000 | Low | Yes |
| POSIX message queue | ~4 us | ~250,000 | Medium | No |
| Signal | ~2 us | ~500,000 | Low | No (same machine) |
| gRPC (loopback) | ~100 us | ~10,000 | Medium | Yes |
| D-Bus | ~200 us | ~5,000 | High | No |

> **Programmer:** **Programmer's Perspective: Go Channels as CSP-Style IPC.** Go channels implement Communicating Sequential Processes (CSP), Tony Hoare's formal model of concurrent computation. In CSP, processes communicate by sending and receiving values on named channels; there is no shared state. Go's channels provide exactly this abstraction:

> ```go
> package main
>
> import (
>     "fmt"
>     "sync"
> )
>
> func producer(ch chan<- int, id int, wg *sync.WaitGroup) {
>     defer wg.Done()
>     for i := 0; i < 5; i++ {
>         ch <- id*100 + i
>     }
> }
>
> func consumer(ch <-chan int, done chan<- bool) {
>     for val := range ch {
>         fmt.Printf("Consumed: %d\n", val)
>     }
>     done <- true
> }
>
> func main() {
>     ch := make(chan int, 10)  // Buffered channel (async)
>     done := make(chan bool)
>     var wg sync.WaitGroup
>
>     // Launch 3 producers
>     for i := 0; i < 3; i++ {
>         wg.Add(1)
>         go producer(ch, i, &wg)
>     }
>
>     // Launch 1 consumer
>     go consumer(ch, done)
>
>     // Wait for all producers, then close channel
>     wg.Wait()
>     close(ch)
>     <-done
> }
> ```
>
> Unbuffered channels (`make(chan int)`) provide synchronous message passing: the sender blocks until the receiver is ready, creating a rendezvous. Buffered channels (`make(chan int, n)`) provide asynchronous message passing with a bounded buffer of size $n$. The `select` statement multiplexes across multiple channels, analogous to `epoll` for file descriptors. Channels are the preferred IPC mechanism within a Go program; for communication between separate OS processes, Go programs typically use gRPC (with `google.golang.org/grpc`), Unix domain sockets (via `net.Dial("unix", path)`), or named pipes.

## 6.10 io_uring: Asynchronous I/O for Linux

Traditional IPC mechanisms rely on synchronous system calls: `read()`, `write()`, `send()`, `recv()`. Each call transitions from user mode to kernel mode and back, incurring overhead of ~100--200 ns per system call on modern hardware. For high-throughput I/O workloads, this overhead becomes significant.

::: definition
**Definition 6.17 (io_uring).** `io_uring` (introduced in Linux 5.1, 2019) is an asynchronous I/O interface based on two ring buffers shared between user space and the kernel:

- **Submission Queue (SQ)**: User space writes I/O request descriptors (Submission Queue Entries, SQEs) to this ring. Each SQE describes an operation (read, write, send, recv, accept, etc.) and its parameters.
- **Completion Queue (CQ)**: The kernel writes completion results (Completion Queue Entries, CQEs) to this ring. Each CQE contains the result code and user data identifying which request completed.

Both rings are memory-mapped and accessible without system calls after initial setup. User space can submit multiple I/O requests and poll for completions without entering the kernel, achieving zero-syscall I/O in the best case.
:::

```c
#include <liburing.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define QUEUE_DEPTH 32

int main(void) {
    struct io_uring ring;
    
    /* Initialise io_uring with queue depth 32 */
    if (io_uring_queue_init(QUEUE_DEPTH, &ring, 0) < 0) {
        perror("io_uring_queue_init");
        return 1;
    }
    
    /* Open a file */
    int fd = open("/tmp/uring_test.txt",
                  O_WRONLY | O_CREAT | O_TRUNC, 0644);
    
    /* Prepare a write request */
    const char *data = "Hello from io_uring!\n";
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_write(sqe, fd, data, strlen(data), 0);
    io_uring_sqe_set_data(sqe, (void *)1);  /* User data for identification */
    
    /* Submit the request (single syscall for potentially many operations) */
    io_uring_submit(&ring);
    
    /* Wait for completion */
    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);
    
    if (cqe->res < 0) {
        fprintf(stderr, "Write failed: %s\n", strerror(-cqe->res));
    } else {
        printf("Wrote %d bytes via io_uring\n", cqe->res);
    }
    
    io_uring_cqe_seen(&ring, cqe);
    
    close(fd);
    io_uring_queue_exit(&ring);
    return 0;
}
```

Compile with: `gcc -o uring_example uring_example.c -luring`

### 6.10.1 io_uring Performance

The key advantage of `io_uring` is **batching and zero-copy submission**. Rather than making one system call per I/O operation, the application fills multiple SQEs in the submission ring and submits them with a single `io_uring_enter()` call (or no system call at all, when using `IORING_SETUP_SQPOLL` mode with a kernel polling thread).

::: example
**Example 6.6 (io_uring vs epoll for Network I/O).** Benchmarks by the io_uring author (Jens Axboe) show:

| Workload | epoll (ops/sec) | io_uring (ops/sec) | Improvement |
|---|---|---|---|
| Random 4K reads (NVMe) | ~200,000 | ~1,600,000 | 8x |
| TCP echo (small messages) | ~350,000 | ~500,000 | 1.4x |
| TCP accept storm | ~100,000 | ~400,000 | 4x |

The greatest gains come from storage I/O, where `io_uring` can drive NVMe devices to their full IOPS capacity by eliminating per-operation system call overhead. For network I/O, the gains are more modest but still significant at high connection counts.
:::

> **Programmer:** **Programmer's Perspective: io_uring in Go and System Design.** Go's runtime uses `epoll` (Linux) or `kqueue` (macOS/BSD) for its internal network poller, which underpins all goroutine-based network I/O. As of Go 1.22, the runtime does not use `io_uring` for its built-in I/O, though proposals exist to add it. Third-party libraries like `github.com/iceber/iouring-go` and `github.com/pawelgaczynski/gain` provide Go wrappers around `io_uring` for applications that need maximum I/O throughput.

> The design principle behind `io_uring` --- **shared-memory ring buffers between user space and kernel** --- is the same principle used in high-performance networking (DPDK, XDP/AF_XDP) and GPU command submission (DRM/KMS). The pattern eliminates the two most expensive operations in I/O: system call overhead (mode switch) and data copying (user-to-kernel buffer copy). When designing high-performance systems, consider whether your I/O pattern can benefit from batched, asynchronous submission via `io_uring` rather than synchronous `read()`/`write()` calls.

## 6.11 IPC Design Patterns

Several recurring patterns appear in IPC-based system design:

### 6.11.1 Producer-Consumer

The producer-consumer pattern decouples data generation from data processing. One or more producer processes write to a shared buffer (pipe, message queue, shared memory ring buffer), and one or more consumer processes read from it.

::: definition
**Definition 6.18 (Producer-Consumer Pattern).** In the producer-consumer pattern, producers generate data items and place them in a bounded buffer of capacity $N$. Consumers remove data items from the buffer and process them. The buffer provides flow control: producers block when the buffer is full, and consumers block when the buffer is empty. This pattern decouples the rate of production from the rate of consumption.
:::

The key synchronisation requirements are:

1. **Mutual exclusion**: At most one process accesses the buffer at a time (if using shared memory)
2. **Full buffer**: Producers must wait when the buffer has $N$ items
3. **Empty buffer**: Consumers must wait when the buffer has 0 items

### 6.11.2 Client-Server

The client-server pattern uses a well-known endpoint (a named pipe, a Unix socket path, or a network address) where the server listens for requests. Clients connect, send requests, and receive responses.

### 6.11.3 Publish-Subscribe

In publish-subscribe, publishers emit events without knowing which processes will receive them. Subscribers register interest in specific event types. A message broker (e.g., D-Bus, Redis pub/sub, NATS) routes events from publishers to matching subscribers.

## 6.12 Security Considerations

IPC mechanisms have security implications that system designers must consider:

**Permission control:**

- POSIX shared memory objects: Controlled by filesystem-like permissions (owner, group, other)
- Unix domain sockets: The socket file has filesystem permissions; additionally, `SO_PEERCRED` reveals the peer's PID, UID, and GID
- Named pipes: Filesystem permissions on the FIFO special file
- Signals: Only processes with the same UID (or root) can send signals to each other

**Data confidentiality:**

- Shared memory and pipes transfer data in plaintext within the kernel
- For cross-machine IPC (TCP sockets, gRPC), TLS encryption should be used
- D-Bus supports Unix credentials passing and AppArmor/SELinux integration for access control

::: theorem
**Theorem 6.4 (IPC Isolation Boundary).** In a correctly configured operating system, IPC is the only mechanism by which processes in different address spaces can exchange data. Specifically, if processes $A$ and $B$ have disjoint virtual address spaces and neither has access to `/proc/<pid>/mem` or `ptrace()` capabilities for the other, then all data exchange between $A$ and $B$ must occur through kernel-mediated IPC mechanisms. This is a consequence of the virtual memory isolation guarantee provided by the MMU and the kernel's page table management.
:::

## Exercises

1. **Exercise 6.1.** Write a C program that implements a producer-consumer system using POSIX shared memory and POSIX semaphores. The shared memory region should contain a circular buffer of 16 integer slots. The producer writes the integers 1 through 100 to the buffer; the consumer reads and prints them. Use two semaphores (`empty` and `full`) and a mutex to synchronise access. Verify that all 100 integers are received in order.

2. **Exercise 6.2.** Compare the latency of three IPC mechanisms by writing a ping-pong benchmark in C. Two processes alternate sending a single byte to each other for 100,000 round trips. Implement the benchmark using: (a) an anonymous pipe pair, (b) a Unix domain socket pair (SOCK_STREAM), and (c) TCP sockets on localhost (127.0.0.1). Measure the average round-trip time for each and explain the performance differences in terms of the kernel code path each mechanism traverses.

3. **Exercise 6.3.** The `PIPE_BUF` atomicity guarantee ensures that writes of up to 4096 bytes to a pipe are atomic. Design an experiment to demonstrate what happens when multiple processes simultaneously write messages larger than `PIPE_BUF` to the same pipe. Write a C program where 4 child processes each write a 8192-byte message (filled with a distinct character, e.g., 'A', 'B', 'C', 'D') to the same pipe. The parent reads from the pipe and checks whether the messages are interleaved. Report your findings and explain why `PIPE_BUF` atomicity matters for logging systems that use pipes.

4. **Exercise 6.4.** Implement a simple RPC system in Go without using any RPC framework. Define a calculator service with `Add(a, b float64) float64` and `Multiply(a, b float64) float64` methods. The client sends requests as JSON over a Unix domain socket; the server parses the request, dispatches to the appropriate method, and returns the result as JSON. Handle errors (unknown method, malformed request) gracefully. Then compare the latency of your hand-written RPC with Go's `net/rpc` package and `google.golang.org/grpc` for the same operations.

5. **Exercise 6.5.** Signals are sometimes called "software interrupts." Explain the analogy by comparing: (a) how hardware interrupts are delivered to the CPU, (b) how signals are delivered to a process, (c) the mechanisms for masking/blocking both, and (d) the restrictions on what code can execute in an interrupt handler vs a signal handler. Write a C program that demonstrates signal masking: block `SIGINT`, send `SIGINT` to the process 5 times, then unblock `SIGINT` and observe how many times the signal handler is invoked. Repeat with a real-time signal and observe the difference.

6. **Exercise 6.6.** Write a Go program that demonstrates the performance difference between unbuffered and buffered channels. Create a pipeline of 4 stages (goroutines), where each stage reads an integer from its input channel, increments it, and sends it to its output channel. Run 1,000,000 values through the pipeline. Measure the throughput with: (a) unbuffered channels between all stages, (b) buffered channels with capacity 1, (c) buffered channels with capacity 100, and (d) buffered channels with capacity 10,000. Plot throughput vs buffer size and explain the results in terms of goroutine scheduling and synchronisation overhead.

7. **Exercise 6.7.** Unix domain sockets can transfer file descriptors via `SCM_RIGHTS` ancillary messages. Write a C program with two processes: a "file server" that opens a file and sends the file descriptor to a "client" process over a Unix domain socket. The client reads from the received file descriptor and prints the contents. Verify that the client can read the file even if it does not have filesystem permission to open the file directly (the server must have the permission). Explain the security implications of file descriptor passing and why it is used by container runtimes and process managers.
