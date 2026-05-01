// Hecks UL Tagging — Accessibility from the Ubiquitous Language
//
// @domain Layout
//
// Reads data-domain tags from the DOM and populates aria-description
// and aria-label from the domain IR. The bluebook descriptions become
// screen reader announcements. No hand-written aria text needed.
//
// Usage: include this script, then call HecksAccessibility.sync(state)
// after domain state loads. State must have state.projects with domain
// aggregates that include description fields.
//

(function () {
  "use strict";

  function sync(state) {
    var descriptions = buildDescriptionMap(state);
    var els = document.querySelectorAll("[data-domain]");

    els.forEach(function (el) {
      var tag = el.dataset.domain;
      var aggName = tag.split(".")[0];
      var desc = descriptions[aggName];

      if (desc) {
        el.setAttribute("aria-description", desc);
      }
      if (!el.getAttribute("aria-label")) {
        el.setAttribute("aria-label", humanize(tag));
      }
    });
  }

  function buildDescriptionMap(state) {
    var map = {};
    if (!state || !state.projects) return map;

    state.projects.forEach(function (project) {
      (project.domains || []).forEach(function (domain) {
        (domain.aggregates || []).forEach(function (agg) {
          if (agg.description) map[agg.name] = agg.description;
        });
      });
    });

    return map;
  }

  function humanize(tag) {
    return tag
      .replace(/([A-Z])/g, " $1")
      .replace(/[._]/g, " ")
      .trim();
  }

  window.HecksAccessibility = { sync: sync };
})();
