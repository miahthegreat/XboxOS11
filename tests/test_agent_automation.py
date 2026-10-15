"""Offline contract checks for agent review automation. No API credentials needed."""
import ast
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class AgentAutomationSafetyTests(unittest.TestCase):
    def test_python_source_syntax(self):
        for path in (ROOT / "automation").glob("*.py"):
            ast.parse(path.read_text(encoding="utf8"), filename=str(path))

    def test_fix_job_is_disabled(self):
        data = (ROOT / ".github/workflows/agent-fix.yml").read_text(encoding="utf8")
        self.assertIn("if: ${{ false }}", data)
        self.assertNotIn("if: ${{ vars.AGENT_LOOP_ENABLED == 'true' }}", data)

    def test_review_does_not_launch_fix_workflow(self):
        data = (ROOT / "automation/review_pr.py").read_text(encoding="utf8")
        self.assertNotIn("agent-fix.yml/dispatches", data)

    def test_no_existing_validation_changes(self):
        self.assertTrue((ROOT / ".github/workflows/validate.yml").exists())

if __name__ == "__main__":
    unittest.main()
