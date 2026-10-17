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

-- A second copy of every flight, ordered by aircraft then date, so one
-- aircraft's history reads only its own granules instead of every flight in
-- the date range. ClickHouse picks it automatically for queries filtering on
-- tail. A projection can't use the tail ALIAS, so this repeats its expression
-- from 15_ontime_tail.sql: keep the two the same, or the projection won't be
-- used. It is built as flights are inserted, so it costs load time and disk;
-- data loaded before it was added needs ALTER TABLE ... MATERIALIZE PROJECTION.
ALTER TABLE faa.ontime
    ADD PROJECTION IF NOT EXISTS by_tail
    (
        SELECT *
        ORDER BY (upper(if(match(Tail_Number, '^[0-9]'), concat('N', Tail_Number), Tail_Number)), FlightDate)
    );
