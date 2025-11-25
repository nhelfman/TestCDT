import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './test',
  fullyParallel: false, // Run tests sequentially for accurate timing measurements
  forbidOnly: !!process.env.CI,
  retries: 0,
  workers: 1, // Single worker to avoid interference
  reporter: [
    ['html', { open: 'never' }],
    ['list']
  ],
  timeout: 120000, // 2 minutes per test
  use: {
    baseURL: 'http://localhost:8080',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium-cdt',
      use: {
        ...devices['Desktop Chrome'],
        launchOptions: {
          args: [
            '--enable-experimental-web-platform-features', // Required for CDT
            '--enable-features=CompressionDictionaryTransportBackend,CompressionDictionaryTransport',
          ],
        },
      },
    },
  ],
  webServer: {
    command: 'NODE_OPTIONS="--no-deprecation" npx http-server -p 8080 -c-1',
    url: 'http://localhost:8080',
    reuseExistingServer: !process.env.CI,
    timeout: 30000,
    stdout: 'ignore',
    stderr: 'pipe',
  },
});
