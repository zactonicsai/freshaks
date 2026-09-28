// The Playwright inspector: a robot that opens a real browser, logs in at the Keycloak
// front office as each demo person, and checks which doors open in BOTH apps.
//
// Needs (from k8s/tests/test-config.yaml): JAVA_URL, PYTHON_URL, DEMO_USER_PASSWORD
// Run on your laptop:  cd tests/playwright && npm install && npx playwright install chromium
//                      JAVA_URL=... PYTHON_URL=... DEMO_USER_PASSWORD=... npx playwright test
const { test, expect } = require('@playwright/test');

const JAVA = (process.env.JAVA_URL || 'http://localhost:8080').replace(/\/$/, '');
const PYTHON = (process.env.PYTHON_URL || 'http://localhost:5000').replace(/\/$/, '');
const PASSWORD = process.env.DEMO_USER_PASSWORD || 'password123';

/** Fill in the Keycloak login form (it appears after the app redirects us to the front office). */
async function keycloakLogin(page, username) {
  await expect(page.locator('#kc-login')).toBeVisible();
  await page.fill('#username', username);
  await page.fill('#password', PASSWORD);
  await page.click('#kc-login');
}

/** Open a Java-store page; log in through Keycloak if the store sends us there. */
async function openJava(page, path, username) {
  await page.goto(JAVA + path);
  if (page.url().includes('/realms/')) {
    await keycloakLogin(page, username);
  }
  await page.waitForURL(url => !url.toString().includes('/realms/'));
}

/** Same for the Python deli. */
async function openPython(page, path, username) {
  await page.goto(PYTHON + path);
  if (page.url().includes('/realms/')) {
    await keycloakLogin(page, username);
  }
  await page.waitForURL(url => !url.toString().includes('/realms/'));
}

test.describe('Java store (Spring Boot)', () => {
  test('front page is public and offers a login link', async ({ page }) => {
    await page.goto(JAVA + '/');
    await expect(page.locator('h1')).toContainText('Fresh Mart');
    await expect(page.locator('#login-link')).toBeVisible();
  });

  test('sam.shopper gets a shopper badge and cannot enter the office', async ({ page }) => {
    await openJava(page, '/app/me.html', 'sam.shopper');
    await expect(page.locator('#badge-username')).toHaveText('sam.shopper');
    await expect(page.locator('[data-testid="role-badge"]')).toContainText(['shopper']);
    await page.goto(JAVA + '/app/office.html');
    await expect(page).toHaveURL(/forbidden\.html/);
    await expect(page.locator('h1')).toContainText('different badge');
  });

  test('sam.shopper can place an order', async ({ page }) => {
    await openJava(page, '/app/shop.html', 'sam.shopper');
    await expect(page.locator('[data-testid="product-card"]').first()).toBeVisible();
    await page.locator('.add-btn').first().click();
    await page.click('#place-order');
    await expect(page.locator('#order-message')).toContainText('placed');
    await expect(page.locator('[data-testid="receipt"]').first()).toBeVisible();
  });

  test('casey.cashier opens the register but not the office', async ({ page }) => {
    await openJava(page, '/app/register.html', 'casey.cashier');
    await expect(page.locator('h1')).toContainText('Cash Register');
    await expect(page.locator('#orders td').first()).toBeVisible();
    await page.goto(JAVA + '/app/office.html');
    await expect(page).toHaveURL(/forbidden\.html/);
  });

  test('morgan.manager opens the office and sees the activity notebook', async ({ page }) => {
    await openJava(page, '/app/office.html', 'morgan.manager');
    await expect(page.locator('h1')).toContainText("Manager's Office");
    await expect(page.locator('[data-testid="activity-row"]').first()).toBeVisible();
  });

  test('riley.ldap (from the LDAP phone book) is a manager too', async ({ page }) => {
    await openJava(page, '/app/office.html', 'riley.ldap');
    await expect(page.locator('h1')).toContainText("Manager's Office");
  });
});

test.describe('Python deli (Flask)', () => {
  test('menu is public', async ({ page }) => {
    await page.goto(PYTHON + '/');
    await expect(page.locator('h1')).toContainText('deli menu');
    await expect(page.locator('[data-testid="menu-item"]').first()).toBeVisible();
  });

  test('casey.cashier sees the kitchen board', async ({ page }) => {
    await openPython(page, '/tickets', 'casey.cashier');
    await expect(page.locator('h1')).toContainText('Kitchen board');
  });

  test('sam.shopper can order but is stopped at the kitchen door', async ({ page }) => {
    await openPython(page, '/order', 'sam.shopper');
    await page.click('#place-ticket');
    await expect(page.locator('#ticket-message')).toContainText('on the board');
    await page.goto(PYTHON + '/tickets');
    await expect(page.locator('h1')).toContainText('different badge');
  });

  test('morgan.manager reads the shared notebook', async ({ page }) => {
    await openPython(page, '/admin', 'morgan.manager');
    await expect(page.locator('h1')).toContainText('Activity notebook');
    await expect(page.locator('[data-testid="activity-row"]').first()).toBeVisible();
  });
});
