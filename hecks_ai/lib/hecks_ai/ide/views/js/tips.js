/* ── Tips — rotating "did you know?" hints above the prompt ── */
IDE.register({
  init(ide) {
    const tips = [
      'Tool calls show in the side panel — click one to expand details',
      'Press Ctrl+S to switch sessions quickly',
      'Press Ctrl+P to open the command palette',
      'Type /sessions to browse and resume past conversations',
      'Click an application in the sidebar to set file context'
    ];

    const el = document.getElementById('tip-text');
    if (!el) return;

    let idx = Math.floor(Math.random() * tips.length);
    el.textContent = tips[idx];

    setInterval(() => {
      idx = (idx + 1) % tips.length;
      el.style.opacity = '0';
      setTimeout(() => { el.textContent = tips[idx]; el.style.opacity = '1'; }, 300);
    }, 30000);
  }
});
