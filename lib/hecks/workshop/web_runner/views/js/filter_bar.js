// Hecks Web Console — <filter-bar>
// Togglable filter buttons. Emits 'filter-change' with the active filter.
//
// Properties: .filters (array of strings), .active (current filter)
// Events: filter-change { detail: { filter } }
import { COLORS, BASE_STYLES } from './shared.js';

class FilterBar extends HTMLElement {
  constructor() { super(); this.attachShadow({ mode: 'open' }); this._filters = []; this._active = 'all'; }

  set filters(list) { this._filters = list; this.render(); }
  set active(f) { this._active = f; this.render(); }
  get active() { return this._active; }

  render() {
    if (!this._filters.length) { this.shadowRoot.innerHTML = ''; return; }

    this.shadowRoot.innerHTML = `
      <style>
        ${BASE_STYLES}
        :host { display: flex; gap: 4px; margin-bottom: 8px; }
        button { font-size: 10px; padding: 2px 8px; border-radius: 3px; border: 1px solid ${COLORS.border};
                 color: #fff; cursor: pointer; font-family: inherit; }
        button.active { background: ${COLORS.border}; }
        button:not(.active) { background: transparent; color: #ffffffaa; }
        button:hover { color: #fff; }
      </style>
      ${this._filters.map(f =>
        `<button data-filter="${f}" class="${f === this._active ? 'active' : ''}">${f}</button>`
      ).join('')}
    `;

    this.shadowRoot.querySelectorAll('button').forEach(btn => {
      btn.addEventListener('click', () => {
        this._active = btn.dataset.filter;
        this.render();
        this.dispatchEvent(new CustomEvent('filter-change', {
          bubbles: true, composed: true, detail: { filter: this._active }
        }));
      });
    });
  }
}

customElements.define('filter-bar', FilterBar);
