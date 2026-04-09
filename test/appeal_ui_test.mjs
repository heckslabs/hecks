// HecksAppeal UI Integration Test
//
// Tests dispatch domain commands and verify state via data-domain-*
// HTML attributes that mirror the domain state. Also checks streamed
// screenshots in /tmp/appeal_screenshots/.
//
// Domain attributes on #ide:
//   data-domain-layout-sidebar="open|collapsed"
//   data-domain-layout-events="open|collapsed"
//   data-domain-layout-tab="editor|diagrams|console|..."
//   data-domain-search-query="..."
//   data-domain-diagram-loaded="true|false"
//
//   npx playwright test --config=playwright.config.mjs
//
import { test, expect } from "@playwright/test";
import { readdirSync } from "fs";

const BASE = "http://localhost:4567";
const SCREENSHOTS = "/tmp/appeal_screenshots";

function dispatch(page, aggregate, command, args) {
  return page.evaluate(
    ([agg, cmd, a]) => {
      if (window.HecksWebClientState && window.HecksWebClientState.dispatch) {
        return window.HecksWebClientState.dispatch(agg, cmd, a || {});
      } else if (window.Hecks && window.Hecks.dispatch) {
        return window.Hecks.dispatch(agg, cmd, a || {});
      }
    },
    [aggregate, command, args || {}]
  );
}

function ide(page) {
  return page.locator("#ide");
}

test.describe("HecksAppeal UI", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(BASE);
    await page.evaluate(() => localStorage.clear());
    await page.reload();
    await page.waitForFunction(() => window.HecksApp && window.HecksApp.state);
    await page.waitForTimeout(3500);
  });

  test("page loads with domain attributes set", async ({ page }) => {
    await expect(ide(page)).toHaveAttribute(
      "data-domain-layout-sidebar",
      "open"
    );
    await expect(ide(page)).toHaveAttribute(
      "data-domain-layout-events",
      "open"
    );
  });

  test("Layout.ToggleSidebar toggles data-domain-layout-sidebar", async ({
    page,
  }) => {
    await dispatch(page, "Layout", "ToggleSidebar");
    await expect(ide(page)).toHaveAttribute(
      "data-domain-layout-sidebar",
      "collapsed"
    );

    await dispatch(page, "Layout", "ToggleSidebar");
    await expect(ide(page)).toHaveAttribute(
      "data-domain-layout-sidebar",
      "open"
    );
  });

  test("Layout.ToggleEventsPanel toggles data-domain-layout-events", async ({
    page,
  }) => {
    await dispatch(page, "Layout", "ToggleEventsPanel");
    await expect(ide(page)).toHaveAttribute(
      "data-domain-layout-events",
      "collapsed"
    );

    await dispatch(page, "Layout", "ToggleEventsPanel");
    await expect(ide(page)).toHaveAttribute(
      "data-domain-layout-events",
      "open"
    );
  });

  test("Layout.SelectTab updates data-domain-layout-tab", async ({ page }) => {
    await dispatch(page, "Layout", "SelectTab", { tab_name: "diagrams" });
    await expect(ide(page)).toHaveAttribute(
      "data-domain-layout-tab",
      "diagrams"
    );

    await dispatch(page, "Layout", "SelectTab", { tab_name: "console" });
    await expect(ide(page)).toHaveAttribute(
      "data-domain-layout-tab",
      "console"
    );

    await dispatch(page, "Layout", "SelectTab", { tab_name: "editor" });
    await expect(ide(page)).toHaveAttribute(
      "data-domain-layout-tab",
      "editor"
    );
  });

  test("Diagram.GenerateOverview sets data-domain-diagram-loaded", async ({
    page,
  }) => {
    await dispatch(page, "Diagram", "GenerateOverview");
    await expect(ide(page)).toHaveAttribute(
      "data-domain-diagram-loaded",
      "true",
      { timeout: 5000 }
    );
  });

  test("Search.SearchDomain updates data-domain-search-query", async ({
    page,
  }) => {
    await dispatch(page, "Search", "SearchDomain", { query: "Pizza" });
    await expect(ide(page)).toHaveAttribute(
      "data-domain-search-query",
      "Pizza",
      { timeout: 3000 }
    );

    await dispatch(page, "Search", "ClearSearch");
    await expect(ide(page)).toHaveAttribute("data-domain-search-query", "");
  });

  test("screenshots stream every second", async ({ page }) => {
    const before = readdirSync(SCREENSHOTS).filter((f) =>
      f.startsWith("snapshot_")
    ).length;
    await page.waitForTimeout(2500);
    const after = readdirSync(SCREENSHOTS).filter((f) =>
      f.startsWith("snapshot_")
    ).length;
    expect(after - before).toBeGreaterThanOrEqual(2);
  });

  test("events are recorded with bluebook names", async ({ page }) => {
    await dispatch(page, "Layout", "ToggleSidebar");
    await page.waitForTimeout(300);
    const events = await page.evaluate(() => window.HecksApp.state.events);
    expect(events.map((e) => e.event)).toContain("SidebarToggled");

    await dispatch(page, "Layout", "SelectTab", { tab_name: "console" });
    await page.waitForTimeout(300);
    const events2 = await page.evaluate(() => window.HecksApp.state.events);
    expect(events2.map((e) => e.event)).toContain("TabSelected");
  });
});
