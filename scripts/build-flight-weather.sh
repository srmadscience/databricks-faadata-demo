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

# Rebuilds faa.flight_weather (flights joined to the weather at both ends):
# all of it, or just the months given, in one statement. Run after loading
# flights, stations or weather.
#
#   scripts/build-flight-weather.sh            every month in faa.ontime
#   scripts/build-flight-weather.sh 202501     just these months
#
# Databricks has no ASOF JOIN, so each end finds its METAR with a window
# instead: flights and observations go into one stream per station, in time
# order (an observation before a flight at the same minute), and
# last_value(... IGNORE NULLS) carries the latest observation forward onto each
# flight. Reports over 2 hours old are not used, so the stream is split by
# station and day, with each observation also put into the next day's: every
# window is small, and the whole build runs as one query.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
dbx_check_connection

flights="TRUE"
weather="TRUE"
insert="INSERT OVERWRITE faa.flight_weather"
if [[ $# -gt 0 ]]; then
  flights=$(months_where FlightDate "$@")
  insert="INSERT INTO faa.flight_weather REPLACE WHERE $flights"
  # The observations those months' flights can match: departures start at most
  # 11 hours before their month in UTC, and the last arrivals (checked over
  # 2016-2026) end within a day of it.
  first=$(printf '%s\n' "$@" | sort | head -1); last=$(printf '%s\n' "$@" | sort | tail -1)
  weather="valid >= TIMESTAMP '${first:0:4}-${first:4:2}-01T00:00:00Z' - INTERVAL 1 DAY
           AND valid < TIMESTAMP '${last:0:4}-${last:4:2}-01T00:00:00Z' + INTERVAL 1 MONTH + INTERVAL 2 DAY"
fi

# obs PREFIX: the matched observation's fields, NULL (or '') if it is over 2 hours old.
obs() {
  local w="$1w" t
  [[ $1 == o ]] && t=fl.sched_dep_utc || t=sched_arr_utc
  local fresh="$w.valid IS NOT NULL AND timestampdiff(MINUTE, $w.valid, $t) <= 120"
  echo "if($fresh, $w.valid, NULL) AS ${1}_obs_time,
        if($fresh, $w.tmpf, NULL) AS ${1}_tmpf, if($fresh, $w.sknt, NULL) AS ${1}_sknt,
        if($fresh, $w.gust, NULL) AS ${1}_gust, if($fresh, $w.vsby, NULL) AS ${1}_vsby,
        if($fresh, $w.ceiling, NULL) AS ${1}_ceiling, if($fresh, $w.p01i, NULL) AS ${1}_p01i,
        if($fresh, $w.wxcodes, '') AS ${1}_wxcodes, if($fresh, $w.category, '') AS ${1}_category,
        if($fresh, $w.wx, '') AS ${1}_wx"
}

# The window: the latest observation at or before each row, in its station and day.
LATEST="last_value(w, true) OVER (PARTITION BY station, day ORDER BY t, kind
                                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)"

dbx_run "
$insert
WITH
-- Each flight, with its stations and its scheduled times in UTC. BTS local
-- times are HHMM numbers, with midnight as 2400; make_timestamp reads them in
-- the airport's time zone.
f AS (
  SELECT fl, o_station, d_station, fl.sched_dep_utc,
         timestampadd(MINUTE, CAST(coalesce(CRSElapsedTime, 0) AS INT), fl.sched_dep_utc) AS sched_arr_utc
  FROM (
    SELECT struct(o.FlightDate, o.Reporting_Airline, o.tail, o.Origin, o.Dest, o.CRSDepTime,
                  make_timestamp(year(dep_day), month(dep_day), day(dep_day),
                                 o.CRSDepTime DIV 100 % 24, o.CRSDepTime % 100, 0, ao.tzname) AS sched_dep_utc,
                  o.DepDelay, o.DepDel15, o.ArrDelay, o.ArrDel15, o.Cancelled, o.CancellationCode,
                  o.Diverted, o.WeatherDelay, o.NASDelay) AS fl,
           o.CRSElapsedTime, ao.station AS o_station, ad.station AS d_station
    FROM (SELECT *, date_add(FlightDate, if(CRSDepTime >= 2400, 1, 0)) AS dep_day
          FROM faa.ontime WHERE $flights) AS o
    INNER JOIN faa.airport_station AS ao ON ao.airport = o.Origin
    LEFT JOIN faa.airport_station AS ad ON ad.airport = o.Dest
    WHERE ao.tzname != ''
  )
),
-- Weather with derived ceiling, flight category and present-weather class.
wx AS (
  SELECT station, valid,
         struct(valid, tmpf, sknt, gust, vsby, p01i, wxcodes, ceiling,
                CASE WHEN vsby IS NULL AND ceiling IS NULL AND skyc1 = '' THEN ''
                     WHEN ceiling < 500 OR vsby < 1 THEN 'LIFR'
                     WHEN ceiling < 1000 OR vsby < 3 THEN 'IFR'
                     WHEN ceiling <= 3000 OR vsby <= 5 THEN 'MVFR'
                     ELSE 'VFR' END AS category,
                CASE WHEN wxcodes RLIKE 'TS' THEN 'Thunderstorm'
                     WHEN wxcodes RLIKE 'FZ' THEN 'Freezing'
                     WHEN wxcodes RLIKE 'SN|SG|PL|GS|GR' THEN 'Snow/ice'
                     WHEN wxcodes RLIKE 'FG' THEN 'Fog'
                     WHEN wxcodes RLIKE 'RA|DZ|SH' THEN 'Rain'
                     ELSE 'None' END AS wx) AS w
  FROM (
    SELECT *,
           -- the lowest broken, overcast or obscured layer
           array_min(array(if(skyc1 IN ('BKN', 'OVC', 'VV'), skyl1, NULL), if(skyc2 IN ('BKN', 'OVC', 'VV'), skyl2, NULL),
                           if(skyc3 IN ('BKN', 'OVC', 'VV'), skyl3, NULL), if(skyc4 IN ('BKN', 'OVC', 'VV'), skyl4, NULL)))
             AS ceiling
    FROM faa.weather
    WHERE $weather
  )
),
-- Each observation in its own day's window and the next day's.
wx_days AS (
  SELECT station, valid, date_add(CAST(valid AS DATE), d) AS day, w
  FROM wx LATERAL VIEW explode(array(0, 1)) AS d
),
dep AS (
  SELECT * EXCEPT (kind, w) FROM (
    SELECT kind, fl, d_station, sched_arr_utc, $LATEST AS ow, w
    FROM (
      SELECT 1 AS kind, o_station AS station, sched_dep_utc AS t, CAST(sched_dep_utc AS DATE) AS day,
             fl, d_station, sched_arr_utc, NULL AS w
      FROM f
      UNION ALL
      SELECT 0, station, valid, day, NULL, NULL, NULL, w FROM wx_days
    )
  )
  WHERE kind = 1
),
arr AS (
  SELECT * EXCEPT (kind, w) FROM (
    SELECT kind, fl, ow, sched_arr_utc, $LATEST AS dw, w
    FROM (
      SELECT 1 AS kind, d_station AS station, sched_arr_utc AS t, CAST(sched_arr_utc AS DATE) AS day,
             fl, ow, sched_arr_utc, NULL AS w
      FROM dep
      UNION ALL
      SELECT 0, station, valid, day, NULL, NULL, NULL, w FROM wx_days
    )
  )
  WHERE kind = 1
)
SELECT fl.FlightDate, fl.Reporting_Airline, fl.tail, fl.Origin, fl.Dest, fl.CRSDepTime,
       fl.sched_dep_utc, sched_arr_utc, fl.DepDelay, fl.DepDel15, fl.ArrDelay, fl.ArrDel15,
       fl.Cancelled, fl.CancellationCode, fl.Diverted, fl.WeatherDelay, fl.NASDelay,
       $(obs o),
       $(obs d)
FROM arr"
dbx_run "OPTIMIZE faa.flight_weather"

dbx_query "
  SELECT count(*) AS flights,
         round(100 * count_if(o_category != '') / count(*), 1) AS pct_origin_wx,
         round(100 * count_if(d_category != '') / count(*), 1) AS pct_dest_wx,
         (SELECT count(*) FROM faa.ontime) AS ontime_flights
  FROM faa.flight_weather"
