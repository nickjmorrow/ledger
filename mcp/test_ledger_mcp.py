import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LEDGER_BIN = os.environ.get("LEDGER_BIN") or os.path.join(HERE, "..", "CLI", ".build", "release", "ledger")


@unittest.skipUnless(os.path.exists(LEDGER_BIN), "build the CLI first: swift build --package-path CLI -c release")
class McpTests(unittest.TestCase):
    def setUp(self):
        self.db = os.path.join(tempfile.mkdtemp(), "ledger.sqlite")
        env = dict(os.environ, LEDGER_DB=self.db, LEDGER_DEVICE="hub", LEDGER_BIN=LEDGER_BIN)
        self.p = subprocess.Popen([sys.executable, os.path.join(HERE, "ledger_mcp.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        self.n = 0

    def tearDown(self):
        self.p.stdin.close()
        self.p.wait()
        self.p.stdout.close()

    def call(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def tool(self, name, /, **args):
        r = self.call("tools/call", {"name": name, "arguments": args})["result"]
        return r["content"][0]["text"], r["isError"]

    def ok(self, name, /, **args):
        text, err = self.tool(name, **args)
        self.assertFalse(err, text)
        return json.loads(text)

    def test_handshake_and_tool_list(self):
        r = self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
        self.assertEqual(r["result"]["serverInfo"]["name"], "ledger")
        tools = self.call("tools/list")["result"]["tools"]
        names = {t["name"] for t in tools}
        self.assertEqual(names, {"ledger_issues", "ledger_issue", "ledger_create_issue", "ledger_edit_issue", "ledger_delete_issue",
                                 "ledger_labels", "ledger_projects", "ledger_cycles", "ledger_summary"})
        for t in tools:
            self.assertEqual(t["inputSchema"]["type"], "object")
            self.assertTrue(t["description"])
        self.assertEqual(self.call("tools/call", {"name": "nope", "arguments": {}})["result"]["isError"], True)

    def test_create_edit_list_delete_flow(self):
        self.ok("ledger_labels", name="Home", color="#6fd3a0")
        self.ok("ledger_projects", name="Garden")
        made = self.ok("ledger_create_issue", title="Buy soil", status="todo", priority="high", due="2026-11-20", labels=["Home"], project="Garden",
                       description="peat free")
        self.assertEqual(made["identifier"], "MOR-1")          # the hub numbers its own writes at once
        self.assertEqual((made["labelNames"], made["project"], made["priority"]), (["Home"], "Garden", 2))
        edited = self.ok("ledger_edit_issue", ref="MOR-1", status="today", add_labels=["Home"], due="none")
        self.assertEqual((edited["status"], edited.get("dueDate")), ("today", None))
        self.assertTrue(edited["startedAt"])
        self.assertEqual(len(self.ok("ledger_issues", status=["today"], label=["home"], search="soil")), 1)
        self.assertEqual(self.ok("ledger_issues", status=["done"]), [])
        self.assertEqual(self.ok("ledger_issue", ref="MOR-1")["title"], "Buy soil")
        summary = self.ok("ledger_summary")
        self.assertEqual(summary["counts"]["today"], 1)
        self.assertEqual(len(summary["today"]), 1)
        self.assertEqual(self.ok("ledger_edit_issue", ref="1", status="done")["status"], "done")
        self.assertEqual(self.ok("ledger_create_issue", title="Next")["identifier"], "MOR-2")
        self.assertEqual(len(self.ok("ledger_cycles")), 2)
        self.ok("ledger_delete_issue", ref="MOR-1")
        self.assertEqual([i["identifier"] for i in self.ok("ledger_issues")], ["MOR-2"])
        self.ok("ledger_labels", name="Home", delete=True)
        self.assertEqual(self.ok("ledger_labels"), [])

    def test_errors_are_reported_not_fatal(self):
        text, err = self.tool("ledger_create_issue", title="x", status="blocked")
        self.assertTrue(err)
        self.assertIn("status must be one of", json.loads(text)["error"])
        text, err = self.tool("ledger_edit_issue", ref="MOR-9", title="x")
        self.assertTrue(err)
        self.assertIn("no issue MOR-9", text)
        text, err = self.tool("ledger_create_issue")
        self.assertTrue(err)
        self.assertIn("title", text)
        text, err = self.tool("ledger_edit_issue", ref="MOR-9", title="--sneaky")
        self.assertIn("no issue", text)
        self.assertEqual(self.ok("ledger_issues"), [])


if __name__ == "__main__":
    unittest.main()
