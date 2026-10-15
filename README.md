# OpenZFS allocator and crypto review evidence

Source, reproduction commands and captured results for these independent changes:

Fetch the candidate branches from `Zaczero/zfs` into the checkout used for reproduction:

```sh
git fetch https://github.com/Zaczero/zfs \
    fix/spl-kvmalloc-speculation perf/gcm-input-reservation \
    fix/aes-null-parameters fix/gcm-hash-table-cleanup
```

| Change | Base | Candidate |
|---|---|---|
| SPL speculative physical allocation | `22013c3917f33c915e5be7b990cc9ba9c85fd3f4` | `d861d36dca5623c2e2d8371efb3cb58226672481` |
| GCM input reservation | same | `71993c7db7ed7429cd37f3174fbe8043bf316c7b` |
| AES missing-parameter admission | same | `5f974a24a8bce4718c987be493117c3f085dd6dc` |
| Accelerated GCM hash-table cleanup | same | `7ebcb6b13d43caf6a4417f296aecb9116bbe09f8` |

- [Allocator reproduction and results](allocator/README.md): actual kernel allocations, constrained masks, fragmentation and reclaimable memory pressure.
- [Crypto reproduction and results](crypto/README.md): native libzpool allocation observation, hash-table wiping, known answers and a scatter-output negative control.
- [Figure source and measurements](figures/README.md).

The kernel modules, binaries, guest disk images and initramfs archives are generated locally, not distributed here. Runtime checks were performed in disposable QEMU guests.
