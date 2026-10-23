// The page's behaviours: draw the diagrams, find a term, keep the rail
// pointing at the section in view, and let a reviewer tick each rule and
// term as checked. Ticks stay in this browser only; nothing here changes
// what the page says, which is all in the Markdown it was rendered from.
(function () {
  var root = document.documentElement;
  var dark = root.dataset.theme === "dark" ||
    (root.dataset.theme !== "light" && window.matchMedia("(prefers-color-scheme: dark)").matches);

  if (window.mermaid) {
    mermaid.initialize({
      startOnLoad: true,
      theme: dark ? "dark" : "neutral",
      fontFamily: "\"Instrument Sans\", system-ui, sans-serif",
      flowchart: { curve: "basis", padding: 12 }
    });
  }

  var input = document.querySelector(".rail input");
  var count = document.querySelector(".rail .count");
  var progress = document.querySelector(".rail .progress");
  var terms = Array.prototype.slice.call(document.querySelectorAll(".term"));
  var sections = Array.prototype.slice.call(document.querySelectorAll("main section"));
  var links = {};
  Array.prototype.forEach.call(document.querySelectorAll(".rail a"), function (a) {
    links[a.getAttribute("href").slice(1)] = a;
  });

  // Ticks are kept per page, keyed by the section and the text ticked.
  var storeKey = "glossary-ticks:" + document.title;
  var ticked = {};
  try { ticked = JSON.parse(window.localStorage.getItem(storeKey) || "{}") || {}; } catch (e) { ticked = {}; }

  function save() {
    try { window.localStorage.setItem(storeKey, JSON.stringify(ticked)); } catch (e) { /* not kept */ }
  }

  var ticks = [];

  function addTick(holder, before, key, label) {
    var box = document.createElement("input");
    box.type = "checkbox";
    box.className = "tick";
    box.setAttribute("aria-label", "Checked: " + label);
    box.checked = !!ticked[key];
    holder.classList.toggle("done", box.checked);
    box.addEventListener("change", function () {
      if (box.checked) { ticked[key] = true; } else { delete ticked[key]; }
      holder.classList.toggle("done", box.checked);
      save();
      tally();
    });
    before.parentNode.insertBefore(box, before);
    ticks.push(box);
  }

  sections.forEach(function (section) {
    Array.prototype.forEach.call(section.querySelectorAll(".rules li"), function (li) {
      var text = li.textContent.trim();
      var span = document.createElement("span");
      while (li.firstChild) span.appendChild(li.firstChild);
      li.appendChild(span);
      addTick(li, span, section.id + "|" + text, text);
    });
  });

  terms.forEach(function (term) {
    var heading = term.querySelector("h4");
    var text = heading.textContent.trim();
    var label = document.createElement("label");
    var span = document.createElement("span");
    span.textContent = text;
    heading.textContent = "";
    label.appendChild(span);
    heading.appendChild(label);
    addTick(term, span, "term|" + term.id, text);
  });

  function tally() {
    var done = ticks.filter(function (box) { return box.checked; }).length;
    progress.hidden = ticks.length === 0;
    progress.textContent = done + " of " + ticks.length + " checked";
  }

  tally();

  function filter() {
    var query = input.value.trim().toLowerCase();
    var shown = 0;
    terms.forEach(function (term) {
      var hit = !query || term.textContent.toLowerCase().indexOf(query) !== -1;
      term.hidden = !hit;
      if (hit) shown += 1;
    });
    sections.forEach(function (section) {
      var any = Array.prototype.some.call(section.querySelectorAll(".term"), function (t) { return !t.hidden; });
      section.hidden = !!query && !any;
      section.classList.toggle("searching", !!query);
      var link = links[section.id];
      if (link) link.parentNode.hidden = section.hidden;
    });
    count.textContent = query ? shown + " of " + terms.length + " terms" : terms.length + " terms";
  }

  input.addEventListener("input", filter);
  filter();

  if ("IntersectionObserver" in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        Object.keys(links).forEach(function (id) { links[id].removeAttribute("aria-current"); });
        var link = links[entry.target.id];
        if (link) link.setAttribute("aria-current", "true");
      });
    }, { rootMargin: "-8% 0px -82% 0px" });
    sections.forEach(function (section) { observer.observe(section); });
  }

  // A link inside a definition lands on a term; a search in progress
  // would hide it, so the search is cleared first.
  document.addEventListener("click", function (event) {
    var a = event.target.closest && event.target.closest("a[href^='#']");
    if (!a) return;
    var target = document.getElementById(a.getAttribute("href").slice(1));
    if (!target) return;
    if (input.value) { input.value = ""; filter(); }
    target.classList.remove("landed");
    void target.offsetWidth;
    target.classList.add("landed");
  });
})();
