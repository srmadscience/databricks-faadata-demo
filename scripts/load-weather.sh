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

# Loads IEM CSVs from data/raw/weather/ (or the files/dirs given) into faa.weather.
# faa.weather is a ReplacingMergeTree keyed on (station, valid), so re-loading
# a file does not leave duplicates once ClickHouse merges. Each year directory
# goes in as one insert: one per station file would be slower, and would leave
# ClickHouse thousands of small parts to merge, as each file spans 12 partitions.
#
#   scripts/load-weather.sh
#   scripts/load-weather.sh data/raw/weather/2025
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ch_check_connection
ensure_loader

paths=("$@")
[[ ${#paths[@]} -gt 0 ]] || paths=("$PROJECT_DIR"/data/raw/weather/[0-9][0-9][0-9][0-9])
[[ -e "${paths[0]}" ]] || { echo "No weather files found; run fetch-weather.sh first." >&2; exit 1; }

# IEM timestamps are "YYYY-MM-DD hh:mm" (no seconds), hence best_effort parsing.
java -jar "$LOADER_JAR" load faa.weather --set date_time_input_format=best_effort --combine "${paths[@]}"

ch_query "SELECT toYear(valid) AS year, uniqExact(station) AS stations, count() AS observations FROM faa.weather GROUP BY year ORDER BY year FORMAT PrettyCompact"
