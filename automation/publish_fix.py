#!/usr/bin/env python3
"""Trusted publisher: do not run any code from a PR or from the agent."""
import base64,json,os,pathlib,subprocess,urllib.request
policy=json.loads((pathlib.Path(__file__).resolve().parent/"agent-policy.json").read_text())
repo=os.environ["REPOSITORY"];number=int(os.environ["PR_NUMBER"]);sha=os.environ["REVIEWED_SHA"]
branch=os.environ["BRANCH"];patch=pathlib.Path(os.environ["PATCH_PATH"]).resolve()
def api(path,method="GET",data=None):
    req=urllib.request.Request("https://api.github.com"+path,method=method,
      data=json.dumps(data).encode() if data is not None else None,
      headers={"Authorization":"Bearer "+os.environ["GH_TOKEN"],"Accept":"application/vnd.github+json","User-Agent":"xboxos11-publisher","Content-Type":"application/json"})
    with urllib.request.urlopen(req,timeout=35) as resp:
        raw=resp.read()
    return json.loads(raw) if raw else {}
def git(*args):
    return subprocess.check_output(["git","-c","core.hooksPath=/dev/null",*args],text=True).strip()
def safe(p):
    return (not p.startswith("/") and "\\" not in p and ".." not in pathlib.PurePosixPath(p).parts
      and any(p.startswith(prefix) for prefix in policy["allowedEditPrefixes"])
      and not any(p.startswith(prefix) for prefix in policy["protectedPrefixes"])
      and p not in policy["protectedFiles"])
pr=api(f"/repos/{repo}/pulls/{number}")
assert pr["state"]=="open" and pr["head"]["sha"]==sha and pr["head"]["ref"]==branch,"Stale target"
assert pr["head"]["repo"]["full_name"]==repo,"Fork denied"
assert policy["optInLabel"] in {x["name"] for x in pr["labels"]},"Opt-in removed"
assert git("rev-parse","HEAD")==sha and not git("status","--porcelain"),"Checkout drift"
raw=patch.read_bytes()
if not raw:
    print("No modifications");raise SystemExit(0)
assert len(raw)<=100000,"Oversized patch"
subprocess.run(["git","apply","--check","--",str(patch)],check=True)
subprocess.run(["git","apply","--",str(patch)],check=True)
changes=git("diff","--name-only","--no-ext-diff").splitlines()
assert changes and len(changes)<=policy["maxChangedFiles"] and all(safe(p) for p in changes),"Prohibited file change"
assert not git("diff","--summary"),"Mode or rename change"
for p in changes:
    assert git("ls-files","--stage","--",p).startswith("100644 "),"Not regular tracked file"
assert len(git("diff","--binary").encode())<=100000,"Oversized diff"
assert api(f"/repos/{repo}/pulls/{number}")["head"]["sha"]==sha,"Remote HEAD changed"
git("add","--",*changes)
git("config","user.name","xboxos11-agent")
git("config","user.email","xboxos11-agent@users.noreply.github.com")
git("commit","-m","fix: address reviewed agent findings")
encoded=base64.b64encode(("x-access-token:"+os.environ["GH_TOKEN"]).encode()).decode()
subprocess.run(["git","-c","http.https://github.com/.extraheader=AUTHORIZATION: basic "+encoded,
    "push","origin",f"HEAD:refs/heads/{branch}"],check=True)
# GitHub's built-in token cannot trigger a PR workflow on push; use explicit workflow_dispatch.
api(f"/repos/{repo}/actions/workflows/validate.yml/dispatches","POST",{"ref":branch})
print("Published scoped fix and dispatched Validate.")
