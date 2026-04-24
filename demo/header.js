// ════════════════════════════════════════════════════════════════
//  Shared header + footer component for all demo pages
//  Ensures consistent nav, language dropdown, and DeFiRe branding
// ════════════════════════════════════════════════════════════════

const DEFIRE_LOGO = "data:image/png;base64,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";

(function () {
  const currentLang = localStorage.getItem('vault-lang') || 'en';
  const currentPage = location.pathname.split('/').pop() || 'index.html';
  const isDemo = currentPage === 'index.html' || currentPage === '';
  const isDocs = currentPage.startsWith('docs-');

  function docsHref() {
    const lang = localStorage.getItem('vault-lang') || 'en';
    return lang === 'es' ? 'docs-es.html' : 'docs-en.html';
  }

  // ── Build header HTML ──
  const headerHTML = `
    <div class="container header-row">
      <a href="https://defire.business/" target="_blank" rel="noopener" class="brand">
        <img src="${DEFIRE_LOGO}" alt="DeFiRe Labs" class="brand-icon" />
        <span>DeFiRe Labs</span>
      </a>
      <nav class="header-nav">
        <span class="erc-badge">ERC-8238</span>
        <a href="index.html" class="nav-link ${isDemo ? 'nav-active' : ''}">Demo</a>
        <a href="${docsHref()}" class="nav-link ${isDocs ? 'nav-active' : ''}" id="docs-link">Docs</a>
        <a href="https://github.com/DeFiRe-business/eip-proposal-5wrench" target="_blank" rel="noopener" class="nav-link">GitHub</a>
        <div class="lang-dropdown">
          <button class="lang-toggle" id="lang-btn" type="button">${currentLang.toUpperCase()} <span class="caret">&#9662;</span></button>
          <div class="lang-menu" id="lang-menu">
            <button data-lang="en" class="lang-option ${currentLang === 'en' ? 'active' : ''}">English</button>
            <button data-lang="es" class="lang-option ${currentLang === 'es' ? 'active' : ''}">Espanol</button>
          </div>
        </div>
      </nav>
      ${isDemo ? '<button id="connect-btn" class="primary">Connect MetaMask</button>' : ''}
    </div>
  `;

  // ── Build footer HTML ──
  const footerHTML = `
    <div class="container footer-row">
      <a href="https://defire.business/" target="_blank" rel="noopener" class="brand brand-sm">
        <img src="${DEFIRE_LOGO}" alt="DeFiRe Labs" class="brand-icon brand-icon-sm" />
        <span>DeFiRe Labs</span>
      </a>
      <span class="muted small">ERC-8238 reference implementation &middot; Sepolia testnet</span>
      <a href="https://github.com/ethereum/ERCs/pull/1703" target="_blank" rel="noopener" class="muted small">PR #1703</a>
    </div>
  `;

  // ── Inject ──
  const header = document.getElementById('site-header');
  if (header) header.innerHTML = headerHTML;

  const footer = document.getElementById('site-footer');
  if (footer) footer.innerHTML = footerHTML;

  // ── Language dropdown logic ──
  const langBtn = document.getElementById('lang-btn');
  const langMenu = document.getElementById('lang-menu');
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

      // Update button label
      langBtn.innerHTML = lang.toUpperCase() + ' <span class="caret">&#9662;</span>';

      // Update active state
      langMenu.querySelectorAll('.lang-option').forEach(function (o) {
        o.classList.toggle('active', o.dataset.lang === lang);
      });

      // Update docs link
      var docsLink = document.getElementById('docs-link');
      if (docsLink) docsLink.href = lang === 'es' ? 'docs-es.html' : 'docs-en.html';

      // If currently on a docs page, navigate to the other language
      if (isDocs) {
        window.location.href = lang === 'es' ? 'docs-es.html' : 'docs-en.html';
      }

      langMenu.classList.remove('open');
    });
  });
})();
