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

-- Run with:  scripts/create-database.sh
-- Files run in name order; add tables as 10_flights.sql, 20_weather.sql, ...
-- Every table is faa.<table> in the catalog set by databricks.catalog, which
-- the scripts and the loader use as their default catalog.
CREATE SCHEMA IF NOT EXISTS faa
COMMENT 'FAA flights, weather and aircraft registry (databricks-faadata-demo)';

-- Where the loader uploads files for read_files to read; they are deleted
-- once loaded.
CREATE VOLUME IF NOT EXISTS faa.staging;
