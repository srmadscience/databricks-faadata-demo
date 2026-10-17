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
# /var/lib/grafana, systemd service grafana-server) with the
# grafana-clickhouse-datasource plugin, reached with key login and passwordless sudo.
# grafana.ssh=local configures a Grafana on this machine instead, without SSH.
#   - installs the ClickHouse datasource and dashboard provider from grafana/provisioning/
#   - copies grafana/dashboards/*.json to the dashboard folder Grafana watches
#   - gives grafana-server the ClickHouse credentials via a root-only env file
#   - restarts Grafana and reports provisioning errors from its log
# Safe to re-run; re-run after adding or changing dashboards.
#
# Settings: grafana.* in clickhouse.properties (see clickhouse.properties.example),
# or the environment variables below.
#
#   scripts/grafana-provision.sh
#   GRAFANA_SSH=me@grafana-host scripts/grafana-provision.sh
#   GRAFANA_SSH=local scripts/grafana-provision.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

GRAFANA_SSH="${GRAFANA_SSH:-$(prop grafana.ssh)}"
[[ -n "$GRAFANA_SSH" ]] || { echo "error: set grafana.ssh=user@host in clickhouse.properties, or GRAFANA_SSH" >&2; exit 1; }
GRAFANA_URL="${GRAFANA_URL:-$(prop grafana.url)}"
GRAFANA_HOST=${GRAFANA_SSH#*@}; [[ "$GRAFANA_SSH" != local ]] || GRAFANA_HOST=localhost
GRAFANA_URL="${GRAFANA_URL:-http://$GRAFANA_HOST:3000}"
GRAFANA_PORT=$(sed -E 's#^[a-z]+://[^/:]+:?([0-9]*).*#\1#' <<< "$GRAFANA_URL"); GRAFANA_PORT="${GRAFANA_PORT:-3000}"
# ClickHouse as Grafana reaches it (native protocol), by default the host in clickhouse.url.
GF_CH_HOST="${GRAFANA_CLICKHOUSE_HOST:-$(prop grafana.clickhouse.host)}"
GF_CH_HOST="${GF_CH_HOST:-$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<< "$CH_URL")}"
GF_CH_PORT="${GRAFANA_CLICKHOUSE_PORT:-$(prop grafana.clickhouse.port)}"; GF_CH_PORT="${GF_CH_PORT:-9000}"
if [[ "$GF_CH_HOST" =~ ^(localhost|127\.0\.0\.1|::1)$ && ! "$GRAFANA_HOST" =~ ^(localhost|127\.0\.0\.1|::1)$ ]]; then
  echo "warn: Grafana will look for ClickHouse at $GF_CH_HOST, i.e. on the Grafana server itself;" >&2
  echo "      set grafana.clickhouse.host if ClickHouse runs elsewhere" >&2
fi

PROV="$PROJECT_DIR/grafana/provisioning"

# remote COMMAND...: runs a shell command on the Grafana server, as ssh would.
if [[ "$GRAFANA_SSH" == local ]]; then
  remote() { bash -c "$*"; }
else
  remote() { ssh -o BatchMode=yes "$GRAFANA_SSH" "$@"; }
fi

echo "Installing provisioning files on $GRAFANA_SSH (ClickHouse at $GF_CH_HOST:$GF_CH_PORT)"
sed -e "s/__CLICKHOUSE_HOST__/$GF_CH_HOST/" -e "s/__CLICKHOUSE_PORT__/$GF_CH_PORT/" "$PROV/datasources/clickhouse.yaml" \
  | remote "sudo install -o root -g grafana -m 640 /dev/stdin /etc/grafana/provisioning/datasources/faa-clickhouse.yaml"
remote "sudo install -o root -g grafana -m 640 /dev/stdin /etc/grafana/provisioning/dashboards/faa.yaml" \
  < "$PROV/dashboards/faa.yaml"

remote "sudo install -d -o grafana -g grafana -m 755 /var/lib/grafana/dashboards/faa"
for f in "$PROJECT_DIR"/grafana/dashboards/*.json; do
  [[ -f "$f" ]] || continue
  remote "sudo install -o grafana -g grafana -m 644 /dev/stdin '/var/lib/grafana/dashboards/faa/$(basename "$f")'" < "$f"
  echo "  dashboard $(basename "$f")"
done

# Credentials travel over SSH stdin (never on a command line) into a file only
# root can read; systemd reads it as root and passes it to grafana-server, and
# the datasource YAML references ${CLICKHOUSE_USER} / ${CLICKHOUSE_PASSWORD}.
printf 'CLICKHOUSE_USER=%s\nCLICKHOUSE_PASSWORD=%s\n' "$CH_USER" "$CH_PASSWORD" \
  | remote "sudo install -o root -g root -m 600 /dev/stdin /etc/grafana/faa-clickhouse.env"
remote "sudo install -d /etc/systemd/system/grafana-server.service.d && \
        printf '[Service]\nEnvironmentFile=/etc/grafana/faa-clickhouse.env\n' \
        | sudo tee /etc/systemd/system/grafana-server.service.d/faa-clickhouse.conf > /dev/null"

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
echo "Grafana provisioned: datasource 'ClickHouse FAA' (uid clickhouse-faa). Dashboards:"
for f in "$PROJECT_DIR"/grafana/dashboards/*.json; do
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print("  %s: %s/d/%s" % (d["title"], sys.argv[2], d["uid"]))' "$f" "$GRAFANA_URL"
done
