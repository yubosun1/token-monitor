// Injected at document start. Replaces Electron's preload.js: exposes the
// same `window.tokenMonitor` surface, backed by the native bridge via
// webkit.messageHandlers. Invokes resolve asynchronously, sends are
// fire-and-forget, pushes fan out to per-event listeners.
(function () {
  'use strict';
  if (window.__tmBridgeInstalled) return;
  window.__tmBridgeInstalled = true;

  var pending = new Map();
  var seq = 0;
  var listeners = {};
  // Safety net against a promise that never resolves (e.g. the web view is
  // torn down between postMessage and the native async reply): reject after
  // a generous deadline so `pending` cannot leak and callers can recover.
  var INVOKE_TIMEOUT_MS = 120000;

  function invoke(method, args) {
    return new Promise(function (resolve, reject) {
      var id = ++seq;
      var timer = setTimeout(function () {
        if (pending.delete(id)) {
          reject(new Error('bridge invoke timeout: ' + method));
        }
      }, INVOKE_TIMEOUT_MS);
      pending.set(id, { resolve: resolve, reject: reject, timer: timer });
      try {
        window.webkit.messageHandlers.bridge.postMessage({ id: id, method: method, args: args || [] });
      } catch (e) {
        clearTimeout(timer);
        pending.delete(id);
        reject(e);
      }
    });
  }

  function send(method, args) {
    try {
      window.webkit.messageHandlers.bridge.postMessage({ method: method, args: args || [] });
    } catch (e) { /* ignore */ }
  }

  function on(event, callback) {
    if (typeof callback !== 'function') return function () {};
    if (!listeners[event]) listeners[event] = new Set();
    listeners[event].add(callback);
    return function () { listeners[event].delete(callback); };
  }

  window.__tmResolve = function (id, value) {
    var p = pending.get(id);
    if (p) { pending.delete(id); clearTimeout(p.timer); p.resolve(value); }
  };
  window.__tmReject = function (id, error) {
    var p = pending.get(id);
    if (p) { pending.delete(id); clearTimeout(p.timer); p.reject(error instanceof Error ? error : new Error(String(error))); }
  };
  window.__tmPush = function (event, payload) {
    var set = listeners[event];
    if (!set) return;
    set.forEach(function (cb) { try { cb(payload); } catch (e) { /* ignore */ } });
  };
  window.__tmOnLoad = function () { send('window:contentReady'); };

  // Removed settings sections leave some DOM lookups null; treat null as an
  // empty iterable everywhere Array.from is called on one.
  var nativeArrayFrom = Array.from;
  try {
    Array.from = function (value, mapFn, thisArg) {
      return nativeArrayFrom(value == null ? [] : value, mapFn, thisArg);
    };
  } catch (_) {}

  // Surface uncaught renderer errors to the native log (dev aid).
  window.addEventListener('error', function (e) {
    var src = '';
    try {
      if (e.target && e.target !== window) {
        src = e.target.src || e.target.href || (e.target.tagName || '') + '#' + (e.target.id || '');
      }
    } catch (_) {}
    var detail = '';
    try { if (e.error && e.error.stack) detail = String(e.error.stack).split('\n').slice(0, 3).join(' | '); } catch (_) {}
    try { send('window:error', [String(e.message || e.error || 'unknown error'), e.filename || src || '', e.lineno || 0, detail]); } catch (_) {}
  });
  window.addEventListener('unhandledrejection', function (e) {
    try { send('window:error', [String((e.reason && e.reason.message) || e.reason || 'unhandled rejection')]); } catch (_) {}
  });

  window.tokenMonitor = {
    getSettings: function () { return invoke('settings:get'); },
    updateSettings: function (patch) { return invoke('settings:update', [patch]); },
    saveSubscriptions: function (subscriptions, base) { return invoke('subscriptions:save', [subscriptions, base]); },
    adoptOrphanedSubscriptions: function () { return invoke('subscriptions:adoptOrphans'); },
    discardOrphanedSubscriptions: function () { return invoke('subscriptions:discardOrphans'); },
    lookupModelPricing: function (modelId) { return invoke('pricing:lookup', [modelId]); },
    getStats: function (options) { return invoke('stats:get', [options]); },
    getSessionDetail: function (args) { return invoke('session:getDetail', [args]); },
    getStreamStatus: function () { return invoke('stream:status'); },
    openDashboard: function () { return invoke('dashboard:open'); },
    getDashboardHistory: function () { return invoke('dashboard:getHistory'); },
    onDashboardHistoryChanged: function (callback) { return on('dashboard:historyChanged', callback); },
    dashboard: {
      ready: function () { send('dashboard:ready'); },
      close: function () { send('dashboard:close'); }
    },
    onOpenSettings: function (callback) { return on('settings:open', callback); },
    onVisibility: function (callback) { return on('window:visibility', callback); },
    onStatsPush: function (callback) { return on('stats:push', callback); },
    onSettingsPush: function (callback) { return on('settings:push', callback); },
    getAppInfo: function () { return invoke('app:getInfo'); },
    copyText: function (text) { return invoke('clipboard:write', [text]); },
    clientSources: function (clientId) { return invoke('usage:clientSources', [clientId]); },
    revealClientSource: function (clientId) { return invoke('usage:revealClientSource', [clientId]); },
    rescanClient: function (clientId) { return invoke('usage:rescanClient', [clientId]); },
    openExternal: function (url) { return invoke('app:openExternal', [url]); },
    openUserData: function () { return invoke('app:openUserData'); },
    mimo: {
      accounts: function () { return invoke('mimo:accounts'); },
      addAccount: function (cookieHeader) { return invoke('mimo:addAccount', [cookieHeader]); },
      openConsole: function () { return invoke('mimo:openConsole'); },
      removeAccount: function (id) { return invoke('mimo:removeAccount', [id]); },
      setAccountEnabled: function (id, enabled) { return invoke('mimo:setAccountEnabled', [id, enabled]); }
    },
    setFloatingBubbleCollapsedSize: function (size) { return invoke('floatingBubble:setCollapsedSize', [size]); },
    signalContentReady: function () { send('window:contentReady'); },
    setViewState: function (patch) { send('window:viewState', [patch]); },
    setTrayIcons: function (icons) { return invoke('tray:setIcons', [icons]); },
    openrouter: {
      getProfiles: function () { return invoke('openrouter:getProfiles'); },
      saveProfile: function (name, apiKey) { return invoke('openrouter:saveProfile', [name, apiKey]); },
      deleteProfile: function (name) { return invoke('openrouter:deleteProfile', [name]); },
      renameProfile: function (oldName, newName) { return invoke('openrouter:renameProfile', [oldName, newName]); },
      setProfileEnabled: function (name, enabled) { return invoke('openrouter:setProfileEnabled', [name, enabled]); }
    },
    thirdparty: {
      getProfiles: function () { return invoke('thirdparty:getProfiles'); },
      saveProfile: function (profile) { return invoke('thirdparty:saveProfile', [profile]); },
      deleteProfile: function (name) { return invoke('thirdparty:deleteProfile', [name]); },
      renameProfile: function (oldName, newName) { return invoke('thirdparty:renameProfile', [oldName, newName]); },
      setProfileEnabled: function (name, enabled) { return invoke('thirdparty:setProfileEnabled', [name, enabled]); }
    },
    codex: {
      accounts: function () { return invoke('codex:accounts'); },
      addAccount: function (options) { return invoke('codex:addAccount', [options]); },
      selectWorkspace: function (options) { return invoke('codex:selectWorkspace', [options]); },
      cancelLogin: function (options) { return invoke('codex:cancelLogin', [options]); },
      removeAccount: function (id) { return invoke('codex:removeAccount', [id]); },
      setAccountEnabled: function (id, enabled) { return invoke('codex:setAccountEnabled', [id, enabled]); },
      switchSystemAccount: function (id) { return invoke('codex:switchSystemAccount', [id]); },
      refreshAccountLimits: function (id) { return invoke('codex:refreshAccountLimits', [id]); }
    },
    close: function () { send('window:close'); }
  };

  // Electron used `-webkit-app-region: drag` on the titlebar; WKWebView
  // ignores it, so forward titlebar presses to the native drag loop.
  document.addEventListener('pointerdown', function (e) {
    if (e.button !== 0) return;
    var el = e.target;
    if (!(el instanceof Element)) return;
    if (!el.closest('.titlebar') && !el.closest('.dash-header')) return;
    if (el.closest('button, input, select, a, .tabs, .window-actions, .actions-hotspot, .no-drag')) return;
    send('window:dragStart');
  }, true);
})();
