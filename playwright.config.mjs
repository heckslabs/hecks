import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./test",
  testMatch: "appeal_ui_test.mjs",
  timeout: 30000,
  use: {
    baseURL: "http://localhost:4567",
    headless: true,
  },
});
