-- Copyright 2026 David Rolfe
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- One row per flight with the weather at both ends, built by
-- scripts/build-flight-weather.sh from faa.ontime + faa.weather (rebuild after
-- loading either). Times are UTC: BTS local schedule times are converted with
-- each airport's time zone (faa.airport_station.tzname), and each end gets the
-- latest METAR at or before the scheduled time, if no more than 2 hours old.
--
-- Flight category (FAA): LIFR ceiling < 500 ft or visibility < 1 mi;
-- IFR < 1,000 ft or < 3 mi; MVFR <= 3,000 ft or <= 5 mi; otherwise VFR.
-- Ceiling = lowest broken (BKN), overcast (OVC) or vertical-visibility (VV) layer.
-- wx = most significant present weather: thunderstorm > freezing > snow > fog > rain > none.
CREATE TABLE IF NOT EXISTS faa.flight_weather
(
    FlightDate        DATE NOT NULL,
    Reporting_Airline STRING NOT NULL,
    tail              STRING NOT NULL,
    Origin            STRING NOT NULL,
    Dest              STRING NOT NULL,
    CRSDepTime        INT NOT NULL,
    sched_dep_utc     TIMESTAMP NOT NULL,
    sched_arr_utc     TIMESTAMP NOT NULL,
    DepDelay          DOUBLE,
    DepDel15          DOUBLE,
    ArrDelay          DOUBLE,
    ArrDel15          DOUBLE,
    Cancelled         DOUBLE NOT NULL,
    CancellationCode  STRING NOT NULL,
    Diverted          DOUBLE NOT NULL,
    WeatherDelay      DOUBLE,
    NASDelay          DOUBLE,

    o_obs_time        TIMESTAMP,
    o_tmpf            DOUBLE,
    o_sknt            DOUBLE,
    o_gust            DOUBLE,
    o_vsby            DOUBLE,
    o_ceiling         DOUBLE,
    o_p01i            DOUBLE,
    o_wxcodes         STRING NOT NULL,
    o_category        STRING NOT NULL,          -- VFR / MVFR / IFR / LIFR, '' if no observation
    o_wx              STRING NOT NULL,

    d_obs_time        TIMESTAMP,
    d_tmpf            DOUBLE,
    d_sknt            DOUBLE,
    d_gust            DOUBLE,
    d_vsby            DOUBLE,
    d_ceiling         DOUBLE,
    d_p01i            DOUBLE,
    d_wxcodes         STRING NOT NULL,
    d_category        STRING NOT NULL,
    d_wx              STRING NOT NULL
)
CLUSTER BY (FlightDate, Origin);
