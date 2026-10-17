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
# Connection settings come from CLICKHOUSE_URL / CLICKHOUSE_USER /
# CLICKHOUSE_PASSWORD, falling back to clickhouse.properties, then defaults.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOADER_JAR="$PROJECT_DIR/target/clickhouse-faadata-demo-0.1.0-SNAPSHOT-all.jar"

prop() {
  [[ -f "$PROJECT_DIR/clickhouse.properties" ]] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PROJECT_DIR/clickhouse.properties" | tail -1
}

CH_URL="${CLICKHOUSE_URL:-$(prop clickhouse.url)}"; CH_URL="${CH_URL:-http://localhost:8123}"
CH_USER="${CLICKHOUSE_USER:-$(prop clickhouse.user)}"; CH_USER="${CH_USER:-default}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-$(prop clickhouse.password)}"
# The Java loader reads these first, so it connects to the same server whatever
# directory the scripts are run from.
export CLICKHOUSE_URL="$CH_URL" CLICKHOUSE_USER="$CH_USER" CLICKHOUSE_PASSWORD="$CH_PASSWORD"

# ch_query SQL [curl args...]: run one statement over HTTP, print the result.
# The password goes in a header, not the URL, so it never shows up in logs.
ch_query() {
  local sql="$1"; shift
  curl -sS --fail-with-body "$CH_URL/" \
    -H "X-ClickHouse-User: $CH_USER" \
    -H "X-ClickHouse-Key: $CH_PASSWORD" \
    --data-binary "$sql" "$@"
}

# ch_insert "INSERT INTO t FORMAT X" [setting=value&...] < data: stream stdin
# as the insert's data, optionally with ClickHouse settings.
ch_insert() {
  local q
  q=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")
  curl -sS --fail-with-body "$CH_URL/?query=$q${2:+&$2}" \
    -H "X-ClickHouse-User: $CH_USER" \
    -H "X-ClickHouse-Key: $CH_PASSWORD" \
    --data-binary @-
}

ch_check_connection() {
  local version
  version=$(ch_query 'SELECT version()') || { echo "error: cannot connect to $CH_URL as $CH_USER: $version" >&2; exit 1; }
  echo "ClickHouse $version at $CH_URL as $CH_USER"
}

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

# month_range 2024-11 2025-02 -> 2024-11 2024-12 2025-01 2025-02
month_range() {
  local y=$((10#${1%-*})) m=$((10#${1#*-})) ey=$((10#${2%-*})) em=$((10#${2#*-}))
  while (( y * 12 + m <= ey * 12 + em )); do
    printf '%04d-%02d\n' "$y" "$m"
    (( m == 12 )) && { m=1; y=$((y + 1)); } || m=$((m + 1))
  done
}
