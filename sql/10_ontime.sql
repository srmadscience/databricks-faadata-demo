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

-- BTS "Reporting Carrier On-Time Performance (1987-present)", one row per flight.
-- https://www.transtats.bts.gov/Fields.asp?gnoyr_VQ=FGJ
-- Column names match the BTS CSV header so files load by name. Times (CRSDepTime
-- etc.) are local to the airport, as HHMM numbers (729 = 07:29; 2400 = midnight).
-- load-flights.sh replaces a whole month on reload (INSERT ... REPLACE WHERE).
-- Here and in every table, numbers with a fraction are DOUBLE, never FLOAT, and
-- integers INT, never SMALLINT: Grafana's Databricks plugin fails on a NULL of
-- either of those types.
CREATE TABLE IF NOT EXISTS faa.ontime
(
    Year                            INT NOT NULL,
    Quarter                         INT NOT NULL,
    Month                           INT NOT NULL,
    DayofMonth                      INT NOT NULL,
    DayOfWeek                       INT NOT NULL,
    FlightDate                      DATE NOT NULL,
    Reporting_Airline               STRING NOT NULL,
    DOT_ID_Reporting_Airline        INT NOT NULL,
    IATA_CODE_Reporting_Airline     STRING NOT NULL,
    Tail_Number                     STRING NOT NULL,
    -- Not in the BTS file: the normalised aircraft registration, filled in by
    -- the loader from Tail_Number. Allegiant (G4) reports tail numbers without
    -- the US "N" prefix (816NV rather than N816NV); no other carrier does, and
    -- the prefixed forms never collide with another tail. A few are in lower
    -- case (n346FR). Empty for some cancelled flights (no aircraft assigned); a
    -- handful are placeholders such as '#N/A' or 'SS1', which match no registration.
    -- It sits here, not at the end, because Delta keeps the file statistics
    -- that clustering and data skipping need only for the first 32 columns.
    tail                            STRING NOT NULL,
    Flight_Number_Reporting_Airline INT NOT NULL,
    OriginAirportID                 INT NOT NULL,
    OriginAirportSeqID              INT NOT NULL,
    OriginCityMarketID              INT NOT NULL,
    Origin                          STRING NOT NULL,
    OriginCityName                  STRING NOT NULL,
    OriginState                     STRING NOT NULL,
    OriginStateFips                 STRING NOT NULL,
    OriginStateName                 STRING NOT NULL,
    OriginWac                       INT NOT NULL,
    DestAirportID                   INT NOT NULL,
    DestAirportSeqID                INT NOT NULL,
    DestCityMarketID                INT NOT NULL,
    Dest                            STRING NOT NULL,
    DestCityName                    STRING NOT NULL,
    DestState                       STRING NOT NULL,
    DestStateFips                   STRING NOT NULL,
    DestStateName                   STRING NOT NULL,
    DestWac                         INT NOT NULL,
    CRSDepTime                      INT NOT NULL,
    DepTime                         INT,
    DepDelay                        DOUBLE,
    DepDelayMinutes                 DOUBLE,
    DepDel15                        DOUBLE,
    DepartureDelayGroups            INT,
    DepTimeBlk                      STRING NOT NULL,
    TaxiOut                         DOUBLE,
    WheelsOff                       INT,
    WheelsOn                        INT,
    TaxiIn                          DOUBLE,
    CRSArrTime                      INT NOT NULL,
    ArrTime                         INT,
    ArrDelay                        DOUBLE,
    ArrDelayMinutes                 DOUBLE,
    ArrDel15                        DOUBLE,
    ArrivalDelayGroups              INT,
    ArrTimeBlk                      STRING NOT NULL,
    Cancelled                       DOUBLE NOT NULL,
    CancellationCode                STRING NOT NULL,
    Diverted                        DOUBLE NOT NULL,
    CRSElapsedTime                  DOUBLE,
    ActualElapsedTime               DOUBLE,
    AirTime                         DOUBLE,
    Flights                         DOUBLE NOT NULL,
    Distance                        DOUBLE NOT NULL,
    DistanceGroup                   INT NOT NULL,
    CarrierDelay                    DOUBLE,
    WeatherDelay                    DOUBLE,
    NASDelay                        DOUBLE,
    SecurityDelay                   DOUBLE,
    LateAircraftDelay               DOUBLE,
    FirstDepTime                    INT,
    TotalAddGTime                   DOUBLE,
    LongestAddGTime                 DOUBLE,
    DivAirportLandings              INT,
    DivReachedDest                  DOUBLE,
    DivActualElapsedTime            DOUBLE,
    DivArrDelay                     DOUBLE,
    DivDistance                     DOUBLE,
    Div1Airport                     STRING NOT NULL,
    Div1AirportID                   INT,
    Div1AirportSeqID                INT,
    Div1WheelsOn                    INT,
    Div1TotalGTime                  DOUBLE,
    Div1LongestGTime                DOUBLE,
    Div1WheelsOff                   INT,
    Div1TailNum                     STRING NOT NULL,
    Div2Airport                     STRING NOT NULL,
    Div2AirportID                   INT,
    Div2AirportSeqID                INT,
    Div2WheelsOn                    INT,
    Div2TotalGTime                  DOUBLE,
    Div2LongestGTime                DOUBLE,
    Div2WheelsOff                   INT,
    Div2TailNum                     STRING NOT NULL,
    Div3Airport                     STRING NOT NULL,
    Div3AirportID                   INT,
    Div3AirportSeqID                INT,
    Div3WheelsOn                    INT,
    Div3TotalGTime                  DOUBLE,
    Div3LongestGTime                DOUBLE,
    Div3WheelsOff                   INT,
    Div3TailNum                     STRING NOT NULL,
    Div4Airport                     STRING NOT NULL,
    Div4AirportID                   INT,
    Div4AirportSeqID                INT,
    Div4WheelsOn                    INT,
    Div4TotalGTime                  DOUBLE,
    Div4LongestGTime                DOUBLE,
    Div4WheelsOff                   INT,
    Div4TailNum                     STRING NOT NULL,
    Div5Airport                     STRING NOT NULL,
    Div5AirportID                   INT,
    Div5AirportSeqID                INT,
    Div5WheelsOn                    INT,
    Div5TotalGTime                  DOUBLE,
    Div5LongestGTime                DOUBLE,
    Div5WheelsOff                   INT,
    Div5TailNum                     STRING NOT NULL
)
-- Liquid clustering keeps each aircraft's flights, and each stretch of dates,
-- in few files, so that queries for either skip most of the table. It
-- clusters data as OPTIMIZE runs (load-flights.sh runs it after loading).
CLUSTER BY (tail, FlightDate);
