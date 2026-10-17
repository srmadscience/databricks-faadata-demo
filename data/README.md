# data/

Everything here except this README, `manifest.sha256` and the `.gitkeep`
placeholders is git-ignored. **Never commit data files.** The scripts in
`scripts/` are the record of where the data comes from; re-running them
re-creates this directory, from the GitHub Releases mirror (shared with
clickhouse-faadata-demo) where it has the files and from the original sources otherwise (see the main README).
`publish/` holds the archives `scripts/publish-data.sh` builds for the mirror.

| Path | Source | Fetched by |
|------|--------|------------|
| `raw/flights/ontime_YYYY_MM.zip` | BTS Reporting Carrier On-Time Performance, one zip per month | `scripts/fetch-flights.sh` |
| `raw/stations/XX_ASOS.geojson` | IEM ASOS station metadata, one file per state network | `scripts/fetch-stations.sh` |
| `raw/stations/ourairports.csv` | OurAirports airport list (IATA/ICAO/FAA codes) | `scripts/fetch-stations.sh` |
| `raw/weather/YYYY/STATION.csv.gz` | IEM ASOS observations, one gzipped file per airport per year | `scripts/fetch-weather.sh` |
| `raw/registry/ReleasableAircraft_YYYYMMDD.zip` | FAA aircraft registry, one zip per download date | `scripts/fetch-registry.sh` |

Rough sizes: flights ~30 MB zipped (~600k rows) per month; weather ~0.4 MB
gzipped (~10k rows) per airport per year, ~350 airports a year.

`raw/<kind>/` may hold symbolic links to another copy of the files, e.g. a
clone of clickhouse-faadata-demo: the scripts and the loader follow them, and
new downloads are added next to them.

To pin down exactly what was loaded:

    scripts/checksums.sh update    # commit data/manifest.sha256
    scripts/checksums.sh verify    # on another machine
