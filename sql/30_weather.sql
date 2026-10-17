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

-- IEM ASOS observations (METAR routine + special reports), times in UTC.
-- https://mesonet.agron.iastate.edu/request/download.phtml
-- Units: tmpf/dwpf/feel F, relh %, drct degrees, sknt/gust knots, p01i inches
-- (0.0001 = trace), alti inHg, mslp mb, vsby miles, skyl feet.
-- One row per (station, valid): load-weather.sh loads into faa.weather_load
-- and MERGEs from there, so reloads never duplicate a report.
CREATE TABLE IF NOT EXISTS faa.weather
(
    station           STRING NOT NULL,
    valid             TIMESTAMP NOT NULL,
    lon               DOUBLE NOT NULL,
    lat               DOUBLE NOT NULL,
    elevation         DOUBLE,
    tmpf              DOUBLE,
    dwpf              DOUBLE,
    relh              DOUBLE,
    drct              DOUBLE,
    sknt              DOUBLE,
    p01i              DOUBLE,
    alti              DOUBLE,
    mslp              DOUBLE,
    vsby              DOUBLE,
    gust              DOUBLE,
    skyc1             STRING NOT NULL,
    skyc2             STRING NOT NULL,
    skyc3             STRING NOT NULL,
    skyc4             STRING NOT NULL,
    skyl1             DOUBLE,
    skyl2             DOUBLE,
    skyl3             DOUBLE,
    skyl4             DOUBLE,
    wxcodes           STRING NOT NULL,
    ice_accretion_1hr DOUBLE,
    ice_accretion_3hr DOUBLE,
    ice_accretion_6hr DOUBLE,
    peak_wind_gust    DOUBLE,
    peak_wind_drct    DOUBLE,
    peak_wind_time    TIMESTAMP,
    feel              DOUBLE,
    metar             STRING NOT NULL,
    snowdepth         DOUBLE
)
CLUSTER BY (station, valid);

-- Staging for load-weather.sh: the files just loaded, before they are merged
-- into faa.weather. Empty between loads.
CREATE TABLE IF NOT EXISTS faa.weather_load LIKE faa.weather;
