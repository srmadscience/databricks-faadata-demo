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

# Turns a fresh Ubuntu 24.04 machine into a complete demo server, everything on
# one host: ClickHouse, Prometheus (scraping ClickHouse's built-in metrics
# endpoint and node_exporter), Grafana with the FAA dashboards plus "Node
# Exporter Full" and "Clickhouse internal exporter", and this repository with
# the data loaded. Used by aws/faa-demo.yaml; run as root from a clone of the
# repository:
#
#   sudo GRAFANA_PASSWORD=secret scripts/install-server.sh [FROM_YYYY-MM TO_YYYY-MM]
#
# FROM/TO (default 2016-01 to last month) is the range of flights to load; pass
# "none" to skip loading. Settings, as environment variables:
#   GRAFANA_PASSWORD  password for Grafana's admin user (required)
#   APP_USER          owner of the repository and runner of the load (default:
#                     the owner of the repository directory)
# ClickHouse, Prometheus and node_exporter listen on localhost only; Grafana on
# port 3000. Safe to re-run.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -n "${GRAFANA_PASSWORD:-}" ]] || { echo "error: set GRAFANA_PASSWORD" >&2; exit 1; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP_USER="${APP_USER:-$(stat -c %U "$REPO")}"
FROM="${1:-2016-01}"
TO="${2:-$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m)}"
export DEBIAN_FRONTEND=noninteractive

step() { echo; echo "=== $(date '+%H:%M:%S') $*"; }

step "Packages"
apt-get update -q
apt-get install -y -q curl gnupg git unzip python3 openjdk-21-jdk-headless maven \
  prometheus prometheus-node-exporter

step "ClickHouse"
if [[ ! -f /etc/apt/sources.list.d/clickhouse.list ]]; then
  curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key \
    | gpg --dearmor --yes -o /usr/share/keyrings/clickhouse-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" \
    > /etc/apt/sources.list.d/clickhouse.list
  apt-get update -q
fi
apt-get install -y -q clickhouse-server clickhouse-client
# The default user gets a random password, kept in the repository's
# clickhouse.properties (git-ignored, readable only by APP_USER) for the
# scripts and passed to Grafana by grafana-provision.sh.
PROPS="$REPO/clickhouse.properties"
CH_PASSWORD=$(sed -n 's/^clickhouse.password=//p' "$PROPS" 2>/dev/null || true)
[[ -n "$CH_PASSWORD" ]] || CH_PASSWORD=$(head -c 32 /dev/urandom | sha256sum | head -c 32)
cat > /etc/clickhouse-server/users.d/default-password.xml <<EOF
<clickhouse>
  <users>
    <default>
      <password remove="1"/>
      <password_sha256_hex>$(printf %s "$CH_PASSWORD" | sha256sum | cut -d' ' -f1)</password_sha256_hex>
    </default>
  </users>
</clickhouse>
EOF
# Metrics, events and asynchronous metrics for Prometheus, at :9363/metrics.
cat > /etc/clickhouse-server/config.d/prometheus.xml <<'EOF'
<clickhouse>
  <prometheus>
    <endpoint>/metrics</endpoint>
    <port>9363</port>
    <metrics>true</metrics>
    <events>true</events>
    <asynchronous_metrics>true</asynchronous_metrics>
  </prometheus>
</clickhouse>
EOF
chown clickhouse:clickhouse /etc/clickhouse-server/users.d/default-password.xml /etc/clickhouse-server/config.d/prometheus.xml
chmod 600 /etc/clickhouse-server/users.d/default-password.xml
systemctl enable clickhouse-server
systemctl restart clickhouse-server
for _ in $(seq 60); do
  curl -fs http://localhost:8123/ping > /dev/null && curl -fs http://localhost:9363/metrics > /dev/null && break
  sleep 1
done
curl -fsS http://localhost:9363/metrics | grep -c '^ClickHouse' | xargs echo "ClickHouse metrics exported:"

step "Prometheus"
# The environment label is what the "Clickhouse internal exporter" dashboard
# filters on.
cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
  - job_name: node
    static_configs:
      - targets: ['localhost:9100']
  - job_name: clickhouse
    static_configs:
      - targets: ['localhost:9363']
        labels:
          environment: faa-demo
EOF
# Listen on localhost only: Prometheus and node_exporter are reached through Grafana.
echo 'ARGS="--web.listen-address=127.0.0.1:9090"' > /etc/default/prometheus
echo 'ARGS="--web.listen-address=127.0.0.1:9100"' > /etc/default/prometheus-node-exporter
systemctl enable prometheus prometheus-node-exporter
systemctl restart prometheus prometheus-node-exporter

step "Grafana"
if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/grafana.gpg
  echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -q
fi
apt-get install -y -q grafana
# Grafana 13 no longer bundles the Prometheus datasource, and grafana cli runs
# as root here, so the plugins it installs must be handed to the grafana user.
grafana cli plugins install grafana-clickhouse-datasource
grafana cli plugins install prometheus
chown -R grafana:grafana /var/lib/grafana/plugins
cat > /etc/grafana/provisioning/datasources/prometheus.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    url: http://localhost:9090
    access: proxy
EOF
cat > /etc/grafana/provisioning/dashboards/monitoring.yaml <<'EOF'
apiVersion: 1
providers:
  - name: monitoring
    folder: Monitoring
    type: file
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards/monitoring
EOF
chown root:grafana /etc/grafana/provisioning/datasources/prometheus.yaml /etc/grafana/provisioning/dashboards/monitoring.yaml
# Node Exporter Full and Clickhouse internal exporter, from grafana.com, with
# their ${DS_PROMETHEUS} input pointed at the datasource above.
install -d -o grafana -g grafana /var/lib/grafana/dashboards/monitoring
for id in 1860 13500; do
  curl -fsSL --retry 5 "https://grafana.com/api/dashboards/$id/revisions/latest/download" \
    | sed 's/\${DS_PROMETHEUS}/prometheus/g' > "/var/lib/grafana/dashboards/monitoring/$id.json"
  chown grafana:grafana "/var/lib/grafana/dashboards/monitoring/$id.json"
done
systemctl enable grafana-server
systemctl restart grafana-server
for _ in $(seq 60); do curl -fs http://localhost:3000/api/health > /dev/null && break; sleep 1; done
grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
  admin reset-admin-password "$GRAFANA_PASSWORD" > /dev/null
echo "Grafana admin password set"

step "Repository"
cat > "$PROPS" <<EOF
clickhouse.url=http://localhost:8123
clickhouse.user=default
clickhouse.password=$CH_PASSWORD
clickhouse.database=faa
grafana.ssh=local
EOF
chown "$APP_USER" "$PROPS"
chmod 600 "$PROPS"
as_app() { sudo -u "$APP_USER" -H bash -c "cd '$REPO' && $*"; }
as_app scripts/create-database.sh > /dev/null
as_app 'mvn -q -B package -DskipTests'
# FAA datasource and dashboards; grafana-provision.sh runs as root here, so its
# sudo calls need no password.
(cd "$REPO" && scripts/grafana-provision.sh)

if [[ "$FROM" != none ]]; then
  step "Loading flights $FROM to $TO (see scripts/reproduce.sh)"
  as_app "scripts/reproduce.sh --time 'install-server.sh on $(hostname)' $FROM $TO"
fi

step "Done"
echo "Grafana: port 3000, user admin. Dashboards: FAA and Monitoring folders."
