/* ── Bluebook/application explorer panel ── */

async function loadBluebooks() {
  try {
    const r = await fetch('/bluebooks');
    const d = await r.json();
    const body = document.getElementById('apps-body');
    if (!d.apps?.length) {
      body.innerHTML = '<span class="tool-empty">No applications found.</span>';
      return;
    }

    const groups = {};
    d.apps.forEach(app => {
      const key = app.group || app.path.replace(/\/[^/]+$/, '') || '_root';
      (groups[key] ||= []).push(app);
    });

    let html = '';
    for (const [group, apps] of Object.entries(groups)) {
      if (apps.length === 1) {
        html += renderSingleApp(apps[0]);
      } else {
        html += renderMultiApp(group, apps);
      }
    }
    body.innerHTML = html;
  } catch (e) {
    document.getElementById('apps-body').textContent = 'Failed to load.';
  }
}

function renderSingleApp(app) {
  const id = app.path.replace(/[^a-zA-Z0-9]/g, '_');
  let html = `<div class="mb-1.5">`;
  html += `<div class="text-fg font-semibold cursor-pointer flex items-center gap-1 py-px hover:text-accent-red" onclick="toggleBookAggs('${id}')">`;
  html += `<span class="book-chevron" id="chev-${id}">&#9654;</span> ${IDE.esc(app.name)}</div>`;
  html += `<div class="book-aggs collapsed" id="aggs-${id}">`;
  html += `<a class="block text-fg no-underline py-px whitespace-nowrap overflow-hidden text-ellipsis cursor-pointer hover:text-accent-blue" onclick="openWorkshop('${app.path}','${IDE.esc(app.name)}')" style="color:var(--blue)">Bluebook</a>`;
  if (app.hecksagon) {
    html += `<a class="block text-fg no-underline py-px whitespace-nowrap overflow-hidden text-ellipsis cursor-pointer hover:text-accent-blue" onclick="openHecksagon('${app.hecksagon}')" style="color:var(--yellow)">Hecksagon</a>`;
  }
  html += `</div></div>`;
  return html;
}

function renderMultiApp(group, apps) {
  const gid = group.replace(/[^a-zA-Z0-9]/g, '_');
  const label = group.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
  let html = `<div class="mb-1.5">`;
  html += `<div class="text-fg font-semibold cursor-pointer flex items-center gap-1 py-px hover:text-accent-red" onclick="toggleBookAggs('g_${gid}')">`;
  html += `<span class="book-chevron" id="chev-g_${gid}">&#9654;</span> ${IDE.esc(label)}</div>`;
  html += `<div class="book-aggs collapsed" id="aggs-g_${gid}">`;
  html += `<div class="text-fg font-semibold cursor-pointer flex items-center gap-1 py-px hover:text-accent-red" onclick="toggleBookAggs('bb_${gid}')" style="color:var(--blue)">`;
  html += `<span class="book-chevron" id="chev-bb_${gid}">&#9654;</span> Bluebooks</div>`;
  html += `<div class="book-aggs collapsed" id="aggs-bb_${gid}">`;
  apps.forEach(app => {
    html += `<a class="block text-fg no-underline py-px whitespace-nowrap overflow-hidden text-ellipsis cursor-pointer hover:text-accent-blue" onclick="openWorkshop('${app.path}','${IDE.esc(app.name)}')" style="padding-left:8px">${IDE.esc(app.name)}</a>`;
  });
  html += `</div></div></div>`;
  return html;
}
