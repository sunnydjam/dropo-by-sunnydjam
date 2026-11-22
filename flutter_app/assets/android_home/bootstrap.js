// Keep this small bootstrap compatible with older Android WebViews. It must
// still report failure if a newer scene script cannot be parsed at all.
(function () {
  var failed = false;
  function reportFailure() {
    if (failed) return;
    failed = true;
    if (window.DropoScene && typeof window.DropoScene.postMessage === 'function') {
      window.DropoScene.postMessage('{"action":"failed"}');
    }
  }
  window.addEventListener('error', function (event) {
    var target = event.target;
    if (target && target !== window) {
      if (target.tagName === 'SCRIPT' ||
          (target.tagName === 'LINK' && target.rel === 'stylesheet')) {
        reportFailure();
      }
      return;
    }
    reportFailure();
  }, true);
  window.addEventListener('unhandledrejection', reportFailure);
}());
