/* Navigation — highlights active section, mobile toggle, collapsible sections
   Domain: StorefrontSite navigation */

function initNavigation() {
  // Highlight current page in sidebar
  const currentPage = window.location.pathname.split('/').pop() || 'index.html';
  document.querySelectorAll('.nav-link').forEach(link => {
    const href = link.getAttribute('href');
    if (href && href.includes(currentPage)) {
      link.classList.add('active');
    } else if (currentPage === 'index.html' && href && href.includes('dashboard')) {
      link.classList.add('active');
    } else {
      link.classList.remove('active');
    }
  });

  // Mobile toggle
  const toggle = document.querySelector('.mobile-toggle');
  const sidebar = document.querySelector('.sidebar');
  if (toggle && sidebar) {
    toggle.addEventListener('click', () => {
      sidebar.classList.toggle('open');
    });
    // Close on outside click
    document.addEventListener('click', (e) => {
      if (sidebar.classList.contains('open') && !sidebar.contains(e.target) && e.target !== toggle) {
        sidebar.classList.remove('open');
      }
    });
  }
}

function initCollapsibles() {
  document.querySelectorAll('.collapsible-header').forEach(header => {
    header.addEventListener('click', () => {
      header.classList.toggle('expanded');
      const body = header.nextElementSibling;
      if (body && body.classList.contains('collapsible-body')) {
        body.classList.toggle('open');
      }
    });
  });
}

function initSearch() {
  const searchInput = document.querySelector('[data-domain-command="SearchAggregates"]');
  if (!searchInput) return;

  searchInput.addEventListener('input', (e) => {
    const query = e.target.value.toLowerCase();
    document.querySelectorAll('[data-searchable]').forEach(el => {
      const text = el.textContent.toLowerCase();
      el.style.display = text.includes(query) ? '' : 'none';
    });
  });
}

document.addEventListener('DOMContentLoaded', () => {
  initNavigation();
  initCollapsibles();
  initSearch();
});
