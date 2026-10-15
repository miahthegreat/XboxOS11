#!/usr/bin/env python3
"""Validate same-repo, opt-in, fresh review without executing PR code."""
import json,os,urllib.request,pathlib

def api(path):
    req=urllib.request.Request("https://api.github.com"+path,headers={"Authorization":"Bearer "+os.environ["GH_TOKEN"],"Accept":"application/vnd.github+json","User-Agent":"xboxos11-fix-gate"})
    with urllib.request.urlopen(req,timeout=30) as resp:return json.load(resp)

repo=os.environ["REPOSITORY"];number=int(os.environ["PR_NUMBER"]);sha=os.environ["REVIEWED_SHA"]
policy=json.loads((pathlib.Path(__file__).parent/"agent-policy.json").read_text())
pr=api(f"/repos/{repo}/pulls/{number}")
assert pr["state"]=="open" and pr["head"]["sha"]==sha and pr["head"]["repo"]["full_name"]==repo, "Untrusted/stale PR"
assert pr["head"]["ref"] not in ("main","master") and not pr["head"]["ref"].startswith("automation/"),"Unsafe branch"
assert policy["optInLabel"] in {x["name"] for x in pr["labels"]},"PR not opted in"
comments=[]
for page in range(1,11):
    batch=api(f"/repos/{repo}/issues/{number}/comments?per_page=100&page={page}")
    comments+=batch
    if len(batch)<100:break
marker=f"<!-- agent-review:{sha}:CHANGES_REQUESTED -->"
matches=[c for c in comments if c["body"].startswith(marker) and c["user"]["login"]=="github-actions[bot]"]
assert len(matches)==1,"Review marker missing/duplicate"
cycles=sum(c["body"].startswith("<!-- agent-review:") and ":CHANGES_REQUESTED -->" in c["body"] for c in comments if c["user"]["login"]=="github-actions[bot]")
assert cycles<=policy["maxCycles"],"Review cycle limit"
files=api(f"/repos/{repo}/pulls/{number}/files?per_page=100")
def allowed(p):
    return any(p.startswith(x) for x in policy["allowedEditPrefixes"]) and not any(p.startswith(x) for x in policy["protectedPrefixes"]) and p not in policy["protectedFiles"]
assert all(allowed(x["filename"]) for x in files),"Protected PR edits"
pathlib.Path("control/review-feedback.json").write_text(json.dumps({"feedback":matches[0]["body"][:16000]}),encoding="utf-8")
with open(os.environ["GITHUB_OUTPUT"],"a") as f:f.write("branch="+pr["head"]["ref"]+"\n")
print("Validated trusted bot review and same-repo HEAD")
