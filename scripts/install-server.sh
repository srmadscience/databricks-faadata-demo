#!/usr/bin/env bash
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

# Turns a fresh Ubuntu 24.04 machine into a demo server for an existing
# Databricks workspace: Grafana with the community Databricks plugin and the
# FAA dashboards, and this repository, optionally with data loaded into
# Databricks. The tables live in the workspace, not on this machine, so it
# needs no database of its own. Used by aws/faa-demo.yaml; run as root from a
# clone of the repository:
#
#   sudo GRAFANA_PASSWORD=secret DATABRICKS_HOST=... DATABRICKS_TOKEN=... \
#        DATABRICKS_WAREHOUSE_ID=... scripts/install-server.sh [FROM_YYYY-MM TO_YYYY-MM]
#
# FROM/TO is the range of flights to load (see scripts/reproduce.sh); without
# them, or with "none", nothing is loaded. Settings, as environment variables:
#   GRAFANA_PASSWORD         password for Grafana's admin user (required)
#   DATABRICKS_HOST, DATABRICKS_TOKEN, DATABRICKS_WAREHOUSE_ID
#                            workspace, personal access token and SQL warehouse
#                            (required, unless databricks.properties has them)
#   DATABRICKS_CATALOG       catalog holding the faa schema (default main)
#   APP_USER                 owner of the repository and runner of the load
#                            (default: the owner of the repository directory)
# The settings are kept in the repository's databricks.properties, readable
# only by APP_USER. Grafana listens on port 3000. Safe to re-run.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -n "${GRAFANA_PASSWORD:-}" ]] || { echo "error: set GRAFANA_PASSWORD" >&2; exit 1; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP_USER="${APP_USER:-$(stat -c %U "$REPO")}"
FROM="${1:-none}"
TO="${2:-$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m)}"
export DEBIAN_FRONTEND=noninteractive

step() { echo; echo "=== $(date '+%H:%M:%S') $*"; }

step "Packages"
apt-get update -q
apt-get install -y -q curl gnupg git unzip python3 openjdk-21-jdk-headless maven

step "Settings"
# Written from the environment; values not given are kept from an earlier run.
PROPS="$REPO/databricks.properties"
old() { sed -n "s/^$1=//p" "$PROPS" 2>/dev/null | tail -1; }
HOST="${DATABRICKS_HOST:-$(old databricks.host)}"
TOKEN="${DATABRICKS_TOKEN:-$(old databricks.token)}"
WAREHOUSE="${DATABRICKS_WAREHOUSE_ID:-$(old databricks.warehouse_id)}"
CATALOG="${DATABRICKS_CATALOG:-$(old databricks.catalog)}"
[[ -n "$HOST" && -n "$TOKEN" && -n "$WAREHOUSE" ]] \
  || { echo "error: set DATABRICKS_HOST, DATABRICKS_TOKEN and DATABRICKS_WAREHOUSE_ID" >&2; exit 1; }
install -o "$APP_USER" -m 600 /dev/null "$PROPS"
cat > "$PROPS" <<PROPS_EOF
databricks.host=$HOST
databricks.token=$TOKEN
databricks.warehouse_id=$WAREHOUSE
databricks.catalog=${CATALOG:-main}
grafana.ssh=local
PROPS_EOF
as_app() { sudo -u "$APP_USER" -H bash -c "cd '$REPO' && $*"; }
# Run as APP_USER, with no DATABRICKS_* left in the environment, the scripts
# read databricks.properties.
unset DATABRICKS_HOST DATABRICKS_TOKEN DATABRICKS_WAREHOUSE_ID DATABRICKS_CATALOG
as_app 'source scripts/lib.sh && dbx_check_connection'

step "Grafana"
if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/grafana.gpg
  echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -q
fi
apt-get install -y -q grafana
systemctl enable grafana-server
systemctl restart grafana-server
for _ in $(seq 60); do curl -fs http://localhost:3000/api/health > /dev/null && break; sleep 1; done
grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
  admin reset-admin-password "$GRAFANA_PASSWORD" > /dev/null
echo "Grafana admin password set"

step "Repository"
as_app 'mvn -q -B package -DskipTests'
as_app scripts/create-database.sh > /dev/null
# The plugin, its datasource and the FAA dashboards; grafana-provision.sh runs
# as root here, so its sudo calls need no password.
(cd "$REPO" && scripts/grafana-provision.sh)

if [[ "$FROM" != none ]]; then
  step "Loading flights $FROM to $TO (see scripts/reproduce.sh)"
  as_app "scripts/reproduce.sh --time 'install-server.sh on $(hostname)' $FROM $TO"
fi

step "Done"
echo "Grafana: port 3000, user admin. Dashboards: FAA folder."
