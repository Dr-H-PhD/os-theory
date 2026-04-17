# Chapter 17: Security and Protection

*"The only truly secure system is one that is powered off, cast in a block of concrete, and sealed in a lead-lined room with armed guards --- and even then I have my doubts."*
--- Eugene Spafford

---

An operating system manages resources on behalf of multiple principals --- users, processes, services --- each with different levels of trust. **Protection** is the mechanism by which the OS controls access to those resources. **Security** is the broader goal of ensuring that the protection mechanisms cannot be circumvented by adversaries, whether they attack through software vulnerabilities, side channels in the hardware, or social engineering. This chapter examines both dimensions: the formal models that govern access control, the concrete mechanisms that Linux and other systems implement, and the hardware-level attacks that have reshaped how we think about trust boundaries.

We begin with the abstract framework --- protection domains, the access matrix, and its decompositions --- then move through the three major access control paradigms (DAC, MAC, RBAC), the Linux Security Modules framework, sandboxing, hardware-level attacks on speculative execution, trusted computing, and finally the oldest and most persistent class of software vulnerability: the buffer overflow.

## 17.1 Protection Domains and the Access Matrix

Every process executes within a **protection domain** that defines the set of resources it may access and the operations it may perform on each resource.

::: definition
**Protection Domain.** A protection domain is a set of pairs $(o_i, R_i)$ where $o_i$ is an object (file, memory segment, device, socket) and $R_i \subseteq \{\text{read}, \text{write}, \text{execute}, \text{append}, \text{delete}, \ldots\}$ is the set of access rights the domain holds for that object.
:::

A process may belong to one domain at a time, but domain switching is permitted --- for example, a user-mode process switches to the kernel domain via a system call, or a setuid binary switches to the file owner's domain upon execution. Domain switching is itself a controlled operation: it requires a specific access right (the `switch` right) in the current domain.

The concept of a protection domain is powerful because it separates the **policy** (what a process should be allowed to do) from the **mechanism** (how the OS enforces it). The access matrix, which we examine next, provides the formal framework for expressing policies.

### 17.1.1 The Access Matrix Model

The **access matrix**, formalised by Lampson (1971) and extended by Graham and Denning (1972), provides the foundational abstraction for all access control systems.

::: definition
**Access Matrix.** An access matrix $A$ is a two-dimensional array where rows represent **domains** (subjects) and columns represent **objects**. The entry $A[d_i, o_j]$ contains the set of access rights that domain $d_i$ holds over object $o_j$.
:::

::: example
**Example 17.1 (Access Matrix).** Consider a system with three domains ($D_1$, $D_2$, $D_3$) and four objects (File1, File2, Printer, Port80):

| | File1 | File2 | Printer | Port80 |
|---|---|---|---|---|
| $D_1$ | read, write | read | | |
| $D_2$ | read | read, write | print | |
| $D_3$ | | read | | bind, listen |

Domain $D_1$ can read and write File1 but can only read File2. Domain $D_3$ can bind and listen on Port80 (a network port treated as an object). No domain has universal access.
:::

The access matrix can include domains themselves as objects, enabling **domain switching**: if $A[D_1, D_2]$ contains the right `switch`, then a process in $D_1$ may transition to $D_2$. This captures setuid execution, kernel entry, and role assumption. Furthermore, the access matrix can include **control rights** that govern modification of the matrix itself:

- **Owner** right: the ability to grant or revoke access to an object.
- **Copy** right: the ability to copy an access right to another domain (with or without the copy right itself, yielding **transfer** vs **limited copy**).

::: definition
**Harrison-Ruzzo-Ullman (HRU) Model.** The HRU model extends the access matrix with a set of commands that modify the matrix. Each command is a sequence of primitive operations:

- `enter r into A[s, o]`: grant right $r$ to subject $s$ for object $o$.
- `delete r from A[s, o]`: revoke right $r$ from $s$ for $o$.
- `create subject s` / `create object o`: add a new row/column.
- `destroy subject s` / `destroy object o`: remove a row/column.

Commands execute only if specific preconditions (the presence of certain rights in certain cells) are satisfied.
:::

::: theorem
**Theorem 17.1 (HRU Safety Problem).** The **safety problem** --- given an access matrix and a set of commands, determine whether a specific access right can ever be granted to a specific subject --- is undecidable in the general case.

*Proof sketch.* Lampson showed that the HRU model can simulate a Turing machine. The subjects and objects form the tape, the access rights encode the tape symbols, and the commands simulate the transition function. Since the halting problem for Turing machines is undecidable, determining whether a specific right can ever appear in the matrix is also undecidable. Harrison, Ruzzo, and Ullman (1976) provided the formal proof, showing a reduction from the halting problem to the safety problem for systems with unrestricted command sets.

For restricted models (e.g., commands with a single operation, or systems without subject/object creation), the safety problem may be decidable, but the general result means there is no algorithm that can verify the safety of an arbitrary access control policy. $\square$
:::

The undecidability of the safety problem has profound implications: we cannot, in general, prove that a given access control configuration will never grant an unintended right. This motivates the development of restricted, tractable models such as Bell-LaPadula, Biba, and RBAC.

The matrix is conceptually clean but impractical to store directly --- a system with 10,000 users and 1,000,000 files would require a $10^{10}$-entry matrix, almost entirely empty. In practice, the matrix is stored in decomposed form: either by column (access control lists) or by row (capability lists).

### 17.1.2 Access Control Lists (ACLs)

An **access control list** stores the access matrix by column: each object carries a list of (domain, rights) pairs.

::: definition
**Access Control List.** For an object $o_j$, its ACL is the list $\{(d_i, A[d_i, o_j]) \mid A[d_i, o_j] \neq \emptyset\}$.
:::

When a process in domain $d$ attempts to access object $o$, the system searches $o$'s ACL for an entry matching $d$ and checks whether the requested operation is in the associated rights set. If no entry exists, access is denied.

ACLs are the dominant access control mechanism in Unix, Windows, and most file systems. Their advantages include:

- **Easy per-object auditing**: to see who can access a file, read its ACL.
- **Straightforward revocation**: to revoke a user's access, remove their entry from the ACL.
- **Locality**: the ACL is stored with the object (e.g., in the inode), so access checks require no additional lookups.

Their disadvantage is that determining all objects accessible to a given domain requires scanning every object's ACL --- an $O(|\text{objects}|)$ operation. This makes it difficult to audit a user's total permissions.

### 17.1.3 Capability Lists

A **capability list** stores the access matrix by row: each domain holds a list of (object, rights) pairs, called **capabilities**.

::: definition
**Capability.** A capability is an unforgeable token that grants its holder specific access rights to a specific object. Formally, a capability for domain $d_i$ is a pair $(o_j, A[d_i, o_j])$.
:::

Capabilities invert the lookup: a process can enumerate all objects it may access by examining its capability list. Revocation, however, is harder --- to revoke access to an object, the system must locate and invalidate all capabilities pointing to that object across all domains.

The **principle of least privilege** is naturally enforced in a capability system: a process holds only the capabilities it needs and cannot acquire new ones without explicit delegation. This contrasts with ACL systems, where a process in a privileged domain (e.g., root) can access any object.

::: example
**Example 17.2 (ACL vs Capability).** Consider revoking user Bob's access to File1.

With an ACL: the system opens File1's ACL, removes Bob's entry, and the change takes effect immediately for subsequent access attempts.

With capabilities: the system must find Bob's capability list (or all capability lists) and remove the capability for File1. If Bob has copied the capability to another process, that copy must also be found and invalidated. Capability systems address this through **indirection tables** (a capability points to an entry in a table, and revocation clears the table entry) or **generations** (each capability carries a generation number that must match the object's current generation).
:::

Historically, capability-based systems (KeyKOS, EROS, seL4) have offered stronger security properties. File descriptors in Unix are a limited form of capability: a process with an open file descriptor can read/write the file regardless of whether the underlying permissions have changed. However, file descriptors lack the full properties of capabilities (they cannot be freely delegated, and they do not encode fine-grained rights).

### 17.1.4 Comparing ACLs and Capabilities

| Property | ACLs | Capabilities |
|---|---|---|
| Storage | Per-object (column of matrix) | Per-subject (row of matrix) |
| Access check | Search object's ACL for subject | Subject presents capability |
| Revocation | Easy (edit the ACL) | Hard (find all copies) |
| Audit (who can access X?) | Easy (read the ACL) | Hard (scan all subjects) |
| Audit (what can X access?) | Hard (scan all objects) | Easy (read the capability list) |
| Least privilege | Not natural (ambient authority) | Natural (explicit delegation) |
| Delegation | Via ACL modification (requires owner rights) | Via capability passing |
| Confused deputy problem | Vulnerable | Resistant |

The **confused deputy problem** (Hardy, 1988) occurs when a privileged program (the "deputy") is tricked into misusing its authority on behalf of an attacker. With ACLs, the deputy's authority is ambient --- it can access anything its domain permits, even if the request comes from an untrusted source. With capabilities, the deputy acts only on the capabilities it receives, so the attacker can only trigger operations they already have capabilities for.

## 17.2 Discretionary Access Control (DAC)

In **discretionary access control**, the owner of a resource decides who may access it. The owner is trusted to set permissions correctly. This is the model used by traditional Unix and Windows systems.

::: definition
**Discretionary Access Control (DAC).** An access control policy in which the owner of an object has discretion to grant or revoke access rights to other subjects. The system enforces the policy but does not override owner decisions.
:::

The weakness of DAC is trust delegation: if Alice grants Bob access to a file, Bob can copy the file's contents to a location accessible by Eve. The system cannot prevent this because Bob has legitimate access. DAC protects against accidents and casual snooping, not against determined information exfiltration.

### 17.2.1 Unix Permission Bits

The traditional Unix permission model encodes access rights in a 12-bit field associated with each inode:

```text
  ┌─── setuid (4000)
  │┌── setgid (2000)
  ││┌─ sticky (1000)
  │││
  │││  ┌─── owner (rwx)
  │││  │┌── group (rwx)
  │││  ││┌─ other (rwx)
  │││  │││
  sst  rwx rwx rwx
```

Each `rwx` triple encodes read (4), write (2), and execute (1) permissions. For a regular file, `r` allows reading the file's contents, `w` allows modifying them, and `x` allows executing the file as a program. For a directory, `r` allows listing entries, `w` allows creating or deleting entries, and `x` allows traversing (using the directory in a path lookup).

::: example
**Example 17.3 (Permission Bits).** The permission bits `0755` (octal) decode as:

- Owner: `rwx` (7 = 4 + 2 + 1) --- full access
- Group: `r-x` (5 = 4 + 0 + 1) --- read and execute
- Other: `r-x` (5 = 4 + 0 + 1) --- read and execute

This is the typical permission for an executable binary: the owner can modify it, but everyone can run it.

The permission bits `0644` decode as:

- Owner: `rw-` (6 = 4 + 2 + 0) --- read and write
- Group: `r--` (4 = 4 + 0 + 0) --- read only
- Other: `r--` (4 = 4 + 0 + 0) --- read only

This is the typical permission for a configuration file.
:::

The **umask** controls the default permissions for newly created files. A umask of `022` means that the group write and other write bits are cleared from the default permissions. If a program creates a file with mode `0666` (the typical default for a regular file), the effective permissions are $0666 \, \& \, \sim 0022 = 0644$.

The **setuid** bit (4000) is a domain-switching mechanism: when a setuid executable is run, the process executes with the effective UID of the file's owner rather than the invoking user. The classic example is `/usr/bin/passwd`, which is owned by root and setuid, allowing any user to change their own password by writing to `/etc/shadow` (which requires root access).

The setuid bit is one of the most dangerous features in Unix security. A vulnerability in a setuid-root program gives an attacker full root access. The **setgid** bit (2000) is analogous for group identity. When set on a directory, new files created in that directory inherit the directory's group rather than the creator's primary group.

The **sticky bit** (1000), when set on a directory (such as `/tmp`), prevents users from deleting files they do not own, even if they have write permission on the directory.

### 17.2.2 Linux Capabilities

Traditional Unix has a binary privilege model: either a process runs as root (UID 0) with full access to everything, or it runs as a regular user with limited access. This violates the principle of least privilege --- a program that needs only to bind to a privileged port (port < 1024) runs with full root access.

Linux capabilities decompose root's privileges into approximately 40 distinct capabilities:

| Capability | Privilege |
|---|---|
| `CAP_NET_BIND_SERVICE` | Bind to ports below 1024 |
| `CAP_NET_RAW` | Use raw sockets (ping, packet capture) |
| `CAP_SYS_ADMIN` | Broad administrative operations (mount, namespace creation) |
| `CAP_SYS_PTRACE` | Trace and inspect other processes |
| `CAP_DAC_OVERRIDE` | Bypass file read/write/execute permission checks |
| `CAP_CHOWN` | Make arbitrary changes to file ownership |
| `CAP_KILL` | Send signals to any process |
| `CAP_SETUID` / `CAP_SETGID` | Set UID/GID of processes |

A program can be granted specific capabilities without running as root:

```c
#include <sys/capability.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    /* Get current process capabilities */
    cap_t caps = cap_get_proc();
    if (caps == NULL) {
        perror("cap_get_proc");
        return 1;
    }

    /* Print current capabilities */
    char *text = cap_to_text(caps, NULL);
    printf("Current capabilities: %s\n", text);
    cap_free(text);

    /* Drop all capabilities except CAP_NET_BIND_SERVICE */
    cap_clear(caps);
    cap_value_t cap_list[] = { CAP_NET_BIND_SERVICE };
    cap_set_flag(caps, CAP_EFFECTIVE, 1, cap_list, CAP_SET);
    cap_set_flag(caps, CAP_PERMITTED, 1, cap_list, CAP_SET);

    if (cap_set_proc(caps) == -1) {
        perror("cap_set_proc");
        cap_free(caps);
        return 1;
    }

    printf("Dropped to CAP_NET_BIND_SERVICE only\n");
    /* Now we can bind to port 80 but cannot do anything else root can do */

    cap_free(caps);
    return 0;
}
```

Containers routinely use capability dropping: by default, Docker and Podman drop all capabilities except a small whitelist, and administrators can further restrict or expand the set.

### 17.2.3 POSIX ACLs

Traditional Unix permission bits are limited to three categories (owner, group, other). **POSIX ACLs** (IEEE 1003.1e, withdrawn but widely implemented) extend this with fine-grained per-user and per-group entries.

A POSIX ACL consists of entries of the form:

```text
type:qualifier:permissions
```

where `type` is one of `user`, `group`, `mask`, or `other`, `qualifier` is a username or group name (empty for the owner or other entries), and `permissions` is a subset of `{r, w, x}`.

```c
#include <sys/acl.h>
#include <acl/libacl.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    /* Set an ACL granting user "alice" read-write access to a file */
    acl_t acl = acl_from_text("u::rw-,u:alice:rw-,g::r--,m::rw-,o::r--");
    if (acl == NULL) {
        perror("acl_from_text");
        return 1;
    }

    if (acl_set_file("/tmp/shared.txt", ACL_TYPE_ACCESS, acl) == -1) {
        perror("acl_set_file");
        acl_free(acl);
        return 1;
    }

    printf("ACL set successfully\n");
    acl_free(acl);
    return 0;
}
```

The `mask` entry acts as an upper bound on the permissions granted to named users and groups: the effective permission for a named user entry is the intersection of the entry's permissions and the mask. This ensures that `chmod` (which modifies the traditional permission bits) remains compatible with POSIX ACLs --- `chmod` adjusts the mask, capping all named entries.

::: example
**Example 17.4 (POSIX ACL Interaction with chmod).** A file has the following ACL:

```text
user::rw-          (owner: read, write)
user:alice:rw-     (alice: read, write)
group::r--         (owning group: read)
mask::rw-          (mask: read, write)
other::r--         (other: read)
```

Alice's effective permissions are $\text{user:alice:rw-} \cap \text{mask::rw-} = \text{rw-}$. Now the administrator runs `chmod 640` on the file, which sets the group bits to `r--`. On a system with POSIX ACLs, this changes the mask to `r--`:

```text
user::rw-
user:alice:rw-     (effective: r--, because mask is now r--)
group::r--
mask::r--          (changed by chmod)
other::---
```

Alice can now only read the file, even though her ACL entry still says `rw-`. The mask ensures backward compatibility: old tools that use `chmod` still control access as expected, even on files with extended ACLs.
:::

## 17.3 Mandatory Access Control (MAC)

In **mandatory access control**, the system enforces a policy that individual users cannot override. Even the owner of a file cannot grant access that violates the system-wide policy.

::: definition
**Mandatory Access Control (MAC).** An access control policy in which the system assigns security labels to subjects and objects, and a system-wide policy determines access based on these labels. Neither subjects nor object owners can alter the policy or the labels (except through a trusted administrator or a trusted process).
:::

MAC is essential in environments where information leakage must be prevented by policy --- military classified systems, healthcare records, and financial data processing.

### 17.3.1 The Bell-LaPadula Model (Confidentiality)

The **Bell-LaPadula** (BLP) model, developed for the US Department of Defense in 1973, formalises a **multi-level security** policy focused on protecting **confidentiality**.

::: definition
**Security Levels and Lattice.** A set of security levels $L = \{L_1, L_2, \ldots, L_n\}$ forms a **lattice** under a dominance relation $\leq$. In the military setting, the standard linear order is:

$$\text{Unclassified} < \text{Confidential} < \text{Secret} < \text{Top Secret}$$

In practice, security labels also include **compartments** (categories): a label is a pair $(\ell, C)$ where $\ell \in L$ and $C \subseteq \mathcal{C}$ is a set of compartments. The dominance relation is:

$$(\ell_1, C_1) \leq (\ell_2, C_2) \iff \ell_1 \leq \ell_2 \text{ and } C_1 \subseteq C_2$$

Each subject $s$ has a **clearance level** $C(s)$, and each object $o$ has a **classification level** $C(o)$.
:::

The BLP model enforces two properties:

::: theorem
**Theorem 17.2 (Bell-LaPadula Properties).**

1. **Simple Security Property (No Read Up):** A subject $s$ can read object $o$ only if $C(s) \geq C(o)$. A Secret-cleared analyst cannot read Top Secret documents.

2. **Star Property (No Write Down):** A subject $s$ can write to object $o$ only if $C(o) \geq C(s)$. A Top Secret-cleared analyst cannot write to a Secret-level file, because doing so could leak Top Secret information into a lower-classified container.

Together, these properties ensure that information can only flow upward in the security lattice: from lower classifications to higher ones, never downward.

*Proof of information flow containment.* Let $I(t)$ denote the set of information possessed by all entities at level $\leq \ell$ at time $t$. Suppose both properties hold. Any information that enters a subject at clearance level $\ell$ can only be written to objects at level $\geq \ell$ (star property), and those objects can only be read by subjects at level $\geq \ell$ (simple security). Therefore $I(t) \subseteq I(t')$ for all $t \leq t'$: no information flows from level $\ell$ to any level $\ell' < \ell$. $\square$
:::

The BLP model is sometimes summarised as "read down, write up" --- though this can be misleading, since subjects typically need to read and write at their own level as well. The formal statement uses $\geq$ and $\leq$ with the subject's current security level.

::: example
**Example 17.5 (BLP Information Flow).** A military intelligence system has four security levels. Analyst Alice has Secret clearance. She:

- Can read Unclassified and Confidential documents (read down: $\text{Secret} \geq \text{Unclassified}$, $\text{Secret} \geq \text{Confidential}$).
- Can read Secret documents (at her own level).
- Cannot read Top Secret documents ($\text{Secret} \not\geq \text{Top Secret}$).
- Can write to Secret and Top Secret containers (write up: $\text{Secret} \leq \text{Secret}$, $\text{Secret} \leq \text{Top Secret}$).
- Cannot write to Confidential or Unclassified containers ($\text{Confidential} \not\geq \text{Secret}$).

This prevents Alice from (accidentally or maliciously) copying Secret information into a Confidential file that lower-cleared personnel could read.
:::

A practical limitation of BLP is the **write-up problem**: if a Top Secret user cannot write to lower levels, they cannot send unclassified emails or create publicly readable documents. Real systems address this with **trusted subjects** that are permitted to violate the star property under controlled conditions (declassification).

### 17.3.2 The Biba Model (Integrity)

Where BLP protects confidentiality, the **Biba model** (1977) protects **integrity** --- the trustworthiness of data.

::: definition
**Biba Integrity Model.** Each subject $s$ has an integrity level $I(s)$ and each object $o$ has an integrity level $I(o)$, drawn from a lattice. The Biba strict integrity policy enforces:

1. **Simple Integrity Property (No Read Down):** Subject $s$ can read object $o$ only if $I(o) \geq I(s)$. A high-integrity process should not read low-integrity (potentially corrupted) data.

2. **Integrity Star Property (No Write Up):** Subject $s$ can write to object $o$ only if $I(s) \geq I(o)$. A low-integrity process should not corrupt high-integrity data.
:::

::: theorem
**Theorem 17.3 (Biba is the Dual of BLP).** The Biba strict integrity model is the exact dual of the Bell-LaPadula model. If we reverse the lattice order (replacing $\leq$ with $\geq$ and vice versa), the BLP simple security property becomes the Biba simple integrity property, and the BLP star property becomes the Biba integrity star property.

*Proof.* BLP simple security: $s$ reads $o$ only if $C(s) \geq C(o)$ (subject dominates object). Reversing the lattice: $s$ reads $o$ only if $I(o) \geq I(s)$ (object dominates subject). This is the Biba simple integrity property.

BLP star: $s$ writes $o$ only if $C(o) \geq C(s)$ (object dominates subject). Reversing: $s$ writes $o$ only if $I(s) \geq I(o)$ (subject dominates object). This is the Biba integrity star property.

Information flow: BLP allows flow upward (low confidentiality to high). Biba allows flow downward (high integrity to low). In the reversed lattice, "upward" becomes "downward." $\square$
:::

::: example
**Example 17.6 (Biba in Practice).** Consider a web server with two integrity levels: High (trusted system configuration) and Low (user-uploaded content).

- The web server process runs at High integrity.
- User uploads are stored at Low integrity.
- Under Biba, the web server can write to High and Low files ($I(\text{High}) \geq I(\text{Low})$).
- The web server cannot read Low-integrity user uploads directly ($I(\text{Low}) \not\geq I(\text{High})$). To process user content, the server must use a sanitisation process that validates the data and raises its integrity level.

This prevents an attacker from uploading a malicious file that the high-integrity server process trusts blindly.
:::

### 17.3.3 Combining BLP and Biba

In practice, systems need both confidentiality and integrity protection. Unfortunately, BLP and Biba can conflict: BLP requires "read down, write up" while Biba requires "read up, write down." A subject that must read lower-classified data for confidentiality purposes cannot read lower-integrity data for integrity purposes.

Resolving this requires careful system design:

- **Chinese Wall model** (Brewer-Nash): prevents conflicts of interest by dynamically restricting access based on which datasets a user has already accessed.
- **Clark-Wilson model**: focuses on well-formed transactions and separation of duty, using certified data items (CDIs) and transformation procedures (TPs) rather than security levels.

| Property | Bell-LaPadula | Biba |
|---|---|---|
| Goal | Confidentiality | Integrity |
| Read rule | No read up | No read down |
| Write rule | No write down | No write up |
| Information flow | Upward only | Downward only |
| Threat model | Information leakage | Data corruption |

## 17.4 Role-Based Access Control (RBAC)

Both DAC and MAC have practical limitations. DAC gives users too much discretion; MAC requires rigid labelling that is difficult to manage in large organisations. **Role-Based Access Control** (RBAC) provides a middle ground by introducing an abstraction layer between users and permissions.

::: definition
**Role-Based Access Control (RBAC).** An access control model in which permissions are not assigned directly to users but to **roles**. Users are assigned to roles, and they acquire the permissions associated with those roles. Formally:

- $U$ = set of users, $R$ = set of roles, $P$ = set of permissions
- $UA \subseteq U \times R$ = user-role assignment
- $PA \subseteq P \times R$ = permission-role assignment
- A user $u$ has permission $p$ if there exists a role $r$ such that $(u, r) \in UA$ and $(p, r) \in PA$.
:::

RBAC simplifies administration: when an employee changes departments, the administrator changes their role assignment rather than individually revoking and granting hundreds of permissions. RBAC also supports several advanced features:

**Role hierarchies**: a "senior engineer" role may inherit all permissions from the "engineer" role plus additional ones. Formally, if $r_1 \geq r_2$ in the role hierarchy, then all permissions of $r_2$ are also permissions of $r_1$.

**Constraints**: rules that restrict role assignments. The most important is **separation of duty** --- the requirement that no single user holds two conflicting roles (e.g., "cheque preparer" and "cheque approver"). Separation of duty can be **static** (the constraint is checked at role assignment time) or **dynamic** (the constraint is checked at runtime --- a user may hold both roles but cannot activate them simultaneously).

::: example
**Example 17.7 (RBAC in a Hospital).** Consider a hospital information system:

| Role | Permissions |
|---|---|
| Doctor | read patient records, write diagnoses, prescribe medication |
| Nurse | read patient records, update vitals, administer medication |
| Receptionist | read patient demographics, schedule appointments |
| Admin | all of the above, plus manage users and roles |

When Dr. Smith is hired, the administrator assigns them the Doctor role. Dr. Smith immediately has the correct permissions without any per-file ACL changes. When Dr. Smith moves to administration, the administrator removes the Doctor role and assigns the Admin role.

Static separation of duty might require that no user holds both the "Prescriber" and "Pharmacist" roles, preventing a single person from prescribing and dispensing a controlled substance.
:::

::: programmer
**Programmer's Perspective: RBAC in Linux and Go.**
Linux implements a coarse form of RBAC through **groups**: each user belongs to one or more groups, and file permissions include a group access class. More sophisticated RBAC is available through PAM modules and SELinux roles.

In Go web applications, RBAC is typically implemented with middleware that checks the authenticated user's roles against the required permissions for each endpoint:

```go
package main

import (
    "net/http"
    "strings"
)

type Role string

const (
    RoleAdmin  Role = "admin"
    RoleEditor Role = "editor"
    RoleViewer Role = "viewer"
)

// permissions maps roles to permitted HTTP method prefixes.
var permissions = map[Role][]string{
    RoleAdmin:  {"GET", "POST", "PUT", "DELETE"},
    RoleEditor: {"GET", "POST", "PUT"},
    RoleViewer: {"GET"},
}

func RequireRole(roles ...Role) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            userRole := Role(r.Header.Get("X-User-Role")) // simplified
            for _, required := range roles {
                if userRole == required {
                    for _, method := range permissions[required] {
                        if strings.EqualFold(r.Method, method) {
                            next.ServeHTTP(w, r)
                            return
                        }
                    }
                }
            }
            http.Error(w, "Forbidden", http.StatusForbidden)
        })
    }
}

func main() {
    mux := http.NewServeMux()
    mux.Handle("/api/articles",
        RequireRole(RoleAdmin, RoleEditor, RoleViewer)(
            http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
                w.Write([]byte("Article data"))
            }),
        ),
    )
    mux.Handle("/api/admin/users",
        RequireRole(RoleAdmin)(
            http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
                w.Write([]byte("User management"))
            }),
        ),
    )
    http.ListenAndServe(":8080", mux)
}
```

This is a DAC-style implementation of RBAC at the application level. For system-level RBAC enforcement, SELinux provides mandatory role-based policies that the application cannot override.
:::

## 17.5 Linux Security Modules: SELinux and AppArmor

The Linux Security Modules (LSM) framework provides a set of hooks in the kernel that allow **pluggable security modules** to make access control decisions. When a process attempts an operation (open a file, create a socket, send a signal), the kernel invokes the LSM hooks, and the active security module can permit or deny the operation.

The LSM architecture is deliberately minimal: it provides only hooks, not policy. Policy is defined by the security module itself. The LSM hooks are located at **authoritative** points in the kernel --- after standard DAC checks but before the operation is performed.

```text
User-space process: open("/etc/shadow", O_RDONLY)
    │
    ▼
Kernel VFS layer:
    1. Path lookup (resolve "/etc/shadow" to inode)
    2. DAC check (traditional permission bits)
       │
       ▼ (if DAC permits)
    3. LSM hook: security_inode_permission(inode, MAY_READ)
       │
       ├── SELinux: check type enforcement rules
       │   allow httpd_t shadow_t:file { read }?  → DENY
       │
       └── AppArmor: check profile rules
           /etc/shadow r?  → DENY
    │
    ▼ (if LSM permits)
    4. Perform the operation
```

### 17.5.1 SELinux

**Security-Enhanced Linux** (SELinux), developed by the NSA and contributed to the Linux kernel in 2003, implements a comprehensive MAC policy engine.

SELinux assigns a **security context** (also called a **label**) to every process and every object. A security context has the form:

```text
user:role:type:level
```

For example, `system_u:system_r:httpd_t:s0` labels the Apache web server process. The policy rules determine what operations are permitted based on these labels. The central mechanism is **Type Enforcement** (TE): rules of the form:

```text
allow httpd_t httpd_config_t:file { read getattr open };
allow httpd_t httpd_log_t:file { append create getattr open };
deny httpd_t shadow_t:file { read write };
```

The first rule permits any process with type `httpd_t` to read, getattr, and open any file with type `httpd_config_t`. Everything not explicitly allowed is denied (default-deny). A typical SELinux policy for a RHEL system contains tens of thousands of rules.

SELinux also enforces **Multi-Level Security (MLS)**, implementing the Bell-LaPadula model with security levels and compartments. The `level` field in the security context carries the MLS label.

SELinux operates in three modes:

- **Enforcing**: policy violations are denied and logged.
- **Permissive**: policy violations are logged but not denied (useful for policy development).
- **Disabled**: SELinux is not active.

::: example
**Example 17.8 (SELinux in Action).** A web server compromise:

```text
# Attacker exploits a vulnerability in Apache (type: httpd_t)
# Attacker tries to read /etc/shadow (type: shadow_t)

# Without SELinux: Apache runs as root or www-data.
#   If www-data, DAC blocks the read (shadow is 640, root:shadow).
#   But if the attacker escalates to root, DAC is bypassed.

# With SELinux: even if the attacker escalates to root within
# the httpd_t domain, SELinux denies the read because there is
# no "allow httpd_t shadow_t:file { read }" rule.

$ ausearch -m avc -ts recent
type=AVC msg=audit(1650000000.000:100): avc: denied { read }
  for pid=1234 comm="httpd" name="shadow"
  scontext=system_u:system_r:httpd_t:s0
  tcontext=system_u:object_r:shadow_t:s0
  tclass=file permissive=0
```

The SELinux denial is logged in the audit log, providing forensic evidence of the attack attempt.
:::

### 17.5.2 AppArmor

**AppArmor** takes a different approach: instead of labelling every object, it confines individual programs using **profiles** that specify what files, capabilities, and network operations each program may access.

```text
# /etc/apparmor.d/usr.sbin.nginx
/usr/sbin/nginx {
  /etc/nginx/**          r,
  /var/log/nginx/**      w,
  /var/www/html/**       r,
  /run/nginx.pid         rw,
  /proc/sys/net/core/somaxconn r,
  network inet tcp,
  network inet6 tcp,
  capability net_bind_service,
  capability setuid,
  capability setgid,
  deny /etc/shadow      r,
  deny /root/**         rwx,
}
```

This profile confines Nginx to reading its configuration, writing to its logs, serving files from `/var/www/html/`, and binding to privileged ports. Any attempt to access other paths is denied.

AppArmor profiles can be in **enforce** mode (violations are denied) or **complain** mode (violations are logged but permitted). The `aa-genprof` tool can generate profiles automatically by monitoring a program's behaviour and recording the resources it accesses.

| Feature | SELinux | AppArmor |
|---|---|---|
| Approach | Label-based (all objects) | Path-based (per program) |
| Granularity | Very fine (type enforcement) | Moderate (file paths, capabilities) |
| Complexity | High (requires labelling the entire filesystem) | Lower (profiles per application) |
| Default distro | RHEL, Fedora, CentOS | Ubuntu, SUSE |
| Policy language | Type Enforcement rules | Path glob rules |
| Rename resistance | Labels follow inodes (rename-safe) | Paths may break on rename |

## 17.6 Sandboxing

Sandboxing goes beyond access control lists and labels: it restricts a process's ability to **make system calls at all**, dramatically reducing the attack surface. If a process cannot call `open()`, it cannot open files, regardless of what DAC or MAC says.

### 17.6.1 seccomp-bpf

The **seccomp** (secure computing) facility in Linux, extended with BPF filters (seccomp-bpf), allows a process to install a filter that specifies which system calls it may invoke and with which arguments.

The original seccomp mode (Linux 2.6.12) was brutally simple: a process called `prctl(PR_SET_SECCOMP, SECCOMP_MODE_STRICT)`, and from that point it could only use `read()`, `write()`, `exit()`, and `sigreturn()`. Any other system call terminated the process.

seccomp-bpf (Linux 3.5) replaced this with a programmable filter using the BPF (Berkeley Packet Filter) instruction set:

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <linux/audit.h>
#include <sys/syscall.h>
#include <stddef.h>

/* BPF filter that allows only read, write, exit, and sigreturn */
static struct sock_filter filter[] = {
    /* Load the syscall number */
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             offsetof(struct seccomp_data, nr)),
    /* Allow read (0) */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_read, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    /* Allow write (1) */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_write, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    /* Allow exit_group (231) */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_exit_group, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    /* Allow sigreturn (15) */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_rt_sigreturn, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    /* Kill the process for anything else */
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL),
};

int main(void) {
    struct sock_fprog prog = {
        .len = sizeof(filter) / sizeof(filter[0]),
        .filter = filter,
    };

    printf("Installing seccomp filter...\n");

    /* Required before installing a filter without CAP_SYS_ADMIN */
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1) {
        perror("prctl(NO_NEW_PRIVS)");
        return 1;
    }

    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) == -1) {
        perror("prctl(SECCOMP)");
        return 1;
    }

    /* This works: write is allowed */
    const char msg[] = "Sandboxed! Only read/write/exit allowed.\n";
    write(STDOUT_FILENO, msg, sizeof(msg) - 1);

    /* This would kill the process: open is not allowed */
    /* FILE *f = fopen("/etc/passwd", "r"); */

    return 0;
}
```

After installing the filter, the process can only invoke read, write, exit_group, and sigreturn. Any other system call --- open, mmap, fork, execve --- results in immediate process termination (or, with `SECCOMP_RET_ERRNO`, an error return). This is extraordinarily restrictive, but it is exactly how Chrome's renderer processes and OpenSSH's post-authentication child are sandboxed.

The seccomp filter is inherited across `fork()` and `execve()`, and once installed, it cannot be removed or relaxed. Multiple filters can be stacked (each filter is applied in sequence), providing defence in depth.

### 17.6.2 pledge and unveil (OpenBSD)

OpenBSD provides two complementary system calls for sandboxing that are simpler than seccomp-bpf but equally effective:

- **`pledge(promises, execpromises)`**: restricts the process to a set of named promise groups. Each promise group covers a set of system calls:
  - `"stdio"`: read, write, close, dup, mmap, clock_gettime, and other basic operations.
  - `"rpath"`: read-only filesystem access (open for reading, stat, readdir).
  - `"wpath"`: write filesystem access.
  - `"cpath"`: create/delete filesystem entries.
  - `"inet"`: Internet socket operations.
  - `"dns"`: DNS resolution.
  - `"proc"`: fork, exec, wait.
  
  Once pledged, the process cannot expand its promises.

- **`unveil(path, permissions)`**: restricts the process's filesystem view. After calling `unveil("/var/www", "r")` and `unveil(NULL, NULL)` (to lock the set), the process can only see `/var/www`, and only for reading.

::: example
**Example 17.9 (pledge + unveil for a Web Server).** An OpenBSD web server might execute:

```c
/* During initialisation (before handling requests): */
unveil("/var/www/html", "r");     /* serve static files */
unveil("/var/log/httpd", "w");    /* write logs */
unveil("/etc/ssl/certs", "r");    /* TLS certificates */
unveil(NULL, NULL);                /* lock: no more unveil calls */

pledge("stdio rpath wpath inet", NULL);
/* Now the server can:
   - do basic I/O (stdio)
   - read files under /var/www/html and /etc/ssl/certs (rpath)
   - write to /var/log/httpd (wpath)
   - use TCP/UDP sockets (inet)
   It CANNOT:
   - fork/exec (no "proc")
   - modify files outside unveiled paths
   - access the network beyond inet
   - load kernel modules, mount filesystems, etc.
*/
```

Even if an attacker exploits a vulnerability in the server, they cannot write files outside `/var/log/httpd`, cannot execute commands, and cannot access anything outside the unveiled paths. The kernel enforces these restrictions --- they cannot be bypassed from user space.
:::

### 17.6.3 Containers as Isolation Boundaries

Linux containers (discussed in detail in Chapter 18) provide process-level isolation using namespaces and cgroups. From a security perspective, a container restricts:

- **Visibility**: PID namespaces hide host processes; mount namespaces hide the host filesystem.
- **Network access**: Network namespaces isolate network interfaces and routing tables.
- **System calls**: Default seccomp profiles block dangerous syscalls (e.g., `reboot`, `mount`, `kexec_load`).
- **Capabilities**: Containers drop most Linux capabilities by default, retaining only those needed for normal operation.
- **Resource limits**: Cgroups prevent a container from exhausting CPU, memory, or I/O bandwidth.

However, containers share the host kernel, so a kernel vulnerability can breach containment. This is fundamentally different from virtualisation, where each guest has its own kernel. A container escape (privilege escalation from inside a container to the host) is a kernel exploit.

::: programmer
**Programmer's Perspective: Go's syscall.AllThreadsSyscall for Sandbox Enforcement.**
Go's runtime multiplexes goroutines across OS threads. When a security-sensitive operation must apply to all threads in a process (such as installing a seccomp filter or calling `prctl`), Go provides `syscall.AllThreadsSyscall`:

```go
package main

import (
    "fmt"
    "syscall"
)

func main() {
    // PR_SET_NO_NEW_PRIVS must be set on ALL threads before seccomp.
    // Go's runtime may have multiple OS threads (one per GOMAXPROCS).
    r1, r2, err := syscall.AllThreadsSyscall(
        syscall.SYS_PRCTL,
        uintptr(0x26), // PR_SET_NO_NEW_PRIVS = 38
        1, 0,
    )
    if err != 0 {
        fmt.Printf("AllThreadsSyscall failed: %v\n", err)
        return
    }
    fmt.Printf("PR_SET_NO_NEW_PRIVS set on all threads: r1=%d r2=%d\n", r1, r2)

    // After this, a seccomp filter can be installed.
    // Without AllThreadsSyscall, a goroutine might be scheduled
    // on a thread that was NOT sandboxed, creating a security gap.
}
```

This function ensures the system call executes on **every** OS thread managed by the Go runtime --- critical because seccomp filters and prctl settings are per-thread in Linux. Without `AllThreadsSyscall`, a goroutine might be scheduled on a thread that was not sandboxed, creating a security gap.

Linux **namespaces** are the building blocks of containers. Each namespace type isolates a different resource: PID namespaces give each container its own PID 1, mount namespaces give each container its own filesystem tree, and user namespaces allow unprivileged users to appear as root inside the container. We will examine the namespace API in detail in Chapter 18.
:::

## 17.7 Hardware Security: Spectre and Meltdown

In January 2018, the disclosure of the **Spectre** and **Meltdown** vulnerabilities shattered a fundamental assumption of operating system security: that the hardware correctly enforces privilege boundaries during speculative execution.

### 17.7.1 Speculative Execution Background

Modern processors execute instructions **speculatively**: when encountering a conditional branch, the CPU predicts the outcome and begins executing the predicted path before the branch condition is resolved. If the prediction is wrong, the CPU rolls back the architectural state (registers, memory writes) and executes the correct path.

Speculative execution is essential for performance: a modern out-of-order CPU can have 100--200 instructions in flight simultaneously. Without speculation, every branch would stall the pipeline for 15--30 cycles (the branch resolution latency).

The key insight of Spectre and Meltdown is that although the architectural state is rolled back on a misprediction, **microarchitectural state** --- specifically, the contents of the CPU cache --- is not. An attacker can use cache timing to infer data that was transiently accessed during speculative execution.

### 17.7.2 Meltdown (CVE-2017-5754)

::: definition
**Meltdown.** An attack that exploits out-of-order execution on Intel (and some ARM) processors to read kernel memory from user space. The attack has three phases:

1. **Transient access**: the attacker executes a load instruction that reads a byte from a kernel address. This load will eventually raise a page fault (because user mode cannot access kernel memory), but the CPU executes it speculatively before the fault is raised, placing the kernel byte in a register.

2. **Encoding**: the transiently loaded byte is used as an index into an attacker-controlled **probe array** (256 pages, one per possible byte value). This brings one specific page of the probe array into the L1 cache.

3. **Extraction**: the CPU detects the fault and rolls back the register state, but the probe array page remains in cache. The attacker times accesses to each of the 256 pages; the page that loads fast (cache hit) reveals the value of the kernel byte.
:::

In pseudocode, the attack is remarkably simple:

```c
/* Meltdown attack kernel */
uint8_t probe[256 * 4096];  /* 256 pages, spaced by page size */

/* Flush the probe array from cache */
for (int i = 0; i < 256; i++)
    _mm_clflush(&probe[i * 4096]);

/* Transient execution: read kernel byte, encode in cache */
/* (suppressing the page fault via exception handling or TSX) */
uint8_t kernel_byte = *(uint8_t *)KERNEL_ADDRESS;  /* faults! */
uint8_t dummy = probe[kernel_byte * 4096];          /* brings one page into cache */

/* After fault recovery: time each probe page */
for (int i = 0; i < 256; i++) {
    uint64_t t0 = __rdtsc();
    uint8_t dummy2 = probe[i * 4096];
    uint64_t dt = __rdtsc() - t0;
    if (dt < THRESHOLD) {
        printf("Kernel byte = 0x%02x\n", i);
        break;
    }
}
```

Meltdown allowed a user-space process to read the entire physical memory of the machine at speeds of up to 500 KB/s, including kernel data structures, other processes' memory, and cryptographic keys.

### 17.7.3 Spectre (CVE-2017-5753, CVE-2017-5715)

Spectre exploits **branch prediction** rather than out-of-order execution of faulting loads.

**Variant 1 (Bounds Check Bypass):** The attacker mistrains the branch predictor so that an array bounds check is speculatively bypassed:

```c
if (x < array1_size) {           /* branch prediction: taken (trained) */
    y = array2[array1[x] * 256]; /* speculatively executed even when x >= array1_size */
}
```

By choosing `x` to be an out-of-bounds value that indexes into sensitive memory (e.g., kernel memory mapped in the same address space), the attacker can leak arbitrary data through the cache side channel, just as in Meltdown.

**Variant 2 (Branch Target Injection):** The attacker poisons the **Branch Target Buffer (BTB)** to redirect indirect branches to a gadget that leaks data. This is more powerful than Variant 1 because it can attack any indirect branch in the kernel or other processes.

Unlike Meltdown, Spectre affects virtually all modern processors (Intel, AMD, ARM, RISC-V) and cannot be fully mitigated in software. It requires a combination of:

- **Compiler barriers** (`lfence` after bounds checks) for Variant 1.
- **Retpolines** (a compiler technique that replaces indirect branches with a return-based trampoline that prevents BTB poisoning) for Variant 2.
- **Microcode updates** (IBRS, IBPB, STIBP) that flush or restrict branch prediction state.
- **Hardware redesign** in newer processor generations.

### 17.7.4 KPTI: Kernel Page Table Isolation

The primary software mitigation for Meltdown is **Kernel Page Table Isolation** (KPTI), also known by its earlier name KAISER.

::: definition
**Kernel Page Table Isolation (KPTI).** A mitigation that maintains two separate page tables for each process:

1. **User page table**: maps user-space memory and a minimal kernel trampoline (just enough to handle the transition to kernel mode). The rest of the kernel is **unmapped**.

2. **Kernel page table**: maps both user-space and kernel memory (the full address space).

When the CPU is in user mode, it uses the user page table. Upon a system call or interrupt, the trampoline switches to the kernel page table. Upon return to user mode, it switches back.
:::

Because the kernel is unmapped in user mode, a Meltdown-style speculative load cannot access kernel memory --- there is simply no page table entry for it, and the speculative load reads zeroes or garbage from unmapped memory.

The cost of KPTI is performance: every system call and interrupt requires a page table switch (a write to the CR3 register on x86), which flushes the TLB. On workloads with high system call rates, KPTI can impose a 5--30% performance overhead, depending on the processor's support for **PCIDs** (Process Context Identifiers) that allow TLB entries from different page tables to coexist.

::: example
**Example 17.10 (KPTI and Spectre Status).** On a Linux system, the mitigation status can be checked:

```text
$ cat /sys/devices/system/cpu/vulnerabilities/meltdown
Mitigation: PTI

$ cat /sys/devices/system/cpu/vulnerabilities/spectre_v1
Mitigation: usercopy/swapgs barriers and __user pointer sanitization

$ cat /sys/devices/system/cpu/vulnerabilities/spectre_v2
Mitigation: Retpolines, IBPB: conditional, IBRS_FW, STIBP: conditional, RSB filling

$ cat /sys/devices/system/cpu/vulnerabilities/spec_store_bypass
Mitigation: Speculative Store Bypass disabled via prctl
```

A system call-intensive benchmark (such as a database performing many small reads) might show a 10--20% throughput reduction with KPTI enabled. Compute-bound workloads (matrix multiplication, rendering) are largely unaffected because they make few system calls.
:::

### 17.7.5 Beyond Spectre and Meltdown

Since 2018, researchers have discovered numerous additional speculative execution vulnerabilities:

| Vulnerability | Year | Mechanism | Affected |
|---|---|---|---|
| Meltdown | 2018 | Speculative permission bypass on loads | Intel, some ARM |
| Spectre V1 | 2018 | Bounds check bypass via branch prediction | All modern CPUs |
| Spectre V2 | 2018 | Branch target injection | All modern CPUs |
| Foreshadow (L1TF) | 2018 | L1 cache terminal fault | Intel |
| MDS (Zombieload) | 2019 | Microarchitectural data sampling | Intel |
| Spectre-BHB | 2022 | Branch history buffer poisoning | Intel, ARM |

The lesson is clear: **performance optimisations in hardware create security vulnerabilities**. The CPU's speculative execution engine is a massive trusted computing base that was never designed with adversarial models in mind. The tension between performance and security in hardware is a defining challenge for the next decade.

## 17.8 Trusted Computing

**Trusted computing** extends the security boundary below the operating system, into the hardware platform itself. The goal is to establish a **chain of trust** from the moment the machine powers on, so that software at every level can verify that the software below it has not been tampered with.

### 17.8.1 Trusted Platform Module (TPM)

::: definition
**Trusted Platform Module (TPM).** A dedicated cryptographic co-processor soldered to the motherboard (or implemented in firmware as fTPM). A TPM provides:

1. **Platform Configuration Registers (PCRs)**: hash registers that accumulate measurements of the boot process. A PCR can only be extended (new value $=$ hash of old value concatenated with new measurement), never directly written. The extend operation is:
   $$\text{PCR}_{\text{new}} = \text{SHA-256}(\text{PCR}_{\text{old}} \| \text{measurement})$$

2. **Key generation and storage**: the TPM can generate and store RSA/ECC keys that never leave the chip.

3. **Sealing**: encrypting data such that it can only be decrypted when the PCRs contain specific values (i.e., the platform is in a known-good state).

4. **Remote attestation**: proving to a remote party that the platform is running specific software, by signing the PCR values with the TPM's endorsement key.
:::

### 17.8.2 Secure Boot and Measured Boot

**Secure Boot** (part of the UEFI specification) enforces that each stage of the boot process --- firmware, bootloader, kernel --- is signed by a trusted authority. If any component's signature is invalid, the boot halts.

**Measured Boot** does not block unsigned code; instead, it records a cryptographic measurement (hash) of each boot stage into the TPM's PCRs. Software or a remote verifier can later inspect the PCR values to determine exactly what code was loaded.

```text
Power On
  │
  ├── UEFI firmware ──────────── measures itself into PCR[0]
  │         │
  │         ├── Bootloader ────── measures bootloader into PCR[4]
  │         │       │
  │         │       ├── Kernel ── measures kernel into PCR[8]
  │         │       │     │
  │         │       │     ├── initrd ── measures initrd into PCR[9]
  │         │       │     │
  │         │       │     └── OS booted, PCRs contain full chain
  │         │       │
  │         │   Secure Boot: verify signature at each step
  │         │   Measured Boot: hash and extend PCR at each step
```

The combination of secure boot (prevent tampering) and measured boot (detect tampering) provides defence in depth: secure boot stops known-bad code from loading, and measured boot catches code that is not on the blocklist but is nonetheless unexpected.

::: example
**Example 17.11 (TPM-Sealed Disk Encryption).** Linux LUKS full-disk encryption can be configured to seal the encryption key to specific PCR values:

1. During initial setup, the disk encryption key is sealed to the TPM with PCR policy: "decrypt only if PCR[0,4,7,8] match these values."
2. On normal boot, the firmware, bootloader, and kernel are measured. If the measurements match, the TPM releases the key, and the disk decrypts automatically.
3. If an attacker modifies the bootloader (e.g., installs a bootkitobject), the PCR values change, the TPM refuses to release the key, and the disk remains encrypted.

This is the mechanism behind Windows BitLocker and Linux systemd-cryptenroll with TPM2 support.
:::

## 17.9 Buffer Overflow Attacks and Mitigations

Buffer overflows are among the oldest and most prevalent classes of security vulnerabilities in systems software. They exploit the fact that C (and to a lesser extent, C++) does not enforce array bounds at runtime.

### 17.9.1 Stack Smashing

A **stack buffer overflow** occurs when a function writes beyond the bounds of a stack-allocated buffer, overwriting the saved return address on the stack.

::: definition
**Stack Smashing.** An attack in which the attacker supplies input that overflows a stack buffer, overwriting the saved return address with the address of attacker-controlled code (or a code gadget). When the function returns, execution jumps to the attacker's chosen address.
:::

Consider the classic vulnerable function:

```c
#include <string.h>

void vulnerable(const char *input) {
    char buffer[64];
    /* No bounds check: if input exceeds 64 bytes, it overflows */
    strcpy(buffer, input);
}

int main(int argc, char *argv[]) {
    if (argc > 1) {
        vulnerable(argv[1]);
    }
    return 0;
}
```

The stack frame for `vulnerable` looks like:

```text
High addresses
┌──────────────────────────┐
│  Return address (8 bytes) │  <── overwritten by attacker
├──────────────────────────┤
│  Saved RBP (8 bytes)     │  <── overwritten
├──────────────────────────┤
│  buffer[63]              │
│  ...                     │  <── overflow writes past here
│  buffer[0]               │
└──────────────────────────┘
Low addresses
```

If the attacker provides 80 bytes of input, the last 16 bytes overwrite the saved RBP and return address. By carefully crafting the input, the attacker can redirect execution to arbitrary code.

The first publicly documented stack smashing exploit was the Morris Worm (1988), which exploited a buffer overflow in the `fingerd` daemon. Aleph One's "Smashing the Stack for Fun and Profit" (Phrack, 1996) popularised the technique.

### 17.9.2 Heap Overflow and Use-After-Free

Stack overflows are not the only type: **heap overflows** corrupt dynamically allocated memory, potentially overwriting function pointers, vtable pointers, or allocator metadata. **Use-after-free** occurs when a program dereferences a pointer to memory that has been freed and potentially reallocated for a different purpose.

Both are common in C/C++ and are the root cause of a significant fraction of real-world exploits.

### 17.9.3 Return-Oriented Programming (ROP)

Modern mitigations (particularly the NX bit) prevent the attacker from executing code on the stack. **Return-Oriented Programming** (ROP) circumvents this by chaining together small snippets of existing code (called **gadgets**), each ending in a `ret` instruction.

::: definition
**Return-Oriented Programming (ROP).** An exploitation technique that constructs arbitrary computations by chaining together short instruction sequences (gadgets) already present in the program's executable code or loaded libraries. Each gadget ends with a `ret` instruction, which pops the next gadget's address from the attacker-controlled stack and jumps to it.
:::

A ROP chain to call `execve("/bin/sh", NULL, NULL)` on x86-64 Linux might look like:

```text
Stack layout (attacker-controlled):
┌─────────────────────────────┐
│ 0x401100: pop rdi; ret      │ ─── loads "/bin/sh" address into rdi
├─────────────────────────────┤
│ 0x402000: "/bin/sh" address │
├─────────────────────────────┤
│ 0x401200: pop rsi; ret      │ ─── loads 0 into rsi (argv = NULL)
├─────────────────────────────┤
│ 0x0000000000000000          │
├─────────────────────────────┤
│ 0x401300: xor rdx,rdx; ret  │ ─── sets rdx = 0 (envp = NULL)
├─────────────────────────────┤
│ 0x401350: mov eax,59; ret   │ ─── sets syscall number to 59 (execve)
├─────────────────────────────┤
│ 0x401400: syscall            │ ─── executes execve(rdi, rsi, rdx)
└─────────────────────────────┘
```

Each "gadget" is a short sequence like `pop rdi; ret` found somewhere in the existing binary or in libc. The attacker never injects new code --- they reuse the code that is already present. This is **Turing-complete**: any computation can be expressed as a ROP chain, given a sufficiently rich set of gadgets.

### 17.9.4 Defence: ASLR, Stack Canaries, NX Bit

Modern operating systems deploy multiple layers of defence against buffer overflow attacks:

**Address Space Layout Randomisation (ASLR):**

::: definition
**ASLR.** A mitigation that randomises the base addresses of the stack, heap, shared libraries, and (with PIE --- Position-Independent Executable) the executable itself each time a process is loaded. An attacker who does not know the address of their target gadget or shellcode cannot construct a reliable exploit.
:::

On a 64-bit Linux system with full ASLR, the stack base has approximately 30 bits of entropy, making brute-force guessing infeasible ($2^{30} \approx 10^9$ attempts, each of which crashes the target process). However, 32-bit systems have much less entropy (~16 bits for the stack), and information leaks can completely defeat ASLR (see exercises).

**Stack Canaries:**

A **stack canary** (also called a **stack protector** or **stack cookie**) is a random value placed between the local variables and the saved return address. Before the function returns, the compiler-inserted check verifies that the canary has not been modified. If it has, the process is terminated.

```c
/* Compiler inserts this logic (GCC -fstack-protector-strong) */
void vulnerable(const char *input) {
    unsigned long canary = __stack_chk_guard;  /* random value */
    char buffer[64];
    strcpy(buffer, input);

    if (canary != __stack_chk_guard) {
        __stack_chk_fail();  /* terminates the process */
    }
}
```

The canary typically includes a null byte, a newline, and a carriage return at specific positions, making it difficult to overwrite with string functions like `strcpy` that terminate on null bytes.

GCC provides three levels of stack protection:

- `-fstack-protector`: protects functions with local buffers > 8 bytes.
- `-fstack-protector-strong`: protects functions with any local array or address-taken variables.
- `-fstack-protector-all`: protects all functions (highest overhead).

**NX Bit (No-eXecute):**

::: definition
**NX Bit.** A hardware feature (called NX on AMD, XD on Intel, XN on ARM) that marks memory pages as non-executable. With NX enabled, the stack and heap are marked non-executable, so even if an attacker injects shellcode, the CPU refuses to execute it, raising a page fault instead.
:::

The combination of ASLR + stack canaries + NX makes traditional buffer overflow exploitation extremely difficult. However, none is individually sufficient:

- ASLR can be defeated by information leaks.
- Stack canaries can be bypassed by overwriting specific variables without touching the canary (e.g., overwriting a function pointer stored before the canary on the stack).
- NX is bypassed by ROP (which reuses existing code, not injected code).

The principle of **defence in depth** requires all three, plus additional hardening.

::: example
**Example 17.12 (Checking Mitigations on Linux).** The `checksec` tool inspects a binary's security properties:

```text
$ checksec --file=/usr/bin/ssh
RELRO           STACK CANARY      NX           PIE
Full RELRO      Canary found      NX enabled   PIE enabled

$ checksec --file=./vulnerable_demo
RELRO           STACK CANARY      NX           PIE
Partial RELRO   No canary found   NX enabled   No PIE
```

The first binary (OpenSSH) has all mitigations enabled: full RELRO (read-only GOT, preventing GOT overwrite attacks), stack canary, NX, and PIE (position-independent executable, enabling full ASLR). The second (our demo) lacks a canary and position-independent execution --- it would be much easier to exploit.
:::

::: programmer
**Programmer's Perspective: Memory Safety and Go.**
Go is largely immune to buffer overflow attacks because:

1. **Bounds checking**: every array and slice access is bounds-checked at runtime. An out-of-bounds access causes a panic (controlled crash), not memory corruption.

2. **No pointer arithmetic**: Go does not permit arbitrary pointer arithmetic. You cannot increment a pointer past the end of an allocation.

3. **Garbage collection**: use-after-free is impossible because the GC will not free memory that is still reachable.

4. **No uninitialised memory**: all variables are zero-initialised. Reading uninitialised memory (a common source of information leaks in C) is impossible.

However, Go's `unsafe` package bypasses all safety guarantees:

```go
package main

import (
    "fmt"
    "unsafe"
)

func main() {
    x := [4]int{10, 20, 30, 40}
    // Unsafe pointer arithmetic: read past the array
    p := unsafe.Pointer(&x[0])
    for i := 0; i < 8; i++ {
        val := *(*int)(unsafe.Add(p, uintptr(i)*unsafe.Sizeof(x[0])))
        fmt.Printf("offset %d: %d\n", i, val)
    }
    // Offsets 4-7 read garbage from the stack --- undefined behaviour.
    // This code is as dangerous as C.
}
```

Code that uses `unsafe` is as vulnerable as C. The Go compiler and tooling flag `unsafe` usage, and it should be audited rigorously. For systems programming that requires pointer manipulation (e.g., device drivers, memory allocators), consider Rust, which provides `unsafe` blocks with stricter ownership rules and borrow checking even for unsafe code's safe interfaces.
:::

## 17.10 Putting It All Together: Defence in Depth

No single security mechanism is sufficient. Modern operating systems layer multiple defences, each independent, so that the failure of one does not compromise the system:

| Layer | Mechanism | Protects Against |
|---|---|---|
| Hardware | NX bit, ASLR (randomised layout) | Code injection, address prediction |
| Hardware | KPTI, retpolines | Spectre, Meltdown |
| Hardware | TPM, secure boot | Firmware tampering, rootkits |
| Kernel | SELinux / AppArmor (MAC) | Privilege escalation, lateral movement |
| Kernel | seccomp-bpf | Syscall-based attacks, kernel exploits |
| Kernel | Namespaces, cgroups | Container escape, resource abuse |
| Kernel | Linux capabilities | Over-privileged processes |
| Compiler | Stack canaries, fortified functions | Stack smashing, format string attacks |
| Compiler | RELRO, PIE | GOT overwrite, code reuse attacks |
| Application | RBAC, capability-based design | Over-privileged processes |
| Application | Input validation, bounds checking | Injection attacks |

::: programmer
**Programmer's Perspective: Linux Namespaces and Container Security.**
The security of a container depends on the correct composition of multiple kernel mechanisms. A minimal container setup in C uses five namespace types:

```c
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/mount.h>

#define STACK_SIZE (1024 * 1024)

static int child_fn(void *arg) {
    (void)arg;

    /* New PID namespace: we are PID 1 */
    printf("Child PID (in namespace): %d\n", getpid());

    /* Set a new hostname */
    sethostname("container", 9);

    /* Mount a new proc for the new PID namespace */
    mount("proc", "/proc", "proc", 0, NULL);

    /* Execute a shell in the isolated namespace */
    char *argv[] = {"/bin/sh", NULL};
    execv("/bin/sh", argv);
    perror("execv");
    return 1;
}

int main(void) {
    char *stack = malloc(STACK_SIZE);
    if (!stack) {
        perror("malloc");
        return 1;
    }

    /* Create child in new PID, UTS, mount, and network namespaces */
    int flags = CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWNS | CLONE_NEWNET;
    pid_t pid = clone(child_fn, stack + STACK_SIZE, flags | SIGCHLD, NULL);
    if (pid == -1) {
        perror("clone");
        return 1;
    }

    printf("Parent: child PID = %d\n", pid);
    waitpid(pid, NULL, 0);

    free(stack);
    return 0;
}
```

This creates a process isolated in four namespaces: it has its own PID space (where it is PID 1), its own hostname, its own mount table, and its own network stack. Combined with a seccomp filter, dropped capabilities, cgroup resource limits, and a restricted root filesystem, this approximates what container runtimes like `runc` and Podman do.

The key insight is that no single mechanism provides adequate isolation. A container without seccomp can exploit kernel vulnerabilities through dangerous syscalls. A container without capability dropping retains dangerous privileges. A container without a user namespace runs as real root on the host. **Defence in depth is not optional --- it is the architecture.**
:::

---

::: exercises
1. **Access Matrix Decomposition.** Given an access matrix with $n$ subjects and $m$ objects, where on average each subject has access to $k$ objects ($k \ll m$), compare the storage costs of (a) the full matrix, (b) ACLs, and (c) capability lists. Under what conditions is each representation most space-efficient? For a system with $n = 10{,}000$ users and $m = 1{,}000{,}000$ files where $k = 100$, calculate the storage for each representation, assuming each right set requires 4 bytes.

2. **BLP Lattice with Compartments.** Consider a Bell-LaPadula system with security levels $\{U, C, S, TS\}$ (Unclassified $<$ Confidential $<$ Secret $<$ Top Secret) and two compartments $\{A, B\}$. A security label is a pair $(\ell, S)$ where $\ell$ is a level and $S \subseteq \{A, B\}$. Define the dominance relation on labels and draw the resulting lattice (a Hasse diagram). How many distinct labels exist? A subject with label $(S, \{A\})$ wishes to write to an object with label $(C, \{A, B\})$. Is this permitted under BLP? Explain carefully.

3. **Biba Dual.** Prove formally that the Biba strict integrity model is the exact dual of Bell-LaPadula: take the BLP properties, reverse the lattice order, and show that the resulting properties are precisely the Biba simple integrity and star properties. Then explain why a system cannot simultaneously enforce both BLP and Biba in their strict forms without using trusted subjects.

4. **seccomp Filter Design.** Design a seccomp-bpf filter (specify the complete allowed syscall set) for a program that: (a) reads a file specified as a command-line argument, (b) performs a computation on the file contents in memory, and (c) writes the result to stdout. The filter should be as restrictive as possible while allowing the program to function. Justify each allowed syscall, including any that are needed for process startup and termination.

5. **Meltdown Attack Mechanics.** Explain why the original Meltdown attack does not affect AMD processors. The answer involves a microarchitectural difference in how Intel and AMD handle permission checks during speculative loads. What is this difference, and why does it prevent the attack? Are there any Meltdown-type attacks that do affect AMD?

6. **ROP Gadget Chain.** Given a binary that contains the following gadgets at known addresses: `pop rdi; ret` at `0x401100`, `pop rsi; ret` at `0x401200`, `xor rdx, rdx; ret` at `0x401300`, `mov eax, 59; ret` at `0x401350`, and `syscall` at `0x401400`. The string `"/bin/sh"` is stored at address `0x402000`. Construct a ROP chain (as a sequence of 8-byte stack values) that invokes `execve("/bin/sh", NULL, NULL)` on x86-64 Linux (syscall number 59). Draw the complete stack layout and trace the execution of each gadget.

7. **Defence Bypass Analysis.** Describe a realistic attack scenario in which an attacker bypasses ASLR on a 64-bit Linux system. Your answer should explain: (a) what type of information leak is used (e.g., format string vulnerability, partial overwrite, timing side channel), (b) how the leaked information enables further exploitation (e.g., calculating gadget addresses), and (c) which additional mitigation (from those discussed in this chapter) could prevent the attack from succeeding even after ASLR is bypassed, and why.
:::
