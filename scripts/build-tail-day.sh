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

# Rebuilds faa.tail_day (flights per aircraft per day) from faa.ontime, one
# month at a time, replacing each month's partition. Run after loading flights.
#
#   scripts/build-tail-day.sh            every month in faa.ontime
#   scripts/build-tail-day.sh 202501     just these months
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ch_check_connection

months=("$@")
[[ ${#months[@]} -gt 0 ]] || months=($(ch_query "SELECT DISTINCT toYYYYMM(FlightDate) FROM faa.ontime ORDER BY 1"))

for m in "${months[@]}"; do
  ch_query "ALTER TABLE faa.tail_day DROP PARTITION $m"
  ch_query "
    INSERT INTO faa.tail_day
    SELECT FlightDate, Reporting_Airline, tail,
           count(), countIf(Cancelled = 0),
           countIf(Cancelled = 1 AND CancellationCode = 'A'),
           countIf(Cancelled = 1 AND CancellationCode != 'A'),
           countIf(Diverted = 1),
           sum(ifNull(CarrierDelay, 0)), countIf(CarrierDelay >= 15)
    FROM faa.ontime
    WHERE toYYYYMM(FlightDate) = $m
    GROUP BY FlightDate, Reporting_Airline, tail"
done

ch_query "
  SELECT (SELECT count() FROM faa.ontime) AS ontime_flights,
         sum(flights) AS tail_day_flights, count() AS tail_day_rows
  FROM faa.tail_day FORMAT PrettyCompact"
