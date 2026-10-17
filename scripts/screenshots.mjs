// Copyright 2026 David Rolfe
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Takes the README's screenshots (docs/screenshots/*.jpg) from a Grafana with
// the FAA dashboards, in headless Chrome. Run it through scripts/screenshots.sh,
// which installs playwright-core and passes the settings:
//   PLAYWRIGHT_CORE  path of playwright-core's index.mjs
//   GRAFANA_URL      Grafana's address
//   GRAFANA_USER, GRAFANA_PASSWORD
//   node screenshots.mjs OUT_DIR [NAME]
const { chromium } = await import(process.env.PLAYWRIGHT_CORE);
const G = process.env.GRAFANA_URL.replace(/\/$/, '');
const OUT = process.argv[2];
const only = process.argv[3];
const RANGE = 'from=2026-02-01T00:00:00.000Z&to=2026-07-31T23:59:59.000Z&timezone=utc';
// name, dashboard, variables, what to scroll to (a panel or row title, or 'bottom')
const SHOTS = [
  ['flight-delays', 'faa-flight-delays', '', null],
  ['flight-delays-rankings', 'faa-flight-delays', '', 'bottom'],
  ['weather-impact', 'faa-weather-impact', '', null],
  ['airport-weather', 'faa-airport-weather', '&var-airport=ORD', null],
  ['airport-weather-clouds', 'faa-airport-weather', '&var-airport=ORD', 'Cloud layers'],
  ['aircraft-reliability', 'faa-aircraft-reliability', '&var-tail=N511AE', null],
  ['aircraft-rankings', 'faa-aircraft-reliability', '&var-tail=N511AE', 'Top 10 least reliable aircraft'],
  ['aircraft-detail', 'faa-aircraft-reliability', '&var-tail=N511AE', 'Aircraft N511AE'],
];
if (only && !SHOTS.some(([name]) => name === only)) {
  throw new Error(`no screenshot ${only}; one of ${SHOTS.map(([name]) => name).join(', ')}`);
}

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 1568, height: 766 }, colorScheme: 'dark' });
try {
  await takeScreenshots();
} catch (e) {
  console.error(`error: ${e.message.split('\n')[0]}`);
  process.exitCode = 1;
} finally {
  await browser.close();
}

async function settle() {
  // Panels load as they scroll into view: wait until no request is running and no
  // panel shows a loading bar, twice in a row.
  for (let quiet = 0, i = 0; quiet < 2 && i < 120; i++) {
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(1500);
    const loading = await page.locator('[aria-label="Panel loading bar"], [data-testid*="loading"]').count();
    quiet = loading ? 0 : quiet + 1;
  }
}

async function takeScreenshots() {
  // Log in through the API, which sets the session cookie for the page.
  let login;
  try {
    login = await page.request.post(`${G}/login`, {
      data: { user: process.env.GRAFANA_USER, password: process.env.GRAFANA_PASSWORD } });
  } catch (e) {
    throw new Error(`cannot reach Grafana at ${G}: ${e.message.split('\n')[0]}`);
  }
  if (!login.ok()) throw new Error(`cannot log in to ${G} as ${process.env.GRAFANA_USER}: HTTP ${login.status()}`);
  for (const [name, uid, vars, target] of SHOTS) {
    if (only && only !== name) continue;
    await takeScreenshot(name, uid, vars, target);
  }
}

async function takeScreenshot(name, uid, vars, target) {
  await page.goto(`${G}/d/${uid}?${RANGE}${vars}&kiosk`);
  await settle();
  if (target) {
    // In headless Chrome the variables bar and the footer stick only within
    // the first screen: pin them where they are, as a desktop browser shows them.
    await page.evaluate(() => {
      for (const el of document.querySelectorAll('*')) {
        if (getComputedStyle(el).position !== 'sticky') continue;
        const r = el.getBoundingClientRect();
        Object.assign(el.style, { position: 'fixed', top: `${r.top}px`, left: `${r.left}px`,
                                  width: `${r.width}px`, zIndex: 1000 });
      }
    });
  }
  // Scroll, wait for the panels that come into view to load, and scroll again,
  // as panels above may have changed height as they loaded.
  for (let pass = 0; pass < 2; pass++) {
    if (target === 'bottom') {
      await page.evaluate(() => {
        for (const el of document.querySelectorAll('*')) {
          if (el.scrollHeight > el.clientHeight + 50 && getComputedStyle(el).overflowY.match(/auto|scroll/)) {
            el.scrollTop = el.scrollHeight;
          }
        }
        window.scrollTo(0, document.body.scrollHeight);
      });
    } else if (target) {
      const el = page.getByText(target, { exact: true }).first();
      await el.evaluate((e) => {
        // put it just below the variables bar, which is about 64 px high
        window.scrollBy(0, e.getBoundingClientRect().top - 74);
      });
    }
    await settle();
  }
  await settle();
  await page.mouse.move(0, 0);
  await page.screenshot({ path: `${OUT}/${name}.jpg`, type: 'jpeg', quality: 85 });
  console.log(`saved ${OUT}/${name}.jpg`);
}
