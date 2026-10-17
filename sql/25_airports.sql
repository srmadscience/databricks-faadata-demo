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
    id                INT NOT NULL,
    ident             STRING NOT NULL,
    type              STRING NOT NULL,
    name              STRING NOT NULL,
    latitude_deg      DOUBLE NOT NULL,
    longitude_deg     DOUBLE NOT NULL,
    elevation_ft      INT,
    continent         STRING NOT NULL,
    iso_country       STRING NOT NULL,
    iso_region        STRING NOT NULL,
    municipality      STRING NOT NULL,
    scheduled_service STRING NOT NULL,
    icao_code         STRING NOT NULL,
    iata_code         STRING NOT NULL,
    gps_code          STRING NOT NULL,
    local_code        STRING NOT NULL
)
-- Replaced whole by load-stations.sh.
CLUSTER BY (iata_code);
