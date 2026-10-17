# ClickHouse vs Databricks: what changed in the port

This project is a port of [clickhouse-faadata-demo](https://github.com/srmadscience/clickhouse-faadata-demo).
Both load the same raw files into the same tables and run the same dashboards on them. This
page goes through every place where the code differs, and why. A port to BigQuery,
[bigquery-faadata-demo](https://github.com/srmadscience/bigquery-faadata-demo), met most of
the same problems first, and several of its answers are reused here.

Some parts are unchanged apart from the client calls: the download scripts and the data
mirror, `reproduce.sh`, the CSV reader in the Java loader, the benchmark's workload, and the
dashboards' layout, panels and variables.

## At a glance

| | ClickHouse | Databricks |
|---|---|---|
| Server | One you run (an EC2 instance in the demo) | A SQL warehouse in a Databricks workspace (serverless on Free Edition) |
| Where the tables are | database `faa` | schema `faa` in a Unity Catalog catalog (`databricks.catalog`) |
| Connection settings | `clickhouse.properties`: URL, user, password | `databricks.properties`: host, personal access token, warehouse ID, catalog |
| Scripts talk to it with | `curl` to the HTTP interface (`ch_query`, `ch_insert`) | `scripts/dbsql.py` (Python standard library only) on the SQL Statement Execution API (`dbx_query`, `dbx_run`, `dbx_values`) |
| Java client | `com.clickhouse:client-v2` | `com.databricks:databricks-jdbc`, plus `java.net.http` for file uploads |
| Table storage | `MergeTree` / `ReplacingMergeTree`, `PARTITION BY`, `ORDER BY` | Delta tables with liquid clustering (`CLUSTER BY`) |
| Getting data in | `INSERT` streams (CSV, or Native format) | files uploaded to a volume, then `INSERT ... SELECT FROM read_files(...)` |
| Replacing data | `ALTER TABLE ... DROP PARTITION`, then insert | `INSERT INTO ... REPLACE WHERE` or `INSERT OVERWRITE`, in one atomic statement |
| Duplicates | `ReplacingMergeTree` removes them in the background | `MERGE` from a staging table, keeping the most complete copy |
| Grafana plugin | `grafana-clickhouse-datasource` | the community plugin `mullerpeter-databricks-datasource` (unsigned) |
| Demo server | AWS CloudFormation: ClickHouse, Prometheus, node_exporter and Grafana on one EC2 instance | AWS CloudFormation: Grafana and the loader on one EC2 instance; the token in Secrets Manager |
| Cost model | the server, whether used or not | the warehouse while it runs (DBUs), plus storage |

## Files

| ClickHouse | Databricks | Change |
|---|---|---|
| `clickhouse.properties.example` | `databricks.properties.example` | different settings, see above |
| `src/.../ClickHouseConfig.java` | `src/.../DatabricksConfig.java` | JDBC connection and the volume's path |
| `src/.../CsvNative.java` (517 lines) | `src/.../CsvConverter.java` | CSV to Native columns, vs CSV to CSV in table order (from the BigQuery port) |
| `src/test/.../CsvNativeTest.java` | `src/test/.../CsvConverterTest.java` | tests for the above |
| `sql/15_ontime_tail.sql`, `sql/16_ontime_by_tail.sql` | (removed) | `tail` is a stored column, and clustering replaces the projection |
| (none) | `scripts/dbsql.py` | runs SQL and uploads files over the REST APIs |
| `grafana/provisioning/datasources/clickhouse.yaml` | `.../databricks.yaml` | the datasource |
| `testresults_*.csv` | (new results) | the ClickHouse results stay in that repository |

Every other SQL file, script and dashboard keeps its name, rewritten in Databricks SQL.

## Schema (`sql/`)

### Catalog, schema and volume

The SQL names tables `faa.<table>`, as in ClickHouse. `faa` is a schema, and the catalog
comes from the connection: the scripts pass `databricks.catalog` to every statement, and the
loader sets it as the JDBC connection's catalog. So, unlike the BigQuery port, nothing
rewrites the SQL. `sql/00_database.sql` also creates the volume `faa.staging`, where the
loader uploads files for `read_files` to read.

The Grafana plugin has no setting for a default catalog, so the dashboards name it
explicitly, as `${catalog}.faa.<table>`. `catalog` is a hidden constant variable, which
`grafana-provision.sh` sets from `databricks.catalog`.

### Column types

| ClickHouse | Databricks | Notes |
|---|---|---|
| `String`, `LowCardinality(String)` | `STRING NOT NULL` | Delta has no dictionary type; Parquet's dictionary encoding does the same job. Empty strings are `''`, never NULL, as in ClickHouse, so the SQL can test `tail = ''`. |
| `UInt8`, `UInt16`, `UInt32`, `Int8`, `Int32` | `INT` (`NOT NULL` unless it was `Nullable`) | never `SMALLINT`, see below |
| `Float32`, `Float64` | `DOUBLE` | never `FLOAT`, see below |
| `Nullable(T)` | a nullable column of the mapped type | |
| `Date`, `Date32` | `DATE` | |
| `DateTime('UTC')` | `TIMESTAMP` | |

The Grafana plugin cannot read a NULL from a `FLOAT` or `SMALLINT` column: the whole query
fails with "converting NULL to float32 is unsupported". `DOUBLE`, `INT`, `BIGINT`, `DATE`,
`TIMESTAMP`, `STRING` and `BOOLEAN` are fine. `DECIMAL` arrives in Grafana as text, so the
dashboards avoid it too. A side effect of `DOUBLE`: a trace of precipitation, stored as
0.0001, now equals the literal 0.0001, which it didn't as a `Float32`.

### Table layout

ClickHouse's `ORDER BY` sorts the data on disk, and its primary index lets a query skip
blocks. Delta's liquid clustering (`CLUSTER BY`, up to four columns) groups rows with nearby
values of all the clustering columns into the same files. Each file's minimum and maximum
then let a query skip files. Clustering happens as `OPTIMIZE` runs, which the load scripts do
after loading. There are no partitions: Databricks advises against them for tables under
about 1 TB.

| Table | ClickHouse | Databricks |
|---|---|---|
| `ontime` | `PARTITION BY toYYYYMM(FlightDate) ORDER BY (FlightDate, Origin, Reporting_Airline)`, plus the `by_tail` projection | `CLUSTER BY (tail, FlightDate)` |
| `weather` | `ReplacingMergeTree`, `PARTITION BY toYYYYMM(valid) ORDER BY (station, valid)` | `CLUSTER BY (station, valid)` |
| `flight_weather` | `ORDER BY (FlightDate, Origin, Reporting_Airline)` | `CLUSTER BY (FlightDate, Origin)` |
| `tail_day` | `ORDER BY (tail, FlightDate, Reporting_Airline)` | `CLUSTER BY (tail, FlightDate)` |
| `stations`, `airports` | `ReplacingMergeTree ORDER BY station` / `id` | `CLUSTER BY (station)` / `(iata_code)`, replaced whole on each load |
| registry tables | `MergeTree ORDER BY tail` etc. | `CLUSTER BY (tail)` etc. |

New in Databricks: `weather_load`, a staging table with `weather`'s columns.

Delta keeps the per-file statistics that clustering and file skipping need only for a
table's first 32 columns. `ontime` has 110, so `tail` sits right after `Tail_Number`, not at
the end; at the end, `CREATE TABLE` fails.

### The `tail` column and the `by_tail` projection

In ClickHouse, `tail` is an `ALIAS` column on `ontime`, computed when a query reads it:
`upper(if(match(Tail_Number, '^[0-9]'), concat('N', Tail_Number), Tail_Number))`. It fixes
Allegiant's tail numbers, which lack the `N`. The `by_tail` projection keeps a second,
hidden copy of `ontime` sorted by that expression, so that one aircraft's history is quick
to read.

Delta has no projections, and an alias column would not help clustering. As in the BigQuery
port, `tail` is a real column, filled in by the loader (`CsvConverter.normaliseTail`, from the
same rule), and `ontime` is clustered by it. There is no second copy of the table, and the
benchmark and dashboards no longer need ClickHouse's `optimize_read_in_order = 0` setting.

### Views

| Idiom | ClickHouse | Databricks |
|---|---|---|
| A literal table | `SELECT * FROM values('bts_code String, iata_code String', ('PBI', 'DJT'), ...)` | `SELECT * FROM VALUES ('PBI', 'DJT'), ... AS t(bts_code, iata_code)` |
| One row per array element | `arrayJoin(arrayFilter(c -> c != '', [local_code, icao_code, ...]))` | `posexplode(filter(array(local_code, icao_code, ...), c -> c != ''))` |
| First row of each group | `ORDER BY ... LIMIT 1 BY iata_code` | `QUALIFY row_number() OVER (PARTITION BY iata_code ORDER BY ...) = 1` |
| Replace columns of `*` | `SELECT ap.* REPLACE (al.bts_code AS iata_code)` | the columns listed |
| Typed NULL | `CAST(NULL AS Nullable(Date32))` | `CAST(NULL AS DATE)` |

Databricks SQL has lambdas (`filter`, `transform`), so array code stays closer to ClickHouse
than in the BigQuery port. In `airport_station`, the position from `posexplode` makes the
order of preference (`local_code`, `icao_code`, `gps_code`, `ident`) explicit, as the
BigQuery port does. In `aircraft`, an aircraft deregistered more than once can have several
records with the same cancellation date, or none; ClickHouse picks one arbitrarily, and here
the most recent action, then the serial number, decide.

## Loading (Java)

### How rows get to the warehouse

ClickHouse's loader sends `INSERT` streams. Databricks reads files instead: SQL can't be fed
a stream of rows the way ClickHouse's HTTP interface can, and `INSERT ... VALUES` over JDBC
would be far too slow for 68 million flights. So the loader:

1. reads the table's columns from `information_schema.columns`,
2. converts each file with `CsvConverter`, as the BigQuery port does: headerless CSV in the
   table's column order, `tail` filled in, NULL written as `\N`, every string quoted so that
   an empty one is `""` and not NULL, and timestamps written in ISO 8601 with a `Z`, so that
   they mean UTC whatever the session's time zone,
3. gzips each one and uploads it to a new directory in the volume `faa.staging` with the
   Files API (`PUT /api/2.0/fs/files/Volumes/...`), `--jobs N` files at a time,
4. runs one `INSERT` that reads them all: `INSERT INTO faa.ontime REPLACE WHERE ... SELECT ...
   FROM read_files('/Volumes/<catalog>/faa/staging/<dir>/', format => 'csv', schema => ...,
   nullValue => '\N', mode => 'FAILFAST')`,
5. deletes the uploaded files.

`FAILFAST` makes a field that doesn't parse fail the load, instead of becoming NULL.

The converter writes a few bytes at a time, so its output goes through a
`BufferedOutputStream` before the `GZIPOutputStream`. Without it, writing one month of
flights took 57 s instead of 4.

### Empty values

The loaders agree on empty strings, which are `''`, but not on empty numbers. `CsvNative`
copies ClickHouse's own CSV rules, under which a quoted empty field (`""`) is 0 in a number
column; BTS writes cancelled flights' missing times (`DepTime`, `ArrTime` and others) that
way. `CsvConverter` makes every empty number NULL, quoted or not. In June 2025, 9,172
flights have a NULL `DepTime` here and 0 in ClickHouse; the Flight history table therefore
shows them blank instead of `0000`.

### Replacing a month

| | ClickHouse | Databricks |
|---|---|---|
| Flights | `ALTER TABLE faa.ontime DROP PARTITION 202501`, then insert. Not atomic. | `INSERT INTO faa.ontime REPLACE WHERE (FlightDate >= DATE '2025-01-01' AND FlightDate < DATE '2025-02-01') SELECT ...`: every month loaded is replaced in one atomic statement, which also fails if a file holds a flight from another month. |
| Stations, airports | `TRUNCATE`, then insert | `INSERT OVERWRITE` |

`REPLACE WHERE` accepts only simple conditions on the columns: it rejects
`date_format(FlightDate, 'yyyyMM') IN (...)`, hence the date ranges (`months_where` in
`scripts/lib.sh`).

### Errors

The JDBC driver's exception messages contain the server's whole response, Java stack trace
and all. The loader prints just the error (`Loader.serverMessage`).

## Scripts

### Running SQL

`ch_query` POSTs SQL to ClickHouse's HTTP port with `curl`, and `ch_insert` streams a file
into an `INSERT ... FORMAT` query. Here `scripts/dbsql.py` submits each statement to the SQL
Statement Execution API, waits for it (cancelling it on Ctrl-C), and fetches the result.
`dbx_query` prints a table, `dbx_run` runs a statement silently, and `dbx_values` returns
tab-separated values for shell loops. `dbsql.py put` uploads a file to the volume. The
token reaches it through the environment, never the command line. Each call runs one
statement.

Most SQL functions change name: `count()` → `count(*)`, `countIf` → `count_if`, `uniqExact`
→ `count(DISTINCT ...)`, `any` → `any_value`, `topK(1)` → `mode`, `argMax` → `max_by`,
`toYear(d)` → `year(d)`, `match` → `RLIKE`, `multiIf` → `CASE`, `ifNull` → `coalesce`,
`intDiv(a, b)` → `a DIV b`, `[a, b]` → `array(a, b)`, `indexOf` → `array_position`.

### Names are case-insensitive

Databricks matches column names without regard to case, so an alias can collide with a
column: in `SELECT ... AS month ... GROUP BY month`, `month` is `ontime`'s `Month` column. The
scripts use other aliases.

### Rebuilding derived tables: `build-tail-day.sh`, `build-flight-weather.sh`

The ClickHouse scripts loop over the months, dropping each month's partition and inserting
it again. Here each script is one statement: `INSERT OVERWRITE` for the whole table, or
`INSERT INTO ... REPLACE WHERE` for the months given (`scripts/build-tail-day.sh 202606`).
Readers never see a half-built table. `OPTIMIZE` then clusters the new rows.

### Matching flights to weather (`build-flight-weather.sh`)

This is the largest rewrite. Each flight takes the latest weather report at or before its
scheduled departure at the origin, and its scheduled arrival at the destination. Reports
more than 2 hours old are not used.

- **ClickHouse** does this with `ASOF LEFT JOIN ... ON station = ... AND valid <= sched_dep_utc`,
  one month at a time.
- **Databricks** has no ASOF join, so the script uses the BigQuery port's method. It stacks
  the flights and the weather reports into one stream per station and day. A window,
  `last_value(w, true) OVER (PARTITION BY station, day ORDER BY t, kind ROWS BETWEEN
  UNBOUNDED PRECEDING AND CURRENT ROW)`, then gives each flight the last report before it.
  Each report is also copied into the next day, so that a flight just after midnight can
  still match a report from late the evening before. It runs once for departures and once
  more for arrivals. For June 2025, a brute-force join found the same report as the window
  for all 611,545 flights, at both ends.

Converting local scheduled times to UTC is simpler here. `make_timestamp(year, month, day,
hour, minute, 0, tzname)` takes the time zone from a column. ClickHouse's `toDateTime` needs
a constant time zone, so its script generated one `multiIf` branch for every time zone in use.

Other details:
- **Ceiling:** the lowest broken, overcast or obscured cloud layer: `array_min(array(...))`,
  which skips NULLs, where ClickHouse used `arrayFilter`/`arrayMin`.
- **Unmatched rows:** ClickHouse's `join_use_nulls = 0` filled them with defaults, tested as
  `valid > toDateTime(0)`. Here they are plain NULLs.

### Weather (`load-weather.sh`)

ClickHouse loads every year straight into `weather`, and `ReplacingMergeTree` removes
duplicate `(station, valid)` rows in the background as it merges parts, keeping the last one
inserted. Delta doesn't deduplicate. So each year directory is uploaded as one file into
`weather_load`, and a `MERGE` copies the rows into `weather`: a report already there is
updated, a new one inserted. Re-loading a year is therefore safe, and duplicates never reach
`weather` at all. For 2025, 3,851,434 reports loaded and 3,850,840 remained, as in the
BigQuery port.

Of a report that IEM lists twice, the `MERGE` keeps the most complete copy: the one with
the fewest missing temperature, dew point, visibility and pressure values. Often one copy
has no temperature. ClickHouse keeps whichever came later in the file, which is not always
the complete one. That explains the small differences between the two databases' weather,
and the few flights per month whose matched weather differs.

### Aircraft registry (`load-registry.sh`)

ClickHouse streams each raw registry file to the server and parses it there with
`input('c1 String, ...')`. Personal data (individuals' names) is blanked in that SQL, which
means the raw file, addresses and all, is sent to the server first.

As in the BigQuery port, the script blanks on the client instead, with `awk`: every field
the tables don't use (addresses among them), and the owner's name unless it belongs to an
organisation. Only then does the file go to the volume. SQL reads it with `read_files`,
every field a `STRING` (`c1` to `c40`), with quoting off (`quote => ''`) because the files
contain bare quotes, and `mode => 'PERMISSIVE'` because rows have from 14 to 40 fields.
`try_to_date` and `try_cast` stand in for ClickHouse's `toDate32OrNull` and
`toUInt16OrNull`.

`aircraft_info.make_model` is NULL, not `' '`, for an aircraft whose model code isn't in the
model table.

### Stations (`load-stations.sh`, `stations_to_csv.py`)

ClickHouse inserted headerless CSV rows and let `ReplacingMergeTree` resolve any station
listed in more than one network file. As in the BigQuery port, `stations_to_csv.py` writes a
header, so the Java loader can match columns by name, and keeps one row per station itself.
The OurAirports CSV goes through the Java loader as well.

### Schema (`create-database.sh`)

The script is the same and still runs one statement at a time; at the end it lists tables
from `information_schema.tables` instead of `system.tables`.

### Local data as symbolic links

`data/raw/<kind>/` can link to another copy of the files, such as a clone of the ClickHouse
project. The loader follows links (`Files.walk(..., FOLLOW_LINKS)`), and so do
`checksums.sh` (`find -L`) and `make_tar.py` (`dereference=True`).

## Benchmark (`QueryBench`)

The workload, its random ranges and its output are unchanged. The differences:

| | ClickHouse | Databricks |
|---|---|---|
| Parameters | `{tail:String}`, `{from:Date}` | JDBC `?` parameters |
| Connections | the client's HTTP connection pool | one JDBC connection per thread, all opened before the test starts, so no timed query waits for one |
| Caching | none to avoid | `SET use_cached_result = false` on each connection, so every query really runs |
| Timeout | socket timeout on the client | `Statement.setQueryTimeout`, which cancels the query |
| Settings | `optimize_read_in_order = 0` (see `by_tail`) | none |
| Results column | `clickhouse_version` | `server` (`Databricks SQL 2026.39`) |

## Grafana dashboards

All 82 queries (74 panel queries and 8 variable queries) were rewritten for the community
Databricks plugin, keeping each panel's layout, title, units, column names and variables.
Typical changes:

- **Date filters.** The plugin has no `$__dateFilter`, so ClickHouse's
  `$__dateFilter(FlightDate)` becomes `FlightDate BETWEEN CAST($__timeFrom AS DATE) AND
  CAST($__timeTo AS DATE)`. `$__timeFilter(valid)` on timestamps is unchanged.
- **Macros without brackets.** The plugin replaces macros from a Go map, in random order, so
  `$__timeFrom()` can be mangled by the replacement for `$__timeFrom`. The queries use only
  the forms without brackets.
- **No semicolons.** The plugin splits a query at every `;` and runs the parts separately.
- **Time series.** Queries return `CAST(FlightDate AS TIMESTAMP) AS time`, not a `DATE`.
- **Division.** Databricks raises an error on division by zero, where ClickHouse returns
  `nan` or `inf`, so ratios use `try_divide`, which returns NULL.
- **Column names** need no change: Databricks accepts any back-quoted alias, `Cxl/1k`,
  `°F` and `◔ FEW` included.
- **Aliases in the same SELECT.** ClickHouse lets a column use an alias defined earlier in
  the same `SELECT` (`round(1000 * Cxl / Flights, 1)`), including in aggregate queries. The
  port repeats the expression or computes it in a subquery.
- **Arrays.** An aircraft's longest gap between flights was
  `arrayMax(arrayDifference(arraySort(groupUniqArray(toRelativeDayNum(FlightDate)))))`. It is
  now `array_sort(collect_set(FlightDate))` in an inner query, and
  `array_max(transform(days, (d, i) -> if(i = 0, 0, datediff(d, days[i - 1]))))` in the outer
  one. `topK(3)(o_wx)`, the three commonest kinds of weather, becomes a count per kind,
  sorted.
- **The latest report.** The Airport Weather stats each read the airport's latest report
  (`ORDER BY valid DESC LIMIT 1`) once, in a subquery, before deriving the ceiling or flight
  category from it.

Each query was run on both databases for June 2025 and the results compared cell by cell.
They agree, apart from the differences explained above (the NULL times, the weather
duplicates), ties in the sort order, and rounding at exactly .5: ClickHouse rounds 10.25 to
10.2, and Databricks rounds it to 10.3. Each panel was also run through Grafana 13.2.3 with
the plugin, to check that every column reaches Grafana with the right type.

The datasource (`grafana/provisioning/datasources/databricks.yaml`) authenticates with the
personal access token, given to Grafana through a file only root can read. The plugin is
unsigned, so `grafana-provision.sh` installs it and adds it to
`allow_loading_unsigned_plugins` in `grafana.ini`. Its default row limit, 10,000, would cut
off a year of one airport's weather reports, so the datasource raises it to 100,000.

## Running in the cloud

The ClickHouse demo server (`aws/faa-demo.yaml` with `install-server.sh`) runs everything on
one EC2 instance: ClickHouse, Prometheus, node_exporter and Grafana, with two monitoring
dashboards.

There is no database server to run or monitor with Databricks, so the instance runs only
Grafana and the loader, on a smaller instance type (m7i.large by default). The template takes
the workspace host, warehouse ID, catalog and token as parameters. The token goes into an AWS
Secrets Manager secret, which only the instance's IAM role can read, instead of the
instance's user data. It doesn't load any data by default (`LoadFrom` is `none`), as the
tables live in the workspace and may well be loaded already. Deleting the stack leaves the
data in Databricks.
