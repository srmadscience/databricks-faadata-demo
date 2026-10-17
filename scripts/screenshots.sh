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

# Retakes the README's screenshots, docs/screenshots/*.jpg, from a Grafana with
# the FAA dashboards and the full data loaded (they show February to July 2026,
# airport ORD and aircraft N511AE), in headless Chrome at 1568x766. Needs Node.js
# and Google Chrome; installs playwright-core into target/screenshots/ the first
# time.
#
#   GRAFANA_PASSWORD=secret scripts/screenshots.sh
#   GRAFANA_PASSWORD=secret scripts/screenshots.sh aircraft-detail    just this one
#
# Settings, as environment variables:
#   GRAFANA_URL       Grafana's address (default: grafana.url in
#                     databricks.properties, else http://localhost:3000)
#   GRAFANA_USER      default admin
#   GRAFANA_PASSWORD  required
#   OUT               where to write them (default docs/screenshots)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ -n "${GRAFANA_PASSWORD:-}" ]] || { echo "error: set GRAFANA_PASSWORD (for GRAFANA_USER, default admin)" >&2; exit 1; }
command -v node > /dev/null || { echo "error: needs Node.js (node)" >&2; exit 1; }
GRAFANA_URL="${GRAFANA_URL:-$(prop grafana.url)}"
export GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
export GRAFANA_USER="${GRAFANA_USER:-admin}" GRAFANA_PASSWORD
OUT="${OUT:-$PROJECT_DIR/docs/screenshots}"

# playwright-core drives the installed Chrome, so there is no browser to download.
PW="$PROJECT_DIR/target/screenshots"
PW_VERSION=1.63.0
if [[ ! -f "$PW/node_modules/playwright-core/package.json" ]] \
   || ! grep -q "\"version\": \"$PW_VERSION\"" "$PW/node_modules/playwright-core/package.json"; then
  echo "Installing playwright-core $PW_VERSION into target/screenshots"
  mkdir -p "$PW"
  (cd "$PW" && npm install --silent --no-save --no-package-lock "playwright-core@$PW_VERSION")
fi
export PLAYWRIGHT_CORE="$PW/node_modules/playwright-core/index.mjs"

mkdir -p "$OUT"
echo "Taking screenshots from $GRAFANA_URL into $OUT"
node "$PROJECT_DIR/scripts/screenshots.mjs" "$OUT" "$@"
