(function exposeFixedPeriodRanges(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.TokenMonitorFixedPeriodRanges = api;
})(typeof window !== 'undefined' ? window : null, function createFixedPeriodRangesApi() {
  const MONTH_MODES = Object.freeze(['month', 'week', 'last7', 'last30', 'custom']);
  const LABELS = Object.freeze({
    today: 'DAY',
    month: 'MONTH',
    allTime: 'TOTAL',
    week: 'WEEK',
    last7: '7D',
    last30: '30D',
    custom: 'CUSTOM'
  });

  function finiteNumber(value) {
    const number = Number(value);
    return Number.isFinite(number) ? number : 0;
  }

  function normalizeDateKey(value) {
    const key = String(value || '').slice(0, 10);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(key)) return '';
    const date = new Date(`${key}T00:00:00Z`);
    return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === key ? key : '';
  }

  function dayKeyAddDays(key, delta) {
    const normalized = normalizeDateKey(key);
    if (!normalized) return '';
    const date = new Date(`${normalized}T00:00:00Z`);
    date.setUTCDate(date.getUTCDate() + Number(delta || 0));
    return date.toISOString().slice(0, 10);
  }

  function localDayKey(value = new Date()) {
    const date = value instanceof Date ? value : new Date(value);
    if (Number.isNaN(date.getTime())) return '';
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }

  function weekStartsOn(locale) {
    try {
      const resolved = new Intl.Locale(String(locale || 'zh-CN'));
      const info = typeof resolved.getWeekInfo === 'function' ? resolved.getWeekInfo() : resolved.weekInfo;
      const firstDay = Number(info?.firstDay);
      if (Number.isInteger(firstDay) && firstDay >= 1 && firstDay <= 7) return firstDay % 7;
    } catch (_) { /* use ISO Monday */ }
    return 1;
  }

  function normalizeMonthMode(value) {
    return MONTH_MODES.includes(value) ? value : 'month';
  }

  function isDerived(value) {
    return value === 'week' || value === 'last7' || value === 'last30' || value === 'custom';
  }

  function slotForSelection(value) {
    return isDerived(value) || value === 'month' ? 'month' : value;
  }

  function displayLabel(value) {
    return LABELS[value] || LABELS.today;
  }

  function rangeForSelection(selection, options = {}) {
    const todayKey = normalizeDateKey(options.todayKey) || localDayKey(options.now);
    if (!todayKey) return null;
    if (selection === 'week') {
      const weekday = new Date(`${todayKey}T00:00:00Z`).getUTCDay();
      const offset = (weekday - weekStartsOn(options.locale) + 7) % 7;
      return { start: dayKeyAddDays(todayKey, -offset), end: todayKey };
    }
    if (selection === 'last7') return { start: dayKeyAddDays(todayKey, -6), end: todayKey };
    if (selection === 'last30') return { start: dayKeyAddDays(todayKey, -29), end: todayKey };
    if (selection === 'custom') {
      const start = normalizeDateKey(options.customStart) || dayKeyAddDays(todayKey, -6);
      const end = normalizeDateKey(options.customEnd) || todayKey;
      return { start: start <= end ? start : end, end: start <= end ? end : start };
    }
    if (selection === 'month') {
      const start = `${todayKey.slice(0, 7)}-01`;
      return { start, end: todayKey };
    }
    return null;
  }

  function addMap(target, key, value) {
    if (!key) return;
    target[key] = finiteNumber(target[key]) + finiteNumber(value);
  }

  function dailyForRange(daily, range) {
    if (!Array.isArray(daily) || !range?.start || !range?.end) return [];
    return daily.filter((day) => {
      const date = normalizeDateKey(day?.date);
      return date && date >= range.start && date <= range.end;
    });
  }

  function derivePeriod(daily, range) {
    const period = {
      totalTokens: 0,
      costUsd: 0,
      clients: {},
      clientCosts: {},
      clientCacheReads: {},
      clientCacheWrites: {},
      clientOutputs: {},
      models: {},
      modelCosts: {},
      modelCacheReads: {},
      modelCacheWrites: {},
      modelOutputs: {},
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      outputTokens: 0,
      sessions: {},
      derivedFixedRange: true
    };
    const rows = dailyForRange(daily, range);
    for (const row of rows) {
      period.totalTokens += finiteNumber(row?.tokens);
      period.costUsd += finiteNumber(row?.cost);
      for (const [client, value] of Object.entries(row?.perClient || {})) {
        addMap(period.clients, client, value?.tokens ?? value);
        addMap(period.clientCosts, client, value?.cost);
      }
      for (const [model, value] of Object.entries(row?.perModel || {})) {
        addMap(period.models, model, value?.tokens ?? value);
        addMap(period.modelCosts, model, value?.cost);
      }
    }
    period.totalTokens = Math.max(0, Math.round(period.totalTokens));
    period.costUsd = Number(period.costUsd.toFixed(6));
    for (const map of [period.clients, period.models]) {
      for (const key of Object.keys(map)) map[key] = Math.max(0, Math.round(map[key]));
    }
    for (const map of [period.clientCosts, period.modelCosts]) {
      for (const key of Object.keys(map)) map[key] = Number(map[key].toFixed(6));
    }
    return period;
  }

  function fixedPeriodSnapshot(selection, options = {}) {
    if (!isDerived(selection)) return { status: 'native', selection, period: null, range: null };
    const range = rangeForSelection(selection, options);
    if (!range) return { status: 'unavailable', selection, reason: 'rangeUnavailable', period: null, range: null };
    const daily = dailyForRange(options.daily || [], range);
    return {
      status: 'ready',
      selection,
      reason: '',
      range,
      daily,
      period: derivePeriod(daily, range)
    };
  }

  return {
    MONTH_MODES,
    dailyForRange,
    dayKeyAddDays,
    derivePeriod,
    displayLabel,
    fixedPeriodSnapshot,
    isDerived,
    localDayKey,
    normalizeMonthMode,
    rangeForSelection,
    slotForSelection,
    weekStartsOn
  };
});
