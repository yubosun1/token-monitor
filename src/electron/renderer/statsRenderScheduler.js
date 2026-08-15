'use strict';

(function exposeStatsRenderScheduler(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.TokenMonitorStatsRenderScheduler = api;
})(typeof window !== 'undefined' ? window : null, function createStatsRenderSchedulerApi() {
  function createStatsRenderScheduler({ isHidden, render }) {
    if (typeof isHidden !== 'function') throw new TypeError('isHidden must be a function');
    if (typeof render !== 'function') throw new TypeError('render must be a function');
    let renderPending = false;
    let rafHandle = null;

    function runRender() {
      rafHandle = null;
      renderPending = false;
      render();
    }

    function request() {
      if (isHidden()) {
        renderPending = true;
        return;
      }
      renderPending = false;
      // Coalesce multiple requests within the same animation frame into a
      // single render: a burst of stats pushes renders once, not N times.
      if (rafHandle != null) return;
      rafHandle = requestAnimationFrame(runRender);
    }

    function flush() {
      if (rafHandle != null) {
        cancelAnimationFrame(rafHandle);
        rafHandle = null;
      }
      if (!renderPending || isHidden()) return;
      runRender();
    }

    return {
      flush,
      request
    };
  }

  return {
    createStatsRenderScheduler
  };
});
