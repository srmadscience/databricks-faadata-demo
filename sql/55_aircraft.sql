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

-- One row per registration: the current FAA record, or for aircraft no longer
-- registered, the most recent deregistration. Join flights with
--     faa.ontime.tail = faa.aircraft.tail
-- Caveat: an N-number reassigned to a different airframe after a flight
-- will describe the new airframe.
CREATE OR REPLACE VIEW faa.aircraft AS
SELECT
    r.tail,
    r.registered,
    r.serial_number,
    m.manufacturer,
    m.model,
    concat(m.manufacturer, ' ', m.model) AS make_model,  -- e.g. "BOEING 737-7H4"
    r.year_mfr,
    m.seats,
    m.engines,
    r.registrant,
    r.air_worth_date,
    r.cancel_date
FROM
(
    SELECT tail, 1 AS registered, serial_number, mfr_mdl_code, year_mfr, registrant,
           air_worth_date, CAST(NULL AS Nullable(Date32)) AS cancel_date
    FROM faa.registry_master
    UNION ALL
    SELECT tail, 0 AS registered, serial_number, mfr_mdl_code, year_mfr, registrant,
           air_worth_date, cancel_date
    FROM faa.registry_dereg
    WHERE tail NOT IN (SELECT tail FROM faa.registry_master)
    ORDER BY cancel_date DESC
    LIMIT 1 BY tail
) AS r
LEFT JOIN faa.registry_models AS m ON m.code = r.mfr_mdl_code;
