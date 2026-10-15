#!/usr/bin/env python3
"""Pack a minimal guest with the supplied kernel's block/filesystem drivers."""
import argparse
import gzip
import lzma
import os
from pathlib import Path
import shutil
import subprocess

p = argparse.ArgumentParser()
p.add_argument("root")
p.add_argument("busybox")
p.add_argument("module_dir")
p.add_argument("drivers", help="ordered module paths, one per line")
p.add_argument("output")
a = p.parse_args()
applets = set(subprocess.check_output(
    [a.busybox, "--list"], text=True).splitlines())
assert {"sh", "mount", "mkdir", "insmod", "rmmod", "dd", "cat", "uname",
        "poweroff"} <= applets, "a full-featured static BusyBox is required"
root = Path(a.root)
root.mkdir()
for directory in ["bin", "dev", "proc", "sys", "modules"]:
    (root / directory).mkdir()
shutil.copy(a.busybox, root / "bin/busybox")
(root / "bin/sh").symlink_to("busybox")
shutil.copy(Path(__file__).with_name("allocator-init"), root / "init")
(root / "init").chmod(0o755)
for i, name in enumerate(dict.fromkeys(Path(a.drivers).read_text().splitlines())):
    path = Path(name)
    data = path.read_bytes()
    if path.suffix == ".xz":
        data = lzma.decompress(data)
    (root / "modules" / f"{i:02}.ko").write_bytes(data)
for name in ["allocator-bench.ko", "allocator-pressure.ko"]:
    shutil.copy(Path(a.module_dir) / name, root / name)
entries = [b"."] + [os.fsencode(str(path.relative_to(root)))
                    for path in sorted(root.rglob("*"))]
archive = subprocess.check_output(
    ["cpio", "--null", "--create", "--format=newc"],
    input=b"\0".join(entries) + b"\0", cwd=root)
Path(a.output).write_bytes(gzip.compress(archive, compresslevel=1, mtime=0))
