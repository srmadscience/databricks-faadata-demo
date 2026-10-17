# clickhouse-faadata-demo
A ClickHouse / Grafana application that uses publicly available FAA flight and weather data.

* **ClickHouse**: any server you can reach over HTTP (port 8123), database `faa`
* **Loader**: Java 21 / Maven, ClickHouse `client-v2`
* **Dashboards**: Grafana with the `grafana-clickhouse-datasource` plugin, querying ClickHouse over its native protocol (port 9000)

Developed with ClickHouse 26.9 and Grafana 13. The ten years of data from 2016 take about
5 GB of downloads and about 10 GB in ClickHouse.

![Flight Delays dashboard, February to July 2026](docs/screenshots/flight-delays.jpg)

## Data

| Table | Source | Grain |
|-------|--------|-------|
| `faa.ontime` | [BTS on-time performance](https://www.transtats.bts.gov/) | one row per scheduled flight; times are airport-local |
| `faa.stations` | [IEM](https://mesonet.agron.iastate.edu/) ASOS station metadata | one row per weather station, incl. time zone |
| `faa.weather` | [IEM ASOS](https://mesonet.agron.iastate.edu/request/download.phtml) observations | one row per METAR (roughly hourly), UTC |
| `faa.airports` | [OurAirports](https://ourairports.com/data/) | one row per airport worldwide: codes, names, coordinates |
| `faa.airport_station` (view) | | BTS airport code → IEM station and time zone |
| `faa.registry_master`, `faa.registry_dereg`, `faa.registry_models` | [FAA aircraft registry](https://www.faa.gov/licenses_certificates/aircraft_certification/aircraft_registry/releasable_aircraft_download) | registered and deregistered aircraft; make/model reference |
| `faa.aircraft` (view), `faa.aircraft_info` (snapshot) | | one row per tail number: model, year built, seats, owner, status |
| `faa.tail_day` | built from `ontime` | one row per aircraft per airline per day: flights, cancellations, carrier delay (for the Aircraft Reliability dashboard) |
| `faa.flight_weather` | built from `ontime` + `weather` | one row per flight with UTC schedule times and the weather (flight category, wind, visibility, present weather) at origin and destination |

To join flights to weather, go through `faa.airport_station`: `ontime.Origin = airport`,
`weather.station = station`. Station ids differ from BTS codes outside the lower 48
(FAI → PAFA, SJU → TJSJ), and `sql/35_airport_aliases.sql` covers re-coded airports
(PBI → DJT) and closed ones (ISN, Williston, closed 2019). Saipan (SPN) has no IEM station.

Flights join to aircraft on `ontime.tail = aircraft_info.tail` (99.9% of 2025 tail numbers
match; aircraft retired since come from the deregistration file). Owner street addresses
are never loaded, and owner names only for organisations, not individuals.

## Layout

    src/main/java/...      Loader: ping | schema | load (streams CSV / .gz / .zip) | bench (query timing)
    sql/                   Table definitions, run in file-name order
    scripts/               Everything needed to rebuild the database and Grafana (below)
    aws/                   CloudFormation template for a complete demo server (below)
    grafana/provisioning/  Datasource + dashboard provider config
    grafana/dashboards/    Exported dashboard JSON (committed)
    data/                  Downloaded data: NOT in git (see data/README.md)

## Reproducing the database

Needs bash, curl, python3, Java 21 and Maven, and a ClickHouse server whose user can
create databases.

    cp clickhouse.properties.example clickhouse.properties   # set clickhouse.url, user, password
    scripts/reproduce.sh 2025-01 2025-12

`clickhouse.properties` is git-ignored, so credentials stay out of the repository.
The `CLICKHOUSE_URL`, `CLICKHOUSE_USER` and `CLICKHOUSE_PASSWORD` environment variables
override it.

`reproduce.sh` runs these steps in order. Each is safe to re-run, and can be run on its own:

| Script | Does |
|--------|------|
| `create-database.sh` | Creates `faa` and the tables from `sql/` |
| `fetch-flights.sh FROM TO` | Downloads BTS months (`YYYY-MM`) not already in `data/raw/flights/` |
| `load-flights.sh` | Loads them, replacing each month's partition |
| `build-tail-day.sh` | Rebuilds `tail_day`; re-run after loading flights |
| `fetch-stations.sh` / `load-stations.sh` | Gets IEM stations and OurAirports; lists airports with no station |
| `fetch-weather.sh FROM TO` | Downloads IEM observations (years) for every airport in `faa.ontime` |
| `load-weather.sh` | Loads them; duplicates are removed by the table engine |
| `build-flight-weather.sh` | Rebuilds `flight_weather`; re-run after loading flights, stations or weather |
| `fetch-registry.sh` / `load-registry.sh` | Gets the FAA registry; replaces the registry tables and `aircraft_info` |

The fetch scripts download from the project's [data mirror](#data-mirror) first and go
to the original sources only for what it lacks, so a full rebuild takes minutes, not hours.

To add more data later, run `reproduce.sh` with a wider range: existing downloads are skipped.
New months come from BTS if the mirror doesn't have them yet. To bring the current year's
weather, the station list or the registry up to date, use `--refresh`:

    scripts/fetch-weather.sh --refresh 2026 2026
    scripts/fetch-stations.sh --refresh
    scripts/fetch-registry.sh --refresh

### Hardware and load times

A full load of January 2016 to July 2026 from an empty server, timed in October 2026 on
three setups:

* **Home**: ClickHouse on an Intel Core i5-6500 (4 cores, 4 threads, 3.2 GHz, 3.6 GHz
  turbo, 6 MB L3) with 48 GB RAM and an SSD; the scripts and Java loader on an Apple M2
  Mac (16 GB RAM) on the same local network; downloads over the internet
* **AWS**: everything on one instance in us-east-1, built by
  [`aws/faa-demo.yaml`](#running-on-aws): an m7i.xlarge (4 vCPUs, 16 GB RAM) or an
  m7i.2xlarge (8 vCPUs, 32 GB RAM), each with a gp3 disk

Both used ClickHouse 26.9 and Java 21. The loader parses the flight CSVs itself, 8 files
at a time, and downloads come from the [data mirror](#data-mirror), four files at a time.

| Step | Home | AWS, 4 vCPUs | AWS, 8 vCPUs | AWS, 8 vCPUs, with `by_tail` |
|------|-----:|-----:|-----:|-----:|
| `create-database.sh` | 1 s | 0 s | 0 s | 0 s |
| `fetch-flights.sh 2016-01 2026-07` (127 months, 3.3 GB) | 7 min 11 s | 2 min 28 s | 2 min 16 s | 2 min 23 s |
| `load-flights.sh` (68.4 million flights) | 1 min 27 s | 3 min 3 s | 1 min 26 s | 1 min 39 s |
| `build-tail-day.sh` | 21 s | 12 s | 8 s | 9 s |
| `fetch-stations.sh` / `load-stations.sh` | 3 s | 2 s | 2 s | 1 s |
| `fetch-weather.sh 2016 2026` (11 years, 1.6 GB) | 2 min 55 s | 13 s | 12 s | 14 s |
| `load-weather.sh` (42.2 million reports) | 2 min 46 s | 1 min 25 s | 58 s | 1 min 0 s |
| `build-flight-weather.sh` | 2 min 43 s | 1 min 35 s | 1 min 9 s | 1 min 10 s |
| `fetch-registry.sh` / `load-registry.sh` | 24 s | 6 s | 5 s | 6 s |
| **Total** | **17 min 51 s** | **9 min 4 s** | **6 min 16 s** | **6 min 42 s** |

At home, downloading takes over half the time. On AWS it is much faster, but with four
vCPUs parsing the flight CSVs is slower, as the loader shares them with ClickHouse
instead of having the M2's eight cores to itself; with eight it matches the M2. Doubling
again to an m7i.4xlarge (16 vCPUs) barely helps: everything but the downloads took 199 s,
against 225 s on 8 vCPUs, all of it saved in `load-flights`, so 8 vCPUs is the better buy. Either way, the result is 197 million rows: 41 GB
of data, stored in 10 GB, and the tables are identical.

The last column adds the `by_tail` projection on `faa.ontime` (see
[Query performance](#query-performance)), which stores every flight a second time. It
takes `ontime` from 4.4 GiB to 9.4 GiB on disk. On AWS with 8 vCPUs it adds 13 s to
`load-flights`, and the tables are otherwise identical. At home the cost is bigger:
`load-flights` went from 87 s to 141 s.

To time a load from scratch, drop the `faa` database and move the downloaded files out of
`data/raw/`, then run:

    scripts/reproduce.sh --time "what changed since the last test" 2016-01 2026-07

This appends each step's time to [`testresults_load.csv`](testresults_load.csv), with the
date, git commit, ClickHouse version and the comment, so runs can be compared.

## Query performance

`scripts/bench-queries.sh` runs randomly generated queries against the loaded database,
many at once, and times each one until its last row has been read. So far there is one
workload. `flight-history` fetches every flight of one aircraft, picked at random from the
9,605 that have flown, between two random dates 1 day to 10 years apart. The length of the
range is spread evenly on a log scale, so days, weeks, months and years are equally likely.

    scripts/bench-queries.sh flight-history --threads 8 --duration 60     # as fast as possible
    scripts/bench-queries.sh flight-history --rate 5 --duration 60        # 5 queries a second

- **Without `--rate`**, each of the threads runs queries back to back. This measures the
  most the server can do.
- **With `--rate`**, queries start on schedule, whatever happened to the earlier ones.
  Each query is timed from when it was due to start, so when the server falls behind,
  the latencies grow instead of the rate quietly dropping.

The results are latency percentiles, overall and by length of range. `--log FILE` writes
one line per query, and `--seed N` repeats an earlier run's queries. Add `--time
"what changed"` before the workload to append a summary to
[`testresults_query.csv`](testresults_query.csv), as `reproduce.sh` does for loads.

Each test ran 8 threads back to back for 60 seconds, from the M2 against the i5-6500,
with the same seed, so the queries were identical.

| Range | Flights returned | Ordered by date: p50 / p99 | `by_tail` projection: p50 / p99 |
| --- | ---: | ---: | ---: |
| 1 to 7 days | 6 | 54 ms / 278 ms | 39 ms / 184 ms |
| 8 to 31 days | 28 | 124 ms / 358 ms | 44 ms / 225 ms |
| 1 to 12 months | 228 | 281 ms / 6.8 s | 85 ms / 586 ms |
| 1 to 10 years | 2,629 | 3.2 s / 19.4 s | 354 ms / 2.2 s |
| **Queries a second** | | **5.7** | **41.4** |

The same test on the AWS m7i.2xlarge with the projection, run on the server itself, managed
91.9 queries a second: p50 / p99 of 12 ms / 44 ms for up to a week, and 169 ms / 869 ms
for 1 to 10 years.

At a steady 20 queries a second, about half what the i5-6500 manages flat out, it keeps up
easily: 13 ms / 28 ms for up to a week, 117 ms / 631 ms for 1 to 10 years, and a p99 of
489 ms overall, against 1.4 s when it is saturated. The AWS m7i.2xlarge, running the test on
the server itself, does the same with less latency: 8 ms / 17 ms for up to a week, 90 ms /
645 ms for 1 to 10 years, and a p99 of 460 ms overall. Short ranges gain most from
having no network in the way; the long ranges, which return thousands of rows, barely
improve.

At 30 queries a second it is barely different: 13 ms / 34 ms for up to a week, 124 ms /
658 ms for 1 to 10 years, and a p99 of 546 ms overall.

At 40 queries a second, just under what the i5-6500 manages flat out, it still completes
every query on schedule on average, but there is no headroom. The p50 holds at 30 ms
overall, while the p99 jumps to 4.1 s; even queries for up to a week see 2.6 s. When a
few long ranges arrive together, they probably hold up the queries behind them.

    scripts/bench-queries.sh flight-history --rate 20 --threads 32 --duration 60

- **Ordered by date.** `faa.ontime` is ordered by date, not by aircraft. To find one
  aircraft's flights, every flight in the range is read and `tail` is computed for each,
  so the cost grows with the length of the range.
- **With the projection.**
  [`sql/16_ontime_by_tail.sql`](sql/16_ontime_by_tail.sql) adds `by_tail`, a second copy
  of the table ordered by aircraft and then date, so only that aircraft's rows are read.
  It costs load time and disk space (see [Hardware and load times](#hardware-and-load-times)).
- **The `ORDER BY` catch.** A query that sorts by `FlightDate` doesn't use the projection
  on its own. Because the table is already in date order, ClickHouse reads it in that
  order and rejects the projection, which made the first test with it slower (3.6 queries
  a second). Queries filtering on `tail` therefore add `SETTINGS optimize_read_in_order =
  0`, as the benchmark and the Aircraft Reliability dashboard do. To check a query, run
  `EXPLAIN` on it and look for `ReadFromMergeTree (by_tail)`.

## Data mirror

The original sources are slow (IEM weather alone takes about 10 hours at one request at a
time), so the raw files are also published as [GitHub Releases](https://github.com/srmadscience/clickhouse-faadata-demo/releases)
on this repository: public, free to download, and outside git itself.

| Release | Files |
|---------|-------|
| `data-flights` | `ontime_YYYY_MM.zip`, as downloaded from BTS |
| `data-weather` | `weather_YYYY.tar`: that year's `YYYY/STATION.csv.gz` files |
| `data-reference` | `stations.tar.gz` (IEM networks and OurAirports), `ReleasableAircraft_YYYYMMDD.zip` |

GitHub shows each file's SHA-256 and the fetch scripts check it. `DATA_REPO=owner/repo`
points them at a fork's releases instead, and `DATA_REPO=none` skips the mirror.

After fetching new data, update the mirror with:

    scripts/publish-data.sh              # DRY_RUN=1 to see what it would upload

It uses the `gh` CLI and uploads only files that are new or changed. The weather data
comes from the Iowa Environmental Mesonet, which asks to be credited; the other sources
are public domain.

## Grafana

Grafana queries ClickHouse directly over its native protocol (port 9000), so the Grafana
server must be able to reach the ClickHouse server. Install the
[ClickHouse plugin](https://grafana.com/grafana/plugins/grafana-clickhouse-datasource/) first.

**Automatic setup** works for a Grafana installed from the Linux packages (configuration in
`/etc/grafana`, run by systemd as `grafana-server`) on a machine you can SSH into with a key
and passwordless sudo. Add to `clickhouse.properties`:

    grafana.ssh=user@grafana-host
    # Only if Grafana must use a different address for ClickHouse than clickhouse.url:
    #grafana.clickhouse.host=clickhouse-host

then run, now and after changing anything in `grafana/`:

    scripts/grafana-provision.sh

This installs the datasource and dashboard provider from `grafana/provisioning/`, copies
`grafana/dashboards/*.json`, puts the ClickHouse credentials in a root-only
`/etc/grafana/faa-clickhouse.env`, restarts Grafana and prints the dashboard links.
`clickhouse.properties.example` lists the other settings. The datasource is
"ClickHouse FAA" (uid `clickhouse-faa`); being provisioned, it is read-only in the UI.

**Any other Grafana** (Docker, Grafana Cloud, Windows): in Connections > Data sources, add a
ClickHouse data source with uid `clickhouse-faa`, the native protocol, port 9000 and default
database `faa`. The uid must match, because the dashboards refer to it. Then import each file
in `grafana/dashboards/` with Dashboards > New > Import.

Dashboards (folder "FAA"):

| Dashboard | Shows |
|-----------|-------|
| Flight Delays (`/d/faa-flight-delays`) | On-time %, delays and cancellations over time, delay causes, airlines, hour/weekday patterns, airport map; top 10 least reliable city pairs and flight numbers |
| Weather Impact (`/d/faa-weather-impact`) | Delays, cancellations and diversions by weather at origin and destination: flight category, present weather, wind, visibility, temperature; worst weather days |
| Airport Weather (`/d/faa-airport-weather`) | Pick an airport on a map coloured by flight category, then see its observed weather (METARs) over time: flight category, the four cloud layers' cover and height, visibility, present weather, wind, temperature and dew point, precipitation and pressure, and the raw reports |
| Aircraft Reliability (`/d/faa-aircraft-reliability`) | Per tail number: carrier-caused cancellations and delays, utilisation, out-of-service gaps, reliability by model and age, top 10 least reliable aircraft; drill into one aircraft: its registration, daily activity, disrupted flights and full flight history |

The top-10 charts rank by carrier cancellations (cancellation code A) per 1,000 flights,
so weather and air-traffic cancellations don't count against an airline, and only consider
aircraft, city pairs or flight numbers with at least "Min flights flown" completed flights
in the time range.

### Screenshots

**Flight Delays**, February to July 2026: headline figures, delays and cancellations by
day, delay causes by month and the airline table (top, above); further down, the airport
map, the most delayed airports and the least reliable city pairs and flight numbers:

![Flight Delays: airport map and top-10 rankings](docs/screenshots/flight-delays-rankings.jpg)

**Weather Impact**, February to July 2026: how late departures, cancellations and delays
vary with the weather at the departure airport:

![Weather Impact dashboard](docs/screenshots/weather-impact.jpg)

**Airport Weather**, Chicago O'Hare, February to July 2026: airports coloured by flight
category at their latest report, that report decoded, and the flight category over time:

![Airport Weather dashboard](docs/screenshots/airport-weather.jpg)

Its cloud layers over the six months, coloured by cover, over the full height and below
5,000 ft, where the shaded bands show the flight category a ceiling at that height gives:
MVFR up to 3,000 ft, IFR below 1,000 ft and LIFR below 500 ft:

![Airport Weather: cloud layers and low cloud](docs/screenshots/airport-weather-clouds.jpg)

**Aircraft Reliability**, February to July 2026: the fleet overview, the least reliable
aircraft (all ten flown by Spirit), and one aircraft's history (N511AE, a PSA Airlines CRJ-700):

![Aircraft Reliability dashboard](docs/screenshots/aircraft-reliability.jpg)
![Aircraft Reliability: least reliable aircraft](docs/screenshots/aircraft-rankings.jpg)
![Aircraft Reliability: one aircraft](docs/screenshots/aircraft-detail.jpg)

To add a dashboard: build it in Grafana, export it as JSON (Share > Export), save it in
`grafana/dashboards/`, commit, and re-run the script.

## Running on AWS

[`aws/faa-demo.yaml`](aws/faa-demo.yaml) is a CloudFormation template that builds the
whole demo on one EC2 instance (Ubuntu 24.04, m7i.xlarge by default) in a new VPC, with
only ports 22 (SSH) and 3000 (Grafana) open:

* ClickHouse, with its built-in Prometheus endpoint switched on
* Prometheus, scraping ClickHouse and node_exporter
* Grafana, with the FAA dashboards, [Node Exporter Full](https://grafana.com/grafana/dashboards/1860)
  and [Clickhouse internal exporter](https://grafana.com/grafana/dashboards/13500)
* this repository, with the flights and weather from `LoadFrom` to `LoadTo` loaded

    aws cloudformation create-stack --stack-name faa-demo \
      --template-body file://aws/faa-demo.yaml \
      --parameters ParameterKey=KeyName,ParameterValue=my-key \
                   ParameterKey=AllowedCidr,ParameterValue=$(curl -s https://checkip.amazonaws.com)/32
    aws cloudformation describe-stacks --stack-name faa-demo --query 'Stacks[0].Outputs'

Grafana's user is `admin`, with the password in the `GrafanaPassword` parameter (default
`hiredavid`). `AllowedCidr` defaults to anywhere, so set it to your own address. The
instance clones the repository and runs [`scripts/install-server.sh`](scripts/install-server.sh),
which works on any fresh Ubuntu 24.04 machine; follow its progress, about 10 to 15
minutes with the load, in `/var/log/faa-setup.log`. ClickHouse, Prometheus and node_exporter
listen only on localhost. Delete the stack to remove everything.

## Large data files

The data does not live in git: the repo holds the *recipe* (the scripts above),
the [data mirror](#data-mirror) holds a copy of the files, and `data/manifest.sha256`
can record checksums of exactly what was loaded.
