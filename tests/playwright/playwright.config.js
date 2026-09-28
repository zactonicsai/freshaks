// Playwright settings. The Job in k8s/tests/playwright-job.yaml copies this folder into
// the mcr.microsoft.com/playwright image (browsers already installed) and runs "npx playwright test".
// @ts-check
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: '.',
  testMatch: /.*\.spec\.js/,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  retries: process.env.CI ? 1 : 0,
  workers: 1,                       // one robot at a time keeps the demo cluster calm
  reporter: process.env.CI ? 'list' : 'html',
  use: {
    headless: true,
    ignoreHTTPSErrors: true,        // nip.io + self-signed certs are fine for a demo
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
});
