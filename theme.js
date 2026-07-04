// Shared light/dark theme. Default is LIGHT; the user's choice is remembered.
// Runs in <head> so the theme is set before paint (no flash). Wires any
// element with id="themeBtn" as a toggle once the DOM is ready, and swaps the
// footer ClockPoint logo to the variant that blends with the active theme.
(function () {
  var saved = null;
  try { saved = localStorage.getItem('cp-theme'); } catch (e) {}
  document.documentElement.setAttribute('data-theme', saved === 'dark' ? 'dark' : 'light');

  function isDark() { return document.documentElement.getAttribute('data-theme') === 'dark'; }
  function label(btn) { btn.textContent = isDark() ? 'Light' : 'Dark'; }
  function footerLogos() {
    var src = isDark() ? 'clockpoint-logo.png' : 'clockpoint-logo.jpg'; // .png = dark bg, .jpg = light bg
    document.querySelectorAll('img.footer-logo').forEach(function (img) {
      if (img.getAttribute('src') !== src) img.setAttribute('src', src);
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    footerLogos();
    var btn = document.getElementById('themeBtn');
    if (!btn) return;
    label(btn);
    btn.addEventListener('click', function () {
      document.documentElement.setAttribute('data-theme', isDark() ? 'light' : 'dark');
      try { localStorage.setItem('cp-theme', document.documentElement.getAttribute('data-theme')); } catch (e) {}
      label(btn);
      footerLogos();
    });
  });
})();
