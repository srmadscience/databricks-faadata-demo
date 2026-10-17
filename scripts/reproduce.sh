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

# Rebuilds everything from scratch, in order: schema, flights and their
# per-aircraft summary, stations, weather, flights joined to weather, aircraft registry.
# Every step is idempotent, so this is also the way to extend the date range.
#
#   scripts/reproduce.sh 2025-01 2025-12
#   scripts/reproduce.sh --time "parallel downloads" 2016-01 2026-07
#
# --time COMMENT appends each step's duration, and the total, to
# testresults_load.csv, with the date, git commit, ClickHouse version and
# COMMENT, which says what changed since the last test. For a full-load test,
# start from an empty server (DROP DATABASE faa) and an empty data/raw/.
set -euo pipefail
cd "$(dirname "$0")"

time=0
if [[ "${1:-}" == --time ]]; then
  [[ -n "${2:-}" ]] || { echo "error: --time needs a comment saying what changed" >&2; exit 1; }
  time=1; comment=$2; shift 2
fi
[[ $# -eq 2 ]] || { echo "usage: $0 [--time COMMENT] FROM_YYYY-MM TO_YYYY-MM" >&2; exit 1; }

if [[ $time -eq 1 ]]; then
  source ./lib.sh
  RESULTS="$PROJECT_DIR/testresults_load.csv"
  [[ -f "$RESULTS" ]] || echo "run_start,git_commit,clickhouse_version,from,to,step,seconds,comment" > "$RESULTS"
  comment="\"${comment//\"/\"\"}\""   # CSV-quoted
  run_start=$(date '+%Y-%m-%dT%H:%M:%S%z')
  commit=$(git -C "$PROJECT_DIR" rev-parse --short HEAD)
  [[ -z "$(git -C "$PROJECT_DIR" status --porcelain -- . ":!testresults_load.csv")" ]] || commit+="-dirty"
  version=$(ch_query 'SELECT version()')
fi

# step SCRIPT [ARGS...]: runs one step, recording its duration with --time.
step() {
  local t0=$SECONDS
  "./$1" "${@:2}"
  [[ $time -eq 0 ]] || echo "$run_start,$commit,$version,$FROM,$TO,${1%.sh},$((SECONDS - t0)),$comment" >> "$RESULTS"
}

FROM=$1; TO=$2
step create-database.sh
step fetch-flights.sh "$FROM" "$TO"
step load-flights.sh
step build-tail-day.sh
step fetch-stations.sh
step load-stations.sh
step fetch-weather.sh "${FROM%-*}" "${TO%-*}"
step load-weather.sh
step build-flight-weather.sh
step fetch-registry.sh
step load-registry.sh
[[ $time -eq 0 ]] || echo "$run_start,$commit,$version,$FROM,$TO,total,$SECONDS,$comment" >> "$RESULTS"
