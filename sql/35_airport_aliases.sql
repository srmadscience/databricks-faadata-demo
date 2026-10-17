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

-- Airport codes BTS still uses after an airport was re-coded, mapped to the
-- current IATA code that OurAirports and IEM use. Add rows here when
-- load-stations.sh reports an airport without a station.
CREATE OR REPLACE VIEW faa.airport_aliases AS
SELECT * FROM values('bts_code String, iata_code String',
    ('PBI', 'DJT'),  -- Palm Beach Intl, renamed 2025
    ('TKI', 'DTX')   -- McKinney National, re-coded
);

-- Closed airports that OurAirports no longer gives any code, so they have to be
-- matched by OurAirports ident and given their IEM station explicitly.
CREATE OR REPLACE VIEW faa.airport_closed AS
SELECT * FROM values('bts_code String, ident String, station String',
    ('ISN', 'US-11527', 'ISN')  -- Williston Sloulin Field, replaced by XWA in 2019
);
