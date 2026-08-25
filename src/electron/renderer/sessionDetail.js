'use strict';

(function exposeSessionDetail(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.TokenMonitorSessionDetail = api;
})(typeof window !== 'undefined' ? window : null, function createSessionDetailApi() {
  function finiteNumber(value) {
    const n = Number(value);
    return Number.isFinite(n) ? n : 0;
  }

  function pad2(value) {
    return String(value).padStart(2, '0');
  }

  function compactTime(value, now = new Date()) {
    const date = value ? new Date(value) : null;
    if (!date || Number.isNaN(date.getTime())) return '';
    const time = `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
    const sameDay = date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth() && date.getDate() === now.getDate();
    return sameDay ? time : `${pad2(date.getMonth() + 1)}/${pad2(date.getDate())} ${time}`;
  }

  function formatToolList(tools) {
    return Array.from(new Set((tools || []).filter(Boolean))).join(' · ');
  }

  function roundPercent(val) {
    const n = finiteNumber(val);
    return Math.round(n * 10) / 10;
  }

  function sessionSummary(detail, options = {}) {
    const now = options.now || new Date();
    const models = Array.isArray(detail?.models) ? detail.models : [];
    const totals = detail?.totals || {};
    const totalTokens = finiteNumber(detail?.totalTokens || totals.totalTokens || models.reduce((s, m) => s + finiteNumber(m.totalTokens), 0));
    const costUsd = finiteNumber(detail?.costUsd || detail?.totalCost || totals.costUsd || models.reduce((s, m) => s + finiteNumber(m.costUsd), 0));
    const messageCount = finiteNumber(detail?.messageCount || totals.messageCount || models.reduce((s, m) => s + finiteNumber(m.messageCount), 0));

    const inputTokens = finiteNumber(totals.inputTokens ?? models.reduce((s, m) => s + finiteNumber(m.inputTokens), 0));
    const outputTokens = finiteNumber(totals.outputTokens ?? models.reduce((s, m) => s + finiteNumber(m.outputTokens), 0));
    const cacheReadTokens = finiteNumber(totals.cacheReadTokens ?? models.reduce((s, m) => s + finiteNumber(m.cacheReadTokens), 0));
    const cacheWriteTokens = finiteNumber(totals.cacheWriteTokens ?? models.reduce((s, m) => s + finiteNumber(m.cacheWriteTokens), 0));
    const reasoningTokens = finiteNumber(totals.reasoningTokens ?? models.reduce((s, m) => s + finiteNumber(m.reasoningTokens), 0));

    const totalInput = inputTokens + cacheReadTokens + cacheWriteTokens;
    const hitPct = totalInput > 0 ? Math.round((cacheReadTokens / totalInput) * 100) : 0;
    const missPct = totalInput > 0 ? 100 - hitPct : 0;

    const inPercent = totalTokens > 0 ? roundPercent(inputTokens / totalTokens * 100) : 0;
    const outPercent = totalTokens > 0 ? roundPercent(outputTokens / totalTokens * 100) : 0;
    const cachePercent = totalTokens > 0 ? roundPercent(cacheReadTokens / totalTokens * 100) : 0;
    const cacheWritePercent = totalTokens > 0 ? roundPercent(cacheWriteTokens / totalTokens * 100) : 0;
    const reasoningPercent = totalTokens > 0 ? roundPercent(reasoningTokens / totalTokens * 100) : 0;

    return {
      client: detail?.client || '',
      sessionId: detail?.sessionId || '',
      period: detail?.period || 'total',
      totalTokens,
      costUsd,
      messageCount,
      inputTokens,
      outputTokens,
      cacheReadTokens,
      cacheWriteTokens,
      reasoningTokens,
      totalInput,
      hitPct,
      missPct,
      cacheHitRate: hitPct,
      inPercent,
      outPercent,
      cachePercent,
      cacheWritePercent,
      reasoningPercent,
      modelCount: models.length,
      startedAt: detail?.startedAt || '',
      lastUsedAt: detail?.lastUsedAt || '',
      timeLabel: compactTime(detail?.lastUsedAt || detail?.startedAt, now)
    };
  }

  function modelBreakdownRows(detail, options = {}) {
    const rawModels = Array.isArray(detail?.models) ? detail.models : [];
    const summary = sessionSummary(detail, options);
    const totalTokens = summary.totalTokens;
    const sortBy = options.sortBy === 'cost' ? 'cost' : options.sortBy === 'name' ? 'name' : 'tokens';

    const rows = rawModels.map((m, idx) => {
      const modelId = String(m.modelId || m.model || `model-${idx + 1}`);
      const mTotal = finiteNumber(m.totalTokens || (finiteNumber(m.inputTokens) + finiteNumber(m.outputTokens) + finiteNumber(m.cacheReadTokens) + finiteNumber(m.cacheWriteTokens)));
      const inputTokens = finiteNumber(m.inputTokens);
      const outputTokens = finiteNumber(m.outputTokens);
      const cacheReadTokens = finiteNumber(m.cacheReadTokens);
      const cacheWriteTokens = finiteNumber(m.cacheWriteTokens);
      const reasoningTokens = finiteNumber(m.reasoningTokens);
      const messageCount = finiteNumber(m.messageCount);
      const costUsd = finiteNumber(m.costUsd || m.cost);

      const totalInput = inputTokens + cacheReadTokens + cacheWriteTokens;
      const hitPct = totalInput > 0 ? Math.round((cacheReadTokens / totalInput) * 100) : 0;
      const missPct = totalInput > 0 ? 100 - hitPct : 0;

      const percent = totalTokens > 0 ? roundPercent(mTotal / totalTokens * 100) : 0;

      const inPercent = mTotal > 0 ? roundPercent(inputTokens / mTotal * 100) : 0;
      const outPercent = mTotal > 0 ? roundPercent(outputTokens / mTotal * 100) : 0;
      const cachePercent = mTotal > 0 ? roundPercent(cacheReadTokens / mTotal * 100) : 0;
      const cacheWritePercent = mTotal > 0 ? roundPercent(cacheWriteTokens / mTotal * 100) : 0;
      const reasoningPercent = mTotal > 0 ? roundPercent(reasoningTokens / mTotal * 100) : 0;

      return {
        key: `model:${modelId}:${idx}`,
        modelId,
        provider: m.provider || '',
        totalTokens: mTotal,
        costUsd,
        messageCount,
        inputTokens,
        outputTokens,
        cacheReadTokens,
        cacheWriteTokens,
        reasoningTokens,
        totalInput,
        hitPct,
        missPct,
        percent,
        cacheHitRate: hitPct,
        inPercent,
        outPercent,
        cachePercent,
        cacheWritePercent,
        reasoningPercent
      };
    });

    if (sortBy === 'cost') {
      rows.sort((a, b) => b.costUsd - a.costUsd || b.totalTokens - a.totalTokens);
    } else if (sortBy === 'name') {
      rows.sort((a, b) => a.modelId.localeCompare(b.modelId));
    } else {
      rows.sort((a, b) => b.totalTokens - a.totalTokens || b.costUsd - a.costUsd);
    }

    return rows;
  }

  function turnRow(turn, index) {
    return {
      key: `turn:${index}`,
      label: `Reply #${index + 1}`,
      value: finiteNumber(turn.tokens && turn.tokens.total),
      tokensAvailable: turn.tokensAvailable !== false,
      cost: finiteNumber(turn.costEstimate),
      tokens: turn.tokens || {},
      tools: formatToolList(turn.tools)
    };
  }

  function timeValue(value) {
    const date = value ? new Date(value) : null;
    return date && !Number.isNaN(date.getTime()) ? date.getTime() : 0;
  }

  function exchangeRows(detail, options = {}) {
    const now = options.now || new Date();
    const sortBy = options.sortBy === 'tokens' ? 'tokens' : 'time';
    const exchanges = (detail && detail.exchanges) || [];
    const rows = exchanges.map((ex, i) => {
      const turnCount = finiteNumber(ex.turnCount);
      const toolCount = (ex.tools || []).length;
      const subtitleParts = [
        compactTime(ex.startedAt, now),
        `${turnCount} turn${turnCount === 1 ? '' : 's'}`,
        toolCount > 0 ? `${toolCount} tool${toolCount === 1 ? '' : 's'}` : ''
      ].filter(Boolean);
      return {
        key: `exchange:${i}`,
        isPrompt: Boolean(ex.promptPreview),
        title: ex.promptPreview ? ex.promptPreview : '(session start)',
        subtitle: subtitleParts.join(' · '),
        value: finiteNumber(ex.tokens && ex.tokens.total),
        tokensAvailable: ex.tokensAvailable !== false,
        cost: finiteNumber(ex.costEstimate),
        startTime: timeValue(ex.startedAt),
        turnCount,
        turns: (ex.turns || []).map(turnRow)
      };
    });
    if (sortBy === 'tokens') rows.sort((a, b) => b.value - a.value || b.startTime - a.startTime);
    else rows.sort((a, b) => b.startTime - a.startTime || b.value - a.value);
    return rows;
  }

  return {
    compactTime,
    exchangeRows,
    formatToolList,
    modelBreakdownRows,
    roundPercent,
    sessionSummary
  };
});
