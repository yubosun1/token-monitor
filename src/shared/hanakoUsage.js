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

const HANAKO_SESSIONS_ROOT = path.join(os.homedir(), '.hanako', 'agents', 'hanako', 'sessions');
const HANAKO_ACTIVITY_ROOT = path.join(os.homedir(), '.hanako', 'agents', 'hanako', 'activity');
const HANAKO_ROOTS = [HANAKO_SESSIONS_ROOT, HANAKO_ACTIVITY_ROOT];

function numberValue(value) {
  const n = Number(value || 0);
  return Number.isFinite(n) ? n : 0;
}

function sourceNamespace(root) {
  return createHash('sha256').update(path.normalize(String(root || ''))).digest('hex').slice(0, 12);
}

function jsonlFiles(root) {
  // Sessions live both at the top level and under subdirectories
  // (sessions/bridge/owner/, sessions/archived/, ...), so walk recursively.
  const out = [];
  const walk = (dir) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (_) {
      return;
    }
    for (const entry of entries) {
      const p = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(p);
      else if (entry.isFile() && entry.name.endsWith('.jsonl')) out.push(p);
    }
  };
  walk(root);
  return out;
}

function collectHanakoRows(options = {}) {
  // Sessions are spread across the sessions tree (including bridge/owner and
  // archived subdirectories) and the daily activity files; the two sources
  // share no message ids, but dedupe by id anyway as a safety net.
  const roots = Array.isArray(options.roots) ? options.roots : HANAKO_ROOTS;
  const rows = [];
  const seenMessageIds = new Set();
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
          const messageId = obj.id || (msg.id ? String(msg.id) : '');
          if (messageId) {
            if (seenMessageIds.has(messageId)) continue;
            seenMessageIds.add(messageId);
          }
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
  HANAKO_SESSIONS_ROOT,
  HANAKO_ACTIVITY_ROOT,
  HANAKO_ROOTS,
  collectHanakoRows,
  buildHanakoPeriods,
  buildHanakoHistoryGraph
};
