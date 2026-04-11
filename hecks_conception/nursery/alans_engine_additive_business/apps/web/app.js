/* Alan's Engine Additive Business -- App Entry Point
   Orchestrates domain-driven interactivity across 16 bounded contexts.
   Fetches live data from hecks-life multi-domain API. */

const API_BASE = 'http://localhost:3100';

document.addEventListener('DOMContentLoaded', () => {
  renderDomainTagCount();
  loadDomains();
});

/* --- API layer --- */

async function fetchDomains() {
  const res = await fetch(`${API_BASE}/domains`);
  if (!res.ok) throw new Error(`Failed to fetch domains: ${res.status}`);
  return res.json();
}

async function fetchDomainDetail(name) {
  const res = await fetch(`${API_BASE}/domains/${name}/domain`);
  if (!res.ok) throw new Error(`Failed to fetch domain ${name}: ${res.status}`);
  return res.json();
}

async function fetchAggregates(domainName, aggregateName) {
  const url = `${API_BASE}/domains/${domainName}/aggregates/${aggregateName}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Failed to fetch aggregates: ${res.status}`);
  return res.json();
}

async function dispatch(domainName, command, attrs) {
  const res = await fetch(`${API_BASE}/domains/${domainName}/dispatch`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ command, attrs })
  });
  return res.json();
}

/* --- Domain loading --- */

async function loadDomains() {
  try {
    const data = await fetchDomains();
    window.__domains = data.domains || [];
    renderDomainList(window.__domains);
  } catch (e) {
    console.warn('API not available, running in static mode:', e.message);
  }
}

function renderDomainList(domains) {
  const container = document.querySelector('[data-domain-list]');
  if (!container) return;

  container.innerHTML = '';
  domains.forEach(name => {
    const el = document.createElement('div');
    el.setAttribute('data-domain-aggregate', name);
    el.className = 'domain-card';
    el.innerHTML = `<h3>${name}</h3><p class="text-gray-400">Loading...</p>`;
    container.appendChild(el);
    loadDomainDetail(name, el);
  });
}

async function loadDomainDetail(name, el) {
  try {
    const detail = await fetchDomainDetail(name);
    const aggs = detail.aggregates || [];
    const aggList = aggs.map(a => {
      const cmds = (a.commands || []).join(', ');
      return `<li><strong>${a.name}</strong> ` +
        `<span class="text-gray-400">${cmds}</span></li>`;
    }).join('');
    el.innerHTML = `<h3>${name}</h3><ul>${aggList}</ul>`;
  } catch (e) {
    const p = el.querySelector('p');
    if (p) p.textContent = 'Failed to load';
  }
}

/* --- Tag counting --- */

function renderDomainTagCount() {
  const els = document.querySelectorAll(
    '[data-domain-aggregate], [data-domain-command], [data-domain-attribute]'
  );
  const countEl = document.querySelector('[data-domain-attribute="domain_tag_count"]');
  if (countEl) countEl.textContent = els.length;
}

/* --- Utilities --- */

function statusBadge(status) {
  const map = {
    published: 'bg-emerald-900/50 text-emerald-400 border-emerald-800',
    active: 'bg-emerald-900/50 text-emerald-400 border-emerald-800',
    approved: 'bg-emerald-900/50 text-emerald-400 border-emerald-800',
    delivered: 'bg-emerald-900/50 text-emerald-400 border-emerald-800',
    shipped: 'bg-blue-900/50 text-blue-400 border-blue-800',
    confirmed: 'bg-blue-900/50 text-blue-400 border-blue-800',
    in_lab: 'bg-blue-900/50 text-blue-400 border-blue-800',
    fulfilling: 'bg-blue-900/50 text-blue-400 border-blue-800',
    draft: 'bg-gray-800/50 text-gray-400 border-gray-700',
    proposed: 'bg-gray-800/50 text-gray-400 border-gray-700',
    placed: 'bg-amber-900/50 text-amber-400 border-amber-800',
    pending: 'bg-amber-900/50 text-amber-400 border-amber-800',
    open: 'bg-amber-900/50 text-amber-400 border-amber-800',
    rejected: 'bg-red-900/50 text-red-400 border-red-800',
    overdue: 'bg-red-900/50 text-red-400 border-red-800'
  };
  const cls = map[status] || 'bg-gray-800/50 text-gray-400 border-gray-700';
  return `<span class="text-[11px] px-2 py-0.5 rounded-full border ${cls}">${status.replace(/_/g, ' ')}</span>`;
}
