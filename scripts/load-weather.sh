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
# They go first into faa.weather_load, each year directory uploaded as one
# file (one upload per station file would be far slower), and are then MERGEd
# into faa.weather on (station, valid): a report already there is replaced,
# so re-loading a year never duplicates it. Of a report that IEM lists twice
# (a few hundred a year), the most complete copy is kept: often one copy has no
# temperature, dew point, visibility or pressure.
#
#   scripts/load-weather.sh
#   scripts/load-weather.sh data/raw/weather/2025
set -euo pipefail
source "$(dirname "$0")/lib.sh"
dbx_check_connection
ensure_loader

paths=("$@")
[[ ${#paths[@]} -gt 0 ]] || paths=("$PROJECT_DIR"/data/raw/weather/[0-9][0-9][0-9][0-9])
[[ -e "${paths[0]}" ]] || { echo "No weather files found; run fetch-weather.sh first." >&2; exit 1; }

# IEM timestamps are UTC, "YYYY-MM-DD hh:mm"; the loader writes them in ISO 8601.
java -jar "$LOADER_JAR" load faa.weather_load --replace --combine --jobs "${LOAD_JOBS:-4}" "${paths[@]}"
echo "Merging into faa.weather"
dbx_run "
  MERGE INTO faa.weather AS w
  USING (SELECT * FROM faa.weather_load
         QUALIFY row_number() OVER (
           PARTITION BY station, valid
           ORDER BY int(tmpf IS NULL) + int(dwpf IS NULL) + int(vsby IS NULL) + int(alti IS NULL), length(metar) DESC, metar) = 1) AS l
  ON w.station = l.station AND w.valid = l.valid
  WHEN MATCHED THEN UPDATE SET *
  WHEN NOT MATCHED THEN INSERT *"
dbx_run "TRUNCATE TABLE faa.weather_load"
dbx_run "OPTIMIZE faa.weather"

dbx_query "SELECT year(valid) AS year, count(DISTINCT station) AS stations, count(*) AS observations FROM faa.weather GROUP BY year ORDER BY year"
