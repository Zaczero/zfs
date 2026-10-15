# Native ICP checks

The probes link the actual built `libzpool`, rather than a transcription of the crypto code. They require Linux x86-64 with glibc because allocation observation uses `__libc_malloc()` and `__libc_free()`. AVX/AVX2 cleanup checks report unsupported implementations explicitly.

## Reproduce

In a disposable guest, check out one of the pinned revisions in the [revision table](../README.md). Configure and build it using the project's normal dependencies:

```sh
./autogen.sh
./configure --with-config=user --enable-debug --without-python
make -j12 tests/zfs-tests/cmd/crypto_test
sh /path/to/evidence/crypto/run-userspace.sh "$PWD" /path/to/results
tests/zfs-tests/cmd/crypto_test -c tests/zfs-tests/tests/functional/crypto/aes_gcm_test.txt
tests/zfs-tests/cmd/crypto_test -c tests/zfs-tests/tests/functional/crypto/aes_ccm_test.txt
```

For a release build, use a separate build configured with `--disable-debug`. The probe makefile uses the selected build's include paths and libzpool flags. It does not modify production source or add symbols to it.

`run-userspace.sh` records configuration, source hashes, compilation output and probe results. A `cleanup.exit` of 1 is the expected negative result for revisions without the hash-table fix; 0 means that check passed, and 77 means no accelerated implementation was tested.

## What the probes observe

`allocation_probe.c` observes malloc/free only during each public `crypto_encrypt()` or `crypto_decrypt()` call. It records allocation count, requested bytes, peak live requested bytes and remaining live bytes. Deliberately reproduced leaks are released after recording them.

The cases cover contiguous input, separate data/tag vectors, fragmented input, authentication failure, tag-only input, short tags, insufficient output capacity, and input whose declared length exceeds its backing UIO. The last case first appends a nonempty prefix. Error cases check output preservation and descriptor fields. Neither RSS nor kernel allocation accounting is measured.

The missing-parameter cases cover CCM/GCM, encrypt/decrypt, and zero/expected parameter lengths with valid keys. The base leaks one allocation in each of the eight cases; the admission fix makes no allocation. The observed 512-byte size is a result for this build, not a portable assertion.

`cleanup_probe.c` invokes the native GCM initializer and cleanup with AES-NI key schedules. It obtains the table's actual requested allocation size from malloc observation, compares it with the recorded context length, and observes the allocation's contents immediately before free. The allocator fills the allocation with a nonzero sentinel so unused table storage is covered too.

| Native backend | Before: allocated / recorded bytes | Before: nonzero bytes at free | After: recorded bytes | After: nonzero bytes at free |
|---|---:|---:|---:|---:|
| AVX | 192 / 0 | 191 | 192 | 0 |
| AVX2/VAES | 256 / 0 | 255 | 256 | 0 |

## Scatter-output negative control

`scatter_mutant.c` replaces only `crypto_put_output_data()` through `LD_PRELOAD`. Its UIO writer finds the starting vector and then incorrectly performs a contiguous copy across vector boundaries. RAW output delegates to the real function.

Build it from the configured OpenZFS directory:

```sh
make -f Makefile -f /path/to/evidence/crypto/probe.mk \
    OUT=/path/to/results scatter-mutant
LD_PRELOAD=/path/to/results/scatter_mutant.so \
    tests/zfs-tests/cmd/crypto_test \
    -c tests/zfs-tests/tests/functional/crypto/aes_gcm_test.txt
```

The old test driver from `abebb71d0afa72b2dc9a1113bdf77c56b2855582` passes with this mutation. The updated driver fails its gap-canary assertion. For the captured comparison, both drivers loaded the same updated GCM library; only the test layout differed.

## Captured results

`results/debug/` and `results/release/` contain the baseline and three independent crypto candidates. The environment was Debian Linux 6.1.0-53-cloud-amd64 in QEMU/KVM, 16 vCPUs exposing AMD Ryzen 9 5950X features, 24 GiB RAM, GCC 12.2.0. Debug used `--enable-debug`; release used `--with-config=user --disable-debug`; both used `--without-python`.

- GCM reservation: 316 vectors across ten AES/GCM combinations, each in RAW and UIO layouts, for 6,320 executions per build. The additional input/output error cases also passed.
- CCM: 552 vectors across three implementations, for 1,656 executions per build.
- AES admission and hash-table cleanup: their existing known-answer drivers passed; the native probes separately exercised both accelerated GCM backends and all eight missing-parameter cases.
- `allocation.log` confirms no leaked staging allocation after truncated input, including the reservation's partially initialized buffer.
- Both functional ZTS scripts, `icp_aes_gcm` and `icp_aes_ccm`, passed for each independent candidate. Full debug `make checkstyle` passed.

Use `final-source.sha256` when present for the final test-driver revision. The AES release driver's final rerun is in `final-vectors-*.log`; its small output-buffer padding adjustment did not change either production source or the allocation-observer runs.

The pre-existing driver requested `avx2`, which is not a registered name. The GCM test update corrects it to `avx2-vaes`. Earlier “unsupported” output from that misspelling was not a hardware capability result.

The cleanup CCM test's first runner invocation collided with a timestamp-named result directory and did not execute; its record is retained as `zts-ccm-runner-collision.summary`. The subsequent `zts-ccm.summary` and detailed log record the completed pass.
