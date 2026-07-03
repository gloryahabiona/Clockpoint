// Adds a Show/Hide toggle to every password field (so people can verify what
// they typed). Works for fields present at load and any added later.
(function () {
  function enhance(inp) {
    if (inp.dataset.pwEnhanced) return;
    inp.dataset.pwEnhanced = '1';
    var wrap = document.createElement('div');
    wrap.style.cssText = 'position:relative;width:100%;';
    inp.parentNode.insertBefore(wrap, inp);
    wrap.appendChild(inp);
    inp.style.paddingRight = '58px';
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = 'Show';
    btn.setAttribute('aria-label', 'Show password');
    btn.style.cssText = 'position:absolute;right:8px;top:50%;transform:translateY(-50%);background:none;border:none;color:var(--text-soft);font-size:11px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;cursor:pointer;padding:6px;';
    btn.addEventListener('click', function () {
      var show = inp.type === 'password';
      inp.type = show ? 'text' : 'password';
      btn.textContent = show ? 'Hide' : 'Show';
    });
    wrap.appendChild(btn);
  }
  function scan(root) {
    if (root && root.querySelectorAll) root.querySelectorAll('input[type=password]').forEach(enhance);
  }
  document.addEventListener('DOMContentLoaded', function () {
    scan(document);
    new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        m.addedNodes.forEach(function (n) {
          if (n.nodeType !== 1) return;
          if (n.matches && n.matches('input[type=password]')) enhance(n);
          scan(n);
        });
      });
    }).observe(document.body, { childList: true, subtree: true });
  });
})();
