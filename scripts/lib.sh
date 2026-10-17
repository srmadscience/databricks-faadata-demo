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

# Shared helpers, sourced by the other scripts. Not meant to be run directly.
#
# Connection settings come from DATABRICKS_HOST / DATABRICKS_TOKEN /
# DATABRICKS_WAREHOUSE_ID / DATABRICKS_CATALOG, falling back to
# databricks.properties, then defaults. SQL names tables faa.<table>, in the
# catalog given by DATABRICKS_CATALOG (default main).

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOADER_JAR="$PROJECT_DIR/target/databricks-faadata-demo-0.1.0-SNAPSHOT-all.jar"

prop() {
  [[ -f "$PROJECT_DIR/databricks.properties" ]] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PROJECT_DIR/databricks.properties" | tail -1
}

DBX_HOST="${DATABRICKS_HOST:-$(prop databricks.host)}"; DBX_HOST="${DBX_HOST#https://}"; DBX_HOST="${DBX_HOST%/}"
DBX_TOKEN="${DATABRICKS_TOKEN:-$(prop databricks.token)}"
DBX_WAREHOUSE="${DATABRICKS_WAREHOUSE_ID:-$(prop databricks.warehouse_id)}"
DBX_WAREHOUSE="${DBX_WAREHOUSE##*/}"   # the ID, or the HTTP path /sql/1.0/warehouses/<id>
DBX_CATALOG="${DATABRICKS_CATALOG:-$(prop databricks.catalog)}"; DBX_CATALOG="${DBX_CATALOG:-main}"
# The staging volume (sql/00_database.sql), for files that SQL reads with read_files.
DBX_VOLUME="/Volumes/$DBX_CATALOG/faa/staging"
# dbsql.py and the Java loader read these, so they connect to the same
# warehouse whatever directory the scripts are run from. The token stays in
# the environment, never on a command line.
export DATABRICKS_HOST="$DBX_HOST" DATABRICKS_TOKEN="$DBX_TOKEN" \
       DATABRICKS_WAREHOUSE_ID="$DBX_WAREHOUSE" DATABRICKS_CATALOG="$DBX_CATALOG"

dbsql() { python3 -I "$PROJECT_DIR/scripts/dbsql.py" "$@"; }

# dbx_query SQL: runs one statement and prints the result as a table.
dbx_query() { dbsql query --format table "$1"; }
# dbx_values SQL: prints the result's values, tab-separated, without a header,
# for shell loops.
dbx_values() { dbsql query --format tsv "$1"; }
# dbx_run SQL: runs one statement, printing nothing.
dbx_run() { dbsql query --format none "$1"; }
# dbx_put LOCAL_FILE VOLUME_PATH / dbx_rm VOLUME_PATH...: copy a file into a
# volume, or delete files from one.
dbx_put() { dbsql put "$1" "$2"; }
dbx_rm() { dbsql rm "$@"; }

dbx_check_connection() {
  [[ -n "$DBX_HOST" && -n "$DBX_TOKEN" && -n "$DBX_WAREHOUSE" ]] || {
    echo "error: set databricks.host, databricks.token and databricks.warehouse_id in databricks.properties" >&2
    echo "       (see databricks.properties.example), or DATABRICKS_HOST / _TOKEN / _WAREHOUSE_ID" >&2
    exit 1
  }
  local info
  info=$(dbx_values "SELECT current_version().dbsql_version, current_user()") \
    || { echo "error: cannot run SQL on warehouse $DBX_WAREHOUSE at $DBX_HOST" >&2; exit 1; }
  echo "Databricks SQL ${info%%$'\t'*} at $DBX_HOST, warehouse $DBX_WAREHOUSE, catalog $DBX_CATALOG, as ${info#*$'\t'}"
}

# dbx_version: the warehouse's Databricks SQL version, for test results.
dbx_version() { dbx_values "SELECT current_version().dbsql_version"; }

# Builds the Java loader if it isn't there yet.
ensure_loader() {  # builds the loader if it is missing or older than its source
  if [[ ! -f "$LOADER_JAR" || -n "$(find "$PROJECT_DIR/src" "$PROJECT_DIR/pom.xml" -newer "$LOADER_JAR" | head -1)" ]]; then
    echo "Building loader..."
    (cd "$PROJECT_DIR" && mvn -q -B package -DskipTests)
  fi
}

# Polite downloader: retries, resumes, and only renames into place when complete.
download() {
  local url="$1" target="$2"
  mkdir -p "$(dirname "$target")"
  curl -fsSL --retry 5 --retry-delay 10 -C - -o "$target.part" "$url" && mv "$target.part" "$target"
}

# Public mirror of data/raw/: GitHub Releases on this repository, published by
# scripts/publish-data.sh. The fetch scripts try it before the original sources.
# Set DATA_REPO=owner/repo to use a fork's releases, or DATA_REPO=none to skip it.
# The raw files are the same for every database, so this uses the ClickHouse
# version's releases.
DATA_REPO="${DATA_REPO:-srmadscience/clickhouse-faadata-demo}"

# mirror_assets TAG: lists release TAG's files as "name<TAB>sha256<TAB>url";
# prints nothing if the release doesn't exist or the mirror is off.
mirror_assets() {
  [[ "$DATA_REPO" != none ]] || return 0
  python3 -I "$PROJECT_DIR/scripts/mirror.py" "$DATA_REPO" "$1"
}

# mirror_fetch LISTING NAME TARGET: downloads file NAME, as listed by
# mirror_assets, to TARGET and checks its SHA-256. Fails if it isn't mirrored.
mirror_fetch() {
  local name sum url
  IFS=$'\t' read -r name sum url < <(awk -F'\t' -v n="$2" '$1 == n' <<< "$1") || true
  [[ -n "$url" ]] || return 1
  download "$url" "$3" || { rm -f "$3.part"; return 1; }
  if [[ "$(shasum -a 256 "$3" | cut -d' ' -f1)" != "$sum" ]]; then
    echo "error: $name from the mirror does not match its checksum; deleted" >&2
    rm -f "$3"
    return 1
  fi
}

# mirror_fetch_many LISTING DIR NAME...: downloads the files NAME... that the
# mirror has, as listed by mirror_assets, into DIR, FETCH_JOBS (default 4) at a
# time: one download from GitHub runs at about 3 MB/s, four together at about
# 11. Checks each file's SHA-256 and prints the names of those it fetched.
# GitHub sometimes answers a burst of downloads with 504s that outlast curl's
# retries, so files the parallel pass misses are tried again one at a time;
# any still missing are named in a warning, and the caller falls back to the
# original source.
mirror_fetch_many() {
  local listing="$1" dir="$2" name sum url args=() missed=()
  shift 2
  for name in "$@"; do
    url=$(awk -F'\t' -v n="$name" '$1 == n { print $3 }' <<< "$listing")
    [[ -z "$url" ]] || args+=(-o "$dir/$name.part" "$url")
  done
  [[ ${#args[@]} -gt 0 ]] || return 0
  mkdir -p "$dir"
  curl -fsSL -Z --parallel-max "${FETCH_JOBS:-4}" --retry 5 --retry-delay 10 -C - "${args[@]}" || true
  for name in "$@"; do
    sum=$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' <<< "$listing")
    [[ -n "$sum" ]] || continue
    if [[ -f "$dir/$name.part" && "$(shasum -a 256 "$dir/$name.part" | cut -d' ' -f1)" == "$sum" ]]; then
      mv "$dir/$name.part" "$dir/$name"
      echo "$name"
    else
      rm -f "$dir/$name.part"
      missed+=("$name")
    fi
  done
  [[ ${#missed[@]} -gt 0 ]] || return 0
  echo "warn: ${#missed[@]} file(s) failed to download from the mirror; retrying one at a time" >&2
  for name in "${missed[@]}"; do
    if mirror_fetch "$listing" "$name" "$dir/$name"; then
      echo "$name"
    else
      echo "warn: could not download $name from the mirror" >&2
    fi
  done
}

# months_where COLUMN YYYYMM...: a predicate for the rows of COLUMN (a DATE) in
# those months, as date ranges, which INSERT ... REPLACE WHERE can use (it
# rejects functions of the column, such as date_format).
months_where() {
  local col="$1" m y n p=""
  shift
  for m in "$@"; do
    [[ "$m" =~ ^[0-9]{6}$ ]] || { echo "error: months are YYYYMM, not $m" >&2; return 1; }
    y=$((10#${m:0:4})); n=$((10#${m:4:2}))
    p+=" OR ($col >= DATE '$(printf '%04d-%02d' "$y" "$n")-01' AND $col < DATE '$( ((n == 12)) && printf '%04d-01' $((y + 1)) || printf '%04d-%02d' "$y" $((n + 1)))-01')"
  done
  echo "(${p# OR })"
}

# month_range 2024-11 2025-02 -> 2024-11 2024-12 2025-01 2025-02
month_range() {
  local y=$((10#${1%-*})) m=$((10#${1#*-})) ey=$((10#${2%-*})) em=$((10#${2#*-}))
  while (( y * 12 + m <= ey * 12 + em )); do
    printf '%04d-%02d\n' "$y" "$m"
    (( m == 12 )) && { m=1; y=$((y + 1)); } || m=$((m + 1))
  done
}
