// The page's three behaviours: draw the diagrams, find a term, and
// keep the rail pointing at the section in view. Nothing here changes
// what the page says — that is all in the Markdown it was rendered from.
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
  var terms = Array.prototype.slice.call(document.querySelectorAll(".term"));
  var sections = Array.prototype.slice.call(document.querySelectorAll("main section"));
  var links = {};
  Array.prototype.forEach.call(document.querySelectorAll(".rail a"), function (a) {
    links[a.getAttribute("href").slice(1)] = a;
  });

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
