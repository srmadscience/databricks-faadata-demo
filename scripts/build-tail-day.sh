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

# Rebuilds faa.tail_day (flights per aircraft per day) from faa.ontime, all of
# it, or just the months given, in one statement. Run after loading flights.
#
#   scripts/build-tail-day.sh            every month in faa.ontime
#   scripts/build-tail-day.sh 202501     just these months
set -euo pipefail
source "$(dirname "$0")/lib.sh"
dbx_check_connection

# INSERT OVERWRITE for everything, or INSERT ... REPLACE WHERE for some months.
months="TRUE"
insert="INSERT OVERWRITE faa.tail_day"
if [[ $# -gt 0 ]]; then
  months=$(months_where FlightDate "$@")
  insert="INSERT INTO faa.tail_day REPLACE WHERE $months"
fi

dbx_run "
  $insert
  SELECT FlightDate, Reporting_Airline, tail,
         count(*), count_if(Cancelled = 0),
         count_if(Cancelled = 1 AND CancellationCode = 'A'),
         count_if(Cancelled = 1 AND CancellationCode != 'A'),
         count_if(Diverted = 1),
         sum(coalesce(CarrierDelay, 0)), count_if(CarrierDelay >= 15)
  FROM faa.ontime
  WHERE $months
  GROUP BY FlightDate, Reporting_Airline, tail"
dbx_run "OPTIMIZE faa.tail_day"

dbx_query "
  SELECT (SELECT count(*) FROM faa.ontime) AS ontime_flights,
         sum(flights) AS tail_day_flights, count(*) AS tail_day_rows
  FROM faa.tail_day"
