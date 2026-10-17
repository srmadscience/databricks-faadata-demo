# Copyright 2026 David Rolfe
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Converts IEM network GeoJSON files to CSV for faa.stations, with a header
line. A station listed in more than one file is written once, from the last.

Usage: python3 -I stations_to_csv.py FILE.geojson... > stations.csv
"""
import csv
import json
import sys

rows = {}
for path in sys.argv[1:]:
    with open(path) as f:
        for feature in json.load(f)["features"]:
            p = feature["properties"]
            lon, lat = feature["geometry"]["coordinates"][:2]
            rows[feature["id"]] = [
                feature["id"], p.get("network", ""), p.get("sname", ""), p.get("state") or "",
                p.get("country") or "", lat, lon,
                "" if p.get("elevation") is None else p["elevation"],
                p.get("tzname") or "", (p.get("archive_begin") or "")[:10],
            ]
out = csv.writer(sys.stdout)
out.writerow(["station", "network", "name", "state", "country", "lat", "lon", "elevation", "tzname",
              "archive_begin"])
out.writerows(rows.values())
