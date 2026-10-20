# Benchmarks: official odin vs odinc

Date: 2026-10-20.

Machine: AMD Ryzen 7 5700X 8-Core Processor (8 cores, 16 threads), 32 GB RAM, Linux 7.2.11-1-cachyos.

## Compilers

- A: the odin installed by mise, `dev-2026-10-nightly:84bc3fc` (`odin version`).
- B: the fork binary named by `ODIN_BIN` in `.mise/config.toml`, `dev-2026-10:ea225db25`, run with `ODIN_ROOT` set to the fork.
- C: odinc, built with `mise run build` (`build/odinc`, change nqylmowwrmrv). No optimized odinc build exists; the build script and the differential test both use default flags.

For A and B, `speed` is `-o:speed` and `default` passes no optimization flag. C has only the default build.

## Method

Each program is compiled and run with its output under `/tmp/bench38`. Before any timing, the binary's stdout and exit code are compared with B default; `match` means both equal, and any other value is reported.

Compile and run wall time are the median of 5 runs, measured with nanosecond clocks around the whole command, so process start is included. Peak RSS is the median of the 5 maximum resident sizes reported by `/usr/bin/time -f %M`. Binary size is the size of the executable file of the last build.

Programs: `loops` is a nested integer loop of 10^8 iterations; `fib` is recursive `fib(35)`; `sieve` is a Sieve of Eratosthenes over a 10,000,001-element static `bool` array. `hello_fmt`, `multi_value_args`, `memory_args` and `map_lookup` are fixtures from `src/driver/testdata/`. Each program's exit code is a checksum (`& 0xff`), so the exit code is part of the check.

## Results

| Program | Compiler | Variant | Compile (ms) | Compile peak RSS (MB) | Binary (KB) | Run (ms) | Run peak RSS (KB) | Check |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| loops | A | speed | 192.7 | 228.2 | 21 | 13.3 | 1876 | match (exit 128) |
| loops | A | default | 91.4 | 224.6 | 42 | 132.5 | 1892 | match (exit 128) |
| loops | B | speed | 360.7 | 260.5 | 63 | 13.2 | 392 | match (exit 128) |
| loops | B | default | 134.2 | 285.2 | 144 | 132.1 | 392 | match (exit 128) |
| loops | C | default | 118.7 | 18.9 | 108 | 110.5 | 392 | match (exit 128) |
| fib | A | speed | 191.2 | 230.0 | 21 | 18.5 | 1892 | match (exit 201) |
| fib | A | default | 91.1 | 228.4 | 42 | 45.2 | 1888 | match (exit 201) |
| fib | B | speed | 361.7 | 264.7 | 63 | 21.5 | 392 | match (exit 201) |
| fib | B | default | 118.6 | 295.9 | 144 | 42.1 | 392 | match (exit 201) |
| fib | C | default | 119.7 | 18.9 | 108 | 61.5 | 392 | match (exit 201) |
| sieve | A | speed | 192.1 | 209.4 | 21 | 18.6 | 11708 | match (exit 3) |
| sieve | A | default | 91.9 | 225.5 | 42 | 87.9 | 11672 | match (exit 3) |
| sieve | B | speed | 361.1 | 261.2 | 63 | 17.5 | 9696 | match (exit 3) |
| sieve | B | default | 122.8 | 281.8 | 144 | 81.7 | 9768 | match (exit 3) |
| sieve | C | default | 119.1 | 19.0 | 108 | 74.8 | 9776 | match (exit 3) |
| hello_fmt | A | speed | 1715.3 | 335.2 | 225 | 2.1 | 2308 | match (exit 0) |
| hello_fmt | A | default | 289.8 | 369.7 | 373 | 2.1 | 2444 | match (exit 0) |
| hello_fmt | B | speed | 1171.4 | 341.8 | 237 | 1.8 | 392 | match (exit 0) |
| hello_fmt | B | default | 213.7 | 397.6 | 441 | 1.8 | 392 | match (exit 0) |
| hello_fmt | C | default | 717.3 | 86.8 | 488 | 1.8 | 392 | match (exit 0) |
| multi_value_args | A | speed | 189.2 | 214.1 | 21 | 2.0 | 1888 | match (exit 65) |
| multi_value_args | A | default | 91.9 | 223.5 | 42 | 2.0 | 1864 | match (exit 65) |
| multi_value_args | B | speed | 360.3 | 259.0 | 63 | 1.8 | 392 | match (exit 65) |
| multi_value_args | B | default | 130.5 | 279.8 | 145 | 1.8 | 392 | match (exit 65) |
| multi_value_args | C | default | 120.3 | 19.0 | 108 | 1.8 | 392 | match (exit 65) |
| memory_args | A | speed | 264.8 | 214.3 | 30 | 2.1 | 1892 | MISMATCH: exit 134, B exit 132 |
| memory_args | A | default | 105.4 | 233.5 | 74 | 61.4 | 1880 | MISMATCH: exit 139, B exit 132 |
| memory_args | B | speed | 398.7 | 254.1 | 69 | 62.9 | 392 | reference (exit 132) |
| memory_args | B | default | 126.6 | 296.0 | 172 | 62.8 | 392 | reference (exit 132) |
| memory_args | C | default | 153.5 | 22.0 | 144 | 57.0 | 392 | match (exit 132) |
| map_lookup | A | speed | 216.9 | 220.2 | 25 | 2.0 | 1916 | match (exit 0) |
| map_lookup | A | default | 99.7 | 224.7 | 64 | 2.0 | 1864 | match (exit 0) |
| map_lookup | B | speed | 373.7 | 251.7 | 63 | 1.8 | 392 | match (exit 0) |
| map_lookup | B | default | 131.4 | 287.0 | 166 | 1.8 | 392 | match (exit 0) |
| map_lookup | C | default | 131.5 | 19.8 | 112 | 1.8 | 392 | match (exit 0) |

Binary sizes are in KB (1024 bytes). Peak RSS for compilation is in MB.

## Summary

- odinc compiles small programs about as fast as the official default build (about 120 ms each) and uses about 19 MB of peak memory against about 280 to 300 MB for B; on hello_fmt it is the slowest compile at 717 ms against 214 ms for B default.
- Without optimization, odinc's binaries run compute loops 3 to 8 times slower than the official `-o:speed` builds (fib 61.5 ms against 18.5 to 21.5 ms; loops 110.5 ms against 13 ms; sieve 74.8 ms against 17.5 to 18.6 ms). Against B default, odinc is slower on fib (61.5 ms against 42.1 ms) and faster on loops (110.5 ms against 132.1 ms), and close on sieve (74.8 ms against 81.7 ms).
- The mise-installed odin (A) fails the check on `memory_args` (exit 134 and 139 against 132 for B), so A is not a reliable reference for that fixture; B and odinc agree with each other on all six programs.
