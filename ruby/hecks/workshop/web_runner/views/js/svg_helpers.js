// Hecks Web Console — SVG drawing helpers
// Line, arrow, and text primitives for diagram overlays.

const NS = 'http://www.w3.org/2000/svg';

export function svgLine(svg, x1, y1, x2, y2, color, dash, opacity) {
  const l = document.createElementNS(NS, 'line');
  l.setAttribute('x1', x1); l.setAttribute('y1', y1);
  l.setAttribute('x2', x2); l.setAttribute('y2', y2);
  l.setAttribute('stroke', color);
  l.setAttribute('stroke-width', '1.5');
  l.setAttribute('stroke-dasharray', dash);
  l.setAttribute('opacity', opacity || 0.6);
  svg.appendChild(l);
  return l;
}

export function svgArrow(svg, x, y, angle, color, opacity) {
  const al = 8, pa = Math.PI / 6;
  const arrow = document.createElementNS(NS, 'polygon');
  arrow.setAttribute('points',
    `${x},${y} ${x - Math.cos(angle - pa) * al},${y - Math.sin(angle - pa) * al} ${x - Math.cos(angle + pa) * al},${y - Math.sin(angle + pa) * al}`
  );
  arrow.setAttribute('fill', color);
  arrow.setAttribute('opacity', opacity || 0.6);
  svg.appendChild(arrow);
}

export function svgText(svg, x, y, text, color, size, weight) {
  const t = document.createElementNS(NS, 'text');
  t.setAttribute('x', x); t.setAttribute('y', y);
  t.setAttribute('text-anchor', 'middle');
  t.setAttribute('font-size', size);
  t.setAttribute('fill', color);
  t.setAttribute('opacity', '0.7');
  if (weight) t.setAttribute('font-weight', weight);
  t.textContent = text;
  svg.appendChild(t);
  return t;
}

// Draw a labeled edge with line, arrow, and optional label.
export function drawEdge(svg, pts, color, dash, opacity, names, bg) {
  const { x1, y1, x2, y2, angle } = pts;
  svgLine(svg, x1, y1, x2, y2, color, dash, opacity);
  svgArrow(svg, x2, y2, angle, color, opacity);
  const mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
  if (names.length > 1) {
    const text = svgText(svg, mx, my + 3, names.length, color, 10, 'bold');
    text.setAttribute('stroke', bg); text.setAttribute('stroke-width', '3'); text.setAttribute('paint-order', 'stroke');
    const title = document.createElementNS(NS, 'title');
    title.textContent = names.join(', '); text.appendChild(title);
  } else if (names[0] && names[0].toLowerCase() !== (pts.toName || '').toLowerCase()) {
    svgText(svg, mx, my - 4, names[0], color, 9);
  }
}

export function svgPath(svg, d, stroke, opts = {}) {
  const path = document.createElementNS(NS, 'path');
  path.setAttribute('d', d);
  path.setAttribute('stroke', stroke);
  path.setAttribute('fill', 'none');
  path.setAttribute('stroke-width', opts.width || '1.5');
  if (opts.dash) path.setAttribute('stroke-dasharray', opts.dash);
  path.setAttribute('opacity', opts.opacity || 0.6);
  svg.appendChild(path);
  return path;
}
