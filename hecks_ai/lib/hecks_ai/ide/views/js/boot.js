/* ── Boot — starts the IDE after DOM is ready ── */

document.addEventListener('DOMContentLoaded', () => {
  IDE.boot();
  loadBluebooks();
  console.log('IDE booted');
});
