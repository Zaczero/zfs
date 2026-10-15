#!/usr/bin/env python3
"""Extract both actual helper bodies from pinned OpenZFS revisions."""
import argparse
import hashlib
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument("repo")
p.add_argument("base")
p.add_argument("candidate", help="commit or path to spl-kmem.c")
p.add_argument("output")
a = p.parse_args()
path = "module/os/linux/spl/spl-kmem.c"

def source(ref):
    if Path(ref).is_file():
        return Path(ref).read_text()
    return subprocess.check_output(
        ["git", "-C", a.repo, "show", f"{ref}:{path}"], text=True)

bodies = []
for label, ref in [("original", a.base), ("candidate", a.candidate)]:
    s = source(ref)
    start = s.index("void *\nspl_kvmalloc(")
    end = s.index("\n}\n", start) + 3
    body = s[start:end].replace("spl_kvmalloc(", f"{label}_kvmalloc(", 1)
    bodies.append(f"/* {ref}; source SHA256 "
                  f"{hashlib.sha256(s.encode()).hexdigest()} */\n{body}")
Path(a.output).write_text("\n".join(bodies))
