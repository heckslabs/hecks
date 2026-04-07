// Hecks Web Console — <domain-diagram>
// Force-directed layout with draggable cards, SVG lines, policy flows, services.
// Keyboard: press 0 to reset layout when input is not focused.
import { COLORS, BASE_STYLES, escHtml } from './shared.js';
import { layoutGraph, edgePoint, PortSpreader, collectPairs } from './graph_layout.js';
import { svgLine, svgArrow, svgText, svgPath, drawEdge } from './svg_helpers.js';

class DomainDiagram extends HTMLElement {
  constructor() { super(); this.attachShadow({ mode: 'open' }); this._state = null; this._cardEls = {}; this._filter = 'all'; }
  set state(s) { this._state = s; this.render(); }
  set filter(f) { this._filter = f; if (this._svgEl) this._drawLines(this._svgEl, this._container); }
  get filter() { return this._filter; }
  disconnectedCallback() { if (this._keyHandler) document.removeEventListener('keydown', this._keyHandler); }

  render() {
    if (!this._state || !this._state.aggregates.length) return;
    const state = this._state, aggs = state.aggregates;

    this.shadowRoot.innerHTML = `
      <style>
        ${BASE_STYLES}
        :host { display: block; position: relative; }
        .container { position: relative; transform-origin: top left; }
        svg { position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; z-index: 0; overflow: visible; }
        .cards { position: relative; z-index: 1; }
        .toolbar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
        .title { color: ${COLORS.blue}; font-weight: 600; font-size: 14px; }
        .nav-hint { font-size: 10px; color: #ffffffaa; padding: 2px 8px; border-radius: 3px; border: 1px solid ${COLORS.border}; }
      </style>
      <div class="toolbar">
        <div style="display:flex;align-items:center;gap:12px">
          <span class="title">${escHtml(state.domain_name || 'Domain')} Domain</span>
          <span id="filter-slot"></span>
        </div>
        <span class="nav-hint">${navigator.platform.indexOf('Mac')>=0?'⌥':'Alt'}+scroll zoom · 0 reset · drag to move</span>
      </div>
      <div class="container"><svg></svg><div class="cards"></div></div>
    `;

    // Filter bar
    const hasPolicies = state.policy_flows && state.policy_flows.length > 0;
    if (hasPolicies) {
      const fb = document.createElement('filter-bar');
      fb.filters = ['all', 'references', 'policies'];
      fb.addEventListener('filter-change', (e) => { this._filter = e.detail.filter; this._drawLines(this._svgEl, this._container); });
      this.shadowRoot.getElementById('filter-slot').appendChild(fb);
    }

    this._container = this.shadowRoot.querySelector('.container');
    this._svgEl = this.shadowRoot.querySelector('svg');
    const container = this._container, svgEl = this._svgEl;
    const cardsEl = this.shadowRoot.querySelector('.cards');
    const W = this.offsetWidth || 700, H = Math.max(this.offsetHeight || 500, 400);
    container.style.minHeight = H + 'px';

    const { nodes: graphNodes, edges: graphEdges } = this._buildGraph(aggs);
    const positions = layoutGraph(graphNodes, graphEdges, W, H);

    this._cardEls = {};
    aggs.forEach(agg => {
      const card = document.createElement('agg-card');
      card.data = agg;
      card.style.cssText = `position:absolute;left:${positions[agg.name].x}px;top:${positions[agg.name].y}px;`;
      this._makeDraggable(card, cardsEl, svgEl, container);
      cardsEl.appendChild(card); this._cardEls[agg.name] = card;
    });

    (state.services || []).forEach((svc, i) => {
      const node = document.createElement('div');
      node.style.cssText = `position:absolute;background:${COLORS.panel}e6;border:1px dashed ${COLORS.cyan};border-radius:12px;padding:4px 10px;font-size:10px;color:${COLORS.cyan};white-space:nowrap;left:${20+i*140}px;top:${H-30}px;`;
      node.textContent = `\u2699 ${svc.name}`;
      node.title = `Service: ${svc.name}${svc.domain ? ` (${svc.domain})` : ''}`;
      cardsEl.appendChild(node);
    });

    const fitZoom = (pos) => {
      const xs = Object.values(pos).map(p => p.x), ys = Object.values(pos).map(p => p.y);
      const cw = Math.max(...xs) - Math.min(...xs) + 200, ch = Math.max(...ys) - Math.min(...ys) + 120;
      return Math.min(1, W / cw, H / ch);
    };
    let zoom = fitZoom(positions);
    const applyZoom = () => { container.style.transform = `scale(${zoom})`; };
    container.addEventListener('wheel', (e) => {
      if (!e.altKey) return; e.preventDefault();
      zoom = Math.max(0.3, Math.min(2, zoom - e.deltaY * 0.001)); applyZoom();
    }, { passive: false });
    // Keyboard: 0 resets layout + zoom
    this._keyHandler = (e) => {
      if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
      if (e.key === '0') {
        const np = layoutGraph(graphNodes, graphEdges, W, H);
        aggs.forEach(a => { const c = this._cardEls[a.name]; if (c) { c.style.left = np[a.name].x+'px'; c.style.top = np[a.name].y+'px'; }});
        zoom = fitZoom(np); applyZoom();
        this._drawLines(svgEl, container);
      }
    };
    document.addEventListener('keydown', this._keyHandler);
    applyZoom();
    requestAnimationFrame(() => this._drawLines(svgEl, container));
  }

  _buildGraph(aggs) {
    const nodes = aggs.map(a => ({ name: a.name, domain: a.domain }));
    const edges = [], seen = {};
    aggs.forEach(agg => {
      agg.attributes.forEach(a => {
        const m = a.type.match(/(?:reference_to|list_of)\((\w+)\)/);
        if (!m || !aggs.find(x => x.name === m[1])) return;
        const pk = agg.name + '|' + m[1];
        if (!seen[pk]) { seen[pk] = true; edges.push({ from: agg.name, to: m[1] }); }
      });
      (agg.references_to || []).forEach(r => {
        if (!aggs.find(x => x.name === r.type)) return;
        const pk = agg.name + '|' + r.type;
        if (!seen[pk]) { seen[pk] = true; edges.push({ from: agg.name, to: r.type }); }
      });
    });
    return { nodes, edges };
  }

  _makeDraggable(card, cardsEl, svgEl, container) {
    card.addEventListener('mousedown', (e) => {
      if (e.composedPath().some(el => el.classList && (el.classList.contains('dot') || el.classList.contains('ref')))) return;
      const startLeft = parseFloat(card.style.left) || 0, startTop = parseFloat(card.style.top) || 0;
      const dx = e.clientX, dy = e.clientY;
      card.style.zIndex = '20'; card.style.cursor = 'grabbing'; e.preventDefault();
      const onMove = (e2) => {
        card.style.left = Math.max(0, startLeft + (e2.clientX - dx)) + 'px';
        card.style.top = Math.max(0, startTop + (e2.clientY - dy)) + 'px';
        this._drawLines(svgEl, container);
      };
      const onUp = () => { card.style.zIndex = ''; card.style.cursor = ''; document.removeEventListener('mousemove', onMove); document.removeEventListener('mouseup', onUp); };
      document.addEventListener('mousemove', onMove);
      document.addEventListener('mouseup', onUp);
    });
  }

  _drawLines(svg, container) {
    svg.innerHTML = '';
    let maxW = container.offsetWidth, maxH = container.offsetHeight;
    Object.values(this._cardEls).forEach(c => {
      maxW = Math.max(maxW, (parseFloat(c.style.left)||0) + c.offsetWidth + 10);
      maxH = Math.max(maxH, (parseFloat(c.style.top)||0) + c.offsetHeight + 10);
    });
    svg.setAttribute('width', maxW); svg.setAttribute('height', maxH);
    svg.style.overflow = 'visible';
    this._ports = new PortSpreader();
    this._state.aggregates.forEach(agg => {
      agg.attributes.forEach(a => {
        const m = a.type.match(/(?:reference_to|list_of)\((\w+)\)/);
        if (m && this._cardEls[agg.name] && this._cardEls[m[1]]) {
          this._ports.count(agg.name);
          this._ports.count(m[1]);
        }
      });
      (agg.references_to || []).forEach(r => {
        if (this._cardEls[agg.name] && this._cardEls[r.type]) {
          this._ports.count(agg.name);
          this._ports.count(r.type);
        }
      });
    });
    (this._state.policy_flows || []).forEach(f => {
      this._ports.count(f.from);
      this._ports.count(f.to);
    });
    if (this._filter === 'all' || this._filter === 'references') this._drawRefLines(svg);
    if (this._filter === 'all' || this._filter === 'policies') this._drawPolicyFlows(svg);
  }

  _drawRefLines(svg) {
    collectPairs(this._state.aggregates, this._cardEls).forEach(edge => {
      const pts = this._edgePair(edge.from, edge.to); if (!pts) return;
      pts.toName = edge.to;
      const dash = edge.isComposition ? 'none' : (edge.isList ? '4,3' : '6,3');
      drawEdge(svg, pts, COLORS.orange, dash, 0.5, edge.names, COLORS.bg);
    });
  }

  _drawPolicyFlows(svg) {
    (this._state.policy_flows || []).forEach(flow => {
      const pts = this._edgePair(flow.from, flow.to); if (!pts) return;
      const mx = (pts.x1+pts.x2)/2, my = (pts.y1+pts.y2)/2 - 30;
      svgPath(svg, `M${pts.x1},${pts.y1} Q${mx},${my} ${pts.x2},${pts.y2}`, COLORS.red, { width: '1.8', dash: '6,3', opacity: 0.8 });
      svgArrow(svg, pts.x2, pts.y2, pts.angle, COLORS.red, 0.8);
      svgText(svg, mx, my-4, flow.event || flow.policy, COLORS.red, 8);
    });
  }

  _edgePair(fromName, toName) {
    const fEl = this._cardEls[fromName], tEl = this._cardEls[toName];
    if (!fEl || !tEl) return null;
    const box = (el) => {
      const x = parseFloat(el.style.left) || 0, y = parseFloat(el.style.top) || 0;
      return { cx: x + el.offsetWidth / 2, cy: y + el.offsetHeight / 2, hw: el.offsetWidth / 2, hh: el.offsetHeight / 2 };
    };
    const f = box(fEl), t = box(tEl), pad = 4;
    const p1 = edgePoint(f.cx, f.cy, f.hw+pad, f.hh+pad, t.cx, t.cy);
    const p2 = edgePoint(t.cx, t.cy, t.hw+pad, t.hh+pad, f.cx, f.cy);
    const angle = Math.atan2(p2.y-p1.y, p2.x-p1.x);
    const np1 = this._ports.nudge(fromName, p1.x, p1.y, angle);
    const np2 = this._ports.nudge(toName, p2.x, p2.y, angle);
    return { x1: np1.x, y1: np1.y, x2: np2.x, y2: np2.y, angle };
  }

}

customElements.define('domain-diagram', DomainDiagram);
