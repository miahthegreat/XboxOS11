"""Offline security and syntax checks for autonomous review loop."""
import ast,pathlib,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
def source(p):return (ROOT/p).read_text(encoding="utf8")
class AgentAutomationSafetyTests(unittest.TestCase):
    def test_python_parses(self):
        for path in (ROOT/"automation").glob("*.py"): ast.parse(path.read_text(encoding="utf8"),filename=str(path))
    def test_separate_job_credentials(self):
        flow=source(".github/workflows/agent-fix.yml")
        generate=flow.split("  generate-patch:",1)[1].split("  publish-scoped-patch:",1)[0]
        publish=flow.split("  publish-scoped-patch:",1)[1]
        self.assertNotIn("contents: write",generate)
        self.assertIn("contents: read",generate)
        self.assertIn("contents: write",publish)
        self.assertNotIn("CURSOR_API_KEY:",publish)
        self.assertIn("CURSOR_API_KEY:",generate)
    def test_review_and_fix_dispatch(self):
        self.assertIn("agent-fix.yml/dispatches",source("automation/review_pr.py"))
        self.assertIn("workflow_dispatch",source(".github/workflows/validate.yml"))
        self.assertIn("workflow_dispatch",source(".github/workflows/agent-review.yml"))
    def test_publisher_not_executing_pr_code(self):
        data=source("automation/publish_fix.py")
        self.assertIn("git\",\"apply",data)
        self.assertIn("core.hooksPath=/dev/null",data)
        self.assertNotIn('shell=True',data)
        self.assertIn("agent-policy.json",data)
    def test_no_credentials_in_agent_script(self):
        data=source("automation/run_cursor_fix.py")
        self.assertNotIn('GH_TOKEN',data)
        self.assertNotIn('git push',data)
if __name__=="__main__":unittest.main()
