// Ryzen Pro Optimizer - Browser UI
// Polls the local PowerShell HTTP server, manages CO setting / testing / reporting.

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
  const auto = document.querySelector('input[name="testMode"]:checked').value === 'auto';
  const body = {
    mode: document.getElementById('test-mode').value,
    iterations: +document.getElementById('iterations').value,
    autoAdjust: auto,
    autoMax: auto ? +document.getElementById('auto-max').value : 0,
    autoInc: auto ? +document.getElementById('auto-inc').value : 1
  };
  const r = await fetchJson('/api/test/start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!r.ok) { showToast('Start failed: ' + r.error, 'error'); return; }
  document.getElementById('start-test').classList.add('hidden');
  document.getElementById('stop-test').classList.remove('hidden');
  document.getElementById('status-card').classList.remove('hidden');
  document.getElementById('report-card').classList.add('hidden');
}

async function stopTest() {
  await fetchJson('/api/test/stop', { method: 'POST' });
  document.getElementById('stop-test').classList.add('hidden');
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
  } catch (e) { /* ignore */ }
}

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
      lastWheaCount = s.wheaEvents.length;
    }
  } catch (e) { /* server may be starting */ }
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

document.addEventListener('keydown', e => {
  if (e.key === 'Escape') resetCo();
});

document.addEventListener('DOMContentLoaded', async () => {
  try {
    await loadCpu();
    await loadCoValues();
    await loadProfiles();
    pollTelemetry();
    pollStatus();
    setInterval(pollTelemetry, POLL_INTERVAL_ACTIVE_MS);
    setInterval(pollStatus, POLL_INTERVAL_ACTIVE_MS);
  } catch (e) {
    document.body.insertAdjacentHTML('beforeend', `<div class="card warn">Failed to initialize: ${e.message}</div>`);
  }
});
