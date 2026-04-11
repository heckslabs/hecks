/* Brand switcher — changes accent color and filters product display
   Domain: StorefrontSite.ConfigureBrand */

function initBrandSwitcher() {
  const buttons = document.querySelectorAll('[data-brand-select]');
  buttons.forEach(btn => {
    btn.addEventListener('click', () => {
      const brand = btn.dataset.brandSelect;
      switchBrand(brand);
    });
  });
}

function switchBrand(brandKey) {
  // Update HTML attribute for CSS variable switching
  document.documentElement.setAttribute('data-brand', brandKey);

  // Update active button state
  document.querySelectorAll('[data-brand-select]').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.brandSelect === brandKey);
  });

  // Filter product listings if on products page
  const productRows = document.querySelectorAll('[data-product-brand]');
  productRows.forEach(row => {
    if (brandKey === 'all') {
      row.style.display = '';
    } else {
      row.style.display = row.dataset.productBrand === brandKey ? '' : 'none';
    }
  });

  // Update brand-specific content
  const brandData = BRANDS.find(b => b.key === brandKey);
  if (brandData) {
    const taglineEl = document.querySelector('[data-domain-attribute="brand_tagline"]');
    if (taglineEl) taglineEl.textContent = brandData.description;

    const wordEl = document.querySelector('[data-domain-attribute="owned_word"]');
    if (wordEl) wordEl.textContent = brandData.owned_word;
  }

  // Dispatch custom event for other components
  document.dispatchEvent(new CustomEvent('brand-switched', { detail: { brand: brandKey } }));
}

document.addEventListener('DOMContentLoaded', initBrandSwitcher);
