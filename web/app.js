// =============================================================================
//  app.js - Ryzen Pro Optimizer browser UI
// =============================================================================
//  Loaded by web/index.html. Talks to the PowerShell server on 127.0.0.1.
//
//  What lives in this file (top to bottom):
//    - Constants and global state (cpuInfo, current/launch CO values, etc.)
//    - fetchJson + showToast helpers
//    - CPU / CO loading and form rendering (renderForm, applyCo, etc.)
//    - Test lifecycle (startTest, stopTest, loadReport)
//    - Telemetry rendering: compact strip + expanded grid
//    - The ProDash IIFE module - Pro Dashboard charts, stats grid, V/F
//      scatter, heatmap, history export, time-window picker, pause/reset
//    - pollStatus + renderSafetyBanner - live test progress + Safety Guard
//    - Profiles list + safe panic-revert prompt
//    - Settings load/save (localStorage v2, default tab-close OFF)
//    - DOMContentLoaded boot: initial loads, start the 1Hz pollers
//
//  Why vanilla JS and no framework: one file, no build step, no npm,
//  works in any modern browser, easy to inspect with View Source. The
//  only third-party dep is Chart.js (vendored at web/vendor/chart.umd.js).
//
//  Polling cadence: 1 Hz for telemetry and status while the page is open.
//  No WebSocket - the simple polling model means the server stays a
//  request/response HTTP listener with no extra connection state.
// =============================================================================

const POLL_INTERVAL_ACTIVE_MS = 1000;
const POLL_INTERVAL_IDLE_MS = 5000;

let cpuInfo = null;
let launchValues = null;
let currentValues = null;
let formInitialValues = null;  // What populates form inputs (defaults to currentValues; overridden by Load Profile)
let loadedProfiles = [];
let currentMode = 'all-cores';
let lastWheaCount = 0;
let stateName = 'IDLE';

// =============================================================================
//  i18n - translates load-bearing UI strings from /locales/{lang}.json
// =============================================================================
//  Strategy:
//    - Strings carry data-i18n="namespace.key" (text content) or
//      data-i18n-attr="attrname|namespace.key" (attribute value, e.g. title).
//    - At boot we detect language: localStorage > navigator.language >
//      'en'. Lookup falls through current language -> English -> the
//      raw key, so a partially-translated locale still renders.
//    - RTL languages (he, ar) flip <html dir>; CSS handles layout
//      mirroring via logical properties + dir-aware rules in style.css.
//    - The language switcher is in the header; choice persists in
//      localStorage and applies immediately without reload.
// =============================================================================
const i18n = (() => {
  const SUPPORTED = ['en','fr','es','de','ru','he','ar','zh','ja'];
  const RTL = new Set(['he','ar']);
  let current = 'en';
  let strings = {};
  let englishFallback = {};

  function detect() {
    const saved = localStorage.getItem('rpo.lang');
    if (saved && SUPPORTED.includes(saved)) return saved;
    const b = (navigator.language || 'en').slice(0, 2).toLowerCase();
    return SUPPORTED.includes(b) ? b : 'en';
  }

  async function fetchLocale(lang) {
    const r = await fetch(`/locales/${lang}.json`);
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r.json();
  }

  // Load English first as the fallback dictionary, then the requested
  // language. If the requested language is English, we just reuse the
  // already-fetched dict so we don't make two identical requests.
  async function load(lang) {
    if (!SUPPORTED.includes(lang)) lang = 'en';
    try {
      if (Object.keys(englishFallback).length === 0) {
        englishFallback = await fetchLocale('en');
      }
      strings = (lang === 'en') ? englishFallback : await fetchLocale(lang);
      current = lang;
      localStorage.setItem('rpo.lang', lang);
      document.documentElement.lang = lang;
      document.documentElement.dir = RTL.has(lang) ? 'rtl' : 'ltr';
      apply();
    } catch (e) {
      console.warn(`i18n: failed to load ${lang}:`, e);
      if (lang !== 'en') return load('en');
    }
  }

  // Lookup with English fallback. `{0}`, `{1}`, ... are positional
  // substitutions. Returns the raw key when not found anywhere - that
  // way unknown keys are visible (not invisible) in development.
  function t(key, ...args) {
    let s = strings[key];
    if (s == null) s = englishFallback[key];
    if (s == null) s = key;
    args.forEach((a, i) => { s = s.split(`{${i}}`).join(String(a)); });
    return s;
  }

  // Apply current translations to every element flagged with
  // data-i18n / data-i18n-attr / data-i18n-html. Safe to re-run; we
  // call it on language change and after dynamic DOM additions.
  function apply() {
    document.querySelectorAll('[data-i18n]').forEach(el => {
      el.textContent = t(el.dataset.i18n);
    });
    document.querySelectorAll('[data-i18n-attr]').forEach(el => {
      // Pipe-separated "attrname|key" lets one element translate any
      // attribute (title, placeholder, aria-label, ...).
      const spec = el.dataset.i18nAttr;
      const pipe = spec.indexOf('|');
      if (pipe < 0) return;
      el.setAttribute(spec.slice(0, pipe), t(spec.slice(pipe + 1)));
    });
    document.querySelectorAll('[data-i18n-html]').forEach(el => {
      el.innerHTML = t(el.dataset.i18nHtml);
    });
  }

  return { detect, load, t, apply, current: () => current, SUPPORTED, RTL };
})();

// =============================================================================
//  Layout: reorganise <main> into two columns + full-width recovery host
// =============================================================================
//  Source order stays roughly semantic (better for screen readers and
//  diffs); a one-shot DOM move at boot puts each section into the right
//  column. CSS Grid does the column split.
//
//  Left column: live data / metrics / results
//  Right column: controls / configuration / settings
//  Recovery host (#recovery-host) is already in the HTML, spans full
//  width via .col-fullwidth so panic-revert and Smart Tune paused
//  banners read prominently across both columns.
// =============================================================================
const LAYOUT_LEFT_IDS = [
  'cpu-info', 'not-supported',
  'telemetry-strip', 'telemetry-expanded',
  'safety-banner',
  'tune-theater', 'tune-results-card',
  'pro-dashboard', 'pro-toggle',
  'live-co-card',
  'status-card', 'report-card'
];
const LAYOUT_RIGHT_IDS = [
  'co-banner', 'bios-setup-card',
  'curve-card', 'test-card',
  'profiles-card',
  'safety-card', 'settings-card'
];

function applyTwoColumnLayout() {
  const main = document.querySelector('main');
  if (!main || main.dataset.twoCol === '1') return;
  const recoveryHost = document.getElementById('recovery-host');
  if (recoveryHost) recoveryHost.classList.add('col-fullwidth');

  const left = document.createElement('div');
  left.className = 'col-left';
  const right = document.createElement('div');
  right.className = 'col-right';

  LAYOUT_LEFT_IDS.forEach(id => {
    const el = document.getElementById(id);
    if (el) left.appendChild(el);
  });
  LAYOUT_RIGHT_IDS.forEach(id => {
    const el = document.getElementById(id);
    if (el) right.appendChild(el);
  });

  main.appendChild(left);
  main.appendChild(right);
  main.dataset.twoCol = '1';
}

async function fetchJson(url, opts) {
  const r = await fetch(url, opts);
  let json;
  try { json = await r.json(); } catch (e) { throw new Error('Non-JSON response from ' + url); }
  return json;
}

function showToast(msg, kind) {
  const t = document.createElement('div');
  t.className = 'toast' + (kind ? ' ' + kind : '');
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 3000);
}

// Escape server- or user-sourced strings before they go into `innerHTML`
// template literals. Profile names, notes, narrative messages, panic
// reasons, and CoreCycler error-type strings all flow through here. The
// threat model is single-trusted-user on localhost, but a corrupted or
// migrated profile JSON could carry `<img src=x onerror=...>` payloads,
// and the profile list re-renders on every Apply/Save/page-load.
function escHtml(s) {
  if (s == null) return '';
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function summarizeCo(arr) {
  if (!arr || !arr.length) return '—';
  const allSame = arr.every(v => v === arr[0]);
  if (allSame) return `All cores ${arr[0]}`;
  if (cpuInfo && cpuInfo.IsDualCcd) {
    const half = arr.length / 2;
    const ccd0 = arr.slice(0, half);
    const ccd1 = arr.slice(half);
    const fmt = a => a.every(v => v === a[0]) ? a[0] : a.join(',');
    return `CCD0 ${fmt(ccd0)} · CCD1 ${fmt(ccd1)}`;
  }
  return arr.join(', ');
}

async function loadVersion() {
  try {
    const r = await fetchJson('/api/version');
    if (r && r.ok && r.data) {
      const el = document.getElementById('app-version');
      if (el) {
        el.textContent = 'v' + r.data.version;
        el.title = 'Installed at ' + (r.data.installDir || 'unknown');
      }
    }
  } catch (_) { /* footer just stays "v—" if the call fails */ }
}

async function loadCpu() {
  const j = await fetchJson('/api/cpu');
  cpuInfo = j.data;
  const card = document.getElementById('cpu-info');

  if (!cpuInfo.SupportsCurveOptimizer) {
    document.getElementById('not-supported').classList.remove('hidden');
    document.getElementById('not-supported').innerHTML =
      `<h2>Curve Optimizer Not Supported</h2>
       <p>${cpuInfo.UnsupportedReason || 'Your CPU does not support Curve Optimizer.'}</p>
       <p class="muted">Detected: ${cpuInfo.Name}</p>`;
    card.classList.add('hidden');
    return;
  }

  const ccdDesc = cpuInfo.IsDualCcd
    ? `${cpuInfo.CcdCount} CCDs${cpuInfo.VCacheCcdIndex !== null ? ' · CCD' + cpuInfo.VCacheCcdIndex + ' has 3D V-Cache' : ''}`
    : '1 CCD';
  card.innerHTML = `<strong>${escHtml(cpuInfo.Name)}</strong> · ${cpuInfo.Cores} cores · ${ccdDesc} · Zen ${escHtml(cpuInfo.ZenGen)}`;

  document.getElementById('curve-card').classList.remove('hidden');
  document.getElementById('test-card').classList.remove('hidden');
  document.getElementById('telemetry-strip').classList.remove('hidden');

  if (!cpuInfo.IsDualCcd) document.getElementById('tab-ccd').classList.add('hidden');
}

// Auto-pick the form mode that best represents the current per-core array.
// Uniform across all cores -> all-cores. Each CCD internally uniform but
// CCDs differ -> per-ccd. Anything mixed -> per-core. This is what makes a
// per-CCD apply visible on reload (without it, the form always defaulted to
// all-cores and showed only the first core, looking like the apply lost).
function detectCoMode(values, cpu) {
  if (!values || !values.length || !cpu) return 'all-cores';
  if (values.every(v => v === values[0])) return 'all-cores';
  if (cpu.IsDualCcd && cpu.CcdCount > 1) {
    const cpc = cpu.CoresPerCcd;
    let ccdUniform = true;
    for (let c = 0; c < cpu.CcdCount && ccdUniform; c++) {
      const first = values[c * cpc];
      for (let i = 1; i < cpc; i++) {
        if (values[c * cpc + i] !== first) { ccdUniform = false; break; }
      }
    }
    if (ccdUniform) return 'per-ccd';
  }
  return 'per-core';
}

// Fetch the SMU's current per-core CO without re-rendering the form or
// switching the mode tab. Used by the Live CO panel during a tune so we
// can keep showing fresh values without yanking the user's form mode
// every 3 seconds.
async function pollCurrentCo() {
  if (!cpuInfo || !cpuInfo.SupportsCurveOptimizer) return;
  try {
    const r = await fetchJson('/api/co/current');
    if (r && r.data) currentValues = r.data;
  } catch (_) { /* SMU can be busy during writes; show last known */ }
}

let liveCoView = 'summary';
let latestSmartTune = null;        // last s.smartTune seen by pollStatus
let autoSwitchedForTune = false;   // one-shot: auto-switch to per-core on tune start

// Resolve the Smart Tune scope that "owns" a given core. Prefers per-core
// scope when it has state (PROBING / LOCKED / FAILED); otherwise falls
// back to the parent CCD scope. Returns null if no tune is active.
function coreScopeFor(coreIdx) {
  if (!latestSmartTune || !Array.isArray(latestSmartTune.scopes)) return null;
  const scopes = latestSmartTune.scopes;
  const perCore = scopes.find(s => s.id === `core${coreIdx}`);
  if (perCore && perCore.status !== 'PENDING') return perCore;
  const ccd = scopes.find(s => Array.isArray(s.cores) && s.cores.includes(coreIdx) && /^CCD\d+$/.test(s.id || ''));
  return ccd || perCore || null;
}

// Map a scope to a (cssClass, badge, title-fragment) triple for pill overlay.
// `currentScopeId` is the scope currently being probed (RUNNING + currentIdx).
function tuneStatusFor(scope, currentScopeId) {
  if (!scope) return { cls: '', badge: '', tip: '' };
  if (scope.status === 'LOCKED')  return { cls: 'tune-locked',  badge: ' 🔒', tip: ' · locked' };
  if (scope.status === 'FAILED')  return { cls: 'tune-failed',  badge: ' ❌', tip: ' · failed' };
  if (scope.id === currentScopeId) return { cls: 'tune-probing', badge: ' ▶',  tip: ' · probing now' };
  if (scope.status === 'PROBING') return { cls: 'tune-probing', badge: ' ▶',  tip: ' · probing' };
  return { cls: 'tune-pending', badge: '', tip: ' · pending' };
}

function renderLiveCo() {
  const el = document.getElementById('live-co-content');
  if (!el) return;
  if (!currentValues || !cpuInfo) { el.textContent = 'Waiting for first read…'; return; }

  const pillClass = v => v < 0 ? 'neg' : v > 0 ? 'pos' : 'zero';
  const fmt = v => (v > 0 ? '+' : '') + v;
  const tuning = latestSmartTune && latestSmartTune.status === 'RUNNING';
  const currentScopeId = tuning && Array.isArray(latestSmartTune.scopes)
    ? (latestSmartTune.scopes[latestSmartTune.currentIdx] || {}).id
    : null;

  if (liveCoView === 'summary') {
    el.innerHTML = `<div class="live-co-summary"><strong>${escHtml(summarizeCo(currentValues))}</strong></div>`;
    return;
  }
  if (liveCoView === 'per-ccd' && cpuInfo.CcdCount > 0) {
    let html = '';
    for (let c = 0; c < cpuInfo.CcdCount; c++) {
      const start = c * cpuInfo.CoresPerCcd;
      const vals = currentValues.slice(start, start + cpuInfo.CoresPerCcd);
      const allSame = vals.every(v => v === vals[0]);
      const label = cpuInfo.VCacheCcdIndex === c ? `CCD${c} (V-Cache 🔋)` : `CCD${c}`;
      const display = allSame
        ? `<span class="co-pill ${pillClass(vals[0])}">${fmt(vals[0])}</span>`
        : vals.map((v, i) => `<span class="co-pill ${pillClass(v)}" title="Core ${start+i}">${fmt(v)}</span>`).join(' ');
      html += `<div class="live-co-row"><span class="live-co-row-label">${label}</span><span class="live-co-row-pills">${display}</span></div>`;
    }
    el.innerHTML = html;
    return;
  }
  // per-core view: pills grouped by CCD. During a Smart Tune, overlay
  // scope status (locked/probing/pending) onto each pill so the user can
  // see the auto-adjust progress without leaving this card.
  const ccds = {};
  currentValues.forEach((v, i) => {
    const ccd = cpuInfo.IsDualCcd ? Math.floor(i / cpuInfo.CoresPerCcd) : 0;
    (ccds[ccd] = ccds[ccd] || []).push({ core: i, value: v });
  });
  let html = '';
  Object.keys(ccds).sort((a, b) => +a - +b).forEach(ccd => {
    const label = cpuInfo.VCacheCcdIndex === +ccd ? `CCD${ccd} (V-Cache 🔋)` : `CCD${ccd}`;
    const pills = ccds[ccd].map(c => {
      const scope = coreScopeFor(c.core);
      const st = tuneStatusFor(scope, currentScopeId);
      return `<span class="co-pill ${pillClass(c.value)} ${st.cls}" title="Core ${c.core}${st.tip}">C${c.core}: ${fmt(c.value)}${st.badge}</span>`;
    }).join('');
    html += `<div class="muted small" style="margin-top:0.5rem">${label}</div><div class="co-pills">${pills}</div>`;
  });
  if (tuning) {
    const legend = `<div class="tune-legend"><span class="tune-locked">🔒 locked</span> · <span class="tune-probing">▶ probing</span> · <span class="tune-pending">pending</span></div>`;
    html = legend + html;
  }
  el.innerHTML = html;
}

// ----------------------------------------------------------------------------
//  Tune Results - per-core table shown after a Smart Tune completes
// ----------------------------------------------------------------------------
//  Surfaces the locked CO per core (resolved per-core scope > CCD scope >
//  launch value), what the SMU is currently at, and per-scope probe/state
//  info. Actions:
//    [Apply recommended] -> POST /api/smart-tune/apply-results
//    [Revert to launch]  -> POST /api/co/revert
//    [Save as profile]   -> POST /api/profiles with the recommended values
//    [Dismiss]           -> hide card (state persists server-side)
// ----------------------------------------------------------------------------

// Resolve "what would Apply Recommended write to core N". Same rule
// the server uses in Get-RecommendedCoFromTune - per-core scope wins
// when LOCKED, else the parent CCD scope when LOCKED, else launch.
function recommendedCoFor(coreIdx, smartTune, launchVals) {
  const launch = (launchVals && launchVals[coreIdx] != null) ? launchVals[coreIdx] : 0;
  if (!smartTune || !Array.isArray(smartTune.scopes)) return launch;
  let val = launch;
  const ccd = smartTune.scopes.find(s => Array.isArray(s.cores) && s.cores.includes(coreIdx) && /^CCD\d+$/.test(s.id || ''));
  if (ccd && ccd.status === 'LOCKED' && ccd.locked != null) val = ccd.locked;
  const perCore = smartTune.scopes.find(s => s.id === `core${coreIdx}`);
  if (perCore && perCore.status === 'LOCKED' && perCore.locked != null) val = perCore.locked;
  return val;
}

// Status label and class for a core, derived from the most-specific
// owning scope. Used to color-code the per-core row.
function coreOutcomeFor(coreIdx, smartTune) {
  if (!smartTune || !Array.isArray(smartTune.scopes)) return { label: '—', cls: '' };
  const perCore = smartTune.scopes.find(s => s.id === `core${coreIdx}`);
  if (perCore && perCore.status !== 'PENDING') {
    if (perCore.status === 'LOCKED') return { label: 'Locked', cls: 'tr-locked', scope: perCore.id, probes: perCore.scopeState?.probesCompleted ?? 0 };
    if (perCore.status === 'FAILED') return { label: 'Failed', cls: 'tr-failed', scope: perCore.id, probes: perCore.scopeState?.probesCompleted ?? 0 };
    return { label: perCore.status, cls: 'tr-pending', scope: perCore.id, probes: perCore.scopeState?.probesCompleted ?? 0 };
  }
  const ccd = smartTune.scopes.find(s => Array.isArray(s.cores) && s.cores.includes(coreIdx) && /^CCD\d+$/.test(s.id || ''));
  if (ccd) {
    if (ccd.status === 'LOCKED') return { label: 'Locked via ' + ccd.id, cls: 'tr-locked', scope: ccd.id, probes: ccd.scopeState?.probesCompleted ?? 0 };
    if (ccd.status === 'FAILED') return { label: 'Failed via ' + ccd.id, cls: 'tr-failed', scope: ccd.id, probes: ccd.scopeState?.probesCompleted ?? 0 };
    return { label: ccd.status + ' via ' + ccd.id, cls: 'tr-pending', scope: ccd.id, probes: ccd.scopeState?.probesCompleted ?? 0 };
  }
  return { label: 'Not tuned', cls: 'tr-pending', scope: '—', probes: 0 };
}

// Render the table contents into #tune-results-table-wrap. Sized for
// up to 32 cores; tabular numerics so the columns stay aligned.
function renderTuneResults(smartTune) {
  const card = document.getElementById('tune-results-card');
  const wrap = document.getElementById('tune-results-table-wrap');
  const meta = document.getElementById('tune-results-meta');
  const summary = document.getElementById('tune-results-summary');
  if (!card || !wrap || !cpuInfo) return;
  if (!smartTune || smartTune.status !== 'COMPLETED') { card.classList.add('hidden'); return; }

  card.classList.remove('hidden');
  const applied = smartTune.applyMode === 'live';
  meta.textContent = `${smartTune.mode || '?'} · ${smartTune.direction || '?'} · ` +
                     (applied ? 'live apply mode (already on SMU)' : 'report mode (SMU reverted to launch)');

  let lockedCount = 0, failedCount = 0;
  let rows = '';
  for (let i = 0; i < cpuInfo.Cores; i++) {
    const start = (launchValues && launchValues[i] != null) ? launchValues[i] : 0;
    const cur   = (currentValues && currentValues[i] != null) ? currentValues[i] : 0;
    const rec   = recommendedCoFor(i, smartTune, launchValues);
    const o     = coreOutcomeFor(i, smartTune);
    if (o.cls === 'tr-locked') lockedCount++;
    if (o.cls === 'tr-failed') failedCount++;
    const delta = rec - start;
    const deltaTxt = delta === 0 ? '' : (delta > 0 ? `(+${delta})` : `(${delta})`);
    const ccdLabel = cpuInfo.IsDualCcd ? `CCD${Math.floor(i / cpuInfo.CoresPerCcd)}` : 'CCD0';
    rows += `<tr class="${o.cls}">
      <td>C${i}</td>
      <td class="tr-ccd">${ccdLabel}</td>
      <td class="tr-num">${start}</td>
      <td class="tr-num"><strong>${rec}</strong> <span class="muted small">${deltaTxt}</span></td>
      <td class="tr-num">${cur}</td>
      <td>${escHtml(o.scope || '—')}</td>
      <td class="tr-num">${o.probes ?? '—'}</td>
      <td>${escHtml(o.label)}</td>
    </tr>`;
  }

  wrap.innerHTML = `<table class="tune-results-table">
    <thead><tr>
      <th>Core</th><th>CCD</th><th>Start CO</th><th>Recommended</th><th>SMU now</th><th>Scope</th><th>Probes</th><th>Outcome</th>
    </tr></thead>
    <tbody>${rows}</tbody>
  </table>`;

  if (applied) {
    summary.innerHTML = `${lockedCount} cores locked · ${failedCount} failed. ` +
      `Values are already on the SMU — use <strong>Revert to launch</strong> if anything feels wrong, or <strong>Save as profile</strong> to keep this configuration.`;
  } else {
    summary.innerHTML = `${lockedCount} cores locked · ${failedCount} failed. ` +
      `The SMU has been reverted to your launch values for safety. ` +
      `Review the table above, then click <strong>Apply recommended</strong> to commit, or <strong>Save as profile</strong> to keep without applying.`;
  }
}

async function applyTuneResults() {
  const btn = document.getElementById('tune-apply-results');
  btn.disabled = true;
  try {
    const r = await fetchJson('/api/smart-tune/apply-results', { method: 'POST' });
    if (!r.ok) { showToast('Apply failed: ' + r.error, 'error'); return; }
    showToast('Tune results applied to SMU ✓');
    await loadCoValues();
  } finally { btn.disabled = false; }
}

async function saveTuneResultsAsProfile() {
  const name = prompt('Profile name?', `smart-tune-${new Date().toISOString().slice(0,10)}`);
  if (!name) return;
  // Build the recommended values array and POST it as a profile.
  // Reuses the standard /api/profiles endpoint - the values column
  // travels as `values` so the rest of the profile machinery (load,
  // apply, delete) treats it identically to a manually-saved profile.
  const recValues = [];
  for (let i = 0; i < cpuInfo.Cores; i++) {
    recValues.push(recommendedCoFor(i, latestSmartTune, launchValues));
  }
  const body = { name, mode: 'per-core', values: recValues, notes: 'Saved from Smart Tune results' };
  const r = await fetchJson('/api/profiles', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!r.ok) { showToast('Profile save failed: ' + r.error, 'error'); return; }
  showToast(`📸 Saved profile "${name}"`);
  await loadProfiles();
}

// Render the per-core status grid shown beneath the live status line.
// One pill per core that has been activated ("Set to Core N" seen),
// with iter X/Y and any error/WHEA counts, color-coded by status.
// Empty input -> empty string (suppresses the section entirely until
// CoreCycler emits its first "Set to Core" line).
function renderPerCoreGrid(perCore) {
  if (!Array.isArray(perCore) || perCore.length === 0) return '';
  const pills = perCore.map(c => {
    const cls = c.status === 'failed' ? 'pc-failed'
              : c.status === 'passed' ? 'pc-passed'
              : 'pc-testing';
    const iter = c.iterationsTotal > 0 ? `${c.iterations}/${c.iterationsTotal}` : `${c.iterations}`;
    const tags = [];
    if (c.errors > 0) tags.push(`${c.errors} err`);
    if (c.whea   > 0) tags.push(`${c.whea} WHEA`);
    const tail = tags.length ? ` · <span class="pc-bad">${tags.join(' · ')}</span>` : '';
    return `<span class="pc-pill ${cls}" title="Core ${c.core} — ${c.status}">C${c.core} · ${iter}${tail}</span>`;
  }).join('');
  return `<div class="pc-grid-label">Per-core progress:</div><div class="pc-grid">${pills}</div>`;
}

async function loadCoValues() {
  if (!cpuInfo || !cpuInfo.SupportsCurveOptimizer) return;
  try {
    const launchR = await fetchJson('/api/co/launch');
    const currentR = await fetchJson('/api/co/current');
    launchValues = launchR.data;
    currentValues = currentR.data;
    if (currentValues) {
      // Switch to whichever tab matches the live SMU state. Skips if the
      // user has a profile staged (formInitialValues set) - they'd want
      // the staged mode, not the SMU mode.
      if (!formInitialValues) {
        const detected = detectCoMode(currentValues, cpuInfo);
        if (detected !== currentMode) {
          currentMode = detected;
          document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.mode === detected));
        }
      }
      const banner = document.getElementById('co-banner');
      banner.classList.remove('hidden');
      banner.innerHTML = `🎯 Detected current Curve Optimizer settings: <strong>${summarizeCo(currentValues)}</strong> <span class="muted">(loaded as your starting point)</span>`;
    }
    renderForm();
  } catch (e) {
    console.warn('CO read failed:', e.message);
  }
}

function renderForm() {
  if (!cpuInfo) return;
  const form = document.getElementById('curve-form');
  const initial = formInitialValues || currentValues || launchValues || new Array(cpuInfo.Cores).fill(0);
  let html = '';
  if (currentMode === 'all-cores') {
    const v = initial[0];
    const cur = currentValues ? currentValues[0] : null;
    html = `<div class="co-input"><label>All cores</label><input type="number" id="co-all" value="${v}" min="-50" max="50">${cur != null ? `<span class="muted small">(current: ${cur})</span>` : ''}</div>`;
  } else if (currentMode === 'per-ccd') {
    for (let c = 0; c < cpuInfo.CcdCount; c++) {
      const start = c * cpuInfo.CoresPerCcd;
      const isVCache = cpuInfo.VCacheCcdIndex === c;
      const label = isVCache ? `CCD${c} (V-Cache)` : `CCD${c} (Standard)`;
      const v = initial[start];
      const cur = currentValues ? currentValues[start] : null;
      html += `<div class="co-input"><label>${label}</label><input type="number" id="co-ccd${c}" value="${v}" min="-50" max="50">${cur != null ? `<span class="muted small">(current: ${cur})</span>` : ''}</div>`;
    }
  } else {
    for (let i = 0; i < cpuInfo.Cores; i++) {
      const ccd = cpuInfo.IsDualCcd ? Math.floor(i / cpuInfo.CoresPerCcd) : 0;
      const v = initial[i];
      const cur = currentValues ? currentValues[i] : null;
      html += `<div class="co-input"><label>Core ${i} (CCD${ccd})</label><input type="number" id="co-core${i}" value="${v}" min="-50" max="50">${cur != null ? `<span class="muted small">(current: ${cur})</span>` : ''}</div>`;
    }
  }
  form.innerHTML = html;
}

// Expand a profile's stored values into a flat per-core array
function expandProfileValues(profile) {
  if (!cpuInfo) return null;
  const arr = new Array(cpuInfo.Cores).fill(0);
  if (!profile || !profile.values) return arr;
  if (profile.mode === 'all-cores') {
    const v = profile.values.all;
    arr.fill(v);
  } else if (profile.mode === 'per-ccd') {
    for (let c = 0; c < cpuInfo.CcdCount; c++) {
      const v = profile.values['ccd' + c];
      const start = c * cpuInfo.CoresPerCcd;
      for (let i = 0; i < cpuInfo.CoresPerCcd; i++) arr[start + i] = v;
    }
  } else if (profile.mode === 'per-core') {
    for (let i = 0; i < cpuInfo.Cores; i++) {
      arr[i] = profile.values[i] !== undefined ? profile.values[i] : 0;
    }
  }
  return arr;
}

function loadProfileIntoForm(profileName) {
  const p = loadedProfiles.find(x => x.name === profileName);
  if (!p) { showToast('Profile not found', 'error'); return; }
  // Switch mode tab
  currentMode = p.mode;
  document.querySelectorAll('.tab').forEach(t => {
    t.classList.toggle('active', t.dataset.mode === p.mode);
  });
  // Override form initial values
  formInitialValues = expandProfileValues(p);
  renderForm();
  // Scroll to curve card so user sees the loaded values
  document.getElementById('curve-card').scrollIntoView({ behavior: 'smooth', block: 'start' });
  showToast(`Loaded "${p.name}" — click Apply to write`, 'warn');
}

function collectValues() {
  if (currentMode === 'all-cores') {
    return { mode: 'all-cores', values: { all: +document.getElementById('co-all').value } };
  } else if (currentMode === 'per-ccd') {
    const v = {};
    for (let c = 0; c < cpuInfo.CcdCount; c++) v['ccd' + c] = +document.getElementById('co-ccd' + c).value;
    return { mode: 'per-ccd', values: v };
  } else {
    const v = {};
    for (let i = 0; i < cpuInfo.Cores; i++) v[i] = +document.getElementById('co-core' + i).value;
    return { mode: 'per-core', values: v };
  }
}

// yyyy-MM-dd-HHmmss to match the pre-tune snapshot naming convention.
function nowSlug() {
  const d = new Date();
  const pad = n => n.toString().padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

let pendingApplyBody = null;
let applyInFlight = false;

// Apply gateway: shows a confirm modal with the settings the user is about
// to write, and offers to auto-save them as a named profile first. The
// actual SMU write lives in performApply.
async function applyCo() {
  const body = collectValues();
  pendingApplyBody = body;
  const arr = expandProfileValues(body) || [];
  const summary = summarizeCo(arr);
  // Build per-CCD pill chips matching the profile-details preview style.
  const ccds = {};
  arr.forEach((v, i) => {
    const ccd = cpuInfo && cpuInfo.IsDualCcd ? Math.floor(i / cpuInfo.CoresPerCcd) : 0;
    (ccds[ccd] = ccds[ccd] || []).push({ core: i, value: v });
  });
  const pillClass = v => v < 0 ? 'neg' : v > 0 ? 'pos' : 'zero';
  const fmt = v => (v > 0 ? '+' : '') + v;
  let valuesHtml = '';
  Object.keys(ccds).sort((a, b) => +a - +b).forEach(ccd => {
    const label = cpuInfo && cpuInfo.VCacheCcdIndex === +ccd ? `CCD${ccd} (V-Cache)` : `CCD${ccd}`;
    const pills = ccds[ccd].map(c => `<span class="co-pill ${pillClass(c.value)}" title="Core ${c.core}">C${c.core}: ${fmt(c.value)}</span>`).join('');
    valuesHtml += `<div class="muted small" style="margin-top:0.4rem">${label}</div><div class="co-pills">${pills}</div>`;
  });
  document.getElementById('apply-confirm-summary').innerHTML =
    `<div class="apply-summary-header"><strong>${body.mode}</strong> · ${summary}</div>${valuesHtml}`;
  document.getElementById('apply-confirm-overlay').classList.remove('hidden');
}

async function performApply(body, alsoSaveProfile) {
  if (applyInFlight) return;
  applyInFlight = true;
  try {
  if (alsoSaveProfile) {
    const name = 'set-curve-optimizer-' + nowSlug();
    const saveBody = Object.assign({}, body, { name, notes: 'Auto-saved before manual Apply' });
    try {
      const sr = await fetchJson('/api/profiles', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(saveBody) });
      if (sr.ok) showToast(`📸 Saved profile "${name}"`);
      else showToast('Profile save failed: ' + sr.error, 'error');
    } catch (e) { showToast('Profile save failed: ' + e.message, 'error'); }
  }
  const r = await fetchJson('/api/co', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!r.ok) { showToast('Apply failed: ' + r.error, 'error'); return; }
  if (r.data && r.data.writesStuck === false) {
    // Silent SMU ignore - PBO/CO almost certainly disabled in BIOS.
    // Show the setup card with a specific "we tried, nothing happened" reason.
    const n = (r.data.mismatches || []).length;
    showToast('⚠ CO write was IGNORED by the SMU - PBO/CO probably disabled in BIOS', 'error');
    BiosSetup.show(`Read-back shows <strong>${n} of ${cpuInfo ? cpuInfo.Cores : '?'}</strong> cores still at their BIOS values after the apply. The SMU accepted the command but didn't change the registers - the classic signature of PBO/CO being disabled in BIOS.`);
  } else if (r.data && r.data.writesStuck === true) {
    showToast('Applied ✓ (verified)');
  } else {
    showToast('Applied ✓');
  }
  await loadCoValues();
  if (alsoSaveProfile) await loadProfiles();
  } finally { applyInFlight = false; }
}

async function revertCo() {
  const r = await fetchJson('/api/co/revert', { method: 'POST' });
  if (!r.ok) { showToast('Revert failed: ' + r.error, 'error'); return; }
  showToast('Reverted to launch values');
  await loadCoValues();
}

async function resetCo() {
  if (!cpuInfo || !cpuInfo.SupportsCurveOptimizer) return;
  const r = await fetchJson('/api/reset-co', { method: 'POST' });
  if (!r.ok) { showToast('Reset failed: ' + r.error, 'error'); return; }
  showToast('CO reset to 0', 'warn');
  await loadCoValues();
}

async function startTest() {
  const mode = document.querySelector('input[name="testMode"]:checked').value;
  if (mode === 'smart') {
    const smartMode = document.getElementById('smart-mode').value;
    const direction = smartMode === 'overclock' ? 'overclock' : 'undervolt';
    const applyMode = document.querySelector('input[name="applyMode"]:checked')?.value || 'report';
    const ok = await SmartTune.start(smartMode, direction, applyMode);
    if (!ok) return;
    document.getElementById('start-test').classList.add('hidden');
    document.getElementById('stop-test').classList.remove('hidden');
    document.getElementById('status-card').classList.remove('hidden');
    document.getElementById('report-card').classList.add('hidden');
    return;
  }
  const auto = mode === 'auto';
  const body = {
    mode: document.getElementById('test-mode').value,
    iterations: +document.getElementById('iterations').value,
    autoAdjust: auto,
    autoMax: auto ? +document.getElementById('auto-max').value : 0,
    autoInc: auto ? +document.getElementById('auto-inc').value : 1,
    safety: {
      maxTempC: settings.safetyMaxTempC,
      maxVid:   settings.safetyMaxVid,
      abortOnWhea: settings.safetyAutoAbortOnWhea
    }
  };
  const r = await fetchJson('/api/test/start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!r.ok) { showToast('Start failed: ' + r.error, 'error'); return; }
  document.getElementById('start-test').classList.add('hidden');
  document.getElementById('stop-test').classList.remove('hidden');
  document.getElementById('status-card').classList.remove('hidden');
  document.getElementById('report-card').classList.add('hidden');
  ProDash.resetStats();
  ProDash.show();
}

async function stopTest() {
  const mode = document.querySelector('input[name="testMode"]:checked').value;
  if (mode === 'smart') {
    await SmartTune.stop();
  } else {
    await fetchJson('/api/test/stop', { method: 'POST' });
  }
  document.getElementById('stop-test').classList.add('hidden');
  document.getElementById('start-test').classList.remove('hidden');
}

async function loadReport() {
  const r = await fetchJson('/api/report');
  if (!r.ok) return;
  const d = r.data;
  const verdictClass = d.verdict === 'PASSED' ? 'verdict-pass' : (d.verdict === 'INCOMPLETE' ? 'verdict-incomplete' : 'verdict-fail');
  const verdictIcon = d.verdict === 'PASSED' ? '✅' : (d.verdict === 'INCOMPLETE' ? '⏱' : '❌');
  let html = `<div class="${verdictClass}">${verdictIcon} ${escHtml(d.verdict)}</div>`;
  html += `<p>Duration: ${escHtml(d.duration || '?')} · Iterations: ${d.iterationsCompleted}/${d.iterationsRequested} · Cores tested: ${(d.coresTested || []).length}</p>`;

  if (d.coresFailed && d.coresFailed.length) {
    html += '<h3>Failed cores</h3><table class="report-tbl"><tr><th>Core</th><th>CCD</th><th>CO at failure</th><th>Type</th></tr>';
    d.coresFailed.forEach(c => html += `<tr><td>${c.core}</td><td>${escHtml(c.ccdLabel)}</td><td>${c.coAtFailure ?? '?'}</td><td>${escHtml(c.errorType)}</td></tr>`);
    html += '</table>';
  } else if (d.verdict === 'PASSED') {
    html += '<p class="muted">All cores passed with flying colors. 🎉</p>';
  }

  if (d.smartSuggestions && d.smartSuggestions.length) {
    html += '<h3>💡 Smart Suggestions</h3><ul>';
    d.smartSuggestions.forEach(s => html += `<li>${escHtml(s)}</li>`);
    html += '</ul>';
  }

  if (d.peaks && (d.peaks.packageTemp || d.peaks.packagePower)) {
    html += '<h3>📊 Peak values during test</h3><p>';
    if (d.peaks.packageTemp) html += `Max temp: <strong>${d.peaks.packageTemp.toFixed(0)}°C</strong> · `;
    if (d.peaks.packagePower) html += `Max power: <strong>${d.peaks.packagePower.toFixed(0)}W</strong>`;
    html += '</p>';
  }

  document.getElementById('report-content').innerHTML = html;
  document.getElementById('report-card').classList.remove('hidden');
  document.getElementById('status-card').classList.add('hidden');
}

function renderTelemetry(t) {
  const strip = document.getElementById('telemetry-strip');
  if (!t) { strip.textContent = 'Sensors unavailable.'; return; }
  const temp = t.packageTemp != null ? t.packageTemp.toFixed(0) + '°C' : '—';
  const power = t.packagePower != null ? t.packagePower.toFixed(0) + 'W' : '—';
  const cores = t.cores || [];
  const vAvg = cores.length ? (cores.reduce((s, c) => s + (c.voltage || 0), 0) / cores.length).toFixed(2) + 'V' : '—';
  const maxClk = cores.length ? Math.max(...cores.map(c => c.clockMHz || 0)).toFixed(0) + ' MHz' : '—';
  strip.innerHTML = `
    <span class="metric"><span class="label">Pkg Temp</span><span class="value">${temp}</span></span>
    <span class="metric"><span class="label">Pkg Power</span><span class="value">${power}</span></span>
    <span class="metric"><span class="label">Avg VID</span><span class="value">${vAvg}</span></span>
    <span class="metric"><span class="label">Max Clock</span><span class="value">${maxClk}</span></span>
    <button class="secondary expand-btn" id="telem-expand">${document.getElementById('telemetry-expanded').classList.contains('hidden') ? '⏵ expand' : '⏷ collapse'}</button>`;
  if (!document.getElementById('telemetry-expanded').classList.contains('hidden')) renderExpandedTelemetry(t);
}

function renderExpandedTelemetry(t) {
  const cores = t.cores || [];
  const target = document.getElementById('telemetry-expanded');
  if (!cores.length || !cpuInfo) {
    target.innerHTML = '<p class="muted small">⏳ Waiting for per-core telemetry — LibreHardwareMonitor takes a few seconds to enumerate all cores on first read.</p>';
    return;
  }
  const ccds = {};
  cores.forEach(c => {
    const ccd = cpuInfo.IsDualCcd ? Math.floor(c.core / cpuInfo.CoresPerCcd) : 0;
    (ccds[ccd] = ccds[ccd] || []).push(c);
  });
  let html = '<div class="expanded-hint muted small">Per-core view: each tile shows voltage · clock · load%. CCDs are grouped; V-Cache CCD has a 🔋 badge.</div>';
  Object.keys(ccds).sort().forEach(ccd => {
    const label = cpuInfo.VCacheCcdIndex === +ccd ? `CCD${ccd} (V-Cache 🔋)` : `CCD${ccd}`;
    html += `<div class="muted small" style="margin-top:0.5rem">${label}</div><div class="core-grid">`;
    ccds[ccd].forEach(c => {
      const cls = c.temperature >= 85 ? 'temp-hot' : c.temperature >= 70 ? 'temp-warn' : '';
      html += `<div class="core-tile ${cls}">
        <div class="num">C${c.core}</div>
        ${c.voltage != null ? `<div>${c.voltage.toFixed(2)}V</div>` : ''}
        ${c.clockMHz != null ? `<div>${(c.clockMHz/1000).toFixed(2)}G</div>` : ''}
        ${c.loadPct != null ? `<div>${c.loadPct.toFixed(0)}%</div>` : ''}
      </div>`;
    });
    html += '</div>';
  });
  if (t.memoryClock || t.fclk) {
    html += '<div class="muted small">';
    if (t.memoryClock) html += `Memory: ${t.memoryClock.toFixed(0)} MHz `;
    if (t.fclk) html += ` · FCLK: ${t.fclk.toFixed(0)} MHz`;
    html += '</div>';
  }
  document.getElementById('telemetry-expanded').innerHTML = html;
}

async function pollTelemetry() {
  try {
    const r = await fetchJson('/api/telemetry');
    renderTelemetry(r.data);
    ProDash.ingest(r.data);
  } catch (e) { /* ignore */ }
}

// ============================================================================
// Pro Dashboard - live charts, stats, safety integration.
// One module wraps Chart.js setup, rolling history, and stat aggregation.
// ============================================================================
const ProDash = (() => {
  const HISTORY_CAP = 1800;       // ~30 min @ 1Hz
  const COLORS = [
    '#06B6D4','#3B82F6','#8B5CF6','#EC4899','#F59E0B','#10B981',
    '#EF4444','#84CC16','#22D3EE','#A855F7','#F472B6','#FBBF24',
    '#34D399','#F87171','#A3E635','#60A5FA'
  ];
  let windowSec = 180;
  let paused = false;
  let history = [];   // [{t, pkgTemp, pkgPower, ccdTemps:[{ccd,tempC}], cores:[{core,voltage,clockMHz,loadPct}]}]
  let charts = {};
  let coreCount = 0;

  // Stats accumulator (reset on demand)
  let stats = freshStats();
  function freshStats() {
    return {
      samples: 0,
      pkgTemp: { min: null, max: null, sum: 0, n: 0 },
      pkgPower:{ min: null, max: null, sum: 0, n: 0 },
      avgClk:  { min: null, max: null, sum: 0, n: 0 },
      maxClk:  null,
      avgVid:  { min: null, max: null, sum: 0, n: 0 },
      maxVid:  null,
      avgLoad: { sum: 0, n: 0 },
      hottestCore: { core: null, temp: null },
    };
  }
  function pushStat(slot, v) {
    if (v == null || isNaN(v)) return;
    if (slot.min == null || v < slot.min) slot.min = v;
    if (slot.max == null || v > slot.max) slot.max = v;
    slot.sum += v; slot.n++;
  }
  function avg(slot) { return slot.n ? slot.sum / slot.n : null; }

  function physicalCores() {
    if (!cpuInfo || !cpuInfo.Cores) return Math.max(coreCount, 8);
    return cpuInfo.Cores;
  }

  // Legend click handler with a third "solo" state via shift+click.
  // - Plain click: toggle visibility of the clicked dataset (Chart.js default)
  // - Shift+click: hide every other dataset and show only this one.
  //   If this dataset is already the only visible one, restore all.
  // This gives the user the three states they asked for (show / hide /
  // show-only-this) with one click + one modifier - no submenu needed.
  function legendClickHandler(e, legendItem, legend) {
    const chart = legend.chart;
    const idx = legendItem.datasetIndex;
    const shift = e && e.native && e.native.shiftKey;
    if (shift) {
      const visible = chart.data.datasets.map((_, i) => chart.isDatasetVisible(i));
      const visibleCount = visible.filter(Boolean).length;
      const isOnlyVisible = visibleCount === 1 && visible[idx];
      chart.data.datasets.forEach((_, i) => {
        chart.setDatasetVisibility(i, isOnlyVisible ? true : (i === idx));
      });
    } else {
      chart.setDatasetVisibility(idx, !chart.isDatasetVisible(idx));
    }
    chart.update();
  }

  // HTML tooltip rendered on document.body so it can extend beyond the
  // canvas. Chart.js's built-in tooltip is drawn ON the canvas, which
  // clips per-core charts (16 rows + title can be ~300px tall vs a 240px
  // canvas). pointer-events: none keeps it from blocking the chart hover
  // that drives it. Edge-flips to stay in the viewport.
  function externalTooltipHandler(context) {
    const tt = context.tooltip;
    let el = document.getElementById('chartjs-html-tooltip');
    if (!el) {
      el = document.createElement('div');
      el.id = 'chartjs-html-tooltip';
      el.className = 'chartjs-html-tooltip';
      document.body.appendChild(el);
    }
    if (tt.opacity === 0) { el.style.opacity = 0; return; }
    const title = (tt.title && tt.title[0]) || '';
    const items = (tt.dataPoints || []).map(dp => {
      const color = dp.dataset.borderColor || '#888';
      return `<div class="tt-row"><span class="tt-swatch" style="background:${color}"></span><span class="tt-label">${dp.dataset.label || ''}</span><span class="tt-value">${dp.formattedValue}</span></div>`;
    }).join('');
    el.innerHTML = (title ? `<div class="tt-title">${title}</div>` : '') + items;
    el.style.opacity = 1;
    // Measure after content insertion, then position
    const canvasRect = context.chart.canvas.getBoundingClientRect();
    const ttRect = el.getBoundingClientRect();
    const gap = 12;
    let x = canvasRect.left + window.pageXOffset + tt.caretX + gap;
    let y = canvasRect.top + window.pageYOffset + tt.caretY - ttRect.height / 2;
    // Flip to the left if it would overflow the right edge
    if (x + ttRect.width > window.innerWidth + window.pageXOffset - 8) {
      x = canvasRect.left + window.pageXOffset + tt.caretX - ttRect.width - gap;
    }
    // Clamp to viewport vertically
    const minY = window.pageYOffset + 8;
    const maxY = window.innerHeight + window.pageYOffset - ttRect.height - 8;
    if (y < minY) y = minY;
    if (y > maxY) y = maxY;
    el.style.left = x + 'px';
    el.style.top = y + 'px';
  }

  function buildLineChart(canvasId, label, opts) {
    opts = opts || {};
    const ctx = document.getElementById(canvasId);
    if (!ctx) return null;
    const datasets = [];
    if (opts.perCore) {
      const n = physicalCores();
      for (let i = 0; i < n; i++) {
        datasets.push({
          label: 'C' + i,
          data: [], borderWidth: 1.2, pointRadius: 0, tension: 0.25,
          borderColor: COLORS[i % COLORS.length],
          backgroundColor: COLORS[i % COLORS.length] + '22',
          fill: false
        });
      }
    } else if (opts.series) {
      for (const s of opts.series) {
        datasets.push({
          label: s.label, data: [], borderWidth: s.w || 1.8, pointRadius: 0, tension: 0.25,
          borderColor: s.color, backgroundColor: s.color + '22', fill: !!s.fill
        });
      }
    }
    return new Chart(ctx, {
      type: 'line',
      data: { labels: [], datasets },
      options: {
        animation: false,
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'nearest', intersect: false },
        layout: { padding: { top: 8 } },
        plugins: {
          legend: { display: !!opts.legend, position: 'bottom', align: 'start',
                    labels: { color: '#8b95a8', boxWidth: 10, font: { size: 10 }, padding: 6, usePointStyle: false },
                    onClick: legendClickHandler },
          tooltip: { enabled: false, external: externalTooltipHandler, mode: 'index', intersect: false }
        },
        scales: {
          x: { ticks: { color: '#5e6878', maxTicksLimit: 6, font: { size: 10 } },
               grid: { color: 'rgba(255,255,255,0.04)' } },
          y: { ticks: { color: '#8b95a8', font: { size: 10 } },
               grid: { color: 'rgba(255,255,255,0.05)' },
               suggestedMin: opts.yMin, suggestedMax: opts.yMax }
        }
      }
    });
  }

  function buildScatter(canvasId) {
    const ctx = document.getElementById(canvasId);
    if (!ctx) return null;
    return new Chart(ctx, {
      type: 'scatter',
      data: { datasets: [{ label: 'core', data: [], pointRadius: 5, pointHoverRadius: 7,
                           pointBackgroundColor: ctx => COLORS[(ctx.dataIndex || 0) % COLORS.length] }] },
      options: {
        animation: false, responsive: true, maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          tooltip: { callbacks: {
            label: (ctx) => `Core ${ctx.raw.core}: ${ctx.raw.x.toFixed(3)}V · ${(ctx.raw.y/1000).toFixed(2)} GHz`
          } }
        },
        scales: {
          x: { title: { display: true, text: 'VID (V)', color: '#8b95a8', font: { size: 10 } },
               ticks: { color: '#8b95a8', font: { size: 10 } },
               grid: { color: 'rgba(255,255,255,0.05)' } },
          y: { title: { display: true, text: 'Clock (MHz)', color: '#8b95a8', font: { size: 10 } },
               ticks: { color: '#8b95a8', font: { size: 10 } },
               grid: { color: 'rgba(255,255,255,0.05)' } }
        }
      }
    });
  }

  function ensureCharts() {
    if (charts.ready) return;
    const ccdSeries = [{ label: 'Pkg (Tctl)', color: '#EF4444', w: 2.2 }];
    if (cpuInfo && cpuInfo.IsDualCcd) {
      ccdSeries.push({ label: 'CCD0', color: '#3B82F6', w: 1.4 });
      ccdSeries.push({ label: 'CCD1', color: '#10B981', w: 1.4 });
    }
    charts.clock = buildLineChart('chart-clock', 'Clock', { perCore: true, legend: true, yMin: 0 });
    charts.temp  = buildLineChart('chart-temp',  'Temp',  { series: ccdSeries, legend: true, yMin: 30, yMax: 100 });
    charts.vid   = buildLineChart('chart-vid',   'VID',   { perCore: true, legend: true, yMin: 0.8, yMax: 1.55 });
    charts.power = buildLineChart('chart-power', 'Power', { series: [{ label: 'Package (W)', color: '#F59E0B', w: 2.2, fill: true }], legend: false, yMin: 0 });
    charts.vf    = buildScatter('chart-vf');
    charts.ready = true;
  }

  function ingest(snap) {
    if (paused || !snap) return;
    history.push(snap);
    if (history.length > HISTORY_CAP) history.shift();
    coreCount = Math.max(coreCount, (snap.cores || []).length);
    accumulateStats(snap);
    render();
  }

  function accumulateStats(snap) {
    stats.samples++;
    pushStat(stats.pkgTemp,  snap.packageTemp);
    pushStat(stats.pkgPower, snap.packagePower);
    const cores = (snap.cores || []).filter(c => c.core < physicalCores());
    if (cores.length) {
      const clks = cores.map(c => c.clockMHz).filter(v => v != null);
      const vids = cores.map(c => c.voltage).filter(v => v != null);
      const loads = cores.map(c => c.loadPct).filter(v => v != null);
      if (clks.length) {
        const a = clks.reduce((s,v)=>s+v,0) / clks.length;
        pushStat(stats.avgClk, a);
        const m = Math.max(...clks);
        if (stats.maxClk == null || m > stats.maxClk) stats.maxClk = m;
      }
      if (vids.length) {
        const a = vids.reduce((s,v)=>s+v,0) / vids.length;
        pushStat(stats.avgVid, a);
        const m = Math.max(...vids);
        if (stats.maxVid == null || m > stats.maxVid) stats.maxVid = m;
      }
      if (loads.length) {
        const a = loads.reduce((s,v)=>s+v,0) / loads.length;
        stats.avgLoad.sum += a; stats.avgLoad.n++;
      }
    }
    // Hottest core uses package temp as proxy unless CCD temps present
    if (snap.ccdTemps && snap.ccdTemps.length) {
      const h = snap.ccdTemps.reduce((p,c) => (p == null || c.tempC > p.tempC) ? c : p, null);
      if (h && (stats.hottestCore.temp == null || h.tempC > stats.hottestCore.temp)) {
        stats.hottestCore = { core: 'CCD' + h.ccd, temp: h.tempC };
      }
    } else if (snap.packageTemp != null) {
      if (stats.hottestCore.temp == null || snap.packageTemp > stats.hottestCore.temp) {
        stats.hottestCore = { core: 'Pkg', temp: snap.packageTemp };
      }
    }
  }

  function windowedHistory() {
    if (!history.length) return [];
    const now = new Date(history[history.length - 1].time).getTime();
    const cutoff = now - windowSec * 1000;
    return history.filter(s => new Date(s.time).getTime() >= cutoff);
  }

  function fmtTime(iso) {
    const d = new Date(iso);
    return d.getHours().toString().padStart(2,'0') + ':' + d.getMinutes().toString().padStart(2,'0') + ':' + d.getSeconds().toString().padStart(2,'0');
  }

  function render() {
    ensureCharts();
    const win = windowedHistory();
    if (!win.length) return;
    const labels = win.map(s => fmtTime(s.time));

    // Clock per-core
    if (charts.clock) {
      charts.clock.data.labels = labels;
      const n = physicalCores();
      for (let i = 0; i < n; i++) {
        charts.clock.data.datasets[i].data = win.map(s => {
          const c = (s.cores || []).find(x => x.core === i);
          return c ? c.clockMHz : null;
        });
      }
      charts.clock.update('none');
    }
    // VID per-core
    if (charts.vid) {
      charts.vid.data.labels = labels;
      const n = physicalCores();
      for (let i = 0; i < n; i++) {
        charts.vid.data.datasets[i].data = win.map(s => {
          const c = (s.cores || []).find(x => x.core === i);
          return c ? c.voltage : null;
        });
      }
      charts.vid.update('none');
    }
    // Temp (Pkg + CCDs)
    if (charts.temp) {
      charts.temp.data.labels = labels;
      charts.temp.data.datasets[0].data = win.map(s => s.packageTemp);
      if (cpuInfo && cpuInfo.IsDualCcd) {
        charts.temp.data.datasets[1].data = win.map(s => {
          const ccd = (s.ccdTemps || []).find(x => x.ccd === 0); return ccd ? ccd.tempC : null;
        });
        charts.temp.data.datasets[2].data = win.map(s => {
          const ccd = (s.ccdTemps || []).find(x => x.ccd === 1); return ccd ? ccd.tempC : null;
        });
      }
      charts.temp.update('none');
    }
    // Power
    if (charts.power) {
      charts.power.data.labels = labels;
      charts.power.data.datasets[0].data = win.map(s => s.packagePower);
      charts.power.update('none');
    }
    // V/F scatter (current snapshot only)
    if (charts.vf) {
      const cur = win[win.length - 1];
      const pts = (cur.cores || [])
        .filter(c => c.core < physicalCores() && c.voltage != null && c.clockMHz != null && c.clockMHz > 100)
        .map(c => ({ x: c.voltage, y: c.clockMHz, core: c.core }));
      charts.vf.data.datasets[0].data = pts;
      charts.vf.update('none');
    }

    renderStats();
    renderHeatmap(win[win.length - 1]);
  }

  function setText(id, v) { const el = document.getElementById(id); if (el) el.textContent = v; }
  function fmt(v, dp, suffix) {
    if (v == null || isNaN(v)) return '—';
    return v.toFixed(dp) + (suffix || '');
  }

  function renderStats() {
    setText('st-samples', stats.samples);
    setText('st-temp',     fmt(stats.pkgTemp.max != null ? lastNonNull('packageTemp') : null, 0, '°C'));
    setText('st-temp-min', fmt(stats.pkgTemp.min, 0, '°C'));
    setText('st-temp-avg', fmt(avg(stats.pkgTemp), 0, '°C'));
    setText('st-temp-max', fmt(stats.pkgTemp.max, 0, '°C'));
    setText('st-pwr',      fmt(lastNonNull('packagePower'), 0, 'W'));
    setText('st-pwr-min',  fmt(stats.pkgPower.min, 0, 'W'));
    setText('st-pwr-avg',  fmt(avg(stats.pkgPower), 0, 'W'));
    setText('st-pwr-max',  fmt(stats.pkgPower.max, 0, 'W'));
    setText('st-clk',      fmt(stats.maxClk, 0, ' MHz'));
    setText('st-clk-min',  fmt(stats.avgClk.min, 0, ''));
    setText('st-clk-avg',  fmt(avg(stats.avgClk), 0, ''));
    setText('st-clk-max',  fmt(stats.maxClk, 0, ''));
    setText('st-vid',      fmt(stats.maxVid, 3, 'V'));
    setText('st-vid-min',  fmt(stats.avgVid.min, 3, ''));
    setText('st-vid-avg',  fmt(avg(stats.avgVid), 3, ''));
    setText('st-vid-max',  fmt(stats.maxVid, 3, ''));
    setText('st-hot',      fmt(stats.hottestCore.temp, 0, '°C'));
    setText('st-hot-core', stats.hottestCore.core ? `peak on ${stats.hottestCore.core}` : '—');
    setText('st-load',     fmt(avg(stats.avgLoad), 0, '%'));

    // Threshold colouring
    const tempTile = document.getElementById('st-temp')?.parentElement;
    if (tempTile) {
      tempTile.classList.remove('warn','danger');
      const maxT = stats.pkgTemp.max || 0;
      if (maxT >= (settings.safetyMaxTempC || 95)) tempTile.classList.add('danger');
      else if (maxT >= ((settings.safetyMaxTempC || 95) - 10)) tempTile.classList.add('warn');
    }
    const vidTile = document.getElementById('st-vid')?.parentElement;
    if (vidTile) {
      vidTile.classList.remove('warn','danger');
      const maxV = stats.maxVid || 0;
      if (maxV >= (settings.safetyMaxVid || 1.45)) vidTile.classList.add('danger');
      else if (maxV >= ((settings.safetyMaxVid || 1.45) - 0.05)) vidTile.classList.add('warn');
    }
  }

  function lastNonNull(field) {
    for (let i = history.length - 1; i >= 0; i--) {
      const v = history[i][field];
      if (v != null) return v;
    }
    return null;
  }

  function renderHeatmap(snap) {
    if (!snap) return;
    const wrap = document.getElementById('core-heatmap');
    if (!wrap) return;
    const n = physicalCores();
    const cores = snap.cores || [];
    let html = '';
    for (let i = 0; i < n; i++) {
      const c = cores.find(x => x.core === i);
      const v = c && c.voltage != null ? c.voltage.toFixed(3) + 'V' : '—';
      const clk = c && c.clockMHz != null && c.clockMHz > 0 ? (c.clockMHz / 1000).toFixed(2) + 'G' : '—';
      const load = c && c.loadPct != null ? c.loadPct.toFixed(0) : 0;
      // Heat class based on package temp as a proxy (per-core temps not available on Ryzen)
      let cls = '';
      if (load > 80) cls = 'heat-hot';
      else if (load > 30) cls = 'heat-warm';
      else if (load < 5) cls = 'heat-cold';
      const ccd = cpuInfo && cpuInfo.IsDualCcd ? Math.floor(i / cpuInfo.CoresPerCcd) : 0;
      const vCacheTag = cpuInfo && cpuInfo.VCacheCcdIndex === ccd ? '🔋' : '';
      html += `<div class="heat-tile ${cls}" title="Core ${i} (CCD${ccd})${vCacheTag ? ' V-Cache':''}">
        <div class="ht-core">C${i}${vCacheTag}</div>
        <div class="ht-row">${v}</div>
        <div class="ht-row">${clk}</div>
        <div class="ht-row">${load}%</div>
        <div class="ht-bar" style="width:${load}%"></div>
      </div>`;
    }
    wrap.innerHTML = html;
  }

  function setWindow(sec) {
    windowSec = sec;
    document.querySelectorAll('.pill[data-range]').forEach(p => p.classList.toggle('active', +p.dataset.range === sec));
    render();
  }

  function resetStats() {
    stats = freshStats();
    showToast('Stats reset');
    render();
  }

  function togglePause() {
    paused = !paused;
    const btn = document.getElementById('pro-pause');
    if (btn) btn.textContent = paused ? '▶ Resume' : '⏸ Pause';
  }

  function exportHistory() {
    const blob = new Blob([JSON.stringify({ exportedAt: new Date().toISOString(), cpu: cpuInfo, history }, null, 2)],
      { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'rpo-telemetry-' + Date.now() + '.json';
    document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
    showToast('Exported ' + history.length + ' samples');
  }

  function show() {
    document.getElementById('pro-dashboard')?.classList.remove('hidden');
    document.getElementById('pro-toggle')?.classList.add('hidden');
    ensureCharts();
    if (history.length) render();
  }
  function hide() {
    document.getElementById('pro-dashboard')?.classList.add('hidden');
    document.getElementById('pro-toggle')?.classList.remove('hidden');
    // Hide the HTML chart tooltip if it's still pinned at its last
    // position from a previous hover. Without this it stays mounted
    // on document.body at opacity 0 forever, technically harmless but
    // an orphan element we may as well clean up.
    const tt = document.getElementById('chartjs-html-tooltip');
    if (tt) tt.style.opacity = 0;
  }
  function isVisible() {
    return !document.getElementById('pro-dashboard')?.classList.contains('hidden');
  }

  // Wire up controls
  document.addEventListener('click', (e) => {
    if (e.target.classList?.contains('pill') && e.target.dataset.range) {
      setWindow(+e.target.dataset.range);
    }
    if (e.target.id === 'pro-pause')    togglePause();
    if (e.target.id === 'pro-clear')    resetStats();
    if (e.target.id === 'pro-export')   exportHistory();
    if (e.target.id === 'pro-collapse') hide();
    if (e.target.id === 'pro-toggle')   show();
  });

  return { ingest, show, hide, isVisible, resetStats };
})();

let pollStatusInFlight = false;
let lastObservedState = null;
let liveCoRefreshCounter = 0;
async function pollStatus() {
  // Guard against overlapping calls. setInterval fires every 1s, but if
  // the server is slow a second poll would start before the first
  // returns, racing the UI updates.
  if (pollStatusInFlight) return;
  pollStatusInFlight = true;
  try {
    const r = await fetchJson('/api/status');
    const s = r.data;
    stateName = s.state;
    if (s.state === 'TESTING' && s.live) {
      const c = s.live;
      const perCoreGrid = renderPerCoreGrid(c.perCore);
      document.getElementById('status-content').innerHTML =
        `<p>Testing core <strong>${c.currentCore ?? '?'}</strong> · Iteration <strong>${c.iteration ?? '?'}/${c.iterationsTotal ?? '?'}</strong></p>
         <p>Errors so far: ${c.errors} · WHEA: ${c.wheaErrors} · Runtime: ${c.runtime || '—'}</p>
         ${perCoreGrid}`;
    }
    // Live CO panel: always visible (set in index.html without `hidden`).
    // Refresh from the SMU every 3 polls (3 s) so Auto-Adjust and Smart
    // Tune writes are visible during tunes, and the idle case still
    // shows fresh values without forcing a manual page reload. Using a
    // side-effect-free fetcher (pollCurrentCo) instead of loadCoValues
    // so the form's mode tab doesn't auto-switch under the user.
    liveCoRefreshCounter++;
    if (liveCoRefreshCounter >= 3) {
      liveCoRefreshCounter = 0;
      await pollCurrentCo();
    }
    renderLiveCo();
    if (s.state === 'REPORTING') {
      // Only fetch + rebuild the report on the *transition* into
      // REPORTING; otherwise we re-fetched once per second and reset
      // the user's scroll position every tick.
      if (lastObservedState !== 'REPORTING') loadReport();
      document.getElementById('start-test').classList.remove('hidden');
      document.getElementById('stop-test').classList.add('hidden');
    }
    if (s.state === 'IDLE') {
      document.getElementById('stop-test').classList.add('hidden');
      document.getElementById('start-test').classList.remove('hidden');
    }
    if (s.wheaEvents && s.wheaEvents.length > lastWheaCount) {
      showToast('⚠ WHEA event detected', 'error');
      document.getElementById('bodyguard').classList.add('alert');
      playSafetyBeep();
      lastWheaCount = s.wheaEvents.length;
    }
    if (s.smartTune) {
      latestSmartTune = s.smartTune;
      // One-shot auto-switch to per-core when a tune starts, so the
      // user immediately sees per-core CO progression without having
      // to click a tab. Respects manual switches after - we only do
      // it once per tune (flag resets when tune ends/stops).
      if (s.smartTune.status === 'RUNNING' && !autoSwitchedForTune) {
        if (liveCoView !== 'per-core') {
          liveCoView = 'per-core';
          document.querySelectorAll('.live-co-tab').forEach(t => t.classList.toggle('active', t.dataset.view === 'per-core'));
        }
        autoSwitchedForTune = true;
      } else if (s.smartTune.status !== 'RUNNING') {
        autoSwitchedForTune = false;
      }
      SmartTune.renderState(s.smartTune);
      renderTuneResults(s.smartTune);
    } else {
      latestSmartTune = null;
      autoSwitchedForTune = false;
    }
    // Surface the BIOS-setup card if the server reports the last CO
    // write didn't take effect (e.g. a Smart Tune apply silently failed).
    if (s.coWritesActive === false) {
      const n = (s.coWriteMismatches || []).length;
      BiosSetup.show(`Server reports the last CO write was ignored by the SMU (<strong>${n}</strong> mismatched cores). PBO + Curve Optimizer are almost certainly disabled in BIOS.`);
    }
    renderSafetyBanner(s);
    lastObservedState = s.state;
  } catch (e) { /* server may be starting */ }
  finally { pollStatusInFlight = false; }
}

function renderSafetyBanner(s) {
  const el = document.getElementById('safety-banner');
  if (!el) return;
  const sg = s.safetyGuard;
  if (!sg || !sg.active) { el.classList.add('hidden'); el.classList.remove('alert','warn'); return; }
  el.classList.remove('hidden','alert','warn');
  let cls = '';
  if (sg.lastAbort) cls = 'alert';
  else if (sg.lastWarning) cls = 'warn';
  if (cls) el.classList.add(cls);
  const violations = (sg.violations || []).map(v => `<span><strong>${escHtml(v.metric)}</strong> ${v.value.toFixed(2)} ≥ ${v.limit}</span>`).join(' ');
  el.innerHTML = `<h3>🛡 Safety Guard — auto-tune watchdog</h3>
    <div class="safety-line">
      <span>Limits: <strong>${sg.maxTempC}°C</strong> · <strong>${sg.maxVid.toFixed(2)}V</strong> · WHEA-abort <strong>${sg.abortOnWhea ? 'ON' : 'off'}</strong></span>
      <span>Aborts: <strong>${sg.abortCount}</strong> · step-backs: <strong>${sg.stepBackCount}</strong></span>
    </div>
    ${violations ? `<div class="safety-line" style="margin-top:0.4rem">Active: ${violations}</div>` : ''}
    ${sg.lastEvent ? `<div class="muted small" style="margin-top:0.3rem">Last: ${escHtml(sg.lastEvent)}</div>` : ''}`;
  if (sg.newAbort) playSafetyBeep();
}

async function loadProfiles() {
  try {
    const r = await fetchJson('/api/profiles');
    loadedProfiles = r.data || [];
    const list = document.getElementById('profiles-list');
    if (loadedProfiles.length === 0) { list.innerHTML = '<p class="muted small">No profiles saved yet.</p>'; return; }
    list.innerHTML = loadedProfiles.map(p => {
      const enc = encodeURIComponent(p.name);
      return `
      <div class="profile-row">
        <div class="profile">
          <span class="grow"><strong>${escHtml(p.name)}</strong> <span class="muted small">· ${escHtml(p.mode)} · ${escHtml(p.cpuModel || '')}${p.notes ? ' · ' + escHtml(p.notes) : ''}</span></span>
          <button data-details="${enc}" class="secondary" title="Preview the saved settings">Details</button>
          <button data-load="${enc}" class="secondary" title="Load into form (no apply)">Load</button>
          <button data-apply="${enc}" class="primary" title="Apply immediately">Apply</button>
          <button data-delete="${enc}" class="secondary" title="Delete">×</button>
        </div>
        <div class="profile-details hidden" id="profile-details-${enc}"></div>
      </div>`;
    }).join('');
  } catch (e) { /* ignore */ }
}

// Inline-expand a profile's full settings under its row. Toggles closed
// if already open. Groups per-core values by CCD so a dual-CCD profile
// shows CCD0/CCD1 sections matching the rest of the UI's conventions.
function toggleProfileDetails(profileName) {
  const p = loadedProfiles.find(x => x.name === profileName);
  if (!p) { showToast('Profile not found', 'error'); return; }
  const el = document.getElementById('profile-details-' + encodeURIComponent(profileName));
  if (!el) return;
  if (!el.classList.contains('hidden')) { el.classList.add('hidden'); el.innerHTML = ''; return; }

  const arr = expandProfileValues(p) || [];
  const ccds = {};
  arr.forEach((v, i) => {
    const ccd = cpuInfo && cpuInfo.IsDualCcd ? Math.floor(i / cpuInfo.CoresPerCcd) : 0;
    (ccds[ccd] = ccds[ccd] || []).push({ core: i, value: v });
  });
  const pillClass = v => v < 0 ? 'neg' : v > 0 ? 'pos' : 'zero';
  const fmt = v => (v > 0 ? '+' : '') + v;
  let valuesHtml = '';
  Object.keys(ccds).sort((a, b) => +a - +b).forEach(ccd => {
    const label = cpuInfo && cpuInfo.VCacheCcdIndex === +ccd ? `CCD${ccd} (V-Cache)` : `CCD${ccd}`;
    const pills = ccds[ccd].map(c => `<span class="co-pill ${pillClass(c.value)}" title="Core ${c.core}">C${c.core}: ${fmt(c.value)}</span>`).join('');
    valuesHtml += `<div class="muted small" style="margin-top:0.4rem">${label}</div><div class="co-pills">${pills}</div>`;
  });

  const created = p.createdAt ? new Date(p.createdAt).toLocaleString() : '?';
  const summary = summarizeCo(arr);
  el.innerHTML = `
    <div class="details-grid">
      <div><span class="muted small">Mode:</span> <strong>${escHtml(p.mode)}</strong></div>
      <div><span class="muted small">CPU:</span> ${escHtml(p.cpuModel || '?')}</div>
      <div><span class="muted small">Cores:</span> ${p.coreCount || arr.length || '?'}</div>
      <div><span class="muted small">CCDs:</span> ${p.ccdCount || '?'}</div>
      <div><span class="muted small">Saved:</span> ${escHtml(created)}</div>
      <div><span class="muted small">Summary:</span> ${escHtml(summary)}</div>
      ${p.notes ? `<div class="details-notes"><span class="muted small">Notes:</span> ${escHtml(p.notes)}</div>` : ''}
    </div>
    <div class="details-values">
      <span class="muted small">Curve Optimizer offsets (per-core view):</span>
      ${valuesHtml || '<span class="muted small">No values</span>'}
    </div>`;
  el.classList.remove('hidden');
}

async function loadHelpContent() {
  const target = document.getElementById('help-content');
  if (target.dataset.loaded === '1') return;
  try {
    const r = await fetch('/help.html');
    const text = await r.text();
    // Defense in depth. The help fragment is served from our local
    // web/ folder so it's trusted in practice, but blindly assigning
    // fetched text to innerHTML is a habit that bites elsewhere. Parse
    // it in a detached document, strip <script> tags and inline event
    // handlers + javascript: hrefs, then import.
    const doc = new DOMParser().parseFromString(text, 'text/html');
    doc.querySelectorAll('script').forEach(s => s.remove());
    doc.querySelectorAll('*').forEach(el => {
      [...el.attributes].forEach(a => {
        if (a.name.toLowerCase().startsWith('on')) el.removeAttribute(a.name);
        if ((a.name === 'href' || a.name === 'src') && a.value.trim().toLowerCase().startsWith('javascript:')) el.removeAttribute(a.name);
      });
    });
    target.innerHTML = doc.body.innerHTML;
    target.dataset.loaded = '1';
  } catch (e) {
    target.innerHTML = '<p>Help content failed to load.</p>';
  }
}

// Event delegation
document.addEventListener('click', async e => {
  if (e.target.classList && e.target.classList.contains('live-co-tab')) {
    document.querySelectorAll('.live-co-tab').forEach(t => t.classList.remove('active'));
    e.target.classList.add('active');
    liveCoView = e.target.dataset.view;
    renderLiveCo();
    return;
  }
  if (e.target.classList && e.target.classList.contains('tab')) {
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    e.target.classList.add('active');
    currentMode = e.target.dataset.mode;
    formInitialValues = null;  // user picked a mode manually — drop any loaded profile staging
    renderForm();
    return;
  }
  switch (e.target.id) {
    case 'apply-co': applyCo(); break;
    case 'apply-confirm-save':
      document.getElementById('apply-confirm-overlay').classList.add('hidden');
      if (pendingApplyBody) { const b = pendingApplyBody; pendingApplyBody = null; performApply(b, true); }
      break;
    case 'apply-confirm-apply':
      document.getElementById('apply-confirm-overlay').classList.add('hidden');
      if (pendingApplyBody) { const b = pendingApplyBody; pendingApplyBody = null; performApply(b, false); }
      break;
    case 'apply-confirm-cancel':
    case 'apply-confirm-backdrop':
      document.getElementById('apply-confirm-overlay').classList.add('hidden');
      pendingApplyBody = null;
      break;
    case 'revert-co': revertCo(); break;
    case 'reset-bios': revertCo(); break;
    case 'reset-co': resetCo(); break;
    case 'start-test': startTest(); break;
    case 'stop-test': stopTest(); break;
    case 'open-help': loadHelpContent(); document.getElementById('help-panel').classList.remove('hidden'); break;
    case 'close-help': document.getElementById('help-panel').classList.add('hidden'); break;
    case 'telem-expand':
      const exp = document.getElementById('telemetry-expanded');
      exp.classList.toggle('hidden');
      pollTelemetry();
      break;
    case 'save-profile': {
      const name = prompt('Profile name?');
      if (!name) break;
      const notes = prompt('Notes (optional):') || '';
      const body = collectValues();
      body.name = name; body.notes = notes;
      const r = await fetchJson('/api/profiles', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      if (r.ok) { showToast('Profile saved'); loadProfiles(); }
      else showToast('Save failed: ' + r.error, 'error');
      break;
    }
  }
  if (e.target.dataset && e.target.dataset.details) {
    toggleProfileDetails(decodeURIComponent(e.target.dataset.details));
  }
  if (e.target.dataset && e.target.dataset.load) {
    loadProfileIntoForm(decodeURIComponent(e.target.dataset.load));
  }
  if (e.target.dataset && e.target.dataset.apply) {
    // Guard against the race between this path (apply-from-profile)
    // and the form's Apply button. Both write to the same SMU. Without
    // the in-flight flag a fast double-click (or apply-then-modal)
    // produced two concurrent writes and the SMU ended up in whichever
    // arrived last.
    if (applyInFlight) return;
    applyInFlight = true;
    try {
      const r = await fetchJson('/api/profiles/' + e.target.dataset.apply + '/apply', { method: 'POST' });
      if (r.ok) { showToast('Profile applied'); formInitialValues = null; loadCoValues(); }
      else showToast('Apply failed: ' + r.error, 'error');
    } finally { applyInFlight = false; }
  }
  if (e.target.dataset && e.target.dataset.delete) {
    if (!confirm('Delete this profile?')) return;
    await fetchJson('/api/profiles/' + e.target.dataset.delete, { method: 'DELETE' });
    loadProfiles();
  }
});

document.addEventListener('keydown', async e => {
  if (e.key === 'Escape') {
    // Close the apply-confirmation modal if it's open and drop the
    // staged body. Otherwise Esc silently primed for a future apply.
    const modal = document.getElementById('apply-confirm-overlay');
    if (modal && !modal.classList.contains('hidden')) {
      modal.classList.add('hidden');
      pendingApplyBody = null;
    }
    // If a test or tune is running, stop it before resetting CO -
    // writing zeros mid-run silently clobbered the running test's
    // offsets and the test kept going as if nothing had happened.
    if (stateName === 'TESTING') {
      try { await stopTest(); } catch (_) {}
    }
    await resetCo();
    if (settings.escShutsDown) {
      try { fetch('/api/shutdown', { method: 'POST', keepalive: true }); } catch (_) {}
      showToast('Esc — CO reset + server stopping', 'warn');
    }
  }
});

document.addEventListener('change', e => {
  if (e.target.name === 'testMode') {
    const v = e.target.value;
    document.getElementById('auto-options').classList.toggle('hidden', v !== 'auto');
    document.getElementById('smart-options').classList.toggle('hidden', v !== 'smart');
    document.getElementById('mode-info-auto').classList.toggle('hidden', v !== 'auto');
    document.getElementById('mode-info-manual').classList.toggle('hidden', v !== 'manual');
    document.getElementById('mode-info-smart').classList.toggle('hidden', v !== 'smart');
    const btn = document.getElementById('start-test');
    if (btn) btn.textContent = v === 'smart' ? '▶ Start Smart Tune'
                              : v === 'auto'  ? '▶ Start Auto-Adjust'
                              : '▶ Start';
  }
});

// ----- Settings (localStorage-backed) -----
// v2: tabCloseShutsDown default flipped to false (Chrome memory-saver + RDP would otherwise
// kill the service mid-test). We bump the key to force the new default on existing installs.
const SETTINGS_KEY = 'rpo.settings.v2';
try { localStorage.removeItem('rpo.settings.v1'); } catch (_) {}
const settings = (() => {
  try { return JSON.parse(localStorage.getItem(SETTINGS_KEY)) || {}; } catch (_) { return {}; }
})();
if (typeof settings.tabCloseShutsDown !== 'boolean') settings.tabCloseShutsDown = false;
if (typeof settings.escShutsDown !== 'boolean') settings.escShutsDown = false;
if (typeof settings.safetyMaxTempC !== 'number') settings.safetyMaxTempC = 95;
if (typeof settings.safetyMaxVid !== 'number') settings.safetyMaxVid = 1.45;
if (typeof settings.safetyAutoAbortOnWhea !== 'boolean') settings.safetyAutoAbortOnWhea = true;

function saveSettings() {
  try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch (_) {}
  // Push runtime-relevant prefs (heartbeat, safety limits) to server
  fetch('/api/settings', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      heartbeatEnabled: settings.tabCloseShutsDown,
      safetyMaxTempC: settings.safetyMaxTempC,
      safetyMaxVid: settings.safetyMaxVid,
      safetyAutoAbortOnWhea: settings.safetyAutoAbortOnWhea
    })
  }).catch(() => {});
}

function applySettingsToUI() {
  const tab = document.getElementById('opt-tabclose');
  const esc = document.getElementById('opt-escshutdown');
  if (tab) tab.checked = settings.tabCloseShutsDown;
  if (esc) esc.checked = settings.escShutsDown;
  const t = document.getElementById('safety-max-temp');   if (t) t.value = settings.safetyMaxTempC;
  const v = document.getElementById('safety-max-vid');    if (v) v.value = settings.safetyMaxVid;
  const w = document.getElementById('safety-whea-abort'); if (w) w.checked = settings.safetyAutoAbortOnWhea;
  if (typeof settings.safetyAudioAlert !== 'boolean') settings.safetyAudioAlert = true;
  const a = document.getElementById('safety-audio-alert'); if (a) a.checked = settings.safetyAudioAlert;
}

// Brief beep using WebAudio. No external assets needed.
function playSafetyBeep() {
  if (!settings.safetyAudioAlert) return;
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.connect(g); g.connect(ctx.destination);
    o.type = 'square'; o.frequency.value = 880;
    g.gain.value = 0.08;
    o.start();
    setTimeout(() => { o.frequency.value = 660; }, 120);
    setTimeout(() => { o.stop(); ctx.close(); }, 280);
  } catch (_) {}
}

document.addEventListener('change', e => {
  if (e.target.id === 'opt-tabclose') { settings.tabCloseShutsDown = e.target.checked; saveSettings(); showToast(settings.tabCloseShutsDown ? 'Tab close will stop server' : 'Tab close will NOT stop server'); }
  if (e.target.id === 'opt-escshutdown') { settings.escShutsDown = e.target.checked; saveSettings(); showToast(settings.escShutsDown ? 'Esc will reset CO + stop server' : 'Esc will only reset CO'); }
  if (e.target.id === 'safety-max-temp') { settings.safetyMaxTempC = +e.target.value || 95; saveSettings(); }
  if (e.target.id === 'safety-max-vid')  { settings.safetyMaxVid = +e.target.value || 1.45; saveSettings(); }
  if (e.target.id === 'safety-whea-abort') { settings.safetyAutoAbortOnWhea = e.target.checked; saveSettings(); }
  if (e.target.id === 'safety-audio-alert'){ settings.safetyAudioAlert = e.target.checked; saveSettings(); }
});

// Heartbeat — server uses absence of pings to detect closed browser and shut down
async function sendHeartbeat() {
  if (!settings.tabCloseShutsDown) return;  // user opted out — no heartbeat needed
  try { await fetch('/api/heartbeat', { method: 'POST' }); } catch (e) { /* server may be gone */ }
}

// Confirm-on-close prompt — only when tab close shuts down server
window.addEventListener('beforeunload', (e) => {
  if (!settings.tabCloseShutsDown) return;
  e.preventDefault();
  e.returnValue = 'Closing this tab will revert CO to launch values and stop the server. Continue?';
  return e.returnValue;
});

// On actual close, fire shutdown beacon — only if user opted in
window.addEventListener('pagehide', () => {
  if (!settings.tabCloseShutsDown) return;
  try {
    if (navigator.sendBeacon) {
      navigator.sendBeacon('/api/shutdown', '');
    } else {
      fetch('/api/shutdown', { method: 'POST', keepalive: true });
    }
  } catch (e) { /* fire and forget */ }
});

async function checkPanicRevert() {
  try {
    const r = await fetchJson('/api/panic-revert');
    if (!r.ok || !r.data) return;
    const p = r.data;
    const html = `
      <div class="recovery-header">
        <span class="recovery-icon">⚠</span>
        <div class="recovery-title">
          <h2>Previous run crash detected</h2>
          <div class="recovery-sub">A BSOD, hard hang, or process kill left a panic-revert breadcrumb. Recommended: revert to the launch snapshot, then start the next test with safer limits.</div>
        </div>
      </div>
      <div class="recovery-details">
        <div><span class="muted small">Captured at</span><strong>${escHtml(new Date(p.capturedAt).toLocaleString())}</strong></div>
        <div><span class="muted small">Reason</span><strong>${escHtml(p.reason)}</strong></div>
        <div><span class="muted small">CO at crash</span><strong>${escHtml((p.values || []).join(','))}</strong></div>
      </div>
      <div class="actions">
        <button class="primary big" id="panic-revert-apply">↶ Revert to launch snapshot</button>
        <button class="secondary" id="panic-revert-dismiss">Dismiss</button>
      </div>`;
    const banner = document.createElement('div');
    banner.className = 'card recovery-card';
    banner.id = 'panic-revert-card';
    banner.innerHTML = html;
    (document.getElementById('recovery-host') || document.querySelector('main')).appendChild(banner);
    showRecoveryBadge('Crash recovery available');
    banner.scrollIntoView({ behavior: 'smooth', block: 'start' });
  } catch (_) {}
}

// Resolve the "last good tested" CO for each core from a paused
// session's scopes. Same resolution rule as recommendedCoFor but
// extended for PROBING scopes - we fall back to scopeState.knownStable
// (the deepest value that actually passed) since the scope didn't get
// to a final lock before the session was interrupted.
function lastGoodCoFromSession(session) {
  const cores = cpuInfo ? cpuInfo.Cores : 16;
  const out = new Array(cores).fill(0);
  if (!session || !Array.isArray(session.scopes)) return out;
  // CCD scopes first (less specific), then per-core (more specific)
  // - same overwrite ordering Get-RecommendedCoFromTune uses server-side.
  const order = [...session.scopes].sort((a, b) => {
    const aPerCore = /^core\d+$/.test(a.id || '') ? 1 : 0;
    const bPerCore = /^core\d+$/.test(b.id || '') ? 1 : 0;
    return aPerCore - bPerCore;
  });
  for (const sc of order) {
    if (!Array.isArray(sc.cores)) continue;
    let val = null;
    if (sc.status === 'LOCKED' && sc.locked != null) val = sc.locked;
    else if (sc.scopeState && sc.scopeState.knownStable != null) val = sc.scopeState.knownStable;
    if (val == null) continue;
    for (const c of sc.cores) {
      if (c >= 0 && c < cores) out[c] = val;
    }
  }
  return out;
}

// Group an array of per-core CO into per-CCD chunks so the recovery
// card can display the values in the same layout as the rest of the UI.
function renderLastGoodValuesGrid(values, editable) {
  if (!cpuInfo || !Array.isArray(values)) return '';
  const ccdsCount = cpuInfo.CcdCount || 1;
  const cpc = cpuInfo.CoresPerCcd || values.length;
  const fmt = v => (v > 0 ? '+' : '') + v;
  const cls = v => v < 0 ? 'neg' : v > 0 ? 'pos' : 'zero';
  let html = '';
  for (let c = 0; c < ccdsCount; c++) {
    const start = c * cpc;
    const label = cpuInfo.VCacheCcdIndex === c ? `CCD${c} (V-Cache 🔋)` : `CCD${c}`;
    let cells = '';
    for (let i = start; i < start + cpc && i < values.length; i++) {
      if (editable) {
        cells += `<span class="recovery-edit-cell"><label class="muted small">C${i}</label>
          <input type="number" class="recovery-edit-input" data-core="${i}" value="${values[i]}" min="-30" max="30" step="1"></span>`;
      } else {
        cells += `<span class="co-pill ${cls(values[i])}" title="Core ${i}">C${i}: ${fmt(values[i])}</span>`;
      }
    }
    html += `<div class="recovery-values-row"><span class="recovery-values-label">${label}</span><div class="recovery-values-cells">${cells}</div></div>`;
  }
  return html;
}

async function checkPendingSmartSession() {
  try {
    const r = await fetchJson('/api/smart-tune/pending-session');
    if (!r.ok || !r.data) return;
    const p = r.data;
    const lastGood = lastGoodCoFromSession(p);
    const html = `
      <div class="recovery-header">
        <span class="recovery-icon">⏸</span>
        <div class="recovery-title">
          <h2>Smart Tune was paused</h2>
          <div class="recovery-sub">A previous session was interrupted before it finished. Continue where it left off (optionally editing the starting per-core CO), or start fresh.</div>
        </div>
      </div>
      <div class="recovery-details">
        <div><span class="muted small">Mode</span><strong>${escHtml(p.mode || '?')}</strong></div>
        <div><span class="muted small">Status when stopped</span><strong>${escHtml(p.status || '?')}</strong></div>
        <div><span class="muted small">Scopes locked</span><strong>${(p.scopes || []).filter(s => s.status === 'LOCKED').length} / ${(p.scopes || []).length}</strong></div>
      </div>
      <div class="recovery-values">
        <div class="recovery-values-title">Last known-good per-core values <span class="muted small">(resolved from locked scopes · falls back to deepest stable probe · then launch)</span></div>
        <div id="recovery-values-grid">${renderLastGoodValuesGrid(lastGood, false)}</div>
      </div>
      <div class="actions">
        <button class="primary big" id="smart-resume" title="Continue from the values shown above">▶ Resume from last position</button>
        <button class="secondary" id="smart-edit" title="Tweak per-core CO before resuming">✎ Edit &amp; resume…</button>
        <button class="secondary" id="smart-discard">✕ Discard session</button>
      </div>
      <div id="recovery-edit-actions" class="actions hidden">
        <button class="primary big" id="smart-resume-edits">▶ Apply edits &amp; resume</button>
        <button class="secondary" id="smart-edit-cancel">Cancel edits</button>
      </div>`;
    const banner = document.createElement('div');
    banner.className = 'card recovery-card';
    banner.id = 'smart-pending-card';
    banner.dataset.lastGood = JSON.stringify(lastGood);
    banner.innerHTML = html;
    (document.getElementById('recovery-host') || document.querySelector('main')).appendChild(banner);
    // Surface a header badge so the user notices recovery options even
    // if they're scrolled away from the top - they ARE easy to miss
    // mixed in with the regular card stream.
    showRecoveryBadge('Smart Tune paused');
    banner.scrollIntoView({ behavior: 'smooth', block: 'start' });
  } catch (_) {}
}

function showRecoveryBadge(text) {
  const header = document.querySelector('header .header-actions');
  if (!header || document.getElementById('recovery-badge')) return;
  const b = document.createElement('button');
  b.id = 'recovery-badge';
  b.className = 'recovery-badge';
  b.title = 'Jump to the recovery prompt at the top of the page';
  b.innerHTML = `<span class="recovery-badge-dot"></span><span>${escHtml(text)}</span>`;
  b.addEventListener('click', () => {
    const card = document.getElementById('smart-pending-card') || document.getElementById('panic-revert-card');
    if (card) card.scrollIntoView({ behavior: 'smooth', block: 'start' });
  });
  header.insertBefore(b, header.firstChild);
}

document.addEventListener('click', async e => {
  if (e.target.id === 'panic-revert-apply' || e.target.closest?.('#panic-revert-apply')) {
    const r = await fetchJson('/api/panic-revert/apply', { method: 'POST' });
    if (r.ok) {
      showToast('Reverted to launch snapshot');
      document.getElementById('panic-revert-card')?.remove();
      document.getElementById('recovery-badge')?.remove();
      loadCoValues();
    } else showToast('Revert failed: ' + r.error, 'error');
  }
  if (e.target.id === 'panic-revert-dismiss' || e.target.closest?.('#panic-revert-dismiss')) {
    await fetchJson('/api/panic-revert/dismiss', { method: 'POST' });
    document.getElementById('panic-revert-card')?.remove();
    document.getElementById('recovery-badge')?.remove();
  }
  if (e.target.id === 'smart-resume' || e.target.closest?.('#smart-resume')) {
    const r = await fetchJson('/api/smart-tune/resume', { method: 'POST' });
    if (r.ok) {
      showToast('Smart Tune resumed');
      document.getElementById('smart-pending-card')?.remove();
      document.getElementById('recovery-badge')?.remove();
      SmartTune.show();
    } else {
      showToast('Resume failed: ' + r.error, 'error');
    }
  }
  // Flip the values grid from read-only pills to editable per-core
  // inputs, swap the action row. Pre-fills inputs with the last-good
  // values; user can adjust any of them within [-30, +30].
  if (e.target.id === 'smart-edit' || e.target.closest?.('#smart-edit')) {
    const card = document.getElementById('smart-pending-card');
    if (!card) return;
    const lastGood = JSON.parse(card.dataset.lastGood || '[]');
    document.getElementById('recovery-values-grid').innerHTML = renderLastGoodValuesGrid(lastGood, true);
    // Hide the default action row, show the edit action row.
    e.target.closest('.actions')?.classList.add('hidden');
    document.getElementById('recovery-edit-actions')?.classList.remove('hidden');
  }
  if (e.target.id === 'smart-edit-cancel' || e.target.closest?.('#smart-edit-cancel')) {
    const card = document.getElementById('smart-pending-card');
    if (!card) return;
    const lastGood = JSON.parse(card.dataset.lastGood || '[]');
    document.getElementById('recovery-values-grid').innerHTML = renderLastGoodValuesGrid(lastGood, false);
    document.getElementById('recovery-edit-actions')?.classList.add('hidden');
    card.querySelector('.actions')?.classList.remove('hidden');
  }
  if (e.target.id === 'smart-resume-edits' || e.target.closest?.('#smart-resume-edits')) {
    const inputs = document.querySelectorAll('#recovery-values-grid .recovery-edit-input');
    const values = new Array(cpuInfo?.Cores || inputs.length).fill(0);
    inputs.forEach(inp => {
      const idx = parseInt(inp.dataset.core, 10);
      const v   = parseInt(inp.value, 10);
      if (Number.isFinite(idx) && Number.isFinite(v)) values[idx] = Math.max(-30, Math.min(30, v));
    });
    const r = await fetchJson('/api/smart-tune/resume', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ values })
    });
    if (r.ok) {
      showToast(`Resumed with edited values (${values.length} cores written)`);
      document.getElementById('smart-pending-card')?.remove();
      document.getElementById('recovery-badge')?.remove();
      SmartTune.show();
      await loadCoValues();
    } else {
      showToast('Resume failed: ' + r.error, 'error');
    }
  }
  if (e.target.id === 'smart-discard' || e.target.closest?.('#smart-discard')) {
    await fetchJson('/api/smart-tune/discard', { method: 'POST' });
    document.getElementById('smart-pending-card')?.remove();
    document.getElementById('recovery-badge')?.remove();
    showToast('Discarded');
  }
});

// =============================================================================
//  Startup disclaimer - blocks the UI until the user accepts the risks.
//  Acceptance is persisted under rpo.disclaimerAccepted (versioned, so we
//  can re-prompt if we update the wording in a future release).
// =============================================================================
const DISCLAIMER_VERSION = 'v1';
const DISCLAIMER_KEY = 'rpo.disclaimerAccepted';

function disclaimerAlreadyAccepted() {
  try { return localStorage.getItem(DISCLAIMER_KEY) === DISCLAIMER_VERSION; }
  catch (_) { return false; }
}

function showDisclaimer() {
  const overlay = document.getElementById('disclaimer-overlay');
  if (!overlay) return;
  overlay.classList.remove('hidden');
  // Trap focus on the accept button for keyboard users
  const accept = document.getElementById('disclaimer-accept');
  if (accept) accept.focus();
}

function dismissDisclaimer(accepted) {
  const overlay = document.getElementById('disclaimer-overlay');
  if (!overlay) return;
  if (accepted) {
    const remember = document.getElementById('disclaimer-dont-show');
    if (remember && remember.checked) {
      try { localStorage.setItem(DISCLAIMER_KEY, DISCLAIMER_VERSION); } catch (_) {}
    }
    overlay.classList.add('hidden');
  } else {
    // "Close tab" - try window.close(), fall back to navigating away
    try { window.close(); } catch (_) {}
    // Some browsers refuse window.close on non-script-opened tabs - show a message
    overlay.querySelector('.disclaimer-card').innerHTML =
      '<h2>Please close this tab.</h2><p class="disclaimer-lead">Your browser blocked the auto-close. ' +
      'Closing the tab now stops nothing on the server side - the service keeps running until you ' +
      'press Ctrl+C in its terminal window.</p>';
  }
}

document.addEventListener('click', e => {
  if (e.target.id === 'disclaimer-accept')  dismissDisclaimer(true);
  if (e.target.id === 'disclaimer-decline') dismissDisclaimer(false);
  if (e.target.id === 'show-disclaimer-again') {
    try { localStorage.removeItem(DISCLAIMER_KEY); } catch (_) {}
    showDisclaimer();
  }
});

document.addEventListener('DOMContentLoaded', async () => {
  try {
    // Layout + i18n FIRST so the user never sees a flash of single-column
    // English UI when their browser is set to e.g. French. Both are
    // synchronous-ish (i18n.load() fetches one JSON file).
    applyTwoColumnLayout();
    const initialLang = i18n.detect();
    const switcher = document.getElementById('lang-switcher');
    if (switcher) {
      switcher.value = initialLang;
      switcher.addEventListener('change', e => i18n.load(e.target.value));
    }
    await i18n.load(initialLang);

    // Disclaimer comes first - if not accepted, show it. Initial loads
    // still happen behind it (the overlay just blocks interaction).
    if (!disclaimerAlreadyAccepted()) showDisclaimer();

    applySettingsToUI();
    saveSettings();  // push current preferences to server on load
    await loadVersion();
    await loadCpu();
    // Show Pro Dashboard and the per-core expanded telemetry grid by
    // default, so the user lands on the full data view without having
    // to click anything. They can still collapse either one.
    ProDash.show();
    document.getElementById('telemetry-expanded')?.classList.remove('hidden');
    await loadCoValues();
    await loadProfiles();
    await checkPanicRevert();
    await checkPendingSmartSession();
    // First-run hint: launch CO all zeros + user has not dismissed = show
    // the BIOS-setup card proactively. No-op if dismissed or CO has values.
    BiosSetup.maybeShowAsFirstRunHint();
    pollTelemetry();
    pollStatus();
    sendHeartbeat();
    setInterval(pollTelemetry, POLL_INTERVAL_ACTIVE_MS);
    setInterval(pollStatus, POLL_INTERVAL_ACTIVE_MS);
    setInterval(sendHeartbeat, 5000);  // every 5s (no-op if user opted out)

    // Tune Results action buttons. The card itself is shown by
    // renderTuneResults() when smartTune.status === 'COMPLETED'.
    document.getElementById('tune-apply-results')?.addEventListener('click', applyTuneResults);
    document.getElementById('tune-revert-launch')?.addEventListener('click', revertCo);
    document.getElementById('tune-save-profile')?.addEventListener('click', saveTuneResultsAsProfile);
    document.getElementById('tune-dismiss')?.addEventListener('click', () => {
      document.getElementById('tune-results-card')?.classList.add('hidden');
    });
  } catch (e) {
    document.body.insertAdjacentHTML('beforeend', `<div class="card warn">Failed to initialize: ${e.message}</div>`);
  }
});

// ============================================================================
//  SmartTune - Tune Theater rendering + start/stop wiring
// ============================================================================
const SmartTune = (() => {
  let lastSeqId = 0;
  let probesCompletedTotal = 0;
  let probesPlannedTotal = 0;

  function show() {
    document.getElementById('tune-theater')?.classList.remove('hidden');
  }
  function hide() {
    document.getElementById('tune-theater')?.classList.add('hidden');
    lastSeqId = 0;
  }

  function fmtTime(iso) {
    const d = new Date(iso);
    const pad = n => n.toString().padStart(2,'0');
    return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  function renderState(s) {
    if (!s || s.status === 'IDLE' || s.status === 'STOPPED') { hide(); return; }
    show();
    document.getElementById('theater-mode').textContent = `${s.mode || '?'} · ${s.direction || '?'}`;
    document.getElementById('theater-session').textContent = (s.sessionId || '—').substring(0, 8);

    // Progress
    probesPlannedTotal = (s.scopes || []).length * 6;  // rough estimate: 6 probes per scope
    probesCompletedTotal = (s.scopes || [])
      .map(sc => (sc.scopeState && sc.scopeState.probesCompleted) || (sc.status === 'LOCKED' ? 6 : 0))
      .reduce((a,b) => a+b, 0);
    const pct = probesPlannedTotal > 0 ? Math.min(100, Math.round(100 * probesCompletedTotal / probesPlannedTotal)) : 0;
    document.getElementById('theater-overall-fill').style.width = pct + '%';
    document.getElementById('theater-overall-pct').textContent = pct + '%';

    // Per-scope cards
    const wrap = document.getElementById('theater-scopes');
    wrap.innerHTML = (s.scopes || []).map((sc, i) => {
      const isActive = i === s.currentIdx && s.status === 'RUNNING';
      const cls = sc.status === 'LOCKED' ? 's-locked' :
                  sc.status === 'FAILED' ? 's-failed' :
                  isActive ? 's-active' : '';
      const ss = sc.scopeState;
      const bounds = ss ? `[${ss.bounds.floor} .. ${ss.bounds.ceiling}]` : '';
      const knownLine = ss
        ? `stable ${ss.knownStable ?? '—'} · edge ${ss.knownUnstable ?? '—'} · ${ss.probesCompleted} probes`
        : 'pending';
      const lockedLine = sc.locked != null ? `<div>🔒 <strong>${sc.locked}</strong></div>` : '';
      let windowLeftPct = 0, windowWidthPct = 100;
      if (ss && ss.knownStable != null && ss.knownUnstable != null) {
        const span = ss.bounds.ceiling - ss.bounds.floor;
        const lo = Math.min(ss.knownStable, ss.knownUnstable);
        const hi = Math.max(ss.knownStable, ss.knownUnstable);
        windowLeftPct = 100 * (lo - ss.bounds.floor) / span;
        windowWidthPct = 100 * (hi - lo) / span;
      }
      return `<div class="theater-scope ${cls}">
        <div class="s-id">${escHtml(sc.id)}${sc.isVCache ? ' 🔋' : ''}</div>
        <div class="s-bounds">${bounds}</div>
        <div class="s-bounds">${escHtml(knownLine)}</div>
        ${lockedLine}
        <div class="s-bisect"><div class="s-bisect-window" style="left:${windowLeftPct}%;width:${windowWidthPct}%"></div></div>
      </div>`;
    }).join('');

    // Narrative — append new entries since lastSeqId
    if (s.narrative && s.narrative.length) {
      const log = document.getElementById('narrative-log');
      const auto = document.getElementById('narrative-autoscroll')?.checked;
      s.narrative.forEach(e => {
        if (e.seqId <= lastSeqId) return;
        const line = document.createElement('div');
        line.className = 'narr-line';
        line.innerHTML = `<span class="narr-ts">${fmtTime(e.ts)}</span><span class="narr-icon">${escHtml(e.icon)}</span>${escHtml(e.message)}`;
        log.appendChild(line);
        lastSeqId = e.seqId;
      });
      if (auto) log.scrollTop = log.scrollHeight;
    }
    if (s.latestSeqId) lastSeqId = Math.max(lastSeqId, s.latestSeqId);

    // Currently strip
    const cur = (s.scopes || [])[s.currentIdx];
    if (cur && cur.scopeState) {
      const ss = cur.scopeState;
      document.getElementById('theater-currently').innerHTML =
        `▶ Probing <strong>${escHtml(cur.id)}</strong> — bounds [${ss.knownStable ?? '?'}, ${ss.knownUnstable ?? '?'}], probe ${ss.probesCompleted + 1}, last result ${escHtml(ss.lastResult || '—')}`;
    } else if (s.status === 'COMPLETED') {
      document.getElementById('theater-currently').innerHTML = '✅ Tune complete — see report below';
    } else if (s.status === 'RUNNING') {
      document.getElementById('theater-currently').textContent = 'Picking next scope…';
    }
  }

  async function start(mode, direction, applyMode) {
    const r = await fetchJson('/api/smart-tune/start', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode, direction, applyMode })
    });
    if (!r.ok) { showToast('Start failed: ' + r.error, 'error'); return false; }
    lastSeqId = 0;
    document.getElementById('narrative-log').innerHTML = '';
    show();
    ProDash.resetStats();
    ProDash.show();
    // New tune - hide any stale Tune Results card from a prior run.
    document.getElementById('tune-results-card')?.classList.add('hidden');
    return true;
  }

  async function stop() {
    await fetchJson('/api/smart-tune/stop', { method: 'POST' });
  }

  return { renderState, start, stop, show, hide };
})();

// ============================================================================
//  BiosSetup - shows BIOS-enable guidance when CO writes don't take effect
// ============================================================================
//  Shown when:
//    1. /api/co or /api/co/revert returns writesStuck=false (definitive
//       signal SMU silently ignored the write - PBO/CO not enabled in BIOS)
//    2. On first load, if the launch snapshot is all zeros AND user hasn't
//       previously dismissed (proactive hint for first-time users)
//
//  Dismissal persists in localStorage. If a write later fails despite
//  dismissal, we re-show (the dismissal flag was wrong - they actually
//  need the guidance after all).
// ============================================================================
const BiosSetup = (() => {
  const DISMISS_KEY = 'rpo.biosSetupDismissed';

  const VENDORS = {
    asus: {
      name: 'ASUS',
      menu: '<strong class="path">Advanced → AMD Overclocking → Precision Boost Overdrive</strong>',
      steps: [
        'Press <code>Del</code> or <code>F2</code> at boot to enter BIOS, then press <code>F7</code> for Advanced Mode if not already there.',
        'Navigate to <strong class="path">Advanced → AMD Overclocking</strong>. Accept the warning prompt.',
        'Open <strong class="path">Precision Boost Overdrive</strong>.',
        'Set <code>PBO Limits</code> to <code>Motherboard</code> (not Disabled, not Auto).',
        'Set <code>Precision Boost Overdrive</code> to <code>Advanced</code>.',
        'Set <code>Curve Optimizer</code> to <code>Per Core</code> (or <code>All Cores</code> if you prefer).',
        'Leave the per-core offsets at <code>0</code> for now — this app will set them.',
        'Press <code>F10</code> → Save & Exit. Boot back into Windows.'
      ]
    },
    msi: {
      name: 'MSI',
      menu: '<strong class="path">OC → CPU Features → AMD Overclocking → Precision Boost Overdrive</strong>',
      steps: [
        'Press <code>Del</code> at boot to enter BIOS, then <code>F7</code> for Advanced Mode.',
        'Navigate to <strong class="path">OC</strong> tab → scroll to <strong class="path">CPU Features</strong>.',
        'Open <strong class="path">AMD Overclocking</strong>. Accept the warning prompt.',
        'Open <strong class="path">Precision Boost Overdrive</strong>.',
        'Set <code>PBO Limits</code> to <code>Motherboard</code>.',
        'Set <code>Precision Boost Overdrive</code> to <code>Advanced</code>.',
        'Set <code>Curve Optimizer</code> to <code>Per Core</code>.',
        '<code>F10</code> → Save & Exit.'
      ]
    },
    gigabyte: {
      name: 'Gigabyte',
      menu: '<strong class="path">Tweaker → Advanced CPU Settings → Precision Boost Overdrive</strong>',
      steps: [
        'Press <code>Del</code> at boot, then <code>F2</code> for Advanced Mode.',
        'Navigate to <strong class="path">Tweaker</strong> tab.',
        'Open <strong class="path">Advanced CPU Settings</strong> (or <strong class="path">AMD Overclocking</strong> on some models).',
        'Open <strong class="path">Precision Boost Overdrive</strong>.',
        'Set <code>PBO Mode</code> to <code>Advanced</code>.',
        'Set <code>PBO Limits</code> to <code>Motherboard</code>.',
        'Open <strong class="path">Curve Optimizer</strong> sub-menu, set to <code>Per Core</code>.',
        '<code>F10</code> → Save & Exit.'
      ]
    },
    asrock: {
      name: 'ASRock',
      menu: '<strong class="path">OC Tweaker → AMD Overclocking → Precision Boost Overdrive</strong>',
      steps: [
        'Press <code>F2</code> or <code>Del</code> at boot.',
        'Open <strong class="path">OC Tweaker</strong> tab.',
        'Open <strong class="path">AMD Overclocking</strong> (accept the warning).',
        'Open <strong class="path">Precision Boost Overdrive</strong>.',
        'Set <code>PBO Limits</code> to <code>Motherboard</code>.',
        'Set <code>Precision Boost Overdrive</code> to <code>Advanced</code>.',
        'Set <code>Curve Optimizer</code> to <code>Per Core</code>.',
        '<code>F10</code> → Save & Exit.'
      ]
    },
    generic: {
      name: 'Other / Generic',
      menu: 'Search for "PBO" or "Curve Optimizer" in your BIOS',
      steps: [
        'Enter BIOS (usually <code>Del</code>, <code>F2</code>, or <code>F12</code> at boot — check your motherboard manual).',
        'Switch to <code>Advanced</code> mode if your BIOS has an EZ Mode toggle.',
        'Look for an <strong class="path">AMD Overclocking</strong> menu, or search the BIOS for <strong>"PBO"</strong>.',
        'Find <strong class="path">Precision Boost Overdrive</strong> — set the master enable to <code>Advanced</code> (not Auto, not Disabled).',
        'Find <strong class="path">PBO Limits</strong> — set to <code>Motherboard</code> (sometimes called "Auto-Motherboard" or just "Manual").',
        'Find <strong class="path">Curve Optimizer</strong> — set to <code>Per Core</code>. Leave offsets at <code>0</code>.',
        'Save & Exit (usually <code>F10</code>).',
        'If you cannot find these menus, look in the manual under "AMD CBS" or "AMD Overclocking" — they are sometimes nested 3-4 levels deep.'
      ]
    }
  };

  function renderVendor(key) {
    const v = VENDORS[key] || VENDORS.generic;
    const html = `<div style="font-size:0.85rem;color:var(--muted);margin-bottom:0.3rem">
        Typical menu path: ${v.menu}
      </div>
      <ol>${v.steps.map(s => `<li>${s}</li>`).join('')}</ol>`;
    const target = document.getElementById('bios-vendor-content');
    if (target) target.innerHTML = html;
    document.querySelectorAll('.bios-tab').forEach(t => {
      t.classList.toggle('active', t.dataset.vendor === key);
    });
  }

  function isDismissed() {
    try { return localStorage.getItem(DISMISS_KEY) === '1'; }
    catch (_) { return false; }
  }

  function setDismissed(yes) {
    try {
      if (yes) localStorage.setItem(DISMISS_KEY, '1');
      else     localStorage.removeItem(DISMISS_KEY);
    } catch (_) {}
  }

  function show(reasonHtml) {
    const card = document.getElementById('bios-setup-card');
    if (!card) return;
    card.classList.remove('hidden');
    const reasonEl = document.getElementById('bios-setup-reason');
    if (reasonEl) reasonEl.innerHTML = reasonHtml || '';
    if (!document.querySelector('.bios-tab.active')) renderVendor('asus');
    card.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function hide() {
    document.getElementById('bios-setup-card')?.classList.add('hidden');
  }

  // First-load hint: if launch values are all zeros AND user hasn't
  // dismissed, show the card as a proactive nudge.
  function maybeShowAsFirstRunHint() {
    if (isDismissed()) return;
    if (!launchValues || !launchValues.length) return;
    const allZero = launchValues.every(v => v === 0);
    if (!allZero) return;
    show('Your launch Curve Optimizer is all zeros. If you have not enabled PBO + Curve Optimizer in your BIOS yet, here is how. Dismiss this card if you already have them enabled.');
  }

  document.addEventListener('click', e => {
    if (e.target.classList?.contains('bios-tab') && e.target.dataset.vendor) {
      renderVendor(e.target.dataset.vendor);
    }
    if (e.target.id === 'bios-setup-dismiss') {
      hide();
      setDismissed(true);
    }
  });

  return { show, hide, maybeShowAsFirstRunHint, isDismissed };
})();
