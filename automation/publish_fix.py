#!/usr/bin/env python3
"""Independent path and lease gate before any agent-authored commit."""
import base64,json,os,pathlib,subprocess,sys
policy=json.load(open(pathlib.Path(__file__).resolve().parent / "agent-policy.json"))
def run(*args): return subprocess.check_output(["git",*args],text=True).strip()
def safe(path):
    p=path.replace("\\","/")
    if p.startswith("/") or ".." in pathlib.PurePosixPath(p).parts: return False
    if any(p.startswith(prefix) for prefix in policy["protectedPrefixes"]): return False
    if p in policy["protectedFiles"]: return False
    return any(p.startswith(prefix) for prefix in policy["allowedEditPrefixes"])
# Include untracked files and detect deletions, renames and modifications.
files=[line[3:] for line in run("status","--porcelain=v1","--untracked-files=all").splitlines() if line]
if not files:
    print("Cursor produced no changes."); sys.exit(0)
if len(files)>policy["maxChangedFiles"] or any(not safe(p) for p in files):
    raise RuntimeError("Agent attempted a protected or excessive file change: "+repr(files))
if run("rev-parse","HEAD")!=os.environ["EXPECTED_SHA"]:
    raise RuntimeError("Unexpected local commit")
branch=os.environ["BRANCH"]
remote=run("ls-remote","origin",f"refs/heads/{branch}").split()
if not remote or remote[0]!=os.environ["EXPECTED_SHA"]:
    raise RuntimeError("Remote branch moved; discard agent result")
subprocess.run(["git","add","--",*files],check=True)
staged=run("diff","--cached","--name-only").splitlines()
if any(not safe(p) for p in staged): raise RuntimeError("Protected staged file")
subprocess.run(["git","config","user.name","xboxos11-agent"],check=True)
subprocess.run(["git","config","user.email","xboxos11-agent@users.noreply.github.com"],check=True)
subprocess.run(["git","commit","-m","fix: address reviewed agent findings"],check=True)
token=os.environ["GH_TOKEN"]
auth=base64.b64encode(("x-access-token:"+token).encode()).decode()
subprocess.run(["git","-c","http.https://github.com/.extraheader=AUTHORIZATION: basic "+auth,
                "push","origin",f"HEAD:refs/heads/{branch}"],check=True)
print("Published scoped fix; Validate will rerun.")
