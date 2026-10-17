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
# trailing comma. Columns are read by position (see the FAA's ardata.pdf), so
# every field arrives as a String (c1..cN) and is trimmed and typed here.
# Owner street addresses are never loaded; owner names only for organisations.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ch_check_connection

zip="${1:-$(ls -1 "$PROJECT_DIR"/data/raw/registry/ReleasableAircraft_*.zip 2>/dev/null | tail -1)}"
[[ -f "$zip" ]] || { echo "No registry zip found; run fetch-registry.sh first." >&2; exit 1; }
echo "Loading $(basename "$zip")"

cols() { local s="c1 String"; for i in $(seq 2 "$1"); do s+=", c$i String"; done; echo "$s"; }
# The files never quote fields but do contain literal quotes ("B"-BALLOON).
SKIP_HEADER="input_format_csv_skip_first_lines=1&format_csv_allow_double_quotes=0"
# Organisation registrant types; 1 (individual) and 4 (co-owned) are people.
ORG="trim(c6) IN ('2', '3', '5', '7', '8', '9')"
d() { echo "toDate32OrNull(concat(substring(trim($1), 1, 4), '-', substring(trim($1), 5, 2), '-', substring(trim($1), 7, 2)))"; }

ch_query "TRUNCATE TABLE faa.registry_master"
unzip -p "$zip" MASTER.txt | ch_insert "
  INSERT INTO faa.registry_master
  SELECT concat('N', trim(c1)), trim(c2), trim(c3), trim(c4), nullIf(toUInt16OrNull(trim(c5)), 0),
         trim(c6), if($ORG, trim(c7), ''), trim(c18), trim(c19), trim(c20), trim(c21), trim(c34),
         $(d c24), $(d c17), $(d c16), $(d c30)
  FROM input('$(cols 35)') FORMAT CSV" "$SKIP_HEADER"

ch_query "TRUNCATE TABLE faa.registry_dereg"
# DEREG has no registrant type, so names are kept only when they look like an
# organisation (a company suffix such as INC/LLC/CORP/BANK/AIRLINES). TRUST is
# deliberately not one: personal family trusts carry an individual's name.
unzip -p "$zip" DEREG.txt | ch_insert "
  INSERT INTO faa.registry_dereg
  SELECT concat('N', trim(c1)), trim(c2), trim(c3), trim(c11), nullIf(toUInt16OrNull(trim(c12)), 0), trim(c4),
         if(match(trim(c5), '\\\\b(INC|LLC|CORP|CORPORATION|CO|COMPANY|LTD|BANK|AIRLINES?|AIRWAYS|LEASING|AVIATION|GOVERNMENT)\\\\b'),
            trim(c5), ''),
         trim(c13), $(d c17), $(d c18), $(d c22), trim(c38)
  FROM input('$(cols 39)') FORMAT CSV" "$SKIP_HEADER"

ch_query "TRUNCATE TABLE faa.registry_models"
unzip -p "$zip" ACFTREF.txt | ch_insert "
  INSERT INTO faa.registry_models
  SELECT trim(c1), trim(c2), trim(c3), trim(c4), trim(c5), trim(c6),
         toUInt8OrNull(trim(c8)), toUInt16OrNull(trim(c9)), trim(c10), toUInt16OrNull(trim(c11))
  FROM input('$(cols 14)') FORMAT CSV" "$SKIP_HEADER"

ch_query "TRUNCATE TABLE faa.aircraft_info"
ch_query "INSERT INTO faa.aircraft_info
          SELECT tail, registered, make_model, year_mfr, seats, registrant, cancel_date FROM faa.aircraft"

ch_query "SELECT 'registry_master' AS t, count() FROM faa.registry_master
          UNION ALL SELECT 'registry_dereg', count() FROM faa.registry_dereg
          UNION ALL SELECT 'registry_models', count() FROM faa.registry_models
          UNION ALL SELECT 'aircraft_info', count() FROM faa.aircraft_info FORMAT PrettyCompact"
echo "BTS tail numbers identified:"
ch_query "
  SELECT count() AS tails, countIf(a.tail != '') AS identified, countIf(a.registered = 1) AS currently_registered,
         round(100 * identified / tails, 1) AS pct
  FROM (SELECT DISTINCT tail FROM faa.ontime WHERE tail != '') AS o
  LEFT JOIN faa.aircraft AS a ON a.tail = o.tail
  SETTINGS join_use_nulls = 0
  FORMAT PrettyCompact"
