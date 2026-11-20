'use strict';
// Interfaz de UserLifecycle. Todo el contenido dinámico se inserta con textContent (nunca innerHTML)
// para que un nombre como <script> no pueda ejecutar código (XSS).

const TOKEN = document.querySelector('meta[name="lc-token"]').content;
const $ = (sel) => document.querySelector(sel);

function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k === 'style') node.style.cssText = v; // CSSOM: permitido por la CSP (setAttribute no)
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}

async function api(method, path, body) {
  const opts = { method, headers: { 'X-Lifecycle-Token': TOKEN } };
  if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(path, opts);
  let data = null;
  try { data = await res.json(); } catch { /* sin cuerpo */ }
  if (!res.ok) throw new Error((data && data.error) || `Error ${res.status}`);
  return data;
}

function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.add('hidden'), 3500);
}

const asArray = (v) => (v === null || v === undefined ? [] : Array.isArray(v) ? v : [v]);

const STATUS = {
  Success: ['Completada', 'ok'], Partial: ['Completada con avisos', 'warn'], Failed: ['Fallida', 'fail'], Rejected: ['Rechazada', 'fail'],
  OK: ['OK', 'ok'], Warning: ['Aviso', 'warn'], Pending: ['Pendiente', 'warn'], Skipped: ['Omitido', 'muted'],
};
const STEP_ICON = { OK: '✓', Warning: '!', Pending: '…', Skipped: '–', Failed: '✕' };
const TYPE = { Onboarding: 'Alta', Offboarding: 'Baja', CloudProvisioning: 'Licencias M365' };

function statusBadge(status) {
  const [label, cls] = STATUS[status] || [status, 'muted'];
  return el('span', { class: `badge ${cls}` }, label);
}

function kv(pairs) {
  return el('dl', { class: 'kv' }, pairs.filter(([, v]) => v !== undefined).flatMap(([k, v]) => [el('dt', {}, k), el('dd', {}, v === null || v === '' ? '—' : v)]));
}

function chips(items, cls) {
  const list = asArray(items);
  if (!list.length) return el('span', { class: 'hint' }, 'Ninguno');
  return el('div', { class: 'chips' }, list.map((i) => el('span', { class: `chip ${cls || ''}` }, i)));
}

function notices(errors, warnings) {
  const out = [];
  if (asArray(errors).length) out.push(el('div', { class: 'notice fail' }, el('strong', {}, 'No se puede continuar:'), el('ul', {}, asArray(errors).map((e) => el('li', {}, e)))));
  if (asArray(warnings).length) out.push(el('div', { class: 'notice warn' }, el('ul', {}, asArray(warnings).map((w) => el('li', {}, w)))));
  return out;
}

function stepsList(steps) {
  return el('ul', { class: 'steps' }, asArray(steps).map((s) => {
    const cls = (STATUS[s.Status] || [, 'muted'])[1];
    return el('li', {}, el('span', { class: `ico ${cls}`, title: (STATUS[s.Status] || [s.Status])[0] }, STEP_ICON[s.Status] || '?'),
      el('div', {}, s.Name, s.Detail ? el('small', {}, s.Detail) : null));
  }));
}

function reportLink(file) {
  return file ? el('a', { href: `/reports/${encodeURIComponent(file)}`, target: '_blank', rel: 'noopener', class: 'btn small' }, 'Ver informe de auditoría') : null;
}

function show(id, ...nodes) {
  const card = $(id);
  card.replaceChildren(...nodes.flat().filter(Boolean));
  card.classList.remove('hidden', 'stale');
}

// ------------------------------------------------------------------ Cabecera y pestañas
let META = null;

async function loadMeta() {
  META = await api('GET', '/api/meta');
  $('#org').textContent = `${META.organization} · ${META.operator}`;
  const badges = $('#badges');
  badges.replaceChildren(
    META.mode === 'Lab' ? el('span', { class: 'badge warn', title: 'Directorio simulado: no se toca ningún AD real' }, 'LAB · directorio simulado') : el('span', { class: 'badge ok' }, 'Active Directory'),
    META.graphEnabled ? el('span', { class: 'badge' }, 'Microsoft Graph activo') : el('span', { class: 'badge muted' }, 'Sin Microsoft Graph'),
  );
  const sel = $('#dept');
  sel.replaceChildren(el('option', { value: '' }, 'Selecciona…'), ...META.departments.map((d) => el('option', { value: d.name }, d.name)));
  $('#title-hints').replaceChildren(...asArray(META.titleRules).map((m) => el('option', { value: m.replace(/\*/g, '').trim() })));
  if (!META.graphEnabled) $('#licenses-card').classList.add('hidden');
}

document.querySelectorAll('.tab').forEach((tab) => tab.addEventListener('click', () => {
  document.querySelectorAll('.tab').forEach((t) => { t.classList.toggle('active', t === tab); t.setAttribute('aria-selected', t === tab); });
  document.querySelectorAll('.panel').forEach((p) => p.classList.toggle('active', p.id === `tab-${tab.dataset.tab}`));
  if (tab.dataset.tab === 'audit') loadAudit();
  if (tab.dataset.tab === 'offboarding') searchUsers();
}));

// ------------------------------------------------------------------ ALTA
const onbForm = $('#onb-form');
let onbPlanInput = null;

function formData() {
  return Object.fromEntries(new FormData(onbForm).entries());
}

onbForm.addEventListener('input', () => {
  if (onbPlanInput) { $('#onb-plan').classList.add('stale'); const b = $('#onb-create'); if (b) b.disabled = true; }
});

onbForm.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const input = formData();
  const btn = $('#onb-preview');
  btn.disabled = true;
  try {
    const plan = await api('POST', '/api/onboarding/preview', input);
    onbPlanInput = input;
    renderOnbPlan(plan);
  } catch (e) { toast(e.message); } finally { btn.disabled = false; }
});

$('#onb-reset').addEventListener('click', () => {
  onbForm.reset();
  onbPlanInput = null;
  ['#onb-plan', '#onb-result'].forEach((id) => $(id).classList.add('hidden'));
  $('#onb-placeholder').classList.remove('hidden');
});

function renderOnbPlan(p) {
  $('#onb-placeholder').classList.add('hidden');
  $('#onb-result').classList.add('hidden');
  const homes = p.HomeFolder ? [`${p.HomeFolder.Path} (${p.HomeFolder.Rights}) → ${p.HomeFolder.Drive}`] : [];
  const shares = asArray(p.Shares).map((s) => `${s.Path} (${s.Rights})`);
  const create = el('button', { class: 'btn primary', id: 'onb-create', disabled: !p.CanProceed, onclick: runOnboarding }, 'Crear usuario');
  show('#onb-plan',
    el('div', { class: 'card-head' }, el('h2', {}, 'Plan de alta'), p.CanProceed ? el('span', { class: 'badge ok' }, 'Listo para crear') : el('span', { class: 'badge fail' }, 'Bloqueado')),
    notices(p.Errors, p.Warnings),
    kv([['Nombre', p.DisplayName], ['Cuenta', p.SamAccountName ? el('span', { class: 'mono' }, p.SamAccountName) : null], ['UPN / correo', p.UserPrincipalName], ['OU', p.OU ? el('span', { class: 'mono' }, p.OU) : null], ['Puesto', p.Title], ['Caduca', p.EndDate]]),
    el('h3', {}, 'Grupos'), chips(p.Groups),
    el('h3', {}, 'Carpetas'), chips([...homes, ...shares]),
    META.graphEnabled ? [el('h3', {}, `Licencias M365 (${p.UsageLocation || '—'})`), chips(p.Licenses)] : null,
    el('div', { class: 'actions', style: 'margin-top:18px' }, create),
  );
}

async function runOnboarding() {
  const btn = $('#onb-create');
  btn.disabled = true;
  btn.textContent = META.graphEnabled && META.mode !== 'Lab' ? 'Creando… (esperando a Entra ID)' : 'Creando…';
  try {
    const r = await api('POST', '/api/onboarding', onbPlanInput);
    renderOnbResult(r);
    $('#onb-plan').classList.add('hidden');
  } catch (e) {
    toast(e.message);
    btn.disabled = false;
    btn.textContent = 'Crear usuario';
  }
}

function secretBox(password) {
  const code = el('code', { class: 'mono' }, '•'.repeat(password.length));
  let visible = false;
  const toggle = el('button', { class: 'btn small', type: 'button', onclick: () => { visible = !visible; code.textContent = visible ? password : '•'.repeat(password.length); toggle.textContent = visible ? 'Ocultar' : 'Mostrar'; } }, 'Mostrar');
  const copy = el('button', { class: 'btn small', type: 'button', onclick: async () => { try { await navigator.clipboard.writeText(password); toast('Contraseña copiada'); } catch { toast('No se pudo copiar'); } } }, 'Copiar');
  return [el('h3', {}, 'Contraseña inicial'), el('div', { class: 'secret' }, code, toggle, copy),
    el('p', { class: 'hint' }, 'Se muestra solo ahora y no se guarda en ningún sitio. Entrégala por un canal seguro: se pedirá cambiarla en el primer inicio de sesión.')];
}

function renderOnbResult(r) {
  const pending = asArray(r.Steps).some((s) => s.Status === 'Pending' || (s.Status === 'Warning' && /licencia/i.test(s.Name)));
  const retry = pending && META.graphEnabled ? el('button', { class: 'btn', onclick: () => retryCloud(r.SamAccountName) }, 'Reintentar licencias') : null;
  show('#onb-result',
    el('div', { class: 'card-head' }, el('h2', {}, r.Status === 'Rejected' ? 'Alta rechazada' : `Alta de ${r.SamAccountName || r.DisplayName}`), statusBadge(r.Status)),
    notices(r.Errors, []),
    r.UserPrincipalName ? kv([['Nombre', r.DisplayName], ['Usuario', el('span', { class: 'mono' }, r.SamAccountName)], ['UPN', r.UserPrincipalName]]) : null,
    r.InitialPassword ? secretBox(r.InitialPassword) : null,
    el('h3', {}, 'Pasos'), stepsList(r.Steps),
    el('div', { class: 'actions', style: 'margin-top:16px' }, reportLink(r.ReportFile), retry),
  );
}

async function retryCloud(sam) {
  try {
    const r = await api('POST', '/api/cloud-provision', { identity: sam });
    toast(`Microsoft 365: ${(STATUS[r.Status] || [r.Status])[0]}`);
    show('#onb-result', el('div', { class: 'card-head' }, el('h2', {}, `Licencias de ${sam}`), statusBadge(r.Status)), stepsList(r.Steps), el('div', { class: 'actions', style: 'margin-top:16px' }, reportLink(r.ReportFile)));
  } catch (e) { toast(e.message); }
}

// ------------------------------------------------------------------ BAJA
let searchTimer = null;
$('#off-search').addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(searchUsers, 250); });

async function searchUsers() {
  const q = $('#off-search').value.trim();
  try {
    const users = asArray(await api('GET', `/api/users?q=${encodeURIComponent(q)}`));
    const list = $('#off-results');
    if (!users.length) { list.replaceChildren(el('li', { class: 'hint' }, 'Sin resultados')); return; }
    list.replaceChildren(...users.map((u) => el('li', {}, el('button', { type: 'button', 'data-sam': u.sam, onclick: (ev) => selectUser(u.sam, ev.currentTarget) },
      el('span', { class: 'who' }, u.name || u.sam, el('small', {}, `${u.sam} · ${u.department || 'sin departamento'}${u.title ? ' · ' + u.title : ''}`)),
      u.enabled ? el('span', { class: 'badge ok' }, 'Activo') : el('span', { class: 'badge muted' }, 'Deshabilitado')))));
  } catch (e) { toast(e.message); }
}

async function selectUser(sam, button) {
  document.querySelectorAll('.userlist button').forEach((b) => b.classList.toggle('selected', b === button));
  try {
    const p = await api('POST', '/api/offboarding/preview', { identity: sam });
    renderOffPlan(p);
  } catch (e) { toast(e.message); }
}

function renderOffPlan(p) {
  $('#off-placeholder').classList.add('hidden');
  $('#off-result').classList.add('hidden');
  const reason = el('input', { maxlength: 200, placeholder: 'Fin de contrato', list: 'reasons' });
  const ticket = el('input', { maxlength: 32, placeholder: 'RRHH-2001' });
  const confirm = el('input', { maxlength: 20, placeholder: p.SamAccountName, autocomplete: 'off', spellcheck: 'false' });
  const go = el('button', { class: 'btn danger', disabled: true }, 'Dar de baja');
  confirm.addEventListener('input', () => { go.disabled = !p.CanProceed || confirm.value !== p.SamAccountName; });
  go.addEventListener('click', async () => {
    go.disabled = true; go.textContent = 'Procesando…';
    try {
      const r = await api('POST', '/api/offboarding', { identity: p.SamAccountName, confirm: confirm.value, reason: reason.value, ticket: ticket.value });
      renderOffResult(r);
      searchUsers();
    } catch (e) { toast(e.message); go.disabled = false; go.textContent = 'Dar de baja'; }
  });

  show('#off-plan',
    el('div', { class: 'card-head' }, el('h2', {}, `Baja de ${p.DisplayName || p.SamAccountName}`), p.CanProceed ? el('span', { class: 'badge warn' }, 'Revisa antes de confirmar') : el('span', { class: 'badge fail' }, 'Bloqueado')),
    notices(p.Errors, p.Warnings),
    kv([['Usuario', el('span', { class: 'mono' }, p.SamAccountName)], ['UPN', p.UserPrincipalName], ['Departamento', p.Department], ['Estado', p.Enabled === null ? null : (p.Enabled ? 'Activo' : 'Deshabilitado')], ['OU actual', p.CurrentOU ? el('span', { class: 'mono' }, p.CurrentOU) : null], ['Se moverá a', el('span', { class: 'mono' }, p.TargetOU)]]),
    el('h3', {}, 'Grupos que se quitarán'), chips(asArray(p.GroupsToRemove).map((g) => g.Name), 'remove'),
    META.graphEnabled ? [el('h3', {}, 'Licencias que se liberarán'), chips(p.LicensesToRemove, 'remove')] : null,
    el('h3', {}, 'Además'),
    el('ul', {}, el('li', {}, 'Se deshabilita la cuenta y se cambia la contraseña por una aleatoria.'), META.graphEnabled ? el('li', {}, 'Se revocan las sesiones abiertas en Microsoft 365.') : null, el('li', {}, 'Se retiran permisos directos en las carpetas compartidas configuradas.'), el('li', {}, 'La cuenta no se borra: queda archivada para retención y auditoría.')),
    p.CanProceed ? [
      el('div', { class: 'row2', style: 'margin-top:16px' }, el('label', {}, 'Motivo', reason), el('label', {}, 'Ticket', ticket)),
      el('datalist', { id: 'reasons' }, ['Fin de contrato', 'Baja voluntaria', 'Despido', 'Jubilación', 'Fin de prácticas'].map((v) => el('option', { value: v }))),
      el('label', {}, `Escribe "${p.SamAccountName}" para confirmar`, confirm),
      el('div', { class: 'actions', style: 'margin-top:14px' }, go),
    ] : null,
  );
}

function renderOffResult(r) {
  $('#off-plan').classList.add('hidden');
  show('#off-result',
    el('div', { class: 'card-head' }, el('h2', {}, `Baja de ${r.DisplayName || r.SamAccountName}`), statusBadge(r.Status)),
    notices(r.Errors, []),
    el('h3', {}, 'Pasos'), stepsList(r.Steps),
    el('div', { class: 'actions', style: 'margin-top:16px' }, reportLink(r.ReportFile)),
  );
}

// ------------------------------------------------------------------ AUDITORÍA
async function loadAudit() {
  try {
    const rows = asArray(await api('GET', '/api/audit'));
    const body = $('#audit-table tbody');
    if (!rows.length) { body.replaceChildren(el('tr', {}, el('td', { colspan: 7, class: 'hint' }, 'Todavía no hay operaciones.'))); }
    else {
      body.replaceChildren(...rows.map((r) => el('tr', {},
        el('td', { class: 'mono' }, (r.startedAt || '').replace('T', ' ').slice(0, 19)),
        el('td', {}, TYPE[r.type] || r.type),
        el('td', {}, r.name || '—', r.sam ? el('span', { class: 'hint mono' }, ` (${r.sam})`) : null),
        el('td', {}, statusBadge(r.status)),
        el('td', {}, r.operator),
        el('td', {}, r.ticket || '—'),
        el('td', {}, r.report ? el('a', { href: `/reports/${encodeURIComponent(r.report)}`, target: '_blank', rel: 'noopener' }, 'Informe') : null))));
    }
    if (META && META.graphEnabled) loadLicenses();
  } catch (e) { toast(e.message); }
}

async function loadLicenses() {
  const skus = asArray(await api('GET', '/api/licenses'));
  $('#licenses').replaceChildren(...skus.map((s) => {
    const pct = s.Enabled ? Math.min(100, Math.round((s.Consumed / s.Enabled) * 100)) : 100;
    return el('div', { class: 'lic' },
      el('div', { class: 'lic-head' }, el('span', { class: 'mono' }, s.SkuPartNumber), el('span', {}, `${s.Consumed} / ${s.Enabled} en uso · ${s.Available} libres`)),
      el('div', { class: `bar ${s.Available <= 0 ? 'full' : ''}` }, el('span', { style: `width:${pct}%` })));
  }));
}

$('#audit-verify').addEventListener('click', async () => {
  try {
    const v = await api('GET', '/api/audit/verify');
    $('#audit-verify-result').replaceChildren(el('div', { class: `notice ${v.Valid ? 'ok' : 'fail'}` }, v.Message, v.LastHash ? el('div', { class: 'mono', style: 'margin-top:4px;overflow-wrap:anywhere' }, `Último hash: ${v.LastHash}`) : null));
  } catch (e) { toast(e.message); }
});

loadMeta().catch((e) => toast(e.message));
