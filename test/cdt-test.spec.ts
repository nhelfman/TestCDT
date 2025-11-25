import { test, expect, chromium } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { execSync } from 'child_process';

// Configuration
const TEST_PAGE_URL = '/cdt-test.html';
const ITERATIONS = 2;
const USER_DATA_DIR = path.join(os.tmpdir(), 'cdt-test-profile');
const CACHE_DIR = process.env.CDT_CACHE_DIR || path.join(USER_DATA_DIR, 'Cache');

console.log(`Using CACHE_DIR: ${CACHE_DIR}`);

// Chrome launch args for CDT support
const CHROME_ARGS =  [
    '--enable-experimental-web-platform-features', // Neded to contentEncoding in resource timing
    `--disk-cache-dir=${CACHE_DIR}`,
    '--no-sandbox', // Required for running Chrome in WSL
];

// Result types
interface TestResult {
  action: string;
  status: 'ok' | 'error';
  message?: string;
  resourceType?: string;
  httpStatus?: number;
  contentEncoding?: string;
  url?: string;
  transferSize?: number | null;
  encodedBodySize?: number | null;
  decodedBodySize?: number | null;
  duration?: number | null;
  downloadTime?: number | null;
  deliveryType?: string | null;
  protocol?: string | null;
}

interface IterationResults {
  iteration: number;
  init: TestResult | null;
  loadBase: TestResult | null;
  loadDiff: TestResult | null;
  loadDiffCached: TestResult | null;
  loadBaseCached: TestResult | null;
}

interface CacheTimingStats {
  resourceType: string;
  samples: number[];
  mean: number;
  median: number;
  min: number;
  max: number;
  stdDev: number;
}

// Parse CDT_TEST_RESULT from console messages
function parseTestResult(consoleMessages: string[]): TestResult | null {
  for (const msg of consoleMessages) {
    if (msg.startsWith('CDT_TEST_RESULT:')) {
      try {
        return JSON.parse(msg.substring('CDT_TEST_RESULT:'.length));
      } catch {
        console.error('Failed to parse result:', msg);
      }
    }
  }
  return null;
}

// Clear the disk cache directory
function clearDiskCache(): void {
  if (fs.existsSync(USER_DATA_DIR)) {
    fs.rmSync(USER_DATA_DIR, { recursive: true, force: true });
  }
  fs.mkdirSync(USER_DATA_DIR, { recursive: true });
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  console.log(`  User data directory cleared: ${USER_DATA_DIR}`);
}

// Flush the filesystem cache to ensure cold cache reads
async function flushFsCache(): Promise<void> {
  try {
    execSync("sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'");
    // Wait a bit to ensure cache flush is fully complete
    await new Promise(resolve => setTimeout(resolve, 500));
    console.log('  Filesystem cache flushed');
  } catch (error) {
    console.error('  Failed to flush filesystem cache:', error);
    throw new Error('FATAL: Failed to flush filesystem cache. Test aborted.');
  }
}

// Execute a single action with a fresh browser instance (but persistent user data)
async function executeAction(
  baseURL: string,
  action: string
): Promise<{ result: TestResult | null; consoleMessages: string[] }> {
  let context;
  let page;
  
  try {
    // Launch a persistent context to preserve CDT dictionary across restarts
    // Use Linux Chrome explicitly (not Windows Chrome via WSL interop)
    context = await chromium.launchPersistentContext(USER_DATA_DIR, {
      headless: true,
      executablePath: '/usr/bin/google-chrome', // Use Linux Chrome
      args: CHROME_ARGS,
    });

    console.log(`  Launched Chrome with cache dir: ${CACHE_DIR}`);

    page = await context.newPage();
    const consoleMessages: string[] = [];

    // Capture console messages
    page.on('console', (msg: { text: () => string }) => {
      consoleMessages.push(msg.text());
    });

    await page.goto(`${baseURL}${TEST_PAGE_URL}?action=${action}`, { waitUntil: 'networkidle' });
    
    // Wait for result to appear
    await page.waitForTimeout(2000);
    
    const result = parseTestResult(consoleMessages);
    return { result, consoleMessages };
  } finally {
    // Ensure cleanup happens even on error
    try {
      if (page) await page.close().catch(() => {});
      if (context) await context.close().catch(() => {});
    } catch {
      // Ignore cleanup errors
    }
  }
}

// Calculate statistics for timing data
function calculateStats(samples: number[], resourceType: string): CacheTimingStats {
  if (samples.length === 0) {
    return {
      resourceType,
      samples: [],
      mean: 0,
      median: 0,
      min: 0,
      max: 0,
      stdDev: 0
    };
  }

  const sorted = [...samples].sort((a, b) => a - b);
  const sum = samples.reduce((a, b) => a + b, 0);
  const mean = sum / samples.length;
  const median = sorted.length % 2 === 0
    ? (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2
    : sorted[Math.floor(sorted.length / 2)];
  const min = sorted[0];
  const max = sorted[sorted.length - 1];
  
  const squaredDiffs = samples.map(x => Math.pow(x - mean, 2));
  const avgSquaredDiff = squaredDiffs.reduce((a, b) => a + b, 0) / samples.length;
  const stdDev = Math.sqrt(avgSquaredDiff);

  return {
    resourceType,
    samples,
    mean,
    median,
    min,
    max,
    stdDev
  };
}

// Format timing report
function formatReport(
  baseCacheStats: CacheTimingStats,
  diffCacheStats: CacheTimingStats,
  allResults: IterationResults[]
): string {
  const lines: string[] = [];
  
  lines.push('');
  lines.push('='.repeat(80));
  lines.push('CDT PERFORMANCE TEST REPORT');
  lines.push('='.repeat(80));
  lines.push('');
  
  lines.push(`Total iterations: ${allResults.length}`);
  lines.push(`Cache directory: ${CACHE_DIR}`);
  lines.push('');
  
  lines.push('-'.repeat(80));
  lines.push('CACHE READ TIMING COMPARISON');
  lines.push('-'.repeat(80));
  lines.push('');
  
  lines.push('Base file (brotli) cache read times:');
  lines.push(`  Samples: ${baseCacheStats.samples.length}`);
  lines.push(`  Mean:    ${baseCacheStats.mean.toFixed(2)} ms`);
  lines.push(`  Median:  ${baseCacheStats.median.toFixed(2)} ms`);
  lines.push(`  Min:     ${baseCacheStats.min.toFixed(2)} ms`);
  lines.push(`  Max:     ${baseCacheStats.max.toFixed(2)} ms`);
  lines.push(`  StdDev:  ${baseCacheStats.stdDev.toFixed(2)} ms`);
  lines.push('');
  
  lines.push('Diff file (dictionary brotli) cache read times:');
  lines.push(`  Samples: ${diffCacheStats.samples.length}`);
  lines.push(`  Mean:    ${diffCacheStats.mean.toFixed(2)} ms`);
  lines.push(`  Median:  ${diffCacheStats.median.toFixed(2)} ms`);
  lines.push(`  Min:     ${diffCacheStats.min.toFixed(2)} ms`);
  lines.push(`  Max:     ${diffCacheStats.max.toFixed(2)} ms`);
  lines.push(`  StdDev:  ${diffCacheStats.stdDev.toFixed(2)} ms`);
  lines.push('');
  
  if (baseCacheStats.mean > 0 && diffCacheStats.mean > 0) {
    const diff = baseCacheStats.mean - diffCacheStats.mean;
    const percentDiff = (diff / baseCacheStats.mean) * 100;
    lines.push('-'.repeat(80));
    lines.push('COMPARISON');
    lines.push('-'.repeat(80));
    lines.push(`  Difference (base - diff): ${diff.toFixed(2)} ms`);
    lines.push(`  Percentage difference: ${percentDiff.toFixed(2)}%`);
    lines.push(`  Diff is ${diff > 0 ? 'faster' : 'slower'} than base by ${Math.abs(diff).toFixed(2)} ms`);
  }
  
  lines.push('');
  lines.push('-'.repeat(80));
  lines.push('DETAILED RESULTS PER ITERATION');
  lines.push('-'.repeat(80));
  
  for (const result of allResults) {
    lines.push('');
    lines.push(`Iteration ${result.iteration}:`);
    
    if (result.loadBase) {
      lines.push(`  Base (network): transferSize=${result.loadBase.transferSize}, duration=${result.loadBase.duration?.toFixed(2)}ms, encoding=${result.loadBase.contentEncoding}`);
    }
    if (result.loadDiff) {
      lines.push(`  Diff (network): transferSize=${result.loadDiff.transferSize}, duration=${result.loadDiff.duration?.toFixed(2)}ms, encoding=${result.loadDiff.contentEncoding}`);
    }
    if (result.loadDiffCached) {
      lines.push(`  Diff (cache):   duration=${result.loadDiffCached.duration?.toFixed(2)}ms, deliveryType=${result.loadDiffCached.deliveryType}`);
    }
    if (result.loadBaseCached) {
      lines.push(`  Base (cache):   duration=${result.loadBaseCached.duration?.toFixed(2)}ms, deliveryType=${result.loadBaseCached.deliveryType}`);
    }
  }
  
  lines.push('');
  lines.push('='.repeat(80));
  
  return lines.join('\n');
}

test.describe('CDT Performance Test', () => {
  test('Run CDT performance test iterations', async ({}, testInfo) => {
    // Get base URL from test config
    const baseURL = testInfo.project.use.baseURL || 'http://localhost:8080';
    
    const allResults: IterationResults[] = [];
    const baseCacheTimes: number[] = [];
    const diffCacheTimes: number[] = [];

    for (let i = 1; i <= ITERATIONS; i++) {
      console.log(`\n--- Iteration ${i}/${ITERATIONS} ---\n`);
      
      const iterationResult: IterationResults = {
        iteration: i,
        init: null,
        loadBase: null,
        loadDiff: null,
        loadDiffCached: null,
        loadBaseCached: null
      };

      // Step 1: Clear cache and verify it's clean
      console.log('Step 1: Clear cache and verify clean state');
      clearDiskCache();
      await flushFsCache();
      
      const initResult = await executeAction(baseURL, 'init');
      iterationResult.init = initResult.result;
      
      if (initResult.result?.status !== 'ok') {
        console.error(`Init failed: ${initResult.result?.message}`);
        throw new Error(`FATAL: Init failed - ${initResult.result?.message}`);
      }

      // Step 2: Load base file (new browser, populates disk cache)
      console.log('Step 2: Load base file (new browser)');
      await flushFsCache();
      const loadBaseResult = await executeAction(baseURL, 'load_base');
      iterationResult.loadBase = loadBaseResult.result;
      
      if (loadBaseResult.result?.status !== 'ok') {
        console.error(`Load base failed: ${loadBaseResult.result?.message}`);
        throw new Error(`FATAL: Load base failed - ${loadBaseResult.result?.message}`);
      }
      console.log(`  Base loaded: transferSize=${loadBaseResult.result.transferSize}, encoding=${loadBaseResult.result.contentEncoding}`);

      // Step 3: Load diff file (new browser, uses disk cache for dictionary)
      console.log('Step 3: Load diff file (new browser)');
      await flushFsCache();
      const loadDiffResult = await executeAction(baseURL, 'load_diff');
      iterationResult.loadDiff = loadDiffResult.result;
      
      if (loadDiffResult.result?.status !== 'ok') {
        console.error(`Load diff failed: ${loadDiffResult.result?.message}`);
        throw new Error(`FATAL: Load diff failed - ${loadDiffResult.result?.message}`);
      }
      console.log(`  Diff loaded: transferSize=${loadDiffResult.result.transferSize}, encoding=${loadDiffResult.result.contentEncoding}`);

      // Validate CDT worked:
      // 1. Base should be at least twice the size of diff
      // 2. Diff content encoding should be 'dcb' (dictionary compressed brotli)
      const baseSize = loadBaseResult.result.transferSize || 0;
      const diffSize = loadDiffResult.result.transferSize || 0;
      const diffEncoding = loadDiffResult.result.contentEncoding;
      
      if (diffEncoding !== 'dcb') {
        console.error(`FATAL: Diff content encoding is '${diffEncoding}', expected 'dcb'.`);
        console.error('CDT is not working - diff was not served with dictionary compression.');
        throw new Error(`FATAL: CDT not working - diff encoding is '${diffEncoding}', expected 'dcb'. Test aborted.`);
      }
      
      if (baseSize < diffSize * 2) {
        console.error(`FATAL: Base size (${baseSize}) is not at least twice the diff size (${diffSize}).`);
        console.error('CDT compression ratio is too low - dictionary compression may not be effective.');
        throw new Error(`FATAL: CDT compression insufficient - base (${baseSize}) should be at least 2x diff (${diffSize}). Test aborted.`);
      }
      
      console.log(`  CDT verified: encoding=${diffEncoding}, base=${baseSize}, diff=${diffSize}, ratio=${(baseSize/diffSize).toFixed(1)}x`);

      // Step 4: Load diff again (new browser) - should be from disk cache
      console.log('Step 4: Load diff (new browser, should be from disk cache)');
      await flushFsCache();
      const loadDiffCachedResult = await executeAction(baseURL, 'load_diff');
      iterationResult.loadDiffCached = loadDiffCachedResult.result;
      
      if (loadDiffCachedResult.result?.status !== 'ok') {
        console.error(`Load diff cached failed: ${loadDiffCachedResult.result?.message}`);
        throw new Error(`FATAL: Load diff cached failed: ${loadDiffCachedResult.result?.message}`);
      }
      
      if (loadDiffCachedResult.result.deliveryType !== 'cache') {
        console.error(`FATAL: Diff was not served from cache. deliveryType=${loadDiffCachedResult.result.deliveryType}`);
        console.error('Cache read timing test cannot proceed without cached resources.');
        console.error('Possible causes:');
        console.error('  - Disk cache not persisting between browser launches');
        console.error('  - Cache-Control headers prevent caching');
        console.error('  - CDN is not returning cacheable responses');
        throw new Error(`FATAL: Diff was not served from cache. deliveryType=${loadDiffCachedResult.result.deliveryType}. Test aborted.`);
      }
      
      console.log(`  Diff served from cache: duration=${loadDiffCachedResult.result.duration?.toFixed(2)}ms`);
      if (loadDiffCachedResult.result.duration !== null && loadDiffCachedResult.result.duration !== undefined) {
        diffCacheTimes.push(loadDiffCachedResult.result.duration);
      }

      // Step 5: Load base again (new browser) - should be from disk cache
      console.log('Step 5: Load base (new browser, should be from disk cache)');
      await flushFsCache();
      const loadBaseCachedResult = await executeAction(baseURL, 'load_base');
      iterationResult.loadBaseCached = loadBaseCachedResult.result;
      
      if (loadBaseCachedResult.result?.status !== 'ok') {
        console.error(`Load base cached failed: ${loadBaseCachedResult.result?.message}`);
        throw new Error(`FATAL: Load base cached failed: ${loadBaseCachedResult.result?.message}`);
      }
      
      if (loadBaseCachedResult.result.deliveryType !== 'cache') {
        console.error(`FATAL: Base was not served from cache. deliveryType=${loadBaseCachedResult.result.deliveryType}`);
        console.error('Cache read timing test cannot proceed without cached resources.');
        throw new Error(`FATAL: Base was not served from cache. deliveryType=${loadBaseCachedResult.result.deliveryType}. Test aborted.`);
      }
      
      console.log(`  Base served from cache: duration=${loadBaseCachedResult.result.duration?.toFixed(2)}ms`);
      if (loadBaseCachedResult.result.duration !== null && loadBaseCachedResult.result.duration !== undefined) {
        baseCacheTimes.push(loadBaseCachedResult.result.duration);
      }

      allResults.push(iterationResult);
    }

    // Calculate statistics
    const baseCacheStats = calculateStats(baseCacheTimes, 'base');
    const diffCacheStats = calculateStats(diffCacheTimes, 'diff');

    // Generate and print report
    const report = formatReport(baseCacheStats, diffCacheStats, allResults);
    console.log(report);

    // Assertions
    expect(allResults.length).toBe(ITERATIONS);
    expect(baseCacheTimes.length).toBe(ITERATIONS);
    expect(diffCacheTimes.length).toBe(ITERATIONS);
  });
});
