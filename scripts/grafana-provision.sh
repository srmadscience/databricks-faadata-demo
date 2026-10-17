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

# Configures a Grafana server over SSH: a Linux package install (/etc/grafana,
# /var/lib/grafana, systemd service grafana-server), reached with key login and
# passwordless sudo. grafana.ssh=local configures a Grafana on this machine
# instead, without SSH.
#   - installs the community Databricks plugin (mullerpeter-databricks-datasource)
#     if it is missing, and allows it to load, as it is unsigned
#   - installs the Databricks datasource and dashboard provider from grafana/provisioning/
#   - copies grafana/dashboards/*.json to the dashboard folder Grafana watches,
#     with their catalog set to databricks.catalog
#   - gives grafana-server the Databricks token via a root-only env file
#   - restarts Grafana and reports provisioning errors from its log
# Grafana uses the same workspace, SQL warehouse, catalog and token as the
# scripts. Safe to re-run; re-run after adding or changing dashboards.
#
# Settings: databricks.* and grafana.* in databricks.properties (see
# databricks.properties.example), or the environment variables below.
#
#   scripts/grafana-provision.sh
#   GRAFANA_SSH=me@grafana-host scripts/grafana-provision.sh
#   GRAFANA_SSH=local scripts/grafana-provision.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

GRAFANA_SSH="${GRAFANA_SSH:-$(prop grafana.ssh)}"
[[ -n "$GRAFANA_SSH" ]] || { echo "error: set grafana.ssh=user@host in databricks.properties, or GRAFANA_SSH" >&2; exit 1; }
GRAFANA_URL="${GRAFANA_URL:-$(prop grafana.url)}"
GRAFANA_HOST=${GRAFANA_SSH#*@}; [[ "$GRAFANA_SSH" != local ]] || GRAFANA_HOST=localhost
GRAFANA_URL="${GRAFANA_URL:-http://$GRAFANA_HOST:3000}"
GRAFANA_PORT=$(sed -E 's#^[a-z]+://[^/:]+:?([0-9]*).*#\1#' <<< "$GRAFANA_URL"); GRAFANA_PORT="${GRAFANA_PORT:-3000}"
[[ -n "$DBX_HOST" && -n "$DBX_TOKEN" && -n "$DBX_WAREHOUSE" ]] \
  || { echo "error: set databricks.host, databricks.token and databricks.warehouse_id in databricks.properties" >&2; exit 1; }
PLUGIN=mullerpeter-databricks-datasource
PLUGIN_URL="https://github.com/mullerpeter/databricks-grafana/releases/download/v1.3.8/$PLUGIN.zip"

PROV="$PROJECT_DIR/grafana/provisioning"

# remote COMMAND...: runs a shell command on the Grafana server, as ssh would.
if [[ "$GRAFANA_SSH" == local ]]; then
  remote() { bash -c "$*"; }
else
  remote() { ssh -o BatchMode=yes "$GRAFANA_SSH" "$@"; }
fi

if ! remote "test -d /var/lib/grafana/plugins/$PLUGIN"; then
  echo "Installing the $PLUGIN plugin"
  remote "sudo grafana cli --pluginUrl '$PLUGIN_URL' plugins install $PLUGIN > /dev/null && \
          sudo chown -R grafana:grafana /var/lib/grafana/plugins/$PLUGIN"
fi
# The plugin is unsigned, so Grafana loads it only if grafana.ini names it:
# add it to allow_loading_unsigned_plugins, keeping any plugins listed already.
remote "sudo bash -s -- $PLUGIN" <<'EOF'
ini=/etc/grafana/grafana.ini
if ! grep -q "^allow_loading_unsigned_plugins.*$1" $ini; then
  if grep -q '^allow_loading_unsigned_plugins *= *[^ ]' $ini; then
    sed -i "s/^\(allow_loading_unsigned_plugins *=.*[^ ]\) *$/\1,$1/" $ini
  elif grep -q '^;*allow_loading_unsigned_plugins' $ini; then
    sed -i "s/^;*allow_loading_unsigned_plugins *=.*/allow_loading_unsigned_plugins = $1/" $ini
  else
    sed -i "s/^\[plugins\]$/[plugins]\nallow_loading_unsigned_plugins = $1/" $ini
  fi
fi
grep -q "^allow_loading_unsigned_plugins.*$1" $ini \
  || { echo "error: set allow_loading_unsigned_plugins = $1 under [plugins] in $ini" >&2; exit 1; }
EOF

echo "Installing provisioning files on $GRAFANA_SSH (Databricks $DBX_HOST, warehouse $DBX_WAREHOUSE, catalog $DBX_CATALOG)"
sed -e "s#__DATABRICKS_HOST__#$DBX_HOST#" -e "s#__HTTP_PATH__#sql/1.0/warehouses/$DBX_WAREHOUSE#" "$PROV/datasources/databricks.yaml" \
  | remote "sudo install -o root -g grafana -m 640 /dev/stdin /etc/grafana/provisioning/datasources/faa-databricks.yaml"
remote "sudo install -o root -g grafana -m 640 /dev/stdin /etc/grafana/provisioning/dashboards/faa.yaml" \
  < "$PROV/dashboards/faa.yaml"

remote "sudo install -d -o grafana -g grafana -m 755 /var/lib/grafana/dashboards/faa"
for f in "$PROJECT_DIR"/grafana/dashboards/*.json; do
  [[ -f "$f" ]] || continue
  # The dashboards' hidden "catalog" constant names the catalog in every query.
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
for v in d["templating"]["list"]:
    if v["name"] == "catalog":
        v["query"] = sys.argv[2]
        v["current"] = {"text": sys.argv[2], "value": sys.argv[2]}
        v["options"] = [{"text": sys.argv[2], "value": sys.argv[2], "selected": True}]
json.dump(d, sys.stdout, indent=2, ensure_ascii=False)' "$f" "$DBX_CATALOG" \
    | remote "sudo install -o grafana -g grafana -m 644 /dev/stdin '/var/lib/grafana/dashboards/faa/$(basename "$f")'"
  echo "  dashboard $(basename "$f")"
done

# The token travels over SSH stdin (never on a command line) into a file only
# root can read; systemd reads it as root and passes it to grafana-server, and
# the datasource YAML references ${DATABRICKS_TOKEN}.
printf 'DATABRICKS_TOKEN=%s\n' "$DBX_TOKEN" \
  | remote "sudo install -o root -g root -m 600 /dev/stdin /etc/grafana/faa-databricks.env"
remote "sudo install -d /etc/systemd/system/grafana-server.service.d && \
        printf '[Service]\nEnvironmentFile=/etc/grafana/faa-databricks.env\n' \
        | sudo tee /etc/systemd/system/grafana-server.service.d/faa-databricks.conf > /dev/null"

echo "Restarting Grafana"
since=$(remote "date '+%Y-%m-%d %H:%M:%S'")
remote "sudo systemctl daemon-reload && sudo systemctl restart grafana-server"
for _ in $(seq 30); do
  remote "curl -fs http://localhost:$GRAFANA_PORT/api/health > /dev/null" && break
  sleep 2
done
remote "systemctl is-active grafana-server"

errors=$(remote "sudo journalctl -u grafana-server --since '$since' --no-pager" \
  | grep -E 'logger=provisioning[^ ]* .*level=(error|warn)' || true)
if [[ -n "$errors" ]]; then
  echo "Provisioning problems:" >&2
  echo "$errors" >&2
  exit 1
fi
echo "Grafana provisioned: datasource 'Databricks FAA' (uid databricks-faa). Dashboards:"
for f in "$PROJECT_DIR"/grafana/dashboards/*.json; do
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print("  %s: %s/d/%s" % (d["title"], sys.argv[2], d["uid"]))' "$f" "$GRAFANA_URL"
done
