/* Navigation -- highlights active section, mobile toggle, search
   Domain: StorefrontSite navigation */

function initNavigation() {
  const currentPage = window.location.pathname.split('/').pop() || 'index.html';

  document.querySelectorAll('.nav-link').forEach(link => {
    const href = link.getAttribute('href');
    const isActive = (href && href.includes(currentPage)) ||
      (currentPage === 'index.html' && href && href.includes('dashboard'));

    if (isActive) {
      link.classList.remove('text-gray-400');
      link.classList.add('bg-surface-2', 'text-white', 'font-medium');
    }
  });

  // Mobile toggle
  const toggle = document.getElementById('mobile-toggle');
  const sidebar = document.getElementById('sidebar');
  if (toggle && sidebar) {
    toggle.addEventListener('click', () => {
      sidebar.classList.toggle('-translate-x-full');
    });
    document.addEventListener('click', (e) => {
      if (!sidebar.classList.contains('-translate-x-full') &&
          !sidebar.contains(e.target) && e.target !== toggle) {
        sidebar.classList.add('-translate-x-full');
      }
    });
  }
}

function initSearch() {
  const searchInput = document.querySelector('[data-domain-command="SearchAggregates"]');
  if (!searchInput) return;
  searchInput.addEventListener('input', (e) => {
    const query = e.target.value.toLowerCase();
    document.querySelectorAll('[data-searchable]').forEach(el => {
      el.style.display = el.textContent.toLowerCase().includes(query) ? '' : 'none';
    });
  });
}

document.addEventListener('DOMContentLoaded', () => {
  initNavigation();
  initSearch();
});
