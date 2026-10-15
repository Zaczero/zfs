# SPL allocation checks

`extract_allocator.py` extracts `spl_kvmalloc()` from the pinned base and candidate source. It renames the functions, without transcribing their logic. Both harness modules compile those functions against the kernel being tested.

`allocator-bench.c` observes physical and virtual calls, their masks and task-local direct-reclaim entry. Its forced-failure cases replace only the physical allocation boundary; virtual fallback is real `__vmalloc()`. Its fragmentation cases use real physical allocations too. Allocation scopes use `memalloc_noio_save()` and are restored afterward.

`allocator-pressure.c` checks allocation/use/free progress under reclaimable pressure. It pins 65% of usable guest pages, then holds a batch totaling approximately one sixteenth of guest RAM. Before each run, userspace fills the page cache from a 512 MiB file. All returned buffers are checked for zero filling, written with a nonzero pattern, checked again and freed. Each run releases its pinned pages.

## Captured environment and results

The additional runs used disposable QEMU/KVM guests with 512 MiB RAM, four vCPUs and a read-only scratch ext4 disk:

| Kernel | Compiler | Config and full boot/results log |
|---|---|---|
| Debian 5.10.223 (`5.10.0-32-cloud-amd64`) | GCC 10.2 | `results/config-5.10`, `results/allocator-5.10.log` |
| Linux 7.2.9, using the deployment host's kernel image/configuration | GCC 15.3 | `results/config-7.2`, `results/allocator-7.2.log` |

Both completed the forced-failure/fragmentation checks with `ALLOC_RESULT 0`, all eight pressure runs with `PRESSURE_DONE rc=0`, and `VALIDATION_PASS`. Each kernel ran baseline and candidate at 8 KiB, 32 KiB, 128 KiB and 1 MiB.

At the start of pressure batches, free memory was approximately 10–14 MiB, while each batch retained approximately 28–30 MiB. Candidate physical attempts entered direct reclaim zero times. Real virtual fallback and direct reclaim within it were observed, including at small multipage sizes:

| Kernel | Candidate size | Allocations | Virtual fallbacks | Physical direct-reclaim entries | Virtual direct-reclaim entries |
|---|---:|---:|---:|---:|---:|
| 5.10.223 | 32 KiB | 949 | 28 | 0 | 7 |
| 5.10.223 | 128 KiB | 237 | 43 | 0 | 11 |
| 7.2.9 | 8 KiB | 3,650 | 8 | 0 | 11 |
| 7.2.9 | 32 KiB | 912 | 1 | 0 | 4 |

These are bounded forward-progress and path checks, not latency comparisons. Background reclaim can make a physical allocation succeed without entering direct reclaim. The fixture retains reclaimable cache; it does not claim progress under irreclaimable exhaustion or establish NUMA/cpuset placement behavior.

Linux 5.10 exercises the older vmalloc compatibility path; Linux 7.2.9 exercises the deployment kernel's allocator. These are extracted-helper tests, not full OpenZFS builds on those kernels. Full OpenZFS and encrypted-I/O checks were run in the separate Linux 6.1 guest.

## Reproduce

Use disposable guests for module execution. Required tools include matching kernel headers and modules, a C compiler, Python 3, cpio, QEMU/KVM, e2fsprogs, and a full-featured **static** BusyBox (`busybox-static` on Debian).

In a copy of this directory, extract the actual source and compile:

```sh
python3 extract_allocator.py /path/to/zfs \
    22013c3917f33c915e5be7b990cc9ba9c85fd3f4 \
    d861d36dca5623c2e2d8371efb3cb58226672481 allocator-body.inc
make -C /lib/modules/$KERNEL/build M="$PWD" CC="$CC" modules
```

Use GCC 10 for the captured Debian 5.10 headers and GCC 15 for the captured 7.2 headers. The makefile selects the GNU C dialect used by the extracted OpenZFS code. The build logs are included.

Create the ordered driver list for the selected kernel:

```sh
for module in virtio_blk virtio_pci ext4; do
    modprobe --show-depends -S "$KERNEL" "$module"
done | awk '/^insmod / {print $2}' > drivers.txt
```

For a kernel module tree outside `/lib/modules`, pass its root with `modprobe -d`. Built-in drivers require no entry. The initramfs builder deduplicates the list while preserving dependency order.

Prepare a scratch disk with deterministic nonzero file data:

```sh
mkdir cache-files
python3 - <<'PY'
with open("cache-files/payload", "wb") as f:
    for _ in range(8192):
        f.write(b"\x53" * 65536)
PY
truncate -s 700M page-cache.img
mkfs.ext4 -q -F -O ^orphan_file -d cache-files page-cache.img
work=$(mktemp -d)
python3 make-initrd.py "$work/root" /path/to/static/busybox \
    "$PWD" drivers.txt "$work/initrd.gz"
timeout --signal=TERM --kill-after=5 180 \
    qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 512 \
    -kernel /boot/vmlinuz-$KERNEL -initrd "$work/initrd.gz" \
    -append 'console=ttyS0 panic=1' \
    -drive file=page-cache.img,if=virtio,format=raw,readonly=on \
    -display none -serial stdio -no-reboot > results.log 2>&1
```

QEMU exiting successfully is not itself a test verdict. Require `VALIDATION_PASS`, no `VALIDATION_FAIL`, `ALLOC_RESULT 0`, and eight `PRESSURE_DONE rc=0` records. The outer deadline terminates a stalled guest independently of kernel progress.

The boot script powers the guest off when complete. To reproduce the original 6.1 latency experiment, use a 24 GiB/16-vCPU guest and load `allocator-bench.ko` twice normally and once with `control=1`; the latter runs the original function for both labels. The [figure notes](../figures/README.md) describe the retained observations and scope.
