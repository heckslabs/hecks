//! Project — emit a client-side app from domain IR using Alan's theme
//!
//! Uses the same html_shared::wrap_page as the serve command.
//! The look is identical to Alan's site — yellow brand, dark surface,
//! Roboto Slab, floating blobs. But the runtime is client-side
//! localStorage, not a server.
//!
//! Usage:
//!   hecks-life project pm.bluebook > index.html

use crate::ir::{Domain, Aggregate, Attribute};
use crate::server::html_shared::{wrap_page, display_name, module_icon, esc};

/// Project a domain to a self-contained app with Alan's theme.
pub fn project(domain: &Domain) -> String {
    let name = &domain.name;
    let aggs = &domain.aggregates;

    // Build sidebar
    let sidebar = build_sidebar(name, aggs);

    // Build main content — stats, content area, modals, script
    let main = build_main(domain);

    // Use wrap_page for Alan's theme
    let mut page = wrap_page(name, &sidebar, &main);

    // Inject our client-side runtime before </body>
    let script = format!("<script>\n{}\n</script>\n", emit_runtime(domain));

    // Inject modals before </body>
    let mut modals = String::new();
    for agg in aggs {
        modals.push_str(&emit_modal(agg));
    }
    modals.push_str(&emit_settings_modal());

    let inject = format!("{}\n{}", modals, script);
    page = page.replace("</body>", &format!("{}\n</body>", inject));

    page
}

fn build_sidebar(name: &str, aggs: &[Aggregate]) -> String {
    let mut s = String::new();

    // All issues link
    s.push_str(r#"<a onclick="setView('all')" data-view="all" class="flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium bg-brand/10 text-brand cursor-pointer">
  <span>☰</span> All
</a>"#);

    for agg in aggs {
        let aname = &agg.name;
        let snake = to_snake(aname);
        let icon = module_icon(aname);
        let label = display_name(aname);

        s.push_str(&format!(
            r#"<a onclick="setView('{snake}')" data-view="{snake}" class="flex items-center gap-3 px-3 py-2 rounded-lg text-sm text-gray-400 hover:bg-surface-2 hover:text-white cursor-pointer">
  <span>{icon}</span> {label}
</a>"#));

        // Sub-items for lifecycle states
        if let Some(ref lc) = agg.lifecycle {
            let states = lifecycle_states(lc);
            for st in &states {
                s.push_str(&format!(
                    r#"<a onclick="setView('{snake}:{st}')" data-view="{snake}:{st}" class="flex items-center gap-3 px-3 py-1.5 ml-6 rounded-lg text-xs text-gray-500 hover:bg-surface-2 hover:text-gray-300 cursor-pointer">
  {}</a>"#, humanize(st)));
            }
        }
    }

    // Settings
    s.push_str(r#"<div class="mt-4 pt-4 border-t border-surface-3">
<a onclick="document.getElementById('settings-modal').showModal()" class="flex items-center gap-3 px-3 py-2 rounded-lg text-sm text-gray-500 hover:bg-surface-2 hover:text-gray-300 cursor-pointer">
  <span>⚙</span> Settings
</a></div>"#);

    s
}

fn build_main(domain: &Domain) -> String {
    let name = &domain.name;
    let mut m = String::new();

    // Header with title and create button
    m.push_str(&format!(
        r#"<div class="flex items-center justify-between mb-6">
  <div>
    <h1 class="text-3xl font-bold text-brand" id="page-title">{name}</h1>
    <p class="text-gray-500 text-sm mt-1" id="page-subtitle">Dashboard</p>
  </div>
  <div class="flex items-center gap-3">
    <input type="text" id="search-box" placeholder="Search..." onkeyup="onSearch(this.value)" class="bg-surface-2 border border-surface-3 rounded-lg px-3 py-1.5 text-sm text-gray-300 w-48 focus:outline-none focus:border-brand">
    <button onclick="openCreate()" class="bg-brand hover:bg-brand-dim text-black px-4 py-2 rounded-lg text-sm font-bold">+ New</button>
  </div>
</div>"#));

    // Stats row
    m.push_str(r#"<div id="stats-row" class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6"></div>"#);

    // Filter bar
    m.push_str(r#"<div id="filter-bar" class="flex items-center gap-2 mb-4 flex-wrap"></div>"#);

    // Content area
    m.push_str(r#"<div id="content"></div>"#);

    // Empty state
    m.push_str(r#"<div id="empty-state" class="text-center py-20 hidden">
  <p class="text-gray-600 text-lg mb-4">Nothing here yet.</p>
  <button onclick="openCreate()" class="bg-brand hover:bg-brand-dim text-black px-6 py-2 rounded-lg font-bold">Create one</button>
</div>"#);

    // Toast
    m.push_str(r#"<div id="toast-container" class="fixed bottom-4 right-4 z-50 space-y-2"></div>"#);

    m
}

fn emit_modal(agg: &Aggregate) -> String {
    let aname = &agg.name;
    let snake = to_snake(aname);
    let label = display_name(aname);
    let mut m = String::new();

    m.push_str(&format!(r#"<dialog id="{snake}-dialog" style="background:#1a1a1a;color:#e5e5e5;border:1px solid #333;border-radius:12px;max-width:560px;width:90vw;padding:0">
<form method="dialog" onsubmit="save{aname}(event)" style="padding:24px">
<h3 style="font-family:'Roboto Slab',serif;font-size:1.25rem;font-weight:bold;color:#ffe400;margin-bottom:16px">{label}</h3>
<input type="hidden" name="id">
"#));

    for attr in useful_attrs(agg) {
        m.push_str(&emit_field(&attr, agg));
    }

    m.push_str(&format!(r#"<div style="display:flex;justify-content:space-between;align-items:center;margin-top:16px;padding-top:12px;border-top:1px solid #333">
<button type="button" id="{snake}-delete-btn" onclick="deleteRecord('{snake}')" style="color:#ef4444;background:none;border:none;font-size:13px;cursor:pointer;display:none">Delete</button>
<div style="display:flex;gap:8px">
<button type="button" onclick="this.closest('dialog').close()" style="color:#999;background:none;border:none;font-size:13px;cursor:pointer">Cancel</button>
<button type="submit" style="background:#ffe400;color:#111;border:none;padding:6px 16px;border-radius:8px;font-size:13px;font-weight:bold;cursor:pointer">Save</button>
</div></div></form>
<form method="dialog" style="position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:-1"><button style="display:block;width:100%;height:100%;opacity:0;cursor:default">close</button></form>
</dialog>
"#));
    m
}

fn emit_field(attr: &Attribute, agg: &Aggregate) -> String {
    let name = &attr.name;
    let label = humanize(name);
    let input_style = "width:100%;background:#111;border:1px solid #333;color:#e5e5e5;border-radius:6px;padding:6px 10px;font-size:13px;margin-top:4px";
    let mut f = String::new();

    f.push_str(&format!(r#"<div style="margin-bottom:12px">
<label style="font-size:11px;color:#999;text-transform:uppercase;letter-spacing:.05em">{label}</label><br>
"#));

    // Lifecycle field → select with states
    if let Some(ref lc) = agg.lifecycle {
        if lc.field == *name {
            f.push_str(&format!(r#"<select name="{name}" style="{input_style}">"#));
            for st in lifecycle_states(lc) {
                f.push_str(&format!(r#"<option value="{st}">{}</option>"#, humanize(&st)));
            }
            f.push_str("</select>\n</div>\n");
            return f;
        }
    }

    // Enum → select
    if attr.attr_type.contains('|') {
        let opts: Vec<&str> = attr.attr_type.split('|').map(|s| s.trim().trim_matches('"')).collect();
        f.push_str(&format!(r#"<select name="{name}" style="{input_style}"><option value="">—</option>"#));
        for o in &opts {
            f.push_str(&format!(r#"<option value="{o}">{}</option>"#, humanize(o)));
        }
        f.push_str("</select>\n");
    } else if attr.list {
        f.push_str(&format!(r#"<input name="{name}" placeholder="comma separated" style="{input_style}">"#));
    } else {
        match attr.attr_type.as_str() {
            "Integer" | "int" | "Float" | "float" => {
                let step = if attr.attr_type.contains("Float") { " step=\"0.01\"" } else { "" };
                f.push_str(&format!(r#"<input name="{name}" type="number"{step} style="{input_style}">"#));
            }
            "Boolean" | "bool" => {
                f.push_str(&format!(r#"<input name="{name}" type="checkbox" style="accent-color:#ffe400">"#));
            }
            "Date" | "date" => {
                f.push_str(&format!(r#"<input name="{name}" type="date" style="{input_style}">"#));
            }
            _ => {
                if name.contains("description") || name.contains("notes") || name.contains("body") {
                    f.push_str(&format!(r#"<textarea name="{name}" rows="3" style="{input_style}"></textarea>"#));
                } else {
                    let req = if name == "title" || name == "name" { " required" } else { "" };
                    f.push_str(&format!(r#"<input name="{name}"{req} style="{input_style}">"#));
                }
            }
        }
    }
    f.push_str("\n</div>\n");
    f
}

fn emit_settings_modal() -> String {
    r#"<dialog id="settings-modal" style="background:#1a1a1a;color:#e5e5e5;border:1px solid #333;border-radius:12px;max-width:400px;padding:24px">
<h3 style="font-family:'Roboto Slab',serif;font-size:1.25rem;font-weight:bold;color:#ffe400;margin-bottom:16px">Settings</h3>
<p style="color:#666;font-size:13px;margin-bottom:16px">Data is stored in your browser's localStorage.</p>
<div style="display:flex;gap:8px">
<button onclick="if(confirm('Reset all data?')){localStorage.clear();location.reload()}" style="background:#ef4444;color:white;border:none;padding:6px 12px;border-radius:6px;font-size:13px;cursor:pointer">Reset All Data</button>
<button onclick="this.closest('dialog').close()" style="color:#999;background:none;border:none;font-size:13px;cursor:pointer">Close</button>
</div>
<form method="dialog" style="position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:-1"><button style="display:block;width:100%;height:100%;opacity:0">close</button></form>
</dialog>"#.into()
}

fn emit_runtime(domain: &Domain) -> String {
    let aggs = &domain.aggregates;
    let mut js = String::new();

    // Storage
    js.push_str("// === Storage ===\n");
    for agg in aggs {
        js.push_str(&format!("const SK_{} = 'app_{}';\n", to_snake(&agg.name).to_uppercase(), to_snake(&agg.name)));
    }
    js.push_str("let COUNTER=parseInt(localStorage.getItem('_counter')||'0');\n");
    js.push_str("function nextId(p){COUNTER++;localStorage.setItem('_counter',COUNTER.toString());return p+'-'+COUNTER;}\n");
    js.push_str("function ld(k){return JSON.parse(localStorage.getItem(k)||'[]');}\n");
    js.push_str("function sv(k,v){localStorage.setItem(k,JSON.stringify(v));}\n\n");

    // Transitions
    for agg in aggs {
        if let Some(ref lc) = agg.lifecycle {
            let su = to_snake(&agg.name).to_uppercase();
            js.push_str(&format!("const TR_{}={{\n", su));
            for t in &lc.transitions {
                let from = if let Some(ref f) = t.from_state {
                    format!("[{}]", f.split(',').map(|s| format!("'{}'", s.trim())).collect::<Vec<_>>().join(","))
                } else { "['*']".into() };
                js.push_str(&format!("'{}':{{from:{},to:'{}'}},\n", t.command, from, t.to_state));
            }
            js.push_str("};\n");
        }
    }
    js.push_str("\nlet currentView='all',searchQuery='';\n\n");

    // Save per aggregate
    for agg in aggs {
        let a = &agg.name;
        let sk = format!("SK_{}", to_snake(a).to_uppercase());
        let sn = to_snake(a);
        js.push_str(&format!("function save{a}(e){{e.preventDefault();const fd=new FormData(e.target),items=ld({sk}),id=fd.get('id'),now=new Date().toISOString();\n"));
        js.push_str("const obj={");
        for attr in useful_attrs(agg) {
            let n = &attr.name;
            if attr.list { js.push_str(&format!("{n}:fd.get('{n}')?fd.get('{n}').split(',').map(s=>s.trim()).filter(Boolean):[],"));
            } else if attr.attr_type == "Integer" || attr.attr_type == "Float" { js.push_str(&format!("{n}:fd.get('{n}')?parseFloat(fd.get('{n}')):null,"));
            } else { js.push_str(&format!("{n}:fd.get('{n}')||null,")); }
        }
        js.push_str("};\n");
        js.push_str("if(id){const it=items.find(i=>i.id===id);if(it){Object.assign(it,obj);it.updated_at=now;}}\n");
        js.push_str(&format!("else{{obj.id=crypto.randomUUID();obj.identifier=nextId('{}');", abbreviate(a)));
        if let Some(ref lc) = agg.lifecycle {
            js.push_str(&format!("if(!obj.{})obj.{}='{}';", lc.field, lc.field, lc.default));
        }
        js.push_str("obj.created_at=now;obj.updated_at=now;items.unshift(obj);}\n");
        js.push_str(&format!("sv({sk},items);document.getElementById('{sn}-dialog').close();toast('Saved');render();}}\n\n"));
    }

    // Delete
    js.push_str("function deleteRecord(s){");
    for agg in aggs {
        let sn = to_snake(&agg.name);
        let sk = format!("SK_{}", sn.to_uppercase());
        js.push_str(&format!("if(s==='{sn}'){{const d=document.getElementById('{sn}-dialog'),id=d.querySelector('[name=id]').value;if(!id||!confirm('Delete?'))return;sv({sk},ld({sk}).filter(i=>i.id!==id));d.close();toast('Deleted');render();return;}}"));
    }
    js.push_str("}\n\n");

    // Transition
    js.push_str("function transition(s,id,cmd){");
    for agg in aggs {
        if let Some(ref lc) = agg.lifecycle {
            let sn = to_snake(&agg.name);
            let su = sn.to_uppercase();
            let f = &lc.field;
            js.push_str(&format!("if(s==='{sn}'){{const t=TR_{su}[cmd],items=ld(SK_{su}),it=items.find(i=>i.id===id);if(!it||!t)return;if(!t.from.includes('*')&&!t.from.includes(it.{f}))return;it.{f}=t.to;it.updated_at=new Date().toISOString();sv(SK_{su},items);render();return;}}"));
        }
    }
    js.push_str("}\n\n");

    // Open create
    js.push_str("function openCreate(){const v=currentView.split(':')[0];\n");
    for (i, agg) in aggs.iter().enumerate() {
        let sn = to_snake(&agg.name);
        let cond = if i == 0 { format!("if(v==='all'||v==='{sn}')") } else { format!("else if(v==='{sn}')") };
        js.push_str(&format!("{cond}{{const d=document.getElementById('{sn}-dialog');d.querySelector('form').reset();d.querySelector('[name=id]').value='';document.getElementById('{sn}-delete-btn').style.display='none';d.showModal();}}\n"));
    }
    js.push_str("}\n\n");

    // Open edit
    for agg in aggs {
        let a = &agg.name;
        let sn = to_snake(a);
        let sk = format!("SK_{}", sn.to_uppercase());
        js.push_str(&format!("function openEdit{a}(id){{const items=ld({sk}),it=items.find(i=>i.id===id);if(!it)return;const d=document.getElementById('{sn}-dialog');d.querySelector('[name=id]').value=it.id;\n"));
        for attr in useful_attrs(agg) {
            let n = &attr.name;
            if attr.list { js.push_str(&format!("d.querySelector('[name={n}]').value=(it.{n}||[]).join(', ');\n"));
            } else { js.push_str(&format!("{{const el=d.querySelector('[name={n}]');if(el){{if(el.type==='checkbox')el.checked=!!it.{n};else el.value=it.{n}||'';}}}}\n")); }
        }
        js.push_str(&format!("document.getElementById('{sn}-delete-btn').style.display='';d.showModal();}}\n\n"));
    }

    // View
    js.push_str("function setView(v){currentView=v;document.querySelectorAll('[data-view]').forEach(el=>{el.className=el.className.replace(/bg-brand\\/10 text-brand/g,'text-gray-400').replace('text-brand','text-gray-400');});const m=document.querySelector('[data-view=\"'+v+'\"]');if(m){m.className=m.className.replace('text-gray-400','bg-brand/10 text-brand');}render();}\n\n");
    js.push_str("function onSearch(q){searchQuery=q.toLowerCase();render();}\n\n");

    // Toast
    js.push_str("function toast(msg){const c=document.getElementById('toast-container'),t=document.createElement('div');t.style.cssText='background:#ffe400;color:#111;padding:8px 16px;border-radius:8px;font-size:13px;font-weight:bold';t.textContent=msg;c.appendChild(t);setTimeout(()=>t.remove(),2000);}\n\n");

    // Status colors
    js.push_str("function stColor(s){return{done:'#22c55e',completed:'#22c55e',cancelled:'#ef4444',in_progress:'#f59e0b',active:'#f59e0b',in_review:'#8b5cf6',todo:'#3b82f6',upcoming:'#6b7280',backlog:'#555',paused:'#6b7280'}[s]||'#555';}\n\n");

    // Render
    js.push_str("function render(){\n");

    // Stats
    js.push_str("let sh='';\n");
    for agg in aggs {
        let sn = to_snake(&agg.name);
        let su = sn.to_uppercase();
        let label = display_name(&agg.name);
        js.push_str(&format!("sh+='<div class=\"bg-surface-2 rounded-xl p-4 border border-surface-3\"><p class=\"text-xs text-gray-500 uppercase\">{label}</p><p class=\"text-2xl font-bold text-brand\">'+ld(SK_{su}).length+'</p></div>';\n"));
    }
    js.push_str("document.getElementById('stats-row').innerHTML=sh;\n\n");

    js.push_str("const[va,vf]=currentView.split(':');\n");
    js.push_str("document.getElementById('page-subtitle').textContent=va==='all'?'All':va.replace(/_/g,' ');\n");
    js.push_str("let html='';\n");

    for agg in aggs {
        let a = &agg.name;
        let sn = to_snake(a);
        let su = sn.to_uppercase();
        let lf = agg.lifecycle.as_ref().map(|l| l.field.clone());
        let label = display_name(a);
        let cols = display_columns(agg);

        js.push_str(&format!("if(va==='all'||va==='{sn}'){{\nlet items=ld(SK_{su});\n"));
        if let Some(ref f) = lf { js.push_str(&format!("if(vf)items=items.filter(i=>i.{f}===vf);\n")); }
        js.push_str("if(searchQuery)items=items.filter(i=>JSON.stringify(i).toLowerCase().includes(searchQuery));\n");
        js.push_str(&format!("if(va!=='all'||items.length>0){{\nhtml+='<h2 class=\"text-sm font-bold text-gray-400 uppercase tracking-wider mb-3 mt-6\">{label}</h2>';\n"));

        // Table
        js.push_str("html+='<div class=\"bg-surface-1 rounded-xl border border-surface-3 overflow-hidden\"><table style=\"width:100%;border-collapse:collapse\"><thead><tr style=\"border-bottom:1px solid #333\">';\n");
        if lf.is_some() { js.push_str("html+='<th style=\"padding:8px 12px;text-align:left;font-size:11px;color:#666;width:100px\">Status</th>';\n"); }
        js.push_str("html+='<th style=\"padding:8px 12px;text-align:left;font-size:11px;color:#666;width:60px\">ID</th>';\n");
        for col in &cols {
            js.push_str(&format!("html+='<th style=\"padding:8px 12px;text-align:left;font-size:11px;color:#666\">{}</th>';\n", humanize(col)));
        }
        js.push_str("html+='<th style=\"width:40px\"></th></tr></thead><tbody>';\n");

        // Rows
        js.push_str(&format!("for(const it of items){{html+='<tr style=\"border-bottom:1px solid #222;cursor:pointer\" onmouseover=\"this.style.background=\\'#1f1f1f\\'\" onmouseout=\"this.style.background=\\'\\'\" onclick=\"openEdit{a}(\\\"'+it.id+'\\\")\">'+\n"));

        if let Some(ref f) = lf {
            js.push_str(&format!("'<td style=\"padding:8px 12px\"><span style=\"display:inline-block;padding:2px 8px;border-radius:9999px;font-size:11px;font-weight:600;background:'+stColor(it.{f})+'20;color:'+stColor(it.{f})+'\">'+(it.{f}||'').replace(/_/g,' ')+'</span></td>'+\n"));
        }
        js.push_str("'<td style=\"padding:8px 12px;font-size:11px;color:#555\">'+(it.identifier||'')+'</td>'+\n");

        for col in &cols {
            let is_list = agg.attributes.iter().any(|a| a.name == *col && a.list);
            let is_enum = agg.attributes.iter().any(|a| a.name == *col && a.attr_type.contains('|'));
            if is_list {
                js.push_str(&format!("'<td style=\"padding:8px 12px;font-size:13px\">'+(it.{col}||[]).map(t=>'<span style=\"display:inline-block;background:#333;color:#ccc;padding:1px 6px;border-radius:9999px;font-size:10px;margin-right:4px\">'+t+'</span>').join('')+'</td>'+\n"));
            } else if is_enum {
                js.push_str(&format!("'<td style=\"padding:8px 12px;font-size:13px\"><span style=\"background:#333;color:#ccc;padding:2px 8px;border-radius:9999px;font-size:11px\">'+(it.{col}||'—')+'</span></td>'+\n"));
            } else {
                js.push_str(&format!("'<td style=\"padding:8px 12px;font-size:13px;color:#e5e5e5\">'+esc(it.{col}||'')+'</td>'+\n"));
            }
        }

        // Dropdown actions
        js.push_str("'<td style=\"padding:8px 12px;text-align:right;position:relative\"><button onclick=\"event.stopPropagation();toggleMenu(this)\" style=\"background:none;border:none;color:#666;cursor:pointer;font-size:16px\">⋯</button>");
        js.push_str("<div class=\"action-menu\" style=\"display:none;position:absolute;right:12px;top:100%;background:#222;border:1px solid #333;border-radius:8px;padding:4px;z-index:50;min-width:160px\">';\n");

        if let Some(ref lc) = agg.lifecycle {
            for t in &lc.transitions {
                js.push_str(&format!(
                    "html+='<div onclick=\"event.stopPropagation();transition(\\'{}\\',\\''+it.id+'\\',\\'{}\\');closeMenus()\" style=\"padding:6px 12px;font-size:12px;color:#ccc;cursor:pointer;border-radius:4px\" onmouseover=\"this.style.background=\\'#333\\'\" onmouseout=\"this.style.background=\\'\\'\">{}</div>';\n",
                    sn, t.command, humanize(&t.command)
                ));
            }
        }
        js.push_str(&format!("html+='<div onclick=\"event.stopPropagation();deleteRecord(\\'{}\\');closeMenus()\" style=\"padding:6px 12px;font-size:12px;color:#ef4444;cursor:pointer;border-radius:4px\" onmouseover=\"this.style.background=\\'#333\\'\" onmouseout=\"this.style.background=\\'\\'\" >Delete</div>';\n", sn));
        js.push_str("html+='</div></td></tr>';}\n");
        js.push_str("html+='</tbody></table></div>';}}\n}}\n");
    }

    js.push_str("document.getElementById('content').innerHTML=html;\n");
    js.push_str("document.getElementById('empty-state').style.display=html?'none':'block';\n");
    js.push_str("}\n\n");

    // Menu toggle
    js.push_str("function toggleMenu(btn){closeMenus();const m=btn.nextElementSibling;m.style.display=m.style.display==='none'?'block':'none';}\nfunction closeMenus(){document.querySelectorAll('.action-menu').forEach(m=>m.style.display='none');}\ndocument.addEventListener('click',closeMenus);\n\n");

    // Escape
    js.push_str("function esc(s){const d=document.createElement('div');d.textContent=s||'';return d.innerHTML;}\n\n");

    // Keyboard
    js.push_str("document.addEventListener('keydown',e=>{if(e.target.tagName==='INPUT'||e.target.tagName==='TEXTAREA'||e.target.tagName==='SELECT')return;if(e.key==='c')openCreate();if(e.key==='/'){e.preventDefault();document.getElementById('search-box').focus();}});\n\n");

    // Seed
    js.push_str(&emit_seed(domain));

    // Boot
    js.push_str("seed();render();\n");
    js
}

fn emit_seed(domain: &Domain) -> String {
    let mut js = String::new();
    js.push_str("function seed(){\n");
    if let Some(first) = domain.aggregates.first() {
        js.push_str(&format!("if(ld('app_{}').length>0)return;\n", to_snake(&first.name)));
    }
    for agg in &domain.aggregates {
        let fixes: Vec<_> = domain.fixtures.iter().filter(|f| f.aggregate_name == agg.name).collect();
        if fixes.is_empty() { continue; }
        let sn = to_snake(&agg.name);
        js.push_str(&format!("const s_{}=[\n", sn));
        for fix in &fixes {
            js.push_str("{");
            js.push_str(&format!("id:crypto.randomUUID(),identifier:nextId('{}'),", abbreviate(&agg.name)));
            for (k, v) in &fix.attributes { js.push_str(&format!("{}:{},", k, fixture_value(v))); }
            js.push_str("created_at:new Date().toISOString(),updated_at:new Date().toISOString()},\n");
        }
        js.push_str(&format!("];\nsv('app_{sn}',s_{sn});\n"));
    }
    js.push_str("}\n\n");
    js
}

// === Helpers ===

fn to_snake(name: &str) -> String {
    let mut s = String::new();
    for (i, c) in name.chars().enumerate() {
        if c.is_uppercase() && i > 0 { s.push('_'); }
        s.push(c.to_lowercase().next().unwrap_or(c));
    }
    s
}

fn humanize(s: &str) -> String {
    s.replace('_', " ").split(' ').map(|w| {
        let mut c = w.chars();
        match c.next() { Some(f) => f.to_uppercase().to_string() + c.as_str(), None => String::new() }
    }).collect::<Vec<_>>().join(" ")
}

fn abbreviate(name: &str) -> String {
    name.chars().filter(|c| c.is_uppercase()).collect::<String>().to_uppercase()
}

fn lifecycle_states(lc: &crate::ir::Lifecycle) -> Vec<String> {
    let mut states = vec![lc.default.clone()];
    for t in &lc.transitions { if !states.contains(&t.to_state) { states.push(t.to_state.clone()); } }
    states
}

fn useful_attrs(agg: &Aggregate) -> Vec<Attribute> {
    agg.attributes.iter()
        .filter(|a| !matches!(a.name.as_str(), "id"|"identifier"|"created_at"|"updated_at"|"sort_order"|"created_by"))
        .cloned().collect()
}

fn display_columns(agg: &Aggregate) -> Vec<String> {
    let skip = ["id","identifier","created_at","updated_at","sort_order","created_by","parent_id"];
    let lf = agg.lifecycle.as_ref().map(|l| l.field.as_str());
    agg.attributes.iter()
        .filter(|a| !skip.contains(&a.name.as_str()))
        .filter(|a| lf.map_or(true, |f| a.name != f))
        .take(5).map(|a| a.name.clone()).collect()
}

fn fixture_value(v: &str) -> String {
    if v.starts_with('[') || v.starts_with('{') { return v.to_string(); }
    if v == "true" || v == "false" { return v.to_string(); }
    if v.parse::<f64>().is_ok() { return v.to_string(); }
    format!("'{}'", v.replace('\'', "\\'"))
}
