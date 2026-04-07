// Hecks Web Console — Shared constants
// Colors, section metadata, base styles for Shadow DOM components.

export const COLORS = {
  bg: '#0d1117', panel: '#161b22', border: '#30363d', muted: '#484f58', text: '#c9d1d9',
  blue: '#58a6ff', green: '#7ee787', orange: '#f0883e', purple: '#d2a8ff',
  red: '#f85149', yellow: '#d29922', cyan: '#79c0ff'
};

export const SECTION_COLORS = {
  attributes: COLORS.green, references: COLORS.orange, commands: COLORS.blue,
  events: COLORS.purple, policies: COLORS.red, queries: COLORS.cyan,
  specifications: COLORS.yellow, 'value objects': COLORS.orange, entities: COLORS.cyan,
  lifecycle: '#d2a8ff', subscribers: COLORS.yellow
};

export const SECTION_ICONS = {
  attributes: 'A', references: '→', commands: '⌘', events: '⚡',
  policies: 'P', 'value objects': '◇', entities: '◈', lifecycle: '↻',
  subscribers: 'S', queries: '?', specifications: '✓'
};

export const BASE_STYLES = `
  * { margin: 0; padding: 0; box-sizing: border-box; }
  :host { display: block; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: ${COLORS.text}; font-size: 12px; }
`;

export function escHtml(s) {
  const d = document.createElement('span');
  d.textContent = s;
  return d.innerHTML;
}
