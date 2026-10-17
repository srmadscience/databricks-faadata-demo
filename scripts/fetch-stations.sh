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

# Downloads the reference data that ties airports to weather stations into
# data/raw/stations/: IEM ASOS station metadata (one GeoJSON per state network)
# and the OurAirports airport list. Kept if already downloaded; otherwise taken
# from the project's mirror (GitHub Releases, see lib.sh) so that everyone gets
# the same snapshot. --refresh downloads the current versions from IEM and
# OurAirports instead.
#
#   scripts/fetch-stations.sh
#   scripts/fetch-stations.sh --refresh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEST="$PROJECT_DIR/data/raw/stations"
mkdir -p "$DEST"

if [[ "${1:-}" != --refresh ]]; then
  if [[ -f "$DEST/ourairports.csv" ]] && ls "$DEST"/*.geojson > /dev/null 2>&1; then
    echo "skip   stations (already downloaded; --refresh to fetch current versions)"
    exit 0
  fi
  if mirror_fetch "$(mirror_assets data-reference)" stations.tar.gz "$DEST.tar.gz"; then
    tar -xzf "$DEST.tar.gz" -C "$(dirname "$DEST")"
    rm "$DEST.tar.gz"
    echo "fetch  stations.tar.gz  (mirror): $(ls "$DEST"/*.geojson | wc -l | tr -d ' ') station networks and ourairports.csv"
    exit 0
  fi
fi
# US states plus the territories that appear in BTS data. (Saipan, SPN, has no
# IEM station in any network.)
NETWORKS="AK AL AR AZ CA CO CT DE FL GA HI IA ID IL IN KS KY LA MA MD ME MI MN MO MS MT
          NC ND NE NH NJ NM NV NY OH OK OR PA RI SC SD TN TX UT VA VT WA WI WV WY
          PR VI GU AS"

for st in $NETWORKS; do
  net="${st}_ASOS"
  rm -f "$DEST/$net.geojson"
  download "https://mesonet.agron.iastate.edu/geojson/network/$net.geojson" "$DEST/$net.geojson" \
    || echo "warn: no IEM network $net" >&2
  sleep 1   # be polite to IEM
done
echo "Fetched $(ls "$DEST"/*.geojson | wc -l | tr -d ' ') station networks"

rm -f "$DEST/ourairports.csv"
download "https://davidmegginson.github.io/ourairports-data/airports.csv" "$DEST/ourairports.csv"
echo "Fetched $(($(wc -l < "$DEST/ourairports.csv") - 1)) airports from OurAirports"
