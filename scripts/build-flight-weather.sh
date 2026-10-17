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

# Rebuilds faa.flight_weather (flights joined to the weather at both ends)
# one month at a time, replacing each month's partition. Run after loading
# flights, stations or weather.
#
#   scripts/build-flight-weather.sh            every month in faa.ontime
#   scripts/build-flight-weather.sh 202501     just these months
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ch_check_connection

months=("$@")
[[ ${#months[@]} -gt 0 ]] || months=($(ch_query "SELECT DISTINCT toYYYYMM(FlightDate) FROM faa.ontime ORDER BY 1"))

# ClickHouse needs a constant time zone to read a local time, so generate one
# multiIf branch per time zone in use: tz = 'X', toDateTime(local, 'X'), ...
utc_of() {  # utc_of LOCAL_STRING_EXPR TZ_EXPR
  local branches=""
  for tz in $(ch_query "SELECT DISTINCT tzname FROM faa.airport_station WHERE tzname != '' ORDER BY 1"); do
    branches+="$2 = '$tz', toDateTime($1, '$tz'), "
  done
  echo "toTimeZone(multiIf(${branches}NULL), 'UTC')"
}

# Local scheduled departure as 'YYYY-MM-DD hh:mm:00'; BTS writes midnight as 2400.
LOCAL_DEP="concat(toString(o.FlightDate + (o.CRSDepTime >= 2400)), ' ',
                  leftPad(toString(intDiv(o.CRSDepTime, 100) % 24), 2, '0'), ':',
                  leftPad(toString(o.CRSDepTime % 100), 2, '0'), ':00')"
DEP_UTC=$(utc_of "$LOCAL_DEP" "ao.tzname")

# Weather with derived ceiling, flight category and present-weather class, for
# the observations a month's flights can match. Each end takes the latest report
# at or before its scheduled UTC time, and reports over 2 hours old are not used,
# so the month from a day before to two days after is enough: departures start
# at most 11 hours before the month in UTC, and the last arrivals (checked over
# 2016-2026) end within a day of it. Without this window, every month's build
# would read all the weather, twice.
wx() {  # wx YYYYMM
  local start="toDateTime(toDate('${1:0:4}-${1:4:2}-01'), 'UTC')"
  echo "
  SELECT station, valid, tmpf, sknt, gust, vsby, p01i, wxcodes,
         arrayFilter((l, c) -> c IN ('BKN', 'OVC', 'VV') AND l IS NOT NULL,
                     [skyl1, skyl2, skyl3, skyl4], [skyc1, skyc2, skyc3, skyc4]) AS layers,
         if(empty(layers), NULL, arrayMin(layers)) AS ceiling,
         multiIf(vsby IS NULL AND ceiling IS NULL AND skyc1 = '', '',
                 ceiling < 500 OR vsby < 1, 'LIFR',
                 ceiling < 1000 OR vsby < 3, 'IFR',
                 ceiling <= 3000 OR vsby <= 5, 'MVFR', 'VFR') AS category,
         multiIf(match(wxcodes, 'TS'), 'Thunderstorm', match(wxcodes, 'FZ'), 'Freezing',
                 match(wxcodes, 'SN|SG|PL|GS|GR'), 'Snow/ice', match(wxcodes, 'FG'), 'Fog',
                 match(wxcodes, 'RA|DZ|SH'), 'Rain', 'None') AS wx
  FROM faa.weather
  WHERE valid >= $start - INTERVAL 1 DAY AND valid < $start + INTERVAL 1 MONTH + INTERVAL 2 DAY"
}

# Fields copied from the matched observation, NULLed if it is over 2 hours old.
obs() {  # obs ALIAS PREFIX SCHED_COL
  local fresh="$1.valid > toDateTime(0) AND dateDiff('minute', $1.valid, $3) <= 120"
  echo "if($fresh, $1.valid, NULL) AS ${2}_obs_time,
        if($fresh, $1.tmpf, NULL) AS ${2}_tmpf, if($fresh, $1.sknt, NULL) AS ${2}_sknt,
        if($fresh, $1.gust, NULL) AS ${2}_gust, if($fresh, $1.vsby, NULL) AS ${2}_vsby,
        if($fresh, $1.ceiling, NULL) AS ${2}_ceiling, if($fresh, $1.p01i, NULL) AS ${2}_p01i,
        if($fresh, $1.wxcodes, '') AS ${2}_wxcodes, if($fresh, $1.category, '') AS ${2}_category,
        if($fresh, $1.wx, '') AS ${2}_wx"
}

for m in "${months[@]}"; do
  ch_query "ALTER TABLE faa.flight_weather DROP PARTITION $m"
  ch_query "
    INSERT INTO faa.flight_weather
    SELECT f.FlightDate, f.Reporting_Airline, f.tail, f.Origin, f.Dest, f.CRSDepTime,
           f.sched_dep_utc, f.sched_arr_utc, f.DepDelay, f.DepDel15, f.ArrDelay, f.ArrDel15,
           f.Cancelled, f.CancellationCode, f.Diverted, f.WeatherDelay, f.NASDelay,
           $(obs ow o f.sched_dep_utc),
           $(obs dw d f.sched_arr_utc)
    FROM (
        SELECT o.FlightDate, o.Reporting_Airline, o.tail, o.Origin, o.Dest, o.CRSDepTime,
               o.DepDelay, o.DepDel15, o.ArrDelay, o.ArrDel15, o.Cancelled, o.CancellationCode,
               o.Diverted, o.WeatherDelay, o.NASDelay,
               ao.station AS o_station, ad.station AS d_station,
               $DEP_UTC AS sched_dep_utc,
               sched_dep_utc + toIntervalMinute(toInt32(ifNull(o.CRSElapsedTime, 0))) AS sched_arr_utc
        FROM faa.ontime AS o
        LEFT JOIN faa.airport_station AS ao ON ao.airport = o.Origin
        LEFT JOIN faa.airport_station AS ad ON ad.airport = o.Dest
        WHERE toYYYYMM(o.FlightDate) = $m AND ao.tzname != ''
    ) AS f
    ASOF LEFT JOIN ($(wx "$m")) AS ow ON ow.station = f.o_station AND ow.valid <= f.sched_dep_utc
    ASOF LEFT JOIN ($(wx "$m")) AS dw ON dw.station = f.d_station AND dw.valid <= f.sched_arr_utc
    SETTINGS join_use_nulls = 0"
  echo "$m: $(ch_query "SELECT count() FROM faa.flight_weather WHERE toYYYYMM(FlightDate) = $m") flights"
done

ch_query "
  SELECT count() AS flights,
         round(100 * countIf(o_category != '') / flights, 1) AS pct_origin_wx,
         round(100 * countIf(d_category != '') / flights, 1) AS pct_dest_wx,
         (SELECT count() FROM faa.ontime) AS ontime_flights
  FROM faa.flight_weather FORMAT PrettyCompact"
