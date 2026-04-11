/* Brand switcher -- changes accent color and filters product display
   Domain: StorefrontSite.ConfigureBrand */

const BRAND_STYLES = {
  duralube:  { bg: 'bg-duralube/20', text: 'text-duralube', border: 'border-duralube/30' },
  motorkote: { bg: 'bg-motorkote/20', text: 'text-motorkote', border: 'border-motorkote/30' },
  slick50:   { bg: 'bg-slick50/20', text: 'text-slick50', border: 'border-slick50/30' }
};

function initBrandSwitcher() {
  document.addEventListener('click', (e) => {
    const btn = e.target.closest('[data-brand-select]');
    if (btn) switchBrand(btn.dataset.brandSelect);
  });
}

function switchBrand(brandKey) {
  document.documentElement.setAttribute('data-brand', brandKey);

  document.querySelectorAll('[data-brand-select]').forEach(btn => {
    const key = btn.dataset.brandSelect;
    const s = BRAND_STYLES[key];
    const isActive = key === brandKey;
    btn.className = `brand-btn flex-1 py-1.5 rounded text-xs font-medium transition ${
      isActive ? `${s.bg} ${s.text} border ${s.border}` : 'text-gray-500 hover:text-gray-300'
    }`;
  });

  // Filter product rows if present
  document.querySelectorAll('[data-product-brand]').forEach(row => {
    row.style.display = row.dataset.productBrand === brandKey ? '' : 'none';
  });

  // Update brand-specific text
  const brandData = typeof BRANDS !== 'undefined' && BRANDS.find(b => b.key === brandKey);
  if (brandData) {
    const tagEl = document.querySelector('[data-domain-attribute="brand_tagline"]');
    if (tagEl) tagEl.textContent = brandData.description;
    const wordEl = document.querySelector('[data-domain-attribute="owned_word"]');
    if (wordEl) wordEl.textContent = brandData.owned_word;
  }

  document.dispatchEvent(new CustomEvent('brand-switched', { detail: { brand: brandKey } }));
}

document.addEventListener('DOMContentLoaded', initBrandSwitcher);
