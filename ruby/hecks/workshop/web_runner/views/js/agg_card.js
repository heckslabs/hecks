// Hecks Web Console — <agg-card> and <agg-explorer>
// Compact aggregate card with dot tabs and explorer panel.
import { COLORS, SECTION_ICONS, BASE_STYLES, escHtml } from './shared.js';

export function buildSections(agg) {
  const sections = [];
  const attrs = agg.attributes.filter(a => !a.type.match(/reference_to|list_of/));
  const refs = agg.attributes.filter(a => a.type.match(/reference_to|list_of/));

  if (attrs.length) sections.push({
    key: 'attributes', color: COLORS.green, items: attrs,
    render: a => `${escHtml(a.name)} <span style="color:${COLORS.muted}">${escHtml(a.type)}</span>`
  });
  if (refs.length) sections.push({
    key: 'references', color: COLORS.orange, items: refs,
    render: a => {
      const m = a.type.match(/(?:reference_to|list_of)\((\w+)\)/);
      const t = m ? m[1] : '';
      return `<span class="ref" data-target="${escHtml(t)}">${escHtml(a.name.replace(/_id$/, ''))} → ${escHtml(t)}</span>`;
    }
  });
  if (agg.commands.length) sections.push({
    key: 'commands', color: COLORS.blue, items: agg.commands,
    render: c => escHtml(typeof c === 'string' ? c : c.name)
  });
  if (agg.events.length) sections.push({
    key: 'events', color: COLORS.purple, items: agg.events,
    render: e => escHtml(e)
  });
  if (agg.policies?.length) sections.push({
    key: 'policies', color: COLORS.red, items: agg.policies,
    render: p => {
      if (typeof p === 'string') return escHtml(p);
      let s = escHtml(p.name);
      if (p.event) s += ` <span style="color:${COLORS.muted}">on ${escHtml(p.event)}</span>`;
      if (p.trigger) s += ` <span style="color:${COLORS.muted}">→ ${escHtml(p.trigger)}</span>`;
      return s;
    }
  });
  if (agg.value_objects?.length) sections.push({
    key: 'value objects', color: COLORS.orange, items: agg.value_objects,
    render: vo => {
      if (typeof vo === 'string') return escHtml(vo);
      return `${escHtml(vo.name)} <span style="color:${COLORS.muted}">(${vo.attributes?.length || 0} attrs)</span>`;
    }
  });
  if (agg.entities?.length) sections.push({
    key: 'entities', color: COLORS.cyan, items: agg.entities,
    render: ent => {
      if (typeof ent === 'string') return escHtml(ent);
      return `${escHtml(ent.name)} <span style="color:${COLORS.muted}">(${ent.attributes?.length || 0} attrs)</span>`;
    }
  });
  if (agg.lifecycle) sections.push({
    key: 'lifecycle', color: '#d2a8ff', items: agg.lifecycle.states || [],
    render: s => {
      const isDef = s === agg.lifecycle.default;
      return `<span style="color:${isDef ? COLORS.green : COLORS.text}">${isDef ? '● ' : '○ '}${escHtml(s)}</span>`;
    }
  });
  if (agg.subscribers?.length) sections.push({
    key: 'subscribers', color: COLORS.yellow, items: agg.subscribers,
    render: sub => {
      let s = escHtml(sub.name || sub);
      if (sub.event) s += ` <span style="color:${COLORS.muted}">on ${escHtml(sub.event)}</span>`;
      return s;
    }
  });
  if (agg.queries?.length) sections.push({
    key: 'queries', color: COLORS.cyan, items: agg.queries, render: q => escHtml(q)
  });
  if (agg.specifications?.length) sections.push({
    key: 'specifications', color: COLORS.yellow, items: agg.specifications, render: s => escHtml(s)
  });
  return sections;
}

class AggCard extends HTMLElement {
  constructor() { super(); this.attachShadow({ mode: 'open' }); this._data = null; }
  set data(agg) { this._data = agg; this.render(); }
  get data() { return this._data; }

  render() {
    if (!this._data) return;
    const agg = this._data;
    const sections = buildSections(agg);

    this.shadowRoot.innerHTML = `
      <style>
        ${BASE_STYLES}
        :host { display: block; }
        .card { background: ${COLORS.panel}e6; border: 1px solid ${COLORS.border}; border-radius: 6px; padding: 8px; min-width: 120px; backdrop-filter: blur(4px); position: relative; white-space: nowrap; }
        .name { color: ${COLORS.orange}; font-weight: 600; font-size: 11px; cursor: pointer; } .name:hover { text-decoration: underline; }
        .domain-tag { position:absolute;top:3px;right:6px;font-size:7px;color:${COLORS.cyan};opacity:0.9; }
        .badge { display: inline-block; font-size: 8px; padding: 1px 4px; border-radius: 3px; margin-left: 4px; vertical-align: middle; }
        .lifecycle-badge { background: ${COLORS.purple}33; color: ${COLORS.purple}; border: 1px solid ${COLORS.purple}55; }
        .dots { display: flex; gap: 6px; margin-top: 4px; flex-wrap: wrap; }
        .dot { width: 16px; height: 16px; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center;
               font-size: 8px; font-weight: bold; color: #fff; cursor: pointer; transition: transform 0.15s; position: relative; }
        .dot:hover { transform: scale(1.3); }
        .dot:hover .tooltip { display: block; }
        .dot.dim { opacity: 0.3; }
        .tooltip { display: none; position: absolute; bottom: 22px; left: 50%; transform: translateX(-50%);
                   background: ${COLORS.bg}; border: 1px solid ${COLORS.border}; border-radius: 4px;
                   padding: 2px 6px; font-size: 9px; white-space: nowrap; color: #e0e0e0 !important;
                   font-weight: 600; pointer-events: none; z-index: 30; }
        .detail-header { font-size: 9px; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 2px; }
        .detail-item { font-size: 10px; line-height: 1.6; color: ${COLORS.text}; }
        .ref { color: ${COLORS.orange}; cursor: pointer; }
        .ref:hover { text-decoration: underline; }
        .card.open { border-bottom-left-radius: 0; border-bottom-right-radius: 0; }
        .dropdown { background: ${COLORS.panel}e6; border: 1px solid ${COLORS.border}; border-top: none; backdrop-filter: blur(4px);
                    border-bottom-left-radius: 6px; border-bottom-right-radius: 6px; padding: 8px; }
      </style>
      <div class="card" part="card">
        ${agg.domain ? `<div class="domain-tag">${escHtml(agg.domain)}</div>` : ''}
        <div class="name">${escHtml(agg.name)}${agg.lifecycle ? `<span class="badge lifecycle-badge">${escHtml(agg.lifecycle.default)}</span>` : ''}</div>
        <div class="dots">${sections.map((s, i) => {
          const icon = SECTION_ICONS[s.key] || s.items.length;
          return `<span class="dot" data-idx="${i}" style="background:${s.color}">${icon}<span class="tooltip">${s.key} (${s.items.length})</span></span>`;
        }).join('')}</div>
      </div>
      <div class="dropdown" style="display:none"></div>
    `;

    const card = this.shadowRoot.querySelector('.card');
    const dropdown = this.shadowRoot.querySelector('.dropdown');
    const dots = this.shadowRoot.querySelectorAll('.dot');
    let activeIdx = -1;

    this.shadowRoot.querySelector('.name').addEventListener('click', () => {
      this.dispatchEvent(new CustomEvent('card-select', { bubbles: true, composed: true, detail: { name: agg.name } }));
    });

    dots.forEach((dot, i) => {
      dot.addEventListener('click', (e) => {
        e.stopPropagation();
        if (activeIdx === i) {
          dropdown.style.display = 'none'; card.classList.remove('open');
          dots.forEach(d => d.classList.remove('dim')); activeIdx = -1; this.style.zIndex = '';
          this.dispatchEvent(new CustomEvent('card-resized', { bubbles: true, composed: true }));
          return;
        }
        activeIdx = i; card.classList.add('open');
        dots.forEach(d => d.classList.add('dim')); dot.classList.remove('dim');
        let html = `<div class="detail-header" style="color:${sections[i].color}">${sections[i].key}</div>`;
        sections[i].items.forEach(item => { html += `<div class="detail-item">${sections[i].render(item)}</div>`; });
        dropdown.innerHTML = html; dropdown.style.display = 'block'; this.style.zIndex = '10';
        dropdown.querySelectorAll('.ref').forEach(ref => {
          ref.addEventListener('click', (ev) => {
            ev.stopPropagation();
            this.dispatchEvent(new CustomEvent('item-navigate', { bubbles: true, composed: true, detail: { target: ref.dataset.target } }));
          });
        });
        this.dispatchEvent(new CustomEvent('card-resized', { bubbles: true, composed: true }));
      });
    });

    card.addEventListener('click', (e) => {
      if (e.target.closest('.dot') || e.target.closest('.name')) return; if (activeIdx >= 0) {
        dropdown.style.display = 'none'; card.classList.remove('open');
        dots.forEach(d => d.classList.remove('dim')); activeIdx = -1; this.style.zIndex = '';
      }
    });

    this.addEventListener('mouseenter', () => {
      this.dispatchEvent(new CustomEvent('card-hover', { bubbles: true, composed: true, detail: { name: agg.name } }));
    });
  }
}

class AggExplorer extends HTMLElement {
  constructor() { super(); this.attachShadow({ mode: 'open' }); this._data = null; }
  set data(agg) { this._data = agg; this.render(); }

  render() {
    if (!this._data) { this.shadowRoot.innerHTML = ''; return; }
    const agg = this._data;
    this.shadowRoot.innerHTML = `
      <style>
        ${BASE_STYLES}
        .title { color: ${COLORS.orange}; font-size: 11px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 6px; font-weight: 600; }
      </style>
      <div class="title">${escHtml(agg.name)}</div>
      <div id="sections"></div>
    `;
    const container = this.shadowRoot.getElementById('sections');
    buildSections(agg).forEach(sec => {
      const panel = document.createElement('section-panel');
      panel.setAttribute('label', sec.key);
      panel.setAttribute('color', sec.color);
      sec.items.forEach(item => {
        const el = document.createElement('agg-item');
        const isRef = sec.key === 'references';
        if (isRef) {
          const m = item.type?.match(/(?:reference_to|list_of)\((\w+)\)/);
          el.setAttribute('name', item.name || item);
          if (m) el.setAttribute('nav-target', m[1]);
        } else {
          el.setAttribute('name', typeof item === 'string' ? item : item.name);
          if (item.type && sec.key === 'attributes') el.setAttribute('type', item.type);
        }
        el.setAttribute('removable', '');
        panel.appendChild(el);
      });
      container.appendChild(panel);
    });
  }
}

customElements.define('agg-card', AggCard);
customElements.define('agg-explorer', AggExplorer);
