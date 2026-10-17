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

-- Normalised aircraft registration. Allegiant (G4) reports tail numbers without
-- the US "N" prefix (816NV rather than N816NV); no other carrier does, and the
-- prefixed forms never collide with another tail. A few are in lower case
-- (n346FR). ALIAS: computed at query time, nothing stored. Empty for some
-- cancelled flights (no aircraft assigned); a handful are placeholders such as
-- '#N/A' or 'SS1', which match no registration.
ALTER TABLE faa.ontime
    ADD COLUMN IF NOT EXISTS tail String ALIAS '';
ALTER TABLE faa.ontime
    MODIFY COLUMN tail String ALIAS
        upper(if(match(Tail_Number, '^[0-9]'), concat('N', Tail_Number), Tail_Number));
