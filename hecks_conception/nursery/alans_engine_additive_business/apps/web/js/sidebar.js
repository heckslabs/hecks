/* Sidebar template — injected into each page to avoid duplicating 40 lines
   Domain: StorefrontSite.Navigation */

function renderSidebar(prefix) {
  const p = prefix || '';
  const el = document.getElementById('sidebar');
  if (!el) return;
  el.innerHTML = `
    <div class="px-5 pt-6 pb-4 border-b border-surface-3" data-domain-attribute="brand">
      <h1 class="text-lg font-bold text-white tracking-tight">Alan's Additives</h1>
      <p class="text-xs text-gray-500 mt-1 tracking-wide">16 bounded contexts. One business.</p>
    </div>
    <div class="flex-1 overflow-y-auto py-4 px-3 space-y-5">
      <div data-domain-aggregate="OperationsNav">
        <div class="text-[10px] font-semibold uppercase tracking-widest text-gray-500 px-2 mb-2">Operations</div>
        <a href="${p}dashboard.html" class="nav-link flex items-center px-3 py-2 rounded-md text-sm text-gray-400 hover:bg-surface-2 hover:text-white transition" data-domain-command="ViewDashboard">Dashboard</a>
        <a href="${p}orders.html" class="nav-link flex items-center px-3 py-2 rounded-md text-sm text-gray-400 hover:bg-surface-2 hover:text-white transition" data-domain-command="ViewOrders">Sales Orders</a>
        <a href="${p}supply-chain.html" class="nav-link flex items-center px-3 py-2 rounded-md text-sm text-gray-400 hover:bg-surface-2 hover:text-white transition" data-domain-command="ViewSupplyChain">Supply Chain</a>
      </div>
      <div data-domain-aggregate="ProductsNav">
        <div class="text-[10px] font-semibold uppercase tracking-widest text-gray-500 px-2 mb-2">Products</div>
        <a href="${p}products.html" class="nav-link flex items-center px-3 py-2 rounded-md text-sm text-gray-400 hover:bg-surface-2 hover:text-white transition" data-domain-command="ViewCatalog">Product Catalog</a>
        <a href="${p}formulations.html" class="nav-link flex items-center px-3 py-2 rounded-md text-sm text-gray-400 hover:bg-surface-2 hover:text-white transition" data-domain-command="ViewFormulations">Formulations</a>
        <a href="${p}pipeline.html" class="nav-link flex items-center px-3 py-2 rounded-md text-sm text-gray-400 hover:bg-surface-2 hover:text-white transition" data-domain-command="ViewPipeline">Formulation Lab</a>
      </div>
      <div data-domain-aggregate="SalesNav">
        <div class="text-[10px] font-semibold uppercase tracking-widest text-gray-500 px-2 mb-2">Sales &amp; Brand</div>
        <a href="${p}campaigns.html" class="nav-link flex items-center px-3 py-2 rounded-md text-sm text-gray-400 hover:bg-surface-2 hover:text-white transition" data-domain-command="ViewCampaigns">Campaigns</a>
        <a href="${p}personas.html" class="nav-link flex items-center px-3 py-2 rounded-md text-sm text-gray-400 hover:bg-surface-2 hover:text-white transition" data-domain-command="ViewPersonas">Buyer Personas</a>
      </div>
      <div data-domain-aggregate="ComplianceNav">
        <div class="text-[10px] font-semibold uppercase tracking-widest text-gray-500 px-2 mb-2">Compliance</div>
        <a href="${p}compliance.html" class="nav-link flex items-center px-3 py-2 rounded-md text-sm text-gray-400 hover:bg-surface-2 hover:text-white transition" data-domain-command="ViewCompliance">SDS &amp; Compliance</a>
      </div>
    </div>
    <div class="px-3 py-4 border-t border-surface-3 flex gap-1" data-domain-aggregate="BrandSwitcher">
      <button class="brand-btn flex-1 py-1.5 rounded text-xs font-medium bg-duralube/20 text-duralube border border-duralube/30" data-brand-select="duralube" data-domain-command="SelectBrand">DuraLube</button>
      <button class="brand-btn flex-1 py-1.5 rounded text-xs font-medium text-gray-500 hover:text-motorkote transition" data-brand-select="motorkote" data-domain-command="SelectBrand">MotorKote</button>
      <button class="brand-btn flex-1 py-1.5 rounded text-xs font-medium text-gray-500 hover:text-slick50 transition" data-brand-select="slick50" data-domain-command="SelectBrand">Slick 50</button>
    </div>`;
}

document.addEventListener('DOMContentLoaded', () => {
  const isSubpage = window.location.pathname.includes('/pages/');
  renderSidebar(isSubpage ? '' : 'pages/');
});
