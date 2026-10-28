package driver

// PT_INTERP path of the x86-64 Linux ELF interpreter. The gABI leaves the
// string implementation-defined; Linux documents this path in ld-linux(8) and
// elf(5) (PT_INTERP).
LINUX_AMD64_DYNAMIC_INTERPRETER :: "/lib64/ld-linux-x86-64.so.2"

// Multiarch library glob for this target. Debian multiarch names the directory
// /usr/lib/<triplet> with triplet x86_64-linux-gnu
// (https://wiki.debian.org/Multiarch). No spec fixes the triplet, so lookup
// uses this glob, which matches that directory.
LINUX_AMD64_MULTIARCH_LIB_PATTERN :: "/usr/lib/x86_64-linux-*"

// x86-64 TLS TCB size in bytes. The psABI (System V AMD64, chapter 3.4.6,
// Thread-Local Storage) places the thread pointer at the TCB; the self pointer
// is at offset 0 and stack_guard at 0x28. 48 is the prefix glibc tcbhead_t and
// musl __pthread share for those fields.
LINUX_AMD64_TCB_SIZE :: 48
