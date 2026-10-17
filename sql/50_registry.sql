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
    tail             STRING NOT NULL,         -- registration incl. "N" prefix, e.g. N101DQ
    serial_number    STRING NOT NULL,
    mfr_mdl_code     STRING NOT NULL,         -- joins faa.registry_models.code
    eng_mfr_mdl      STRING NOT NULL,
    year_mfr         INT,
    type_registrant  STRING NOT NULL,         -- 1 individual, 2 partnership, 3 corporation, 4 co-owned,
                                              -- 5 government, 7 LLC, 8 non-citizen corp, 9 non-citizen co-owned
    registrant       STRING NOT NULL,         -- owner name; '' for individuals and co-owners
    certification    STRING NOT NULL,
    type_aircraft    STRING NOT NULL,
    type_engine      STRING NOT NULL,
    status_code      STRING NOT NULL,
    mode_s_code_hex  STRING NOT NULL,
    air_worth_date   DATE,
    cert_issue_date  DATE,
    last_action_date DATE,
    expiration_date  DATE
)
CLUSTER BY (tail);

-- Deregistered aircraft (DEREG.txt): retired, exported or re-registered.
-- An N-number can be deregistered more than once over the years.
CREATE TABLE IF NOT EXISTS faa.registry_dereg
(
    tail             STRING NOT NULL,
    serial_number    STRING NOT NULL,
    mfr_mdl_code     STRING NOT NULL,
    eng_mfr_mdl      STRING NOT NULL,
    year_mfr         INT,
    status_code      STRING NOT NULL,
    registrant       STRING NOT NULL,         -- '' unless an organisation (see faa.registry_master)
    certification    STRING NOT NULL,
    air_worth_date   DATE,
    cancel_date      DATE,
    last_action_date DATE,
    mode_s_code_hex  STRING NOT NULL
)
CLUSTER BY (tail);

-- Aircraft make/model reference (ACFTREF.txt).
CREATE TABLE IF NOT EXISTS faa.registry_models
(
    code            STRING NOT NULL,
    manufacturer    STRING NOT NULL,
    model           STRING NOT NULL,
    type_aircraft   STRING NOT NULL,          -- 4 fixed-wing single-engine, 5 fixed-wing multi-engine, ...
    type_engine     STRING NOT NULL,          -- 4 turbo-fan, 5 turbo-jet, 2 turbo-prop, ...
    category        STRING NOT NULL,
    engines         INT,
    seats           INT,
    weight_class    STRING NOT NULL,
    cruise_speed    INT
)
CLUSTER BY (code);
