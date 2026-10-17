# Copyright 2026 David Rolfe
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Runs SQL on a Databricks SQL warehouse, and copies files to and from Unity
Catalog volumes, with the REST APIs and nothing but the standard library.
Used by scripts/lib.sh; settings come from the environment it exports:
DATABRICKS_HOST, DATABRICKS_TOKEN, DATABRICKS_WAREHOUSE_ID, DATABRICKS_CATALOG.

Usage:
  python3 -I dbsql.py query [--format table|tsv|none] SQL   (SQL "-" reads stdin)
  python3 -I dbsql.py put LOCAL_FILE /Volumes/...
  python3 -I dbsql.py rm /Volumes/...
"""
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HOST = os.environ.get("DATABRICKS_HOST", "").removeprefix("https://").removeprefix("http://").rstrip("/")
TOKEN = os.environ.get("DATABRICKS_TOKEN", "")
WAREHOUSE = os.environ.get("DATABRICKS_WAREHOUSE_ID", "")
CATALOG = os.environ.get("DATABRICKS_CATALOG", "main")


def fail(message):
    print("error: " + message, file=sys.stderr)
    sys.exit(1)


def call(method, path, body=None, data=None, headers=None, attempts=4):
    """Calls the REST API; returns the parsed JSON response, or None if empty.
    Retries on server errors, rate limits and lost connections."""
    url = "https://" + HOST + urllib.parse.quote(path, safe="/?=&")
    hdrs = {"Authorization": "Bearer " + TOKEN, **(headers or {})}
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                text = response.read()
                return json.loads(text) if text else None
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            try:
                detail = json.loads(detail).get("message", detail)
            except ValueError:
                pass
            if e.code < 500 and e.code != 429 or attempt == attempts:
                fail(f"{method} {path}: HTTP {e.code}: {detail}")
            problem = f"HTTP {e.code}: {detail}"
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt == attempts:
                fail(f"{method} {path}: {e}")
            problem = str(e)
        print(f"warn: {method} {path}: {problem}; retrying", file=sys.stderr)
        time.sleep(2 ** attempt)


def execute(sql):
    """Runs one statement and returns (column names, rows), rows as lists of
    strings or None. Waits as long as the statement takes, and cancels it on
    Ctrl-C."""
    response = call("POST", "/api/2.0/sql/statements/", {
        "statement": sql,
        "warehouse_id": WAREHOUSE,
        "catalog": CATALOG,
        "wait_timeout": "30s",
        "on_wait_timeout": "CONTINUE",
        "disposition": "INLINE",
        "format": "JSON_ARRAY",
    })
    statement_id = response["statement_id"]

    def cancel(signum, frame):
        call("POST", f"/api/2.0/sql/statements/{statement_id}/cancel", attempts=1)
        fail("cancelled")
    previous = signal.signal(signal.SIGINT, cancel)
    try:
        pause = 0.5
        while response["status"]["state"] in ("PENDING", "RUNNING"):
            time.sleep(pause)
            pause = min(pause * 2, 5)
            response = call("GET", f"/api/2.0/sql/statements/{statement_id}")
    finally:
        signal.signal(signal.SIGINT, previous)
    status = response["status"]
    if status["state"] != "SUCCEEDED":
        error = status.get("error", {})
        fail(f"{status['state']}: {error.get('message', '')}".rstrip(": "))
    columns = [c["name"] for c in response.get("manifest", {}).get("schema", {}).get("columns", [])]
    rows = []
    result = response.get("result") or {}
    while True:
        rows.extend(result.get("data_array") or [])
        link = result.get("next_chunk_internal_link")
        if not link:
            break
        result = call("GET", link)
    return columns, rows


def is_number(value):
    try:
        float(value)
        return True
    except (TypeError, ValueError):
        return False


def print_table(columns, rows):
    """Prints rows aligned under their column names; numbers right-aligned."""
    if not columns:
        return
    cells = [["NULL" if v is None else v for v in row] for row in rows]
    widths = [max([len(c)] + [len(row[i]) for row in cells]) for i, c in enumerate(columns)]
    numeric = [bool(cells) and all(is_number(row[i]) or row[i] == "NULL" for row in cells)
               for i in range(len(columns))]

    def line(values):
        return " │ ".join(v.rjust(w) if n else v.ljust(w) for v, w, n in zip(values, widths, numeric)).rstrip()
    print(line(columns))
    print("─┼─".join("─" * w for w in widths))
    for row in cells:
        print(line(row))


def main(args):
    if not (HOST and TOKEN and WAREHOUSE):
        fail("DATABRICKS_HOST, DATABRICKS_TOKEN and DATABRICKS_WAREHOUSE_ID must be set (see scripts/lib.sh)")
    if not args:
        fail(__doc__)
    command, args = args[0], args[1:]
    if command == "query":
        fmt = "table"
        if args[:1] == ["--format"]:
            fmt, args = args[1], args[2:]
        if len(args) != 1:
            fail("query takes one SQL statement")
        sql = sys.stdin.read() if args[0] == "-" else args[0]
        columns, rows = execute(sql)
        if fmt == "table":
            print_table(columns, rows)
        elif fmt == "tsv":
            for row in rows:
                print("\t".join("" if v is None else v for v in row))
    elif command == "put" and len(args) == 2:
        with open(args[0], "rb") as f:
            call("PUT", "/api/2.0/fs/files" + args[1] + "?overwrite=true", data=f.read(),
                 headers={"Content-Type": "application/octet-stream"})
    elif command == "rm" and args:
        for path in args:
            call("DELETE", "/api/2.0/fs/files" + path)
    else:
        fail(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
