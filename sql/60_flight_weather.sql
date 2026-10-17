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
    FlightDate        Date,
    Reporting_Airline LowCardinality(String),
    tail              String,
    Origin            LowCardinality(String),
    Dest              LowCardinality(String),
    CRSDepTime        UInt16,
    sched_dep_utc     DateTime('UTC'),
    sched_arr_utc     DateTime('UTC'),
    DepDelay          Nullable(Float32),
    DepDel15          Nullable(Float32),
    ArrDelay          Nullable(Float32),
    ArrDel15          Nullable(Float32),
    Cancelled         Float32,
    CancellationCode  LowCardinality(String),
    Diverted          Float32,
    WeatherDelay      Nullable(Float32),
    NASDelay          Nullable(Float32),

    o_obs_time        Nullable(DateTime('UTC')),
    o_tmpf            Nullable(Float32),
    o_sknt            Nullable(Float32),
    o_gust            Nullable(Float32),
    o_vsby            Nullable(Float32),
    o_ceiling         Nullable(Float32),
    o_p01i            Nullable(Float32),
    o_wxcodes         LowCardinality(String),
    o_category        LowCardinality(String),   -- VFR / MVFR / IFR / LIFR, '' if no observation
    o_wx              LowCardinality(String),

    d_obs_time        Nullable(DateTime('UTC')),
    d_tmpf            Nullable(Float32),
    d_sknt            Nullable(Float32),
    d_gust            Nullable(Float32),
    d_vsby            Nullable(Float32),
    d_ceiling         Nullable(Float32),
    d_p01i            Nullable(Float32),
    d_wxcodes         LowCardinality(String),
    d_category        LowCardinality(String),
    d_wx              LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(FlightDate)
ORDER BY (FlightDate, Origin, Reporting_Airline);
