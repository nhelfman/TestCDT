# CDT Performance Test

This project tests Compression Dictionary Transport (CDT) performance by comparing cache read timing between base (brotli) and diff (dictionary-compressed brotli) files. We can experiment with different cache IO throughputs to understand the impact of cache read performance.

## Test Results

See [sweep-test-result.md](sweep-test-result.md) for full test results involving different cache throttling levels.

## Overview

The automated test consists of:
- **`cdt-test.html`** - A minimal test page that executes actions based on URL query parameters
- **`test/cdt-test.spec.ts`** - Playwright automation script that orchestrates the test flow

To manually test using a simple UI it is possible to use this simple test page:
https://nhelfman.github.io/TestCDT/

## Prerequisites

- Node.js 18+
- Chrome browser with CDT support

## Installation

```bash
npm install
npx playwright install chromium
```

## Running the Test

```bash
# Run the full test suite
npm test

# Run with headed browser (visible)
npm run test:headed

# Run in debug mode
npm run test:debug
```

## Test Flow

For each iteration (default: 10), the test:

1. **Init** - Verify cache is clean (no pre-existing entries)
2. **Load Base** - Fetch base file (brotli compressed) over network
3. **Load Diff** - Fetch diff file (should use CDT dictionary compression)
4. **Validate CDT** - Verify diff `transferSize` is much smaller than base
5. **Load Diff (cached)** - Fetch diff again, verify served from cache, measure timing
6. **Load Base (cached)** - Fetch base again, verify served from cache, measure timing

The browser context is closed between each step to ensure cold loads.

## Test Page Actions

The `cdt-test.html` page accepts these query parameters:

| Parameter | Values | Description |
|-----------|--------|-------------|
| `action` | `init`, `load_base`, `load_diff` | Action to execute |
| `baseUrl` | URL | Override default base file URL |
| `diffUrl` | URL | Override default diff file URL |
| `wscdt` | `1`, `2` | CDT group selector (1=treatment, 2=control) |

### Output Format

Results are output to console in JSON format:
```
CDT_TEST_RESULT:{"action":"load_base","status":"ok","transferSize":12345,...}
```

## Report Output

After all iterations, the test outputs a report comparing:
- Cache read timing statistics (mean, median, min, max, stdDev)
- Detailed per-iteration results
- Comparison between base and diff cache read times

## Configuration

Edit `playwright.config.ts` to adjust:
- Number of iterations (modify `ITERATIONS` in test file cdt-test.spec.ts)
- Chrome launch flags for CDT
- Timeouts and other Playwright settings

