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
  card.innerHTML = `<strong>${cpuInfo.Name}</strong> · ${cpuInfo.Cores} cores · ${ccdDesc} · Zen ${cpuInfo.ZenGen}`;

  document.getElementById('curve-card').classList.remove('hidden');
  document.getElementById('test-card').classList.remove('hidden');
  document.getElementById('telemetry-strip').classList.remove('hidden');

  if (!cpuInfo.IsDualCcd) document.getElementById('tab-ccd').classList.add('hidden');
}

async function loadCoValues() {
  if (!cpuInfo || !cpuInfo.SupportsCurveOptimizer) return;
  try {
    const launchR = await fetchJson('/api/co/launch');
    const currentR = await fetchJson('/api/co/current');
    launchValues = launchR.data;
    currentValues = currentR.data;
    if (currentValues) {
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

async function applyCo() {
  const body = collectValues();
  const r = await fetchJson('/api/co', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!r.ok) { showToast('Apply failed: ' + r.error, 'error'); return; }
  showToast('Applied ✓');
  await loadCoValues();
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
    const ok = await SmartTune.start(smartMode, direction);
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
  let html = `<div class="${verdictClass}">${verdictIcon} ${d.verdict}</div>`;
  html += `<p>Duration: ${d.duration || '?'} · Iterations: ${d.iterationsCompleted}/${d.iterationsRequested} · Cores tested: ${(d.coresTested || []).length}</p>`;

  if (d.coresFailed && d.coresFailed.length) {
    html += '<h3>Failed cores</h3><table class="report-tbl"><tr><th>Core</th><th>CCD</th><th>CO at failure</th><th>Type</th></tr>';
    d.coresFailed.forEach(c => html += `<tr><td>${c.core}</td><td>${c.ccdLabel}</td><td>${c.coAtFailure ?? '?'}</td><td>${c.errorType}</td></tr>`);
    html += '</table>';
  } else if (d.verdict === 'PASSED') {
    html += '<p class="muted">All cores passed with flying colors. 🎉</p>';
  }

  if (d.smartSuggestions && d.smartSuggestions.length) {
    html += '<h3>💡 Smart Suggestions</h3><ul>';
    d.smartSuggestions.forEach(s => html += `<li>${s}</li>`);
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
  if (!cores.length || !cpuInfo) { document.getElementById('telemetry-expanded').innerHTML = '<p class="muted small">No per-core data.</p>'; return; }
  const ccds = {};
  cores.forEach(c => {
    const ccd = cpuInfo.IsDualCcd ? Math.floor(c.core / cpuInfo.CoresPerCcd) : 0;
    (ccds[ccd] = ccds[ccd] || []).push(c);
  });
  let html = '';
  Object.keys(ccds).sort().forEach(ccd => {
    const label = cpuInfo.VCacheCcdIndex === +ccd ? `CCD${ccd} (V-Cache)` : `CCD${ccd}`;
    html += `<div class="muted small">${label}</div><div class="core-grid">`;
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
        plugins: {
          legend: { display: !!opts.legend, position: 'bottom',
                    labels: { color: '#8b95a8', boxWidth: 10, font: { size: 10 } } },
          tooltip: { enabled: true, mode: 'index', intersect: false }
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
    charts.clock = buildLineChart('chart-clock', 'Clock', { perCore: true, legend: false, yMin: 0 });
    charts.temp  = buildLineChart('chart-temp',  'Temp',  { series: ccdSeries, legend: true, yMin: 30, yMax: 100 });
    charts.vid   = buildLineChart('chart-vid',   'VID',   { perCore: true, legend: false, yMin: 0.8, yMax: 1.55 });
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

async function pollStatus() {
  try {
    const r = await fetchJson('/api/status');
    const s = r.data;
    stateName = s.state;
    if (s.state === 'TESTING' && s.live) {
      const c = s.live;
      document.getElementById('status-content').innerHTML =
        `<p>Testing core <strong>${c.currentCore ?? '?'}</strong> · Iteration <strong>${c.iteration ?? '?'}/${c.iterationsTotal ?? '?'}</strong></p>
         <p>Errors so far: ${c.errors} · WHEA: ${c.wheaErrors} · Runtime: ${c.runtime || '—'}</p>`;
    }
    if (s.state === 'REPORTING') {
      loadReport();
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
    if (s.smartTune) SmartTune.renderState(s.smartTune);
    renderSafetyBanner(s);
  } catch (e) { /* server may be starting */ }
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
  const violations = (sg.violations || []).map(v => `<span><strong>${v.metric}</strong> ${v.value.toFixed(2)} ≥ ${v.limit}</span>`).join(' ');
  el.innerHTML = `<h3>🛡 Safety Guard — auto-tune watchdog</h3>
    <div class="safety-line">
      <span>Limits: <strong>${sg.maxTempC}°C</strong> · <strong>${sg.maxVid.toFixed(2)}V</strong> · WHEA-abort <strong>${sg.abortOnWhea ? 'ON' : 'off'}</strong></span>
      <span>Aborts: <strong>${sg.abortCount}</strong> · step-backs: <strong>${sg.stepBackCount}</strong></span>
    </div>
    ${violations ? `<div class="safety-line" style="margin-top:0.4rem">Active: ${violations}</div>` : ''}
    ${sg.lastEvent ? `<div class="muted small" style="margin-top:0.3rem">Last: ${sg.lastEvent}</div>` : ''}`;
  if (sg.newAbort) playSafetyBeep();
}

async function loadProfiles() {
  try {
    const r = await fetchJson('/api/profiles');
    loadedProfiles = r.data || [];
    const list = document.getElementById('profiles-list');
    if (loadedProfiles.length === 0) { list.innerHTML = '<p class="muted small">No profiles saved yet.</p>'; return; }
    list.innerHTML = loadedProfiles.map(p => `
      <div class="profile">
        <span class="grow"><strong>${p.name}</strong> <span class="muted small">· ${p.mode} · ${p.cpuModel || ''}${p.notes ? ' · ' + p.notes : ''}</span></span>
        <button data-load="${encodeURIComponent(p.name)}" class="secondary" title="Load into form (no apply)">Load</button>
        <button data-apply="${encodeURIComponent(p.name)}" class="primary" title="Apply immediately">Apply</button>
        <button data-delete="${encodeURIComponent(p.name)}" class="secondary" title="Delete">×</button>
      </div>`).join('');
  } catch (e) { /* ignore */ }
}

async function loadHelpContent() {
  const target = document.getElementById('help-content');
  if (target.dataset.loaded === '1') return;
  try {
    const r = await fetch('/help.html');
    target.innerHTML = await r.text();
    target.dataset.loaded = '1';
  } catch (e) {
    target.innerHTML = '<p>Help content failed to load.</p>';
  }
}

// Event delegation
document.addEventListener('click', async e => {
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
    case 'revert-co': revertCo(); break;
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
  if (e.target.dataset && e.target.dataset.load) {
    loadProfileIntoForm(decodeURIComponent(e.target.dataset.load));
  }
  if (e.target.dataset && e.target.dataset.apply) {
    const r = await fetchJson('/api/profiles/' + e.target.dataset.apply + '/apply', { method: 'POST' });
    if (r.ok) { showToast('Profile applied'); formInitialValues = null; loadCoValues(); }
    else showToast('Apply failed: ' + r.error, 'error');
  }
  if (e.target.dataset && e.target.dataset.delete) {
    if (!confirm('Delete this profile?')) return;
    await fetchJson('/api/profiles/' + e.target.dataset.delete, { method: 'DELETE' });
    loadProfiles();
  }
});

document.addEventListener('keydown', async e => {
  if (e.key === 'Escape') {
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
    const html = `<h2>⚠ Previous run crash detected</h2>
      <p>The last session left a panic-revert breadcrumb at <code>${new Date(p.capturedAt).toLocaleString()}</code>.<br>
      It was in the middle of <strong>${p.reason}</strong> with CO values <code>${(p.values || []).join(',')}</code>.</p>
      <p>This usually means a BSOD or hard hang while tuning. Recommended: revert to the launch snapshot, then start the next test with safer limits.</p>
      <div class="actions">
        <button class="primary" id="panic-revert-apply">Revert to launch snapshot</button>
        <button class="secondary" id="panic-revert-dismiss">Dismiss</button>
      </div>`;
    const banner = document.createElement('div');
    banner.className = 'card warn';
    banner.id = 'panic-revert-card';
    banner.innerHTML = html;
    document.querySelector('main').insertBefore(banner, document.querySelector('main').firstChild);
  } catch (_) {}
}

document.addEventListener('click', async e => {
  if (e.target.id === 'panic-revert-apply') {
    const r = await fetchJson('/api/panic-revert/apply', { method: 'POST' });
    if (r.ok) { showToast('Reverted to launch snapshot'); document.getElementById('panic-revert-card')?.remove(); loadCoValues(); }
    else showToast('Revert failed: ' + r.error, 'error');
  }
  if (e.target.id === 'panic-revert-dismiss') {
    await fetchJson('/api/panic-revert/dismiss', { method: 'POST' });
    document.getElementById('panic-revert-card')?.remove();
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
    // Disclaimer comes first - if not accepted, show it. Initial loads
    // still happen behind it (the overlay just blocks interaction).
    if (!disclaimerAlreadyAccepted()) showDisclaimer();

    applySettingsToUI();
    saveSettings();  // push current preferences to server on load
    await loadCpu();
    await loadCoValues();
    await loadProfiles();
    await checkPanicRevert();
    pollTelemetry();
    pollStatus();
    sendHeartbeat();
    setInterval(pollTelemetry, POLL_INTERVAL_ACTIVE_MS);
    setInterval(pollStatus, POLL_INTERVAL_ACTIVE_MS);
    setInterval(sendHeartbeat, 5000);  // every 5s (no-op if user opted out)
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
        <div class="s-id">${sc.id}${sc.isVCache ? ' 🔋' : ''}</div>
        <div class="s-bounds">${bounds}</div>
        <div class="s-bounds">${knownLine}</div>
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
        line.innerHTML = `<span class="narr-ts">${fmtTime(e.ts)}</span><span class="narr-icon">${e.icon}</span>${e.message}`;
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
        `▶ Probing <strong>${cur.id}</strong> — bounds [${ss.knownStable ?? '?'}, ${ss.knownUnstable ?? '?'}], probe ${ss.probesCompleted + 1}, last result ${ss.lastResult || '—'}`;
    } else if (s.status === 'COMPLETED') {
      document.getElementById('theater-currently').innerHTML = '✅ Tune complete — see report below';
    } else if (s.status === 'RUNNING') {
      document.getElementById('theater-currently').textContent = 'Picking next scope…';
    }
  }

  async function start(mode, direction) {
    const r = await fetchJson('/api/smart-tune/start', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode, direction })
    });
    if (!r.ok) { showToast('Start failed: ' + r.error, 'error'); return false; }
    lastSeqId = 0;
    document.getElementById('narrative-log').innerHTML = '';
    show();
    ProDash.resetStats();
    ProDash.show();
    return true;
  }

  async function stop() {
    await fetchJson('/api/smart-tune/stop', { method: 'POST' });
  }

  return { renderState, start, stop, show, hide };
})();
