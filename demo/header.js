// ════════════════════════════════════════════════════════════════
//  Shared header + footer for all demo pages
//  Header injects immediately, footer waits for DOMContentLoaded
// ════════════════════════════════════════════════════════════════

(function () {
  var LOGO = "IconDeFireLabs.png";
  var currentLang = localStorage.getItem('vault-lang') || 'en';
  var currentPage = location.pathname.split('/').pop() || 'index.html';
  var isDemo = currentPage === 'index.html' || currentPage === '';
  var isDocs = currentPage.startsWith('docs-');

  function docsHref() {
    var lang = localStorage.getItem('vault-lang') || 'en';
    return lang === 'es' ? 'docs-es.html' : 'docs-en.html';
  }

  var headerHTML = ''
    + '<div class="container header-row">'
    +   '<a href="https://defire.business/" target="_blank" rel="noopener" class="brand">'
    +     '<img src="' + LOGO + '" alt="DeFiRe Labs" class="brand-icon" />'
    +     '<span>DeFiRe Labs</span>'
    +   '</a>'
    +   '<nav class="header-nav">'
    +     '<span class="erc-badge">ERC-8238</span>'
    +     '<a href="index.html" class="nav-link ' + (isDemo ? 'nav-active' : '') + '">Demo</a>'
    +     '<a href="' + docsHref() + '" class="nav-link ' + (isDocs ? 'nav-active' : '') + '" id="docs-link">Docs</a>'
    +     '<a href="https://github.com/DeFiRe-business/eip-proposal-5wrench" target="_blank" rel="noopener" class="nav-link">GitHub</a>'
    +     '<div class="lang-dropdown">'
    +       '<button class="lang-toggle" id="lang-btn" type="button">' + currentLang.toUpperCase() + ' <span class="caret">&#9662;</span></button>'
    +       '<div class="lang-menu" id="lang-menu">'
    +         '<button data-lang="en" class="lang-option ' + (currentLang === 'en' ? 'active' : '') + '">English</button>'
    +         '<button data-lang="es" class="lang-option ' + (currentLang === 'es' ? 'active' : '') + '">Espanol</button>'
    +       '</div>'
    +     '</div>'
    +   '</nav>'
    +   (isDemo ? '<button id="connect-btn" class="primary">Connect MetaMask</button>' : '')
    + '</div>';

  var footerHTML = ''
    + '<div class="container footer-row">'
    +   '<a href="https://defire.business/" target="_blank" rel="noopener" class="brand brand-sm">'
    +     '<img src="' + LOGO + '" alt="DeFiRe Labs" class="brand-icon brand-icon-sm" />'
    +     '<span>DeFiRe Labs</span>'
    +   '</a>'
    +   '<span class="muted small">ERC-8238 reference implementation &middot; Sepolia testnet</span>'
    +   '<a href="https://github.com/ethereum/ERCs/pull/1703" target="_blank" rel="noopener" class="muted small">PR #1703</a>'
    + '</div>';

  // Header: inject now (element exists above the script tag)
  var header = document.getElementById('site-header');
  if (header) header.innerHTML = headerHTML;

  // Footer + lang dropdown: wait for full DOM
  document.addEventListener('DOMContentLoaded', function () {
    var footer = document.getElementById('site-footer');
    if (footer) footer.innerHTML = footerHTML;

    // Language dropdown
    var langBtn = document.getElementById('lang-btn');
    var langMenu = document.getElementById('lang-menu');
    if (!langBtn || !langMenu) return;

    langBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      langMenu.classList.toggle('open');
    });

    document.addEventListener('click', function () {
      langMenu.classList.remove('open');
    });

    langMenu.querySelectorAll('.lang-option').forEach(function (opt) {
      opt.addEventListener('click', function () {
        var lang = opt.dataset.lang;
        localStorage.setItem('vault-lang', lang);
        langBtn.innerHTML = lang.toUpperCase() + ' <span class="caret">&#9662;</span>';
        langMenu.querySelectorAll('.lang-option').forEach(function (o) {
          o.classList.toggle('active', o.dataset.lang === lang);
        });
        var docsLink = document.getElementById('docs-link');
        if (docsLink) docsLink.href = lang === 'es' ? 'docs-es.html' : 'docs-en.html';
        if (isDocs) {
          window.location.href = lang === 'es' ? 'docs-es.html' : 'docs-en.html';
        }
        langMenu.classList.remove('open');
      });
    });
  });
})();
