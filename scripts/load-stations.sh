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

# Replaces faa.stations and faa.airports with the files in data/raw/stations/,
# then reports BTS airports that have no matching IEM station (no weather).
#
#   scripts/load-stations.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
dbx_check_connection
ensure_loader

files=("$PROJECT_DIR"/data/raw/stations/*.geojson)
[[ -f "${files[0]}" ]] || { echo "No station files found; run fetch-stations.sh first." >&2; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
python3 -I "$PROJECT_DIR/scripts/stations_to_csv.py" "${files[@]}" > "$tmp/stations.csv"
java -jar "$LOADER_JAR" load faa.stations --replace "$tmp/stations.csv"

# OurAirports has extra columns (links, keywords) that faa.airports leaves out;
# the loader matches columns by name and drops them.
java -jar "$LOADER_JAR" load faa.airports --replace "$PROJECT_DIR/data/raw/stations/ourairports.csv"

echo "BTS airports without an IEM station:"
dbx_query "
  SELECT airport, any_value(state) AS state, count(*) AS flights
  FROM (SELECT Origin AS airport, OriginState AS state FROM faa.ontime)
  WHERE airport NOT IN (SELECT airport FROM faa.airport_station)
  GROUP BY airport ORDER BY flights DESC"
