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

-- One row per aircraft per airline per day, summarising faa.ontime for the
-- Aircraft Reliability dashboard: about a quarter of the rows, and ordered by
-- tail so one aircraft's history reads only its own rows. Built by
-- scripts/build-tail-day.sh (rebuild after loading flights). Rows with an
-- empty tail hold the flights that had no aircraft assigned. An aircraft almost
-- never flies for two airlines in a day, so count() = aircraft-days.
CREATE TABLE IF NOT EXISTS faa.tail_day
(
    FlightDate        Date,
    Reporting_Airline LowCardinality(String),
    tail              String,
    flights           UInt32,   -- scheduled, including cancelled
    completed         UInt32,   -- not cancelled (diverted included)
    cxl_carrier       UInt32,   -- cancelled by the carrier (code A)
    cxl_other         UInt32,   -- cancelled for weather, NAS or security (B, C, D)
    diverted          UInt32,
    carrier_delay     Float64,  -- sum of CarrierDelay minutes
    delayed15         UInt32    -- CarrierDelay >= 15
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(FlightDate)
ORDER BY (tail, FlightDate, Reporting_Airline);
