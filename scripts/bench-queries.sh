#!/usr/bin/env bash
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

# Query performance test: runs randomly generated queries of one workload
# against the loaded database and prints latency percentiles, overall and by
# length of date range (see QueryBench.java).
#
#   scripts/bench-queries.sh flight-history --rate 20 --duration 60
#   scripts/bench-queries.sh --time "first query test" flight-history --threads 16
#
# Options, after the workload:
#   --rate Q       start Q queries a second (open loop); without it, each
#                  thread runs queries back to back, for the most the server can do
#   --threads N    queries in flight at once, at most (default 8)
#   --duration S   seconds to run for (default 60)
#   --seed N       repeat an earlier run's queries
#   --log FILE     one line per query: latency, rows, aircraft and dates
# --time COMMENT appends a summary to testresults_query.csv, with the date, git
# commit, ClickHouse version and COMMENT, which says what changed since the
# last test.
#
# Workloads:
#   flight-history  every flight of a random aircraft between two random dates,
#                   1 day to 10 years apart
set -euo pipefail
source "$(dirname "$0")/lib.sh"

record=()
if [[ "${1:-}" == --time ]]; then
  [[ -n "${2:-}" ]] || { echo "error: --time needs a comment saying what changed" >&2; exit 1; }
  commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD)
  [[ -z "$(git -C "$PROJECT_DIR" status --porcelain -- . ":!testresults_*.csv")" ]] || commit+="-dirty"
  record=(--results "$PROJECT_DIR/testresults_query.csv" --commit "$commit" --comment "$2")
  shift 2
fi
[[ $# -ge 1 ]] || { sed -n '/^# Query performance/,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 1; }

ensure_loader
java -jar "$LOADER_JAR" bench "$@" ${record[@]+"${record[@]}"}
