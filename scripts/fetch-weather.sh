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

# Downloads IEM ASOS observations, one gzipped CSV per station per year, into
# data/raw/weather/YEAR/STATION.csv.gz. A year not downloaded yet is first
# unpacked from the project's mirror (GitHub Releases, see lib.sh), if it has
# that year. Then any station still missing is fetched from IEM: by default the
# stations for each year are those of the airports flown that year in
# faa.ontime, via faa.airport_station (so load flights and stations first).
# Existing files are kept; --refresh fetches every station again from IEM, e.g.
# to bring the current year up to date.
#
#   scripts/fetch-weather.sh 2025 2025
#   scripts/fetch-weather.sh 2025 2025 ORD JFK
#   scripts/fetch-weather.sh --refresh 2026 2026
set -euo pipefail
source "$(dirname "$0")/lib.sh"

refresh=0
[[ "${1:-}" == --refresh ]] && { refresh=1; shift; }
[[ $# -ge 2 ]] || { echo "usage: $0 [--refresh] FROM_YEAR TO_YEAR [STATION...]" >&2; exit 1; }
from=$1; to=$2; shift 2
given=("$@")
[[ ${#given[@]} -gt 0 ]] || ch_check_connection

DEST="$PROJECT_DIR/data/raw/weather"
MIRROR=""
[[ $refresh -eq 1 ]] || MIRROR=$(mirror_assets data-weather)
IEM="https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py"
# report_type 3/4 = routine + special METARs. trace=0.0001 keeps p01i numeric.
PARAMS="data=all&tz=Etc/UTC&format=onlycomma&latlon=yes&elev=yes&missing=empty&trace=0.0001&direct=no&report_type=3&report_type=4"

# Years not downloaded yet come from the mirror first, several at a time.
tars=()
for year in $(seq "$from" "$to"); do
  [[ -d "$DEST/$year" ]] || tars+=("weather_$year.tar")
done
[[ ${#tars[@]} -eq 0 ]] || mirror_fetch_many "$MIRROR" "$DEST" "${tars[@]}" > /dev/null

for year in $(seq "$from" "$to"); do
  if [[ -f "$DEST/weather_$year.tar" ]]; then
    tar -xf "$DEST/weather_$year.tar" -C "$DEST"
    rm "$DEST/weather_$year.tar"
    echo "$year: $(ls "$DEST/$year" | wc -l | tr -d ' ') stations from the mirror"
  fi
  if [[ ${#given[@]} -gt 0 ]]; then
    stations=("${given[@]}")
  else
    stations=($(ch_query "
      SELECT DISTINCT station FROM faa.airport_station
      WHERE airport IN (SELECT Origin FROM faa.ontime WHERE toYear(FlightDate) = $year
                        UNION DISTINCT
                        SELECT Dest FROM faa.ontime WHERE toYear(FlightDate) = $year)
      ORDER BY station"))
  fi
  echo "$year: ${#stations[@]} stations needed"

  for st in "${stations[@]}"; do
    target="$DEST/$year/$st.csv.gz"
    if [[ -f "$target" && $refresh -eq 0 ]]; then
      continue
    fi
    rm -f "$target"
    url="$IEM?station=$st&year1=$year&month1=1&day1=1&year2=$((year + 1))&month2=1&day2=1&$PARAMS"
    if download "$url" "${target%.gz}"; then
      echo "fetch  $year/$st.csv.gz  $(($(wc -l < "${target%.gz}") - 1)) obs"
      gzip -f "${target%.gz}"
    else
      rm -f "${target%.gz}.part"
      echo "warn: failed $year/$st" >&2
    fi
    sleep 1   # IEM asks for sequential, unhurried requests
  done
done
