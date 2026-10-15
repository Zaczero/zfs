# Figures and their measurements

`graphs.py` regenerates both figures from the adjacent raw logs:

```sh
uv run --with matplotlib graphs.py
```

The published PNGs are also present at the repository root.

## Allocation latency

`allocator-refined.log` and `allocator-control-0.log` are two before/after comparisons in a Linux 6.1.0-53-cloud-amd64 guest with 24 GiB RAM and 16 vCPUs. Each contains 16 observations per implementation per size and memory condition, interleaved in ABBA order. Each observation includes allocation, writing the complete buffer and freeing it.

For fragmented 1 MiB requests, baseline medians were 301.46 and 378.3635 µs; candidate medians were 115.083 and 99.993 µs. All 32 baseline physical attempts entered direct reclaim; none of the 32 candidate attempts did. Contiguous-memory medians were approximately 90–92 µs in both arms.

`allocator-control-1.log` runs the original implementation for both labels. It is retained as a comparison control, not shown in the main figure and not treated as a statistically established noise floor.

The logs contain cumulative kernel messages. The plotting script selects the final completed module invocation. The source at allocator revision `1e438acd719d4b8bbd449c14a51ac28049166cdf` produced these measurements; the current revision changes only comments relative to it.

## GCM allocation work

`work-{base,gcm}-*.log` records native public-API allocation measurements at 32 KiB, 128 KiB and 1 MiB payload sizes. `segments-*.log` holds payload size at 1 MiB while varying input segmentation. The figure reports staging allocation, excluding the separately observed key-schedule allocation.

These measurements compare base `22013c3917f33c915e5be7b990cc9ba9c85fd3f4` with GCM revision `abebb71d0afa72b2dc9a1113bdf77c56b2855582`. The current revision adds stronger tests and an assertion without changing the reservation algorithm.

The source-level deletion removes accumulated-prefix copying. The plotted values are requested allocation bytes and peak live requested bytes, not process RSS, crypto throughput or filesystem performance.
