// Shared light/dark theme. Default is LIGHT; the user's choice is remembered.
// Runs in <head> so the theme is set before paint (no flash). Wires any
// element with id="themeBtn" as a toggle once the DOM is ready.
(function () {
  var saved = null;
  try { saved = localStorage.getItem('cp-theme'); } catch (e) {}
  document.documentElement.setAttribute('data-theme', saved === 'dark' ? 'dark' : 'light');

  function label(btn) {
    btn.textContent = document.documentElement.getAttribute('data-theme') === 'dark' ? 'Light' : 'Dark';
  }
  document.addEventListener('DOMContentLoaded', function () {
    var btn = document.getElementById('themeBtn');
    if (!btn) return;
    label(btn);
    btn.addEventListener('click', function () {
      var next = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      document.documentElement.setAttribute('data-theme', next);
      try { localStorage.setItem('cp-theme', next); } catch (e) {}
      label(btn);
    });
  });
})();
