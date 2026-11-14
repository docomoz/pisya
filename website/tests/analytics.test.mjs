import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { measurementIdFromConfig } from '../scripts/analytics-config.mjs';

const source = await readFile(new URL('../dist/analytics.js', import.meta.url), 'utf8');

test('measurement ID persists in configuration and can be explicitly overridden', () => {
  const config = { gaMeasurementId: 'G-EXAMPLE123' };
  assert.equal(measurementIdFromConfig(config, {}), 'G-EXAMPLE123');
  assert.equal(measurementIdFromConfig(config, { PISA_GA_MEASUREMENT_ID: 'G-OTHER456' }), 'G-OTHER456');
  assert.equal(measurementIdFromConfig(config, { PISYA_GA_MEASUREMENT_ID: 'G-OLD123', PISA_GA_MEASUREMENT_ID: 'G-OTHER456' }), 'G-OTHER456');
  assert.equal(measurementIdFromConfig(config, { PISYA_GA_MEASUREMENT_ID: 'G-OLD123' }), 'G-OLD123');
  assert.equal(measurementIdFromConfig(config, { PISYA_GA_MEASUREMENT_ID: '' }), '');
  assert.equal(measurementIdFromConfig({ gaMeasurementId: '' }, {}), '');
  assert.throws(() => measurementIdFromConfig({ gaMeasurementId: 'invalid' }, {}), /GA4 measurement ID/);
  assert.throws(() => measurementIdFromConfig(config, { PISYA_GA_MEASUREMENT_ID: 'G-<BAD>' }), /GA4 measurement ID/);
});

function page(id) {
  const scripts = [];
  const listeners = {};
  const timers = [];
  const navigations = [];
  const document = {
    querySelector: () => id ? { content: id } : null,
    createElement: () => ({}),
    head: { appendChild: script => scripts.push(script) },
    addEventListener: (event, callback) => { listeners[event] = callback; },
    referrer: 'https://search.example/search?q=private',
  };
  const window = {
    location: { origin: 'https://getpisa.app', pathname: '/', search: '?secret=private', assign: url => navigations.push(url) },
    setTimeout: callback => timers.push(callback),
  };
  runInNewContext(source, { document, window, URL, Date, encodeURIComponent });
  return { window, scripts, listeners, timers, navigations };
}

test('analytics is disabled without a valid measurement ID', () => {
  for (const id of ['', 'G-INVALID"']) {
    const state = page(id);
    assert.equal(state.scripts.length, 0);
    assert.equal(state.window.pisaTrack, undefined);
  }
});

test('analytics config requests one automatic page view with sanitized URLs', () => {
  const state = page('G-TEST123');
  assert.equal(state.scripts[0].src, 'https://www.googletagmanager.com/gtag/js?id=G-TEST123');
  const configs = state.window.dataLayer.filter(args => args[0] === 'config');
  assert.equal(configs.length, 1);
  assert.equal(configs[0][1], 'G-TEST123');
  assert.notEqual(configs[0][2].send_page_view, false);
  assert.equal(configs[0][2].page_title, 'Pisa');
  assert.equal(configs[0][2].page_location, 'https://getpisa.app/');
  assert.equal(configs[0][2].page_referrer, 'https://search.example');
  const views = state.window.dataLayer.filter(args => args[0] === 'event' && args[1] === 'page_view');
  assert.equal(views.length, 0);
});

test('analytics sends only allowed events and enumerated link values', () => {
  const state = page('G-TEST123');
  const click = (href, attrs = {}) => state.listeners.click({ target: { closest: () => ({ getAttribute: name => name === 'href' ? href : attrs[name] }) } });
  for (const location of ['header', 'hero', 'install']) click('#install-guide', { 'data-analytics-location': location });
  for (const destination of ['source', 'install_guide', 'privacy']) click('https://github.com/docomoz/pisa', { 'data-analytics-destination': destination });
  click('https://t.me/docomoz');
  state.window.pisaTrack('copy_install_command');
  state.window.pisaTrack('private_event', { text: 'secret' });
  state.window.pisaTrack('github_click', 'secret');
  state.window.pisaTrack('install_guide_click', 'secret');
  const events = state.window.dataLayer.filter(args => args[0] === 'event');
  assert.deepEqual(Array.from(events, args => args[1]), [
    'install_guide_click', 'install_guide_click', 'install_guide_click',
    'github_click', 'github_click', 'github_click', 'contact_click', 'copy_install_command',
  ]);
  assert.deepEqual(Array.from(events.slice(0, 3), args => args[2].cta_location), ['header', 'hero', 'install']);
  assert.deepEqual(Array.from(events.slice(3, 6), args => args[2].github_destination), ['source', 'install_guide', 'privacy']);
});

test('all tracked page links have an allowed classification', async () => {
  const html = await readFile(new URL('../dist/index.html', import.meta.url), 'utf8');
  const links = [...html.matchAll(/<a\b([^>]*)>/g)].map(match => match[1]);
  const ctas = links.filter(link => link.includes('href="#install-guide"'));
  assert.equal(ctas.length, 3);
  assert.deepEqual(ctas.map(link => link.match(/data-analytics-location="([^"]+)"/)?.[1]), ['header', 'hero', 'install']);
  const github = links.filter(link => link.includes('href="https://github.com/docomoz/pisa'));
  assert.equal(github.length, 5);
  assert.deepEqual(github.map(link => link.match(/data-analytics-destination="([^"]+)"/)?.[1]), ['source', 'source', 'privacy', 'install_guide', 'source']);
});

test('download proceeds even when the analytics callback never arrives', () => {
  const state = page('G-TEST123');
  let prevented = false;
  const link = { getAttribute: () => '/download', hasAttribute: () => false, href: 'https://getpisa.app/download', target: '' };
  state.listeners.click({ target: { closest: () => link }, button: 0, preventDefault: () => { prevented = true; } });
  assert.equal(prevented, true);
  const event = state.window.dataLayer.find(args => args[1] === 'download_click');
  assert.ok(event);
  state.timers[0]();
  event[2].event_callback();
  assert.deepEqual(state.navigations, ['https://getpisa.app/download']);
});
