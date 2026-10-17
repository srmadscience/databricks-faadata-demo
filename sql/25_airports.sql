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

-- OurAirports airport list (public domain), worldwide, one row per airport.
-- https://ourairports.com/data/
-- Used to translate BTS airport codes (IATA) into IEM station ids, and for
-- names and coordinates on Grafana maps.
CREATE TABLE IF NOT EXISTS faa.airports
(
    id                UInt32,
    ident             String,
    type              LowCardinality(String),
    name              String,
    latitude_deg      Float64,
    longitude_deg     Float64,
    elevation_ft      Nullable(Int32),
    continent         LowCardinality(String),
    iso_country       LowCardinality(String),
    iso_region        LowCardinality(String),
    municipality      String,
    scheduled_service LowCardinality(String),
    icao_code         String,
    iata_code         String,
    gps_code          String,
    local_code        String
)
ENGINE = ReplacingMergeTree
ORDER BY id;
