/* Alan's Engine Additive Business — App Entry Point
   Orchestrates domain-driven interactivity across 16 bounded contexts */

document.addEventListener('DOMContentLoaded', () => {
  renderDomainTagCount();
});

function renderDomainTagCount() {
  const domainElements = document.querySelectorAll(
    '[data-domain-aggregate], [data-domain-command], [data-domain-attribute]'
  );
  const countEl = document.querySelector('[data-domain-attribute="domain_tag_count"]');
  if (countEl) {
    countEl.textContent = domainElements.length;
  }
}

/* Utility: create an element with domain tags */
function domEl(tag, attrs, children) {
  const el = document.createElement(tag);
  Object.entries(attrs).forEach(([k, v]) => el.setAttribute(k, v));
  if (typeof children === 'string') {
    el.textContent = children;
  } else if (Array.isArray(children)) {
    children.forEach(c => { if (c) el.appendChild(c); });
  }
  return el;
}

/* Utility: status badge */
function statusBadge(status) {
  const map = {
    published: 'success', active: 'success', approved: 'success', delivered: 'success',
    shipped: 'info', confirmed: 'info', in_lab: 'info', fulfilling: 'info',
    draft: 'muted', proposed: 'muted', placed: 'warning', pending: 'warning',
    open: 'warning', rejected: 'danger', overdue: 'danger', suspended: 'danger'
  };
  const cls = map[status] || 'muted';
  return `<span class="badge badge-${cls}">${status.replace(/_/g, ' ')}</span>`;
}
