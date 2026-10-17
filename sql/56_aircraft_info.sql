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

-- Snapshot of the faa.aircraft view, refreshed by load-registry.sh after it
-- replaces the registry tables. Dashboards join this small table rather than
-- the view, which re-runs its UNION and join on every query. (A ClickHouse
-- dictionary would be faster still, but its CLICKHOUSE source must log in and
-- would need the password written into its definition.)
CREATE TABLE IF NOT EXISTS faa.aircraft_info
(
    tail       String,
    registered UInt8,
    make_model LowCardinality(String),
    year_mfr   Nullable(UInt16),
    seats      Nullable(UInt16),
    registrant String,
    cancel_date Nullable(Date32)
)
ENGINE = MergeTree
ORDER BY tail;
