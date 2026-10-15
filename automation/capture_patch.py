#!/usr/bin/env python3
"""Produce a text patch as an inert artifact. No GitHub credentials."""
import pathlib,subprocess,sys
dest=pathlib.Path(sys.argv[1])
def git(*args):
    return subprocess.run(["git",*args],capture_output=True,text=True,check=True).stdout
changed=git("status","--porcelain=v1","--untracked-files=all")
if not changed:
    dest.write_text("",encoding="utf8");print("No candidate changes");sys.exit(0)
if any(line[:2]=="??" for line in changed.splitlines()):
    raise RuntimeError("New/untracked files require human review")
if any(line[:2].strip() not in ("M",) for line in changed.splitlines()):
    raise RuntimeError("Only modifications to existing regular files are supported")
patch=git("diff","--binary","--no-ext-diff")
if not patch or len(patch.encode())>100000:raise RuntimeError("Empty or oversized patch")
dest.write_text(patch,encoding="utf8")
print("Captured candidate patch bytes:",len(patch.encode()))
