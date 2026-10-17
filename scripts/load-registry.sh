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

# Replaces faa.registry_master, faa.registry_dereg and faa.registry_models with
# the newest data/raw/registry/ReleasableAircraft_*.zip (or the zip given),
# refreshes the faa.aircraft_info snapshot, then reports how many BTS tail
# numbers it identifies.
#
#   scripts/load-registry.sh
#   scripts/load-registry.sh data/raw/registry/ReleasableAircraft_20261010.zip
#
# The FAA files are comma-separated with space-padded fields, a UTF-8 BOM and a
# trailing comma. Columns are read by position (see the FAA's ardata.pdf): each
# file is uploaded to the staging volume and read with read_files, every field
# a STRING (c1..cN), then trimmed and typed here. Owner street addresses and
# individuals' names are blanked before the files leave this machine.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
dbx_check_connection

zip="${1:-$(ls -1 "$PROJECT_DIR"/data/raw/registry/ReleasableAircraft_*.zip 2>/dev/null | tail -1)}"
[[ -f "$zip" ]] || { echo "No registry zip found; run fetch-registry.sh first." >&2; exit 1; }
echo "Loading $(basename "$zip")"

tmp=$(mktemp -d)
staged=()
trap 'rm -rf "$tmp"; [[ ${#staged[@]} -eq 0 ]] || dbx_rm "${staged[@]}" 2> /dev/null || true' EXIT

# stage FILE KEEP [AWK_CONDITION NAME_FIELD]: uploads FILE from the zip to the
# staging volume, without its header line, and with every field but those
# listed in KEEP blanked first (addresses and the like), and the owner's name
# in NAME_FIELD blanked unless AWK_CONDITION says it is an organisation.
# Prints the read_files call that reads it. The files never quote fields but do
# contain literal quotes ("B"-BALLOON), so quoting is off; rows have 14 to 40
# fields, the last empty, and missing ones are NULL.
stage() {
  unzip -p "$zip" "$1" | awk -F, -v OFS=, -v keep="$2" -v name="${4:-0}" "
    BEGIN { n = split(keep, k, \" \"); for (i = 1; i <= n; i++) kept[k[i]] = 1 }
    NR == 1 { next }
    {
      if (name && !(${3:-1})) \$name = \"\"
      for (i = 1; i <= NF; i++) if (!(i in kept)) \$i = \"\"
      print
    }" | gzip -1 > "$tmp/$1.csv.gz"
  dbx_put "$tmp/$1.csv.gz" "$DBX_VOLUME/registry/$1.csv.gz"
  staged+=("$DBX_VOLUME/registry/$1.csv.gz")
  rm "$tmp/$1.csv.gz"
}
read_files() {
  local schema; schema=$(for i in $(seq 1 40); do printf 'c%d STRING, ' "$i"; done)
  echo "read_files('$DBX_VOLUME/registry/$1.csv.gz', format => 'csv', header => false,
                   schema => '${schema%, }', quote => '', mode => 'PERMISSIVE')"
}
t() { echo "coalesce(trim($1), '')"; }
d() { echo "try_to_date(trim($1), 'yyyyMMdd')"; }
year() { echo "nullif(try_cast(trim($1) AS INT), 0)"; }
int() { echo "try_cast(trim($1) AS INT)"; }
# Organisation registrant types; 1 (individual) and 4 (co-owned) are people.
ORG="trim(c6) IN ('2', '3', '5', '7', '8', '9')"

stage MASTER.txt "1 2 3 4 5 6 7 16 17 18 19 20 21 24 30 34" "\$6 ~ /^ *[235789] *\$/" 7
dbx_run "
  INSERT OVERWRITE faa.registry_master
  SELECT concat('N', $(t c1)), $(t c2), $(t c3), $(t c4), $(year c5),
         $(t c6), if($ORG, $(t c7), ''), $(t c18), $(t c19), $(t c20), $(t c21), $(t c34),
         $(d c24), $(d c17), $(d c16), $(d c30)
  FROM $(read_files MASTER.txt)"

# DEREG has no registrant type, so names are kept only when they look like an
# organisation (a company suffix such as INC/LLC/CORP/BANK/AIRLINES). TRUST is
# deliberately not one: personal family trusts carry an individual's name.
stage DEREG.txt "1 2 3 4 5 11 12 13 17 18 22 38" \
  "\$5 ~ /(^|[^A-Z])(INC|LLC|CORP|CORPORATION|CO|COMPANY|LTD|BANK|AIRLINES?|AIRWAYS|LEASING|AVIATION|GOVERNMENT)([^A-Z]|\$)/" 5
dbx_run "
  INSERT OVERWRITE faa.registry_dereg
  SELECT concat('N', $(t c1)), $(t c2), $(t c3), $(t c11), $(year c12), $(t c4),
         if(trim(c5) RLIKE r'\b(INC|LLC|CORP|CORPORATION|CO|COMPANY|LTD|BANK|AIRLINES?|AIRWAYS|LEASING|AVIATION|GOVERNMENT)\b',
            trim(c5), ''),
         $(t c13), $(d c17), $(d c18), $(d c22), $(t c38)
  FROM $(read_files DEREG.txt)"

stage ACFTREF.txt "1 2 3 4 5 6 8 9 10 11"
dbx_run "
  INSERT OVERWRITE faa.registry_models
  SELECT $(t c1), $(t c2), $(t c3), $(t c4), $(t c5), $(t c6),
         $(int c8), $(int c9), $(t c10), $(int c11)
  FROM $(read_files ACFTREF.txt)"

dbx_run "
  INSERT OVERWRITE faa.aircraft_info
  SELECT tail, registered, make_model, year_mfr, seats, registrant, cancel_date FROM faa.aircraft"

dbx_query "SELECT 'registry_master' AS t, count(*) AS n FROM faa.registry_master
           UNION ALL SELECT 'registry_dereg', count(*) FROM faa.registry_dereg
           UNION ALL SELECT 'registry_models', count(*) FROM faa.registry_models
           UNION ALL SELECT 'aircraft_info', count(*) FROM faa.aircraft_info"
echo "BTS tail numbers identified:"
dbx_query "
  SELECT count(*) AS tails, count(a.tail) AS identified, count_if(a.registered = 1) AS currently_registered,
         round(100 * count(a.tail) / count(*), 1) AS pct
  FROM (SELECT DISTINCT tail FROM faa.ontime WHERE tail != '') AS o
  LEFT JOIN faa.aircraft_info AS a ON a.tail = o.tail"
