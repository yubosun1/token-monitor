'use strict';

/**
 * Hanako Agent session usage parser.
 *
 * Hanako (a local Pi-SDK based agent) writes session transcripts to
 * ~/.hanako/agents/hanako/sessions/*.jsonl with `message.usage` in camelCase
 * (input/output/cacheRead/cacheWrite plus a provider-reported cost object).
 * This adapter converts those rows into the same shape promaUsage.js produces
 * and reuses its tokscale-compatible aggregators under the `hanako` client id.
 */

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { createHash } = require('node:crypto');
const {
  buildTokscaleJson,
  buildPromaHistoryGraph,
  timestampMs
} = require('./promaUsage');

const HANAKO_ROOT = path.join(os.homedir(), '.hanako', 'agents', 'hanako', 'sessions');

function numberValue(value) {
  const n = Number(value || 0);
  return Number.isFinite(n) ? n : 0;
}

function sourceNamespace(root) {
  return createHash('sha256').update(path.normalize(String(root || ''))).digest('hex').slice(0, 12);
}

function jsonlFiles(root) {
  try {
    return fs.readdirSync(root)
      .filter((n) => n.endsWith('.jsonl'))
      .map((n) => path.join(root, n));
  } catch (_) {
    return [];
  }
}

function collectHanakoRows(options = {}) {
  const roots = Array.isArray(options.roots) ? options.roots : [HANAKO_ROOT];
  const rows = [];
  for (const root of roots) {
    const sourceId = sourceNamespace(root);
    for (const filePath of jsonlFiles(root)) {
      const sessionId = `${path.basename(filePath, path.extname(filePath))}@${sourceId}`;
      let content = '';
      try {
        content = String(fs.readFileSync(filePath, 'utf8') || '');
      } catch (_) {
        continue; // skip unreadable files
      }
      for (const line of content.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)) {
        try {
          const obj = JSON.parse(line);
          const msg = obj.message;
          if (!msg || !msg.usage || typeof msg.usage !== 'object') continue;
          const u = msg.usage;
          const input = numberValue(u.input !== undefined ? u.input : u.input_tokens);
          const output = numberValue(u.output !== undefined ? u.output : u.output_tokens);
          const cacheRead = numberValue(u.cacheRead !== undefined ? u.cacheRead : u.cache_read_input_tokens);
          const cacheWrite = numberValue(u.cacheWrite !== undefined ? u.cacheWrite : u.cache_creation_input_tokens);
          const model = msg.model || obj.modelId || 'unknown';
          const createdAt = timestampMs(obj.timestamp || msg.timestamp || obj._createdAt);
          rows.push({
            sessionId,
            model,
            input,
            output,
            cacheRead,
            cacheWrite,
            createdAt,
            messages: 1
          });
        } catch (_) {
          // skip malformed lines
        }
      }
    }
  }
  return rows;
}

/**
 * Build today / month / allTime periods in the same tokscale-compatible shape
 * promaUsage.buildPromaPeriods returns, tagged with the `hanako` client id.
 */
function buildHanakoPeriods(options = {}) {
  const now = options.now ? new Date(options.now) : new Date();
  const rows = Array.isArray(options.rows) ? options.rows : collectHanakoRows(options);
  const buildOptions = { rows, pricingByModel: options.pricingByModel, client: 'hanako' };
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 0, 0, 0).getTime();
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1, 0, 0, 0, 0).getTime();

  return {
    today: buildTokscaleJson({ todayStart }, buildOptions),
    month: buildTokscaleJson({ monthStart }, buildOptions),
    allTime: buildTokscaleJson({ allTimeSince: options.allTimeSince }, { ...buildOptions, includeUndated: true })
  };
}

function buildHanakoHistoryGraph(options = {}) {
  return buildPromaHistoryGraph({ ...options, rows: Array.isArray(options.rows) ? options.rows : collectHanakoRows(options), client: 'hanako' });
}

module.exports = {
  HANAKO_ROOT,
  collectHanakoRows,
  buildHanakoPeriods,
  buildHanakoHistoryGraph
};
