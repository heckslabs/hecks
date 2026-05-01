// Hecks Web Console — <section-panel> and <agg-item>
// Collapsible sections and item rows for sidebar/cards.
import { COLORS, BASE_STYLES, escHtml } from './shared.js';

class SectionPanel extends HTMLElement {
  static get observedAttributes() { return ['label', 'color', 'collapsed']; }

  constructor() { super(); this.attachShadow({ mode: 'open' }); }
  connectedCallback() { this.render(); }
  attributeChangedCallback() { this.render(); }
  get isCollapsed() { return this.hasAttribute('collapsed'); }

  render() {
    const label = this.getAttribute('label') || '';
    const color = this.getAttribute('color') || COLORS.blue;
    const collapsed = this.isCollapsed;

    this.shadowRoot.innerHTML = `
      <style>
        ${BASE_STYLES}
        .header {
          font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px;
          padding-left: 8px; border-left: 2px solid ${color}; color: ${color};
          cursor: pointer; user-select: none; display: flex; align-items: center; gap: 4px;
          margin-top: 8px; margin-bottom: 3px;
        }
        .header:hover .chevron { opacity: 1; }
        .chevron {
          font-size: 8px; transition: transform 0.2s, opacity 0.2s;
          opacity: ${collapsed ? '0.5' : '1'};
          transform: ${collapsed ? 'none' : 'rotate(90deg)'};
        }
        .items { display: ${collapsed ? 'none' : 'block'}; margin-left: 10px; }
      </style>
      <div class="header" part="header">
        <span class="chevron">&#9654;</span>
        <span>${label}</span>
      </div>
      <div class="items" part="items"><slot></slot></div>
    `;

    this.shadowRoot.querySelector('.header').addEventListener('click', () => {
      if (this.isCollapsed) this.removeAttribute('collapsed');
      else this.setAttribute('collapsed', '');
      this.dispatchEvent(new CustomEvent('section-toggle', {
        bubbles: true, detail: { label, collapsed: this.isCollapsed }
      }));
    });
  }
}

class AggItem extends HTMLElement {
  static get observedAttributes() { return ['name', 'type', 'removable', 'nav-target']; }

  constructor() { super(); this.attachShadow({ mode: 'open' }); }
  connectedCallback() { this.render(); }
  attributeChangedCallback() { this.render(); }

  render() {
    const name = this.getAttribute('name') || '';
    const type = this.getAttribute('type') || '';
    const removable = this.hasAttribute('removable');
    const navTarget = this.getAttribute('nav-target');
    const isRef = !!navTarget;

    this.shadowRoot.innerHTML = `
      <style>
        ${BASE_STYLES}
        :host { display: block; line-height: 1.8; }
        .row { display: flex; align-items: center; gap: 4px; }
        .row:hover .remove { opacity: 1; }
        .name { color: ${COLORS.text}; }
        .type { color: ${COLORS.muted}; }
        .ref { color: ${COLORS.orange}; cursor: pointer; }
        .ref:hover { text-decoration: underline; }
        .remove { color: ${COLORS.red}; cursor: pointer; font-size: 11px; opacity: 0; transition: opacity 0.2s; margin-left: 2px; }
        .deleted { text-decoration: line-through; opacity: 0.5; }
        .undo { color: ${COLORS.blue}; cursor: pointer; font-size: 11px; margin-left: 4px; }
      </style>
      <div class="row">
        ${isRef
          ? `<span class="ref">${escHtml(name.replace(/_id$/, ''))} → ${escHtml(navTarget)}</span>`
          : `<span class="name">${escHtml(name)}</span><span class="type">${escHtml(type)}</span>`
        }
        ${removable ? '<span class="remove">×</span>' : ''}
      </div>
    `;

    if (isRef) {
      this.shadowRoot.querySelector('.ref')?.addEventListener('click', (e) => {
        e.stopPropagation();
        this.dispatchEvent(new CustomEvent('item-navigate', {
          bubbles: true, composed: true, detail: { target: navTarget }
        }));
      });
    }

    if (removable) {
      this.shadowRoot.querySelector('.remove')?.addEventListener('click', (e) => {
        e.stopPropagation();
        const row = this.shadowRoot.querySelector('.row');
        row.classList.add('deleted');
        this.shadowRoot.querySelector('.remove').style.display = 'none';
        const undo = document.createElement('span');
        undo.className = 'undo'; undo.textContent = '(undo)';
        undo.addEventListener('click', (e2) => {
          e2.stopPropagation();
          this.dispatchEvent(new CustomEvent('item-undo', {
            bubbles: true, composed: true, detail: { name }
          }));
        });
        row.appendChild(undo);
        this.dispatchEvent(new CustomEvent('item-remove', {
          bubbles: true, composed: true, detail: { name, type }
        }));
      });
    }
  }
}

customElements.define('section-panel', SectionPanel);
customElements.define('agg-item', AggItem);
