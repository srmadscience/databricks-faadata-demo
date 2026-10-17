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
# Each file holds exactly one month, and that month's partition is dropped
# before loading, so re-running never duplicates flights.
#
#   scripts/load-flights.sh
#   scripts/load-flights.sh data/raw/flights/ontime_2025_06.zip
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ch_check_connection
ensure_loader

files=("$@")
[[ ${#files[@]} -gt 0 ]] || files=("$PROJECT_DIR"/data/raw/flights/ontime_*.zip)
[[ -f "${files[0]}" ]] || { echo "No flight files found; run fetch-flights.sh first." >&2; exit 1; }

for f in "${files[@]}"; do
  [[ "$(basename "$f")" =~ ^ontime_([0-9]{4})_([0-9]{2})\.zip$ ]] \
    || { echo "error: unexpected file name $f" >&2; exit 1; }
  ch_query "ALTER TABLE faa.ontime DROP PARTITION ${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
done
# --binary parses the CSV here and sends ClickHouse ready-made columns, which
# costs the server about a tenth of the CPU of parsing CSV itself; the loader
# then becomes the bottleneck, so it loads LOAD_JOBS (default 8) files at a time.
java -jar "$LOADER_JAR" load faa.ontime --binary --jobs "${LOAD_JOBS:-8}" "${files[@]}"

ch_query "SELECT toYYYYMM(FlightDate) AS month, count() AS flights FROM faa.ontime GROUP BY month ORDER BY month FORMAT PrettyCompact"
