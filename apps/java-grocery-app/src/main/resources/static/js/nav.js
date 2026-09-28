/* Draws the top bar. It asks /api/me "who am I?" and shows only the doors your badge can open. */
(function () {
  var nav = document.getElementById('nav');
  if (!nav) { return; }

  function link(href, label, active) {
    return '<a href="' + href + '" class="px-3 py-1.5 rounded-lg text-sm font-medium ' +
      (active ? 'bg-brand text-white' : 'text-stone-700 hover:bg-stone-100') + '">' + label + '</a>';
  }

  function has(roles, r) { return roles.indexOf(r) !== -1; }

  function render(me) {
    var here = window.location.pathname;
    var roles = me ? (me.roles || []) : [];
    var links = link('/', 'Home', here === '/' || here === '/index.html');
    if (me) {
      links += link('/app/shop.html', '🛒 Shop', here === '/app/shop.html');
      if (has(roles, 'cashier') || has(roles, 'manager')) {
        links += link('/app/register.html', '🧾 Register', here === '/app/register.html');
      }
      if (has(roles, 'manager')) {
        links += link('/app/office.html', '📊 Office', here === '/app/office.html');
      }
      links += link('/app/me.html', '🪪 My badge', here === '/app/me.html');
    }

    var right;
    if (me) {
      right = '<span class="text-sm text-stone-600 mr-2 hidden sm:inline">' + FM.esc(me.username) +
        ' <span class="text-stone-400">·</span> ' + roles.map(function (r) { return FM.esc(r); }).join(', ') + '</span>' +
        '<button id="logout-btn" class="px-3 py-1.5 rounded-lg text-sm font-medium border border-stone-300 hover:bg-stone-100">Log out</button>';
    } else {
      right = '<a id="login-link" href="/oauth2/authorization/keycloak" ' +
        'class="px-3 py-1.5 rounded-lg text-sm font-medium bg-brand text-white hover:bg-brand-dark">Log in</a>';
    }

    nav.innerHTML =
      '<div class="max-w-5xl mx-auto px-4 h-14 flex items-center justify-between gap-3">' +
      '<a href="/" class="font-bold text-brand text-lg tracking-tight">🥬 Fresh Mart <span class="text-xs font-normal text-stone-500">Java store</span></a>' +
      '<div class="flex items-center gap-1 flex-wrap">' + links + '</div>' +
      '<div class="flex items-center">' + right + '</div></div>';

    var logout = document.getElementById('logout-btn');
    if (logout) {
      logout.addEventListener('click', function () {
        // Spring Security wants a POST with the CSRF token; a tiny form does exactly that.
        var form = document.createElement('form');
        form.method = 'POST';
        form.action = '/logout';
        var csrf = document.createElement('input');
        csrf.type = 'hidden'; csrf.name = '_csrf'; csrf.value = FM.cookie('XSRF-TOKEN');
        form.appendChild(csrf);
        document.body.appendChild(form);
        form.submit();
      });
    }
  }

  FM.api('/api/me', { noRedirect: true })
    .then(function (me) { window.FM_ME = me; render(me); document.dispatchEvent(new CustomEvent('fm:me', { detail: me })); })
    .catch(function () { window.FM_ME = null; render(null); document.dispatchEvent(new CustomEvent('fm:me', { detail: null })); });
})();
