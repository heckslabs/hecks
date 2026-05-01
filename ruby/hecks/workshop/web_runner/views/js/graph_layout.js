// Hecks Web Console — Force-directed graph layout
// Positions nodes using repulsion + attraction + center gravity.

export function layoutGraph(nodes, edges, width, height) {
  const NW = 160, NH = 80, REP = 20000, ATT = 0.003, GROUP = 0.008, DAMP = 0.9, ITERS = 300;
  const cx = width/2, cy = height/2, r = Math.min(width, height)/3;
  const deg = {}, pos = {}, vel = {};
  nodes.forEach(n => { deg[n.name] = 0; });
  edges.forEach(e => { deg[e.from]++; deg[e.to]++; });
  // Seed same-domain nodes near each other
  const domainIdx = {}, domains = [];
  nodes.forEach(n => {
    const d = n.domain || '_'; if (!domainIdx[d]) { domainIdx[d] = domains.length; domains.push(d); }
  });
  nodes.forEach((n, i) => {
    const di = domainIdx[n.domain || '_'];
    const ga = (2*Math.PI*di)/Math.max(domains.length, 1);
    const gcx = cx + r*0.6*Math.cos(ga), gcy = cy + r*0.6*Math.sin(ga);
    const spread = 60, ai = (2*Math.PI*i)/nodes.length;
    pos[n.name] = { x: gcx + spread*Math.cos(ai), y: gcy + spread*Math.sin(ai) };
    vel[n.name] = { x: 0, y: 0 };
  });
  for (let it = 0; it < ITERS; it++) {
    const f = {}; nodes.forEach(n => f[n.name] = { x: 0, y: 0 });
    for (let i = 0; i < nodes.length; i++) for (let j = i+1; j < nodes.length; j++) {
      const na = nodes[i].name, nb = nodes[j].name;
      let dx = pos[na].x-pos[nb].x, dy = pos[na].y-pos[nb].y;
      const d = Math.max(Math.sqrt(dx*dx+dy*dy), 20), force = REP/(d*d);
      f[na].x += dx/d*force; f[na].y += dy/d*force; f[nb].x -= dx/d*force; f[nb].y -= dy/d*force;
    }
    edges.forEach(e => {
      const dx = pos[e.to].x-pos[e.from].x, dy = pos[e.to].y-pos[e.from].y;
      f[e.from].x += dx*ATT; f[e.from].y += dy*ATT; f[e.to].x -= dx*ATT; f[e.to].y -= dy*ATT;
    });
    // Domain grouping: attract same-domain nodes toward their centroid
    const centroids = {};
    nodes.forEach(n => {
      const d = n.domain || '_'; if (!centroids[d]) centroids[d] = { x: 0, y: 0, n: 0 };
      centroids[d].x += pos[n.name].x; centroids[d].y += pos[n.name].y; centroids[d].n++;
    });
    Object.values(centroids).forEach(c => { c.x /= c.n; c.y /= c.n; });
    nodes.forEach(n => {
      const c = centroids[n.domain || '_'];
      f[n.name].x += (c.x-pos[n.name].x)*GROUP; f[n.name].y += (c.y-pos[n.name].y)*GROUP;
      const cp = 0.0005+deg[n.name]*0.001;
      f[n.name].x += (cx-pos[n.name].x)*cp; f[n.name].y += (cy-pos[n.name].y)*cp;
      vel[n.name].x = (vel[n.name].x+f[n.name].x)*DAMP; vel[n.name].y = (vel[n.name].y+f[n.name].y)*DAMP;
      pos[n.name].x = Math.max(NW/2, Math.min(width-NW/2, pos[n.name].x+vel[n.name].x));
      pos[n.name].y = Math.max(NH/2, Math.min(height-NH/2, pos[n.name].y+vel[n.name].y));
    });
  }
  const result = {}; nodes.forEach(n => { result[n.name] = { x: Math.round(pos[n.name].x-NW/2), y: Math.round(pos[n.name].y-NH/2) }; });
  return result;
}

// Spreads multiple arrow endpoints along a card edge so they don't overlap.
export class PortSpreader {
  constructor() { this._count = {}; this._used = {}; }
  count(name) { this._count[name] = (this._count[name]||0) + 1; }
  nudge(name, px, py, angle) {
    this._used[name] = (this._used[name]||0) + 1;
    const idx = this._used[name]-1, total = this._count[name]||1;
    const off = (idx-(total-1)/2)*8, perp = angle+Math.PI/2;
    return { x: px+Math.cos(perp)*off, y: py+Math.sin(perp)*off };
  }
}

// Collect all relationship pairs from aggregate data for line drawing.
export function collectPairs(aggs, cardEls) {
  const pairMap = {};
  aggs.forEach(agg => {
    agg.attributes.forEach(a => {
      const rm = a.type.match(/reference_to\((\w+)\)/), lm = a.type.match(/list_of\((\w+)\)/);
      const target = rm ? rm[1] : (lm ? lm[1] : null);
      if (!target || !cardEls[agg.name] || !cardEls[target]) return;
      const key = agg.name + '|' + target;
      if (!pairMap[key]) pairMap[key] = { from: agg.name, to: target, isList: !!lm, isComposition: false, names: [] };
      pairMap[key].names.push(a.name.replace(/_id$/, ''));
      if (lm) pairMap[key].isList = true;
    });
    (agg.references_to || []).forEach(r => {
      if (!cardEls[agg.name] || !cardEls[r.type]) return;
      const key = agg.name + '|' + r.type;
      const isComp = r.kind === 'composition';
      if (!pairMap[key]) pairMap[key] = { from: agg.name, to: r.type, isList: false, isComposition: isComp, names: [] };
      pairMap[key].names.push(r.name);
      if (isComp) pairMap[key].isComposition = true;
    });
  });
  return Object.values(pairMap);
}

export function edgePoint(cx, cy, hw, hh, tx, ty) {
  const dx = tx-cx, dy = ty-cy;
  if (dx === 0 && dy === 0) return { x: cx, y: cy };
  if (Math.abs(dx)*hh > Math.abs(dy)*hw) { const s = dx > 0 ? 1 : -1; return { x: cx+s*hw, y: cy+dy*hw/Math.abs(dx) }; }
  else { const s = dy > 0 ? 1 : -1; return { x: cx+dx*hh/Math.abs(dy), y: cy+s*hh }; }
}
