"""Offline automation migration and safety contract checks."""
import ast
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

def source(path):
    return (ROOT / path).read_text(encoding="utf8")

class AgentAutomationSafetyTests(unittest.TestCase):
    def test_python_parses(self):
        for path in (ROOT / "automation").glob("*.py"):
            ast.parse(path.read_text(encoding="utf8"), filename=str(path))

    def test_separate_job_credentials(self):
        flow = source(".github/workflows/agent-fix.yml")
        generate = flow.split("  generate-patch:", 1)[1].split("  publish-scoped-patch:", 1)[0]
        publish = flow.split("  publish-scoped-patch:", 1)[1]
        self.assertIn("contents: read", generate)
        self.assertNotIn("contents: write", generate)
        self.assertIn("contents: write", publish)
        self.assertIn("CLAUDE_CODE_OAUTH_TOKEN:", generate)
        self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN:", publish)
        self.assertNotIn("CURSOR_API_KEY", flow)
        self.assertNotIn("cursor.com/install", flow)
        self.assertIn("vars.CLAUDE_LOOP_ENABLED == 'true'", generate)
        self.assertIn("vars.CLAUDE_LOOP_ENABLED == 'true'", source(".github/workflows/agent-review.yml"))

    def test_review_and_fix_dispatch(self):
        self.assertIn("agent-fix.yml/dispatches", source("automation/review_pr.py"))
        self.assertIn("workflow_dispatch", source(".github/workflows/validate.yml"))

    def test_publisher_is_separate(self):
        data = source("automation/publish_fix.py")
        self.assertIn('core.hooksPath=/dev/null', data)
        self.assertNotIn("shell=True", data)
        self.assertIn("agent-policy.json", data)

    def test_agent_script_no_github_write_token(self):
        data = source("automation/run_claude_fix.py")
        self.assertNotIn("GH_TOKEN", data)
        tree = ast.parse(data)
        self.assertFalse(any(
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "subprocess"
            and node.func.attr in ("Popen", "call", "check_call", "check_output", "run")
            and node.args and isinstance(node.args[0], (ast.List, ast.Tuple))
            and node.args[0].elts and isinstance(node.args[0].elts[0], ast.Constant)
            and node.args[0].elts[0].value in ("git", "gh")
            for node in ast.walk(tree)
        ), "Agent script must not invoke git or gh subprocesses")
        self.assertIn("--allowedTools", data)
        self.assertNotIn("--dangerously-skip-permissions", data)
        self.assertIn("CLAUDE_CODE_OAUTH_TOKEN", data)

if __name__ == "__main__":
    unittest.main()
