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

# Publishes data/raw/ as GitHub Releases on $DATA_REPO (this repository by
# default): the public mirror that the fetch scripts try before the original
# sources. Uploads only files that are new or have changed, comparing SHA-256s
# with what each release already holds, so re-run it after fetching more data.
# Needs the gh CLI, logged in with write access to the repository.
#
#   scripts/publish-data.sh                    everything
#   scripts/publish-data.sh flights weather    some of: flights weather reference
#   DRY_RUN=1 scripts/publish-data.sh          list what would be uploaded
#
# Releases (git tags), each holding files named as below:
#   data-flights    ontime_YYYY_MM.zip       BTS, exactly as downloaded
#   data-weather    weather_YYYY.tar         that year's YYYY/STATION.csv.gz files
#   data-reference  stations.tar.gz          IEM station networks + OurAirports
#                   ReleasableAircraft_YYYYMMDD.zip   FAA registry, as downloaded
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ "$DATA_REPO" != none ]] || { echo "error: DATA_REPO=none" >&2; exit 1; }
[[ "${DRY_RUN:-0}" == 1 ]] || gh auth status > /dev/null || { echo "error: gh is not logged in" >&2; exit 1; }
# Authenticated listing avoids GitHub's 60-requests-per-hour anonymous limit.
GITHUB_TOKEN=$(gh auth token 2>/dev/null || true); export GITHUB_TOKEN

RAW="$PROJECT_DIR/data/raw"
STAGE="$PROJECT_DIR/data/publish"   # archives built for upload (git-ignored)
mkdir -p "$STAGE"

CREDITS="Mirror of the raw data for https://github.com/$DATA_REPO, so the database can be rebuilt without re-downloading from the original sources. scripts/fetch-*.sh use it automatically; see data/README.md.

Each file's SHA-256 is shown by GitHub and checked by the fetch scripts."

# publish TAG TITLE NOTES FILE...: creates the release if needed, then uploads
# each file that it lacks or holds a different version of.
publish() {
  local tag="$1" title="$2" notes="$3"; shift 3
  local listing f name sum have new=0 changed=0 same=0
  if ! gh release view "$tag" -R "$DATA_REPO" > /dev/null 2>&1; then
    echo "create release $tag"
    [[ "${DRY_RUN:-0}" == 1 ]] || gh release create "$tag" -R "$DATA_REPO" --latest=false \
      --title "$title" --notes "$notes"$'\n\n'"$CREDITS"
  fi
  listing=$(mirror_assets "$tag")
  for f in "$@"; do
    name=$(basename "$f")
    sum=$(shasum -a 256 "$f" | cut -d' ' -f1)
    have=$(awk -F'\t' -v n="$name" '$1 == n {print $2}' <<< "$listing")
    if [[ "$have" == "$sum" ]]; then
      same=$((same + 1))
      continue
    fi
    if [[ -z "$have" ]]; then new=$((new + 1)); else changed=$((changed + 1)); fi
    echo "upload $tag/$name  ($(du -h "$f" | cut -f1 | tr -d ' ')${have:+, replaces older version})"
    [[ "${DRY_RUN:-0}" == 1 ]] || gh release upload "$tag" -R "$DATA_REPO" --clobber "$f"
  done
  echo "$tag: $new new, $changed changed, $same unchanged"
}

publish_flights() {
  local files=("$RAW"/flights/ontime_*.zip)
  [[ -f "${files[0]}" ]] || { echo "no flight files"; return; }
  publish data-flights "Data: BTS on-time flights" \
    "BTS Reporting Carrier On-Time Performance, one zip per month, as downloaded from https://www.transtats.bts.gov/ (US government work, public domain)." \
    "${files[@]}"
}

publish_weather() {
  local dir year files=()
  for dir in "$RAW"/weather/[0-9][0-9][0-9][0-9]; do
    [[ -d "$dir" ]] || continue
    year=$(basename "$dir")
    (cd "$RAW/weather" && python3 -I "$PROJECT_DIR/scripts/make_tar.py" "$STAGE/weather_$year.tar" . "$year"/*.csv.gz)
    files+=("$STAGE/weather_$year.tar")
  done
  [[ ${#files[@]} -gt 0 ]] || { echo "no weather files"; return; }
  publish data-weather "Data: IEM ASOS weather" \
    "Hourly and special METAR observations for the airports in the flight data, one tar per year of YEAR/STATION.csv.gz files, from the Iowa Environmental Mesonet, Iowa State University (https://mesonet.agron.iastate.edu/). Please credit IEM when using this data." \
    "${files[@]}"
}

publish_reference() {
  local files=()
  if [[ -f "$RAW/stations/ourairports.csv" ]]; then
    (cd "$RAW" && python3 -I "$PROJECT_DIR/scripts/make_tar.py" "$STAGE/stations.tar.gz" . stations/*.geojson stations/ourairports.csv)
    files+=("$STAGE/stations.tar.gz")
  fi
  for f in "$RAW"/registry/ReleasableAircraft_*.zip; do
    [[ -f "$f" ]] && files+=("$f")
  done
  [[ ${#files[@]} -gt 0 ]] || { echo "no reference files"; return; }
  publish data-reference "Data: stations, airports, aircraft registry" \
    "stations.tar.gz: IEM ASOS station metadata (Iowa Environmental Mesonet, https://mesonet.agron.iastate.edu/) and the OurAirports airport list (https://ourairports.com/data/, public domain). ReleasableAircraft_YYYYMMDD.zip: the FAA aircraft registry as downloaded on that date (https://registry.faa.gov/, public domain)." \
    "${files[@]}"
}

what=("$@")
[[ ${#what[@]} -gt 0 ]] || what=(flights weather reference)
for w in "${what[@]}"; do
  case "$w" in
    flights|weather|reference) "publish_$w" ;;
    *) echo "usage: $0 [flights] [weather] [reference]" >&2; exit 1 ;;
  esac
done
