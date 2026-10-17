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

# Loads BTS zips from data/raw/flights/ (or the files given) into faa.ontime.
# Each file holds exactly one month, and the load replaces those months
# (INSERT ... REPLACE WHERE), all in one statement, so re-running never
# duplicates flights. OPTIMIZE then clusters the new rows by tail and date.
#
#   scripts/load-flights.sh
#   scripts/load-flights.sh data/raw/flights/ontime_2025_06.zip
set -euo pipefail
source "$(dirname "$0")/lib.sh"
dbx_check_connection
ensure_loader

files=("$@")
[[ ${#files[@]} -gt 0 ]] || files=("$PROJECT_DIR"/data/raw/flights/ontime_*.zip)
[[ -f "${files[0]}" ]] || { echo "No flight files found; run fetch-flights.sh first." >&2; exit 1; }

months=()
for f in "${files[@]}"; do
  [[ "$(basename "$f")" =~ ^ontime_([0-9]{4})_([0-9]{2})\.zip$ ]] \
    || { echo "error: unexpected file name $f" >&2; exit 1; }
  months+=("${BASH_REMATCH[1]}${BASH_REMATCH[2]}")
done
# The loader converts and uploads LOAD_JOBS (default 8) files at a time; the
# INSERT fails if a file holds a flight from a month its name doesn't say.
java -jar "$LOADER_JAR" load faa.ontime --jobs "${LOAD_JOBS:-8}" \
  --replace-where "$(months_where FlightDate "${months[@]}")" "${files[@]}"
echo "Clustering faa.ontime"
dbx_run "OPTIMIZE faa.ontime"

dbx_query "SELECT date_format(FlightDate, 'yyyy-MM') AS yyyy_mm, count(*) AS flights FROM faa.ontime GROUP BY 1 ORDER BY 1"
