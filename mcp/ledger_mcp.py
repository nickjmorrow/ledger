#!/usr/bin/env python3
"""Ledger MCP server (stdio). A thin wrapper: every tool runs the `ledger` CLI, so the CLI and Claude behave identically.

Environment: LEDGER_DB (database file, default ~/Library/Application Support/Ledger/ledger.sqlite), LEDGER_DEVICE (this database's device
name; the hub's is `hub`), LEDGER_BIN (path to ledger, default `ledger` on PATH or ~/.local/bin/ledger), LEDGER_AUTOSYNC=0 to skip syncing.
"""
import json
import os
import shutil
import subprocess
import sys

PROTOCOL = "2025-06-18"
LEDGER = os.environ.get("LEDGER_BIN") or shutil.which("ledger") or os.path.expanduser("~/.local/bin/ledger")

INSTRUCTIONS = (
    "Ledger is the user's task tracker (it replaces Linear): issues with a MOR-n number, status, priority, due date, labels, project, cycle, sub-issues and recurrence. "
    "Statuses are inbox, todo, today, done, canceled, duplicate. Priority is none, urgent, high, medium or low. Labels and projects are given by name. "
    "New issues land in the current cycle unless cycle is 'none'. Give due dates as YYYY-MM-DD and only when there is a real deadline. "
    "To clear a field when editing, pass 'none' (for labels pass an empty list). Completing a recurring issue creates the next one automatically. "
    "Changes sync to the hub; deleted issues are gone for good, so confirm before deleting."
)


def S(desc, **props):
    def one(v):
        d = {"type": v[0], "description": v[1]}
        if v[0] == "array":
            d["items"] = {"type": "string"}
        return d
    return ({"type": "object", "properties": {k: one(v) for k, v in props.items()},
             "required": [k for k, v in props.items() if len(v) < 3], "additionalProperties": False}, desc)


def opt(args, flag, value):
    # "--flag=value" so a value that starts with "-" is not mistaken for another option
    return args + [f"{flag}={value}"] if value not in (None, "") else args


ISSUE_FIELDS = dict(
    status=("string", "inbox, todo, today, done, canceled or duplicate", "opt"),
    priority=("string", "none, urgent, high, medium or low", "opt"),
    due=("string", "Due date YYYY-MM-DD, or 'none' to clear", "opt"),
    labels=("array", "Label names (on edit this replaces the labels; [] clears them)", "opt"),
    add_labels=("array", "Label names to add", "opt"),
    remove_labels=("array", "Label names to remove", "opt"),
    project=("string", "Project name, or 'none'", "opt"),
    parent=("string", "Parent issue like MOR-12, or 'none'", "opt"),
    cycle=("string", "Cycle number or 'current', or 'none'", "opt"),
    description=("string", "Markdown description", "opt"),
    recur=("string", "Repeat after completing: day:N, week:N or month:N, or 'none'", "opt"),
)
JSON_KEYS = {"add_labels": "addLabels", "remove_labels": "removeLabels"}


def issue_json(a, extra=()):
    body = {JSON_KEYS.get(k, k): a[k] for k in (*ISSUE_FIELDS, *extra) if a.get(k) is not None}
    return ["--json", json.dumps(body)]


def put_named(kind, a, fields):
    """labels/projects: list, or create/update/delete the one called `name`."""
    if not a.get("name"):
        return [kind, "list"]
    if a.get("delete"):
        return [kind, "delete", a["name"]]
    args = [kind, "put", a["name"]]
    for flag, key in fields:
        args = opt(args, flag, a.get(key))
    return args


# name -> (schema, description, argv builder). Builders return the arguments after `ledger`.
TOOLS = {
    "ledger_issues": (*S("List issues (manual order, newest first), optionally filtered. Open work is status inbox, todo or today. Use search for words in title or description.",
                        status=("array", "Statuses to keep", "opt"), label=("array", "Label names (any of)", "opt"), priority=("array", "Priorities to keep", "opt"),
                        project=("string", "Project name", "opt"), cycle=("string", "Cycle number or 'current'", "opt"), parent=("string", "Parent issue, like MOR-12", "opt"),
                        due_before=("string", "Due on or before YYYY-MM-DD", "opt"), search=("string", "Words to find", "opt"),
                        archived=("boolean", "Include archived issues", "opt"), limit=("integer", "Most issues (default 100)", "opt")),
                     lambda a: ["issue", "list"] + [x for k, flag in (("status", "--status"), ("label", "--label"), ("priority", "--priority")) for v in a.get(k) or [] for x in (flag, v)]
                     + [x for k, flag in (("project", "--project"), ("cycle", "--cycle"), ("parent", "--parent"), ("due_before", "--due-before"),
                                          ("search", "--search"), ("limit", "--limit")) for x in ([f"{flag}={a[k]}"] if a.get(k) not in (None, "") else [])]
                     + (["--archived"] if a.get("archived") else [])),
    "ledger_issue": (*S("One issue by number (MOR-12), with its sub-issues.", ref=("string", "MOR-12, 12 or an id")), lambda a: ["issue", "show", a["ref"]]),
    "ledger_create_issue": (*S("Create an issue. It goes into the current cycle unless cycle is given.", title=("string", "Title"), **ISSUE_FIELDS),
                           lambda a: ["issue", "create"] + issue_json(a, ("title",))),
    "ledger_edit_issue": (*S("Change fields of an issue, including its status (todo, today, done...). Only the given fields change.", ref=("string", "MOR-12, 12 or an id"),
                            title=("string", "New title", "opt"), **ISSUE_FIELDS),
                         lambda a: ["issue", "edit", a["ref"]] + issue_json(a, ("title",))),
    "ledger_delete_issue": (*S("Permanently delete an issue (its sub-issues are kept). Prefer status canceled unless the user asked to delete.", ref=("string", "MOR-12, 12 or an id")),
                           lambda a: ["issue", "delete", a["ref"]]),
    "ledger_labels": (*S("List the labels. With name, create that label or change its color or name; with delete=true remove it from every issue.",
                        name=("string", "Label to create, change or delete", "opt"), color=("string", "Color like #ffc83d", "opt"),
                        rename=("string", "New name", "opt"), delete=("boolean", "Delete the label", "opt")),
                    lambda a: put_named("label", a, (("--color", "color"), ("--rename", "rename")))),
    "ledger_projects": (*S("List the projects. With name, create that project or change it; with delete=true remove it.",
                          name=("string", "Project to create, change or delete", "opt"), color=("string", "Color like #ffc83d", "opt"),
                          description=("string", "Description", "opt"), status=("string", "Status, like active", "opt"),
                          rename=("string", "New name", "opt"), delete=("boolean", "Delete the project", "opt")),
                      lambda a: put_named("project", a, (("--color", "color"), ("--description", "description"), ("--status", "status"), ("--rename", "rename")))),
    "ledger_cycles": (*S("The two-week cycles, newest first (numbers continue Linear's)."), lambda a: ["cycle", "list"]),
    "ledger_summary": (*S("Issue counts per status, the issues in Today, and the current cycle with its open and done counts. Use it for 'what's on my plate'."),
                      lambda a: ["summary"]),
}

READ_ONLY = {"ledger_issues", "ledger_issue", "ledger_cycles", "ledger_summary"}
AUTOSYNC = os.environ.get("LEDGER_AUTOSYNC", "1") != "0"


def sync_quietly():
    """Keep this copy in step with the sync hub when sync is set up (a no-op, quickly, when it isn't, or when the hub is unreachable)."""
    if not AUTOSYNC:
        return
    try:
        subprocess.run([LEDGER, "sync"], capture_output=True, text=True, timeout=8)
    except (OSError, subprocess.TimeoutExpired):
        pass


def run_ledger(args):
    try:
        p = subprocess.run([LEDGER] + args, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"could not run ledger: {e}", True
    out = (p.stdout or "").strip()
    if p.returncode != 0:
        return (p.stderr.strip() or out or f"ledger exited {p.returncode}"), True
    return out or "ok", False


def run_tool(name, args):
    sync_quietly()                      # pick up what the phone and Mac did since the last call
    text, err = _run_tool(name, args)
    if name not in READ_ONLY and not err:
        sync_quietly()                  # and send what this call changed
    return text, err


def _run_tool(name, args):
    if name not in TOOLS:
        return f"unknown tool: {name}", True
    try:
        return run_ledger(TOOLS[name][2](args))
    except KeyError as e:
        return f"missing argument: {e}", True


TOOL_LIST = [{"name": n, "description": d, "inputSchema": s} for n, (s, d, _) in TOOLS.items()]


def handle(msg):
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:  # notification
        return None

    def ok(result): return {"jsonrpc": "2.0", "id": mid, "result": result}

    def err(code, text): return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": text}}

    if method == "initialize":
        return ok({"protocolVersion": PROTOCOL, "capabilities": {"tools": {}}, "serverInfo": {"name": "ledger", "version": "1.0"}, "instructions": INSTRUCTIONS})
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": TOOL_LIST})
    if method == "tools/call":
        params = msg.get("params") or {}
        text, is_err = run_tool(params.get("name", ""), params.get("arguments") or {})
        return ok({"content": [{"type": "text", "text": text}], "isError": is_err})
    return err(-32601, f"method not found: {method}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        try:
            reply = handle(msg)
        except Exception as e:  # never die on one bad request
            reply = {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32603, "message": str(e)}}
        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
