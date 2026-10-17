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

# Downloads the FAA aircraft registry (ReleasableAircraft.zip, ~70 MB, updated
# daily) into data/raw/registry/ReleasableAircraft_YYYYMMDD.zip. If there is
# no copy yet, the newest one on the project's mirror (GitHub Releases, see
# lib.sh) is used, so everyone gets the same snapshot. --refresh downloads
# today's from the FAA; older copies are kept so earlier loads can be redone.
#
#   scripts/fetch-registry.sh
#   scripts/fetch-registry.sh --refresh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

URL="https://registry.faa.gov/database/ReleasableAircraft.zip"
DEST="$PROJECT_DIR/data/raw/registry"

if [[ "${1:-}" != --refresh ]]; then
  existing=$(ls -1 "$DEST"/ReleasableAircraft_*.zip 2>/dev/null | tail -1 || true)
  if [[ -n "$existing" ]]; then
    echo "skip   $(basename "$existing") (--refresh to download today's)"
    exit 0
  fi
  MIRROR=$(mirror_assets data-reference)
  name=$(awk -F'\t' '$1 ~ /^ReleasableAircraft_[0-9]+\.zip$/ {print $1}' <<< "$MIRROR" | sort | tail -1)
  if [[ -n "$name" ]] && mirror_fetch "$MIRROR" "$name" "$DEST/$name"; then
    echo "fetch  $name  (mirror)"
    exit 0
  fi
fi

target="$DEST/ReleasableAircraft_$(date -u +%Y%m%d).zip"
if [[ -f "$target" ]]; then
  echo "skip   $(basename "$target")"
  exit 0
fi

echo "fetch  $(basename "$target")"
# registry.faa.gov's CDN refuses curl's default User-Agent with a 403.
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36"
mkdir -p "$(dirname "$target")"
curl -fsSL --retry 5 --retry-delay 10 -A "$UA" -o "$target.part" "$URL"
unzip -tq "$target.part" > /dev/null || { echo "error: download is not a valid zip" >&2; rm -f "$target.part"; exit 1; }
mv "$target.part" "$target"
