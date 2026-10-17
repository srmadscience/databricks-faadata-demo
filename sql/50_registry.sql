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

-- FAA Civil Aviation Aircraft Registry (Releasable Aircraft database).
-- https://www.faa.gov/licenses_certificates/aircraft_certification/aircraft_registry/releasable_aircraft_download
-- Loaded by scripts/load-registry.sh, which replaces all three tables.
-- Owner street addresses are never loaded, and owner names only for
-- organisations (airlines, lessors, banks), not individuals.

-- Currently registered aircraft (MASTER.txt).
CREATE TABLE IF NOT EXISTS faa.registry_master
(
    tail             String,                  -- registration incl. "N" prefix, e.g. N101DQ
    serial_number    String,
    mfr_mdl_code     LowCardinality(String),  -- joins faa.registry_models.code
    eng_mfr_mdl      LowCardinality(String),
    year_mfr         Nullable(UInt16),
    type_registrant  LowCardinality(String),  -- 1 individual, 2 partnership, 3 corporation, 4 co-owned,
                                              -- 5 government, 7 LLC, 8 non-citizen corp, 9 non-citizen co-owned
    registrant       String,                  -- owner name; '' for individuals and co-owners
    certification    LowCardinality(String),
    type_aircraft    LowCardinality(String),
    type_engine      LowCardinality(String),
    status_code      LowCardinality(String),
    mode_s_code_hex  String,
    air_worth_date   Nullable(Date32),
    cert_issue_date  Nullable(Date32),
    last_action_date Nullable(Date32),
    expiration_date  Nullable(Date32)
)
ENGINE = MergeTree
ORDER BY tail;

-- Deregistered aircraft (DEREG.txt): retired, exported or re-registered.
-- An N-number can be deregistered more than once over the years.
CREATE TABLE IF NOT EXISTS faa.registry_dereg
(
    tail             String,
    serial_number    String,
    mfr_mdl_code     LowCardinality(String),
    eng_mfr_mdl      LowCardinality(String),
    year_mfr         Nullable(UInt16),
    status_code      LowCardinality(String),
    registrant       String,                  -- '' unless an organisation (see faa.registry_master)
    certification    LowCardinality(String),
    air_worth_date   Nullable(Date32),
    cancel_date      Nullable(Date32),
    last_action_date Nullable(Date32),
    mode_s_code_hex  String
)
ENGINE = MergeTree
ORDER BY (tail, cancel_date)
SETTINGS allow_nullable_key = 1;

-- Aircraft make/model reference (ACFTREF.txt).
CREATE TABLE IF NOT EXISTS faa.registry_models
(
    code            String,
    manufacturer    LowCardinality(String),
    model           LowCardinality(String),
    type_aircraft   LowCardinality(String),   -- 4 fixed-wing single-engine, 5 fixed-wing multi-engine, ...
    type_engine     LowCardinality(String),   -- 4 turbo-fan, 5 turbo-jet, 2 turbo-prop, ...
    category        LowCardinality(String),
    engines         Nullable(UInt8),
    seats           Nullable(UInt16),
    weight_class    LowCardinality(String),
    cruise_speed    Nullable(UInt16)
)
ENGINE = MergeTree
ORDER BY code;
