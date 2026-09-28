/* Fresh Mart helper toolbox — shared by every page.
 * FM.api(path, options) talks to the Java API with the same cookies the browser got at login.
 *   - adds the CSRF header (X-XSRF-TOKEN) from the XSRF-TOKEN cookie on every request
 *   - 401 (no badge)  -> go log in through Keycloak
 *   - 403 (wrong badge) -> go to the friendly "forbidden" page
 */
window.FM = (function () {
  function cookie(name) {
    var parts = document.cookie.split(';');
    for (var i = 0; i < parts.length; i++) {
      var kv = parts[i].trim().split('=');
      if (kv[0] === name) { return decodeURIComponent(kv.slice(1).join('=')); }
    }
    return '';
  }

  async function api(path, options) {
    options = options || {};
    var headers = Object.assign({ 'Accept': 'application/json' }, options.headers || {});
    var init = { method: options.method || 'GET', headers: headers, credentials: 'same-origin' };
    if (options.body !== undefined) {
      headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(options.body);
    }
    var xsrf = cookie('XSRF-TOKEN');
    if (xsrf) { headers['X-XSRF-TOKEN'] = xsrf; }

    var res = await fetch(path, init);
    if (res.status === 401) {
      if (!options.noRedirect) { window.location.href = '/oauth2/authorization/keycloak'; }
      throw new Error('Please log in');
    }
    if (res.status === 403) {
      if (!options.noRedirect) { window.location.href = '/app/forbidden.html'; }
      throw new Error('Your badge does not open this door');
    }
    if (!res.ok) {
      var message = res.statusText;
      try { var err = await res.json(); if (err && err.message) { message = err.message; } } catch (e) { /* not json */ }
      throw new Error(message);
    }
    if (res.status === 204) { return null; }
    return res.json();
  }

  function money(n) { return '$' + Number(n || 0).toFixed(2); }
  function el(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s === undefined || s === null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function when(iso) { return iso ? new Date(iso).toLocaleString() : ''; }
  function toast(msg, ok) {
    var box = el('toast');
    if (!box) { return; }
    box.textContent = msg;
    box.className = 'fixed bottom-4 right-4 px-4 py-3 rounded-xl shadow-lg text-sm font-medium ' +
      (ok === false ? 'bg-red-600 text-white' : 'bg-brand text-white');
    box.classList.remove('hidden');
    clearTimeout(box._t);
    box._t = setTimeout(function () { box.classList.add('hidden'); }, 3500);
  }

  return { api: api, money: money, el: el, esc: esc, when: when, toast: toast, cookie: cookie };
})();
