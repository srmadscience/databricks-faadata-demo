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

-- IEM ASOS station metadata (location and time zone), one row per station.
-- Station ids are FAA identifiers, which match the BTS Origin/Dest codes for
-- airports in the lower 48; elsewhere IEM uses ICAO codes (PANC, TJSJ), which
-- faa.airport_station resolves. tzname converts BTS local times to UTC.
CREATE TABLE IF NOT EXISTS faa.stations
(
    station   LowCardinality(String),
    network   LowCardinality(String),
    name      String,
    state     LowCardinality(String),
    country   LowCardinality(String),
    lat       Float64,
    lon       Float64,
    elevation Nullable(Float32),
    tzname    LowCardinality(String),
    archive_begin Nullable(Date32)
)
ENGINE = ReplacingMergeTree
ORDER BY station;
