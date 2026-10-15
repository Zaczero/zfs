from pathlib import Path
import json
import re
import statistics
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

root = Path(__file__).parent
plt.rcParams.update({
    "font.size": 11, "axes.spines.top": False, "axes.spines.right": False,
    "figure.facecolor": "white", "axes.facecolor": "white",
})
colors = ["#0072b2", "#d55e00"]
styles = ["-", "--"]
raw = []
for run in ["allocator-refined", "allocator-control-0", "allocator-control-1"]:
    text = (root / f"{run}.log").read_text().rsplit("ALLOC_RESULT 0", 2)[-2]
    for line in text.splitlines():
        if "ALLOC_BENCH," not in line:
            continue
        row = line.split("ALLOC_BENCH,", 1)[1].split(",")
        raw.append(dict(run=run, fixture=row[0], size=int(row[2]),
                        arm=int(row[1]), us=int(row[5])/1000))
fig, axes = plt.subplots(1, 2, figsize=(11, 4.8), sharey=True)
panels = [
    ("unfragmented", False, "Contiguous memory available"),
    ("fragmented", False, "Fragmented memory"),
]
for ax, (fixture, control, title) in zip(axes, panels):
    for arm in [0, 1]:
        values = sorted(r["us"] for r in raw if r["fixture"] == fixture
                        and r["size"] == 1048576 and r["arm"] == arm
                        and (r["run"] == "allocator-control-1") == control)
        label = (["Baseline A", "Baseline B"] if control else ["Before", "After"])[arm]
        ax.step([50] + values + [2000],
                [0] + [100*(i+1)/len(values) for i in range(len(values))] + [100],
                where="post", color=colors[arm], linestyle=styles[arm],
                linewidth=2.5, label=label)
    ax.set_xscale("log")
    ax.set_xlim(50, 2000)
    ax.set_xticks([50, 100, 200, 500, 1000, 2000],
                 ["50", "100", "200", "500", "1,000", "2,000"])
    ax.set_ylim(0, 103)
    ax.set_title(title, fontsize=12)
    ax.set_xlabel("Allocate, write and free 1 MiB (µs, log scale)")
    ax.grid(alpha=.18)
    ax.legend(frameon=False, loc="lower right")
axes[0].set_ylabel("Allocations completed within this latency (%)")
fig.suptitle("SPL: avoiding optional reclaim reduces allocation latency under fragmentation",
             fontsize=14)
fig.text(.5, .02,
         "Linux 6.1 x86-64 guest · 1 MiB allocation/write/free · empirical cumulative distributions\n"
         "32 observations per variant. Physical-attempt reclaim in fragmented memory: before 32/32, after 0/32 allocations.",
         ha="center", fontsize=9)
fig.tight_layout(rect=[0, .13, 1, .92])
fig.savefig(root / "allocator-latency-ecdf.png", dpi=180)
fig.savefig(root / "allocator-latency-ecdf.svg")

records = []
for size in [32768, 131072, 1048576]:
    for arm in ["base", "gcm"]:
        text = (root / f"work-{arm}-{size}.log").read_text()
        text = text.split("implementation=generic\n", 1)[1].split(
            "implementation=avx", 1)[0]
        for layout in ["raw", "split", "fragmented"]:
            match = re.search(
                rf"^{layout} rc=0 allocations=(\d+) large=\d+ bytes=(\d+) peak=(\d+) leaked=0$",
                text, re.M)
            assert match, (arm, size, layout)
            count, allocated, peak = map(int, match.groups())
            records.append(dict(size=size, arm=arm, layout=layout,
                                count=count-1, bytes=allocated-512, peak=peak-512))
(root / "gcm-work.json").write_text(json.dumps(records, indent=2))
fig, axes = plt.subplots(1, 2, figsize=(11, 4.8))
for arm_index, arm in enumerate(["base", "gcm"]):
    rows = [r for r in records if r["arm"] == arm and r["layout"] == "split"]
    label = ["Before", "After"][arm_index]
    axes[0].plot([r["size"]/1024 for r in rows],
                 [r["peak"]/1024 for r in rows], color=colors[arm_index],
                 linewidth=2.5, linestyle=styles[arm_index],
                 marker=["o", "s"][arm_index], label=label)
    volume = []
    for chunk in [1048576, 262144, 65536, 16384, 4096]:
        text = (root / f"segments-{arm}-{chunk}.log").read_text()
        text = text.split("implementation=generic\n", 1)[1].split(
            "implementation=avx", 1)[0]
        match = re.search(r"^fragmented rc=0 allocations=\d+ large=\d+ bytes=(\d+)", text, re.M)
        assert match
        volume.append((1048576//chunk+2, (int(match.group(1))-512)/1048576))
    axes[1].plot([r[0] for r in volume], [r[1] for r in volume],
                 color=colors[arm_index], linewidth=2.5,
                 linestyle=styles[arm_index], marker=["o", "s"][arm_index],
                 label=label)
axes[0].set_xticks([32, 128, 512, 1024], ["32", "128", "512", "1,024"])
axes[0].set_xlabel("Payload size (KiB)")
axes[0].set_title("Data + separate tag: peak staging")
axes[0].set_ylabel("Simultaneous staging allocation (KiB)")
axes[0].set_ylim(0, 2400)
axes[1].set_xscale("log", base=2)
axes[1].set_xticks([3, 6, 18, 66, 258], ["3", "6", "18", "66", "258"])
axes[1].set_xlabel("Input segments, including two tag fragments (log scale)")
axes[1].set_title("1 MiB payload: fragmentation amplifies work")
axes[1].set_ylabel("Staging bytes allocated per decrypt (MiB)")
axes[1].set_ylim(0, 150)
for ax in axes:
    ax.legend(frameon=False)
    ax.grid(axis="y", alpha=.15)
fig.suptitle("GCM input reservation removes repeated staging allocations", fontsize=14)
fig.text(.5, .02,
         "ICP AES-GCM decryption · measured staging allocations · 16-byte tag included; key schedule excluded\n"
         "Left: ordinary data/tag layout. Right: fixed 1 MiB payload split across more segments. Lines connect measured inputs.",
         ha="center", fontsize=9)
fig.tight_layout(rect=[0, .13, 1, .92])
fig.savefig(root / "gcm-staging-curves.png", dpi=180)
fig.savefig(root / "gcm-staging-curves.svg")
