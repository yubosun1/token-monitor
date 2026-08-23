'use strict';

(function exposeThemePresets(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.TokenMonitorThemePresets = api;
})(typeof window !== 'undefined' ? window : null, function createThemePresetsApi() {
  const INTERFACE_COLOR_KEYS = ['accent', 'bg', 'text', 'muted'];

  const THEME_VAR_MAP = {
    accent: '--accent',
    bg: '--glass-rgb',
    text: '--text',
    muted: '--muted'
  };

  const DEFAULT_THEME = {
    accent: '#b7ead4',
    bg: '#303438',
    text: '#eef5fb',
    muted: '#a3adbb'
  };

  const THEME_PRESETS = [
    { id: 'default', colors: { ...DEFAULT_THEME } }
  ];

  function hexToRgbTriplet(hex) {
    const v = String(hex).replace('#', '');
    return `${parseInt(v.slice(0, 2), 16)}, ${parseInt(v.slice(2, 4), 16)}, ${parseInt(v.slice(4, 6), 16)}`;
  }

  function normalizeOverrides(overrides) {
    return overrides && typeof overrides === 'object' ? overrides : {};
  }

  function mergeThemeColors(_overrides) {
    return { ...DEFAULT_THEME };
  }

  function themeCssVarEntries(_overrides) {
    return [];
  }

  function mergeVendorColors(brand, _overrides) {
    return { ...(brand || {}) };
  }

  return {
    INTERFACE_COLOR_KEYS,
    THEME_VAR_MAP,
    DEFAULT_THEME,
    THEME_PRESETS,
    normalizeOverrides,
    mergeThemeColors,
    hexToRgbTriplet,
    themeCssVarEntries,
    mergeVendorColors
  };
});
