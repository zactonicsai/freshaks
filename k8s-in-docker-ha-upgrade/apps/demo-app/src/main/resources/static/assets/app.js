/*
 * Front-end logic shared by both demo applications. Plain JavaScript, no framework.
 * The page is static HTML; everything dynamic comes from the JSON API under /api.
 */
(function () {
  'use strict';

  // Short helper: find an element by its id.
  const $ = (id) => document.getElementById(id);

  // Remember whether the user was signed in, to notice when a session is lost.
  let wasSignedIn = false;

  // Read one cookie by name ("" when it does not exist).
  function cookie(name) {
    const row = document.cookie.split('; ').find((entry) => entry.startsWith(name + '='));
    return row ? decodeURIComponent(row.slice(name.length + 1)) : '';
  }

  // Call the API of this application. Cookies (the session) are sent along.
  function api(path, options) {
    const settings = Object.assign({ credentials: 'same-origin', cache: 'no-store' }, options || {});
    settings.headers = Object.assign({ Accept: 'application/json' }, settings.headers || {});
    return fetch(path, settings);
  }

  // Show or hide an element.
  function show(element, visible) {
    if (element) { element.hidden = !visible; }
  }

  // ---- Live status: which version and which pod answers right now -----------------

  async function refreshInfo() {
    const dot = $('live-dot');
    try {
      const response = await api('/api/info');
      if (!response.ok) { throw new Error('HTTP ' + response.status); }
      const info = await response.json();
      $('app-name').textContent = info.app;
      document.title = info.app;
      $('live-version').textContent = info.version;
      $('live-pod').textContent = info.pod;
      $('live-time').textContent = new Date().toLocaleTimeString();
      $('other-app-name').textContent = info.otherAppName;
      // Going straight to the login address of the other app signs the user in
      // there without a password: Keycloak still knows the browser (single sign-on).
      $('other-app-link').href = info.otherAppUrl + '/oauth2/authorization/keycloak';
      if (dot) { dot.dataset.state = 'up'; }
    } catch (error) {
      $('live-time').textContent = 'no answer at ' + new Date().toLocaleTimeString();
      if (dot) { dot.dataset.state = 'down'; }
    }
  }

  // ---- Who is signed in --------------------------------------------------------------

  async function loadMe() {
    let response;
    try {
      response = await api('/api/me');
    } catch (error) {
      return;
    }
    if (response.status === 401) {
      // No session on the pod that answered. If there was one before, the pod was
      // probably replaced (upgrade, node drain): sessions live in pod memory.
      show($('session-notice'), wasSignedIn);
      wasSignedIn = false;
      show($('view-signed-in'), false);
      show($('view-signed-out'), true);
      show($('panels'), false);
      show($('panels-locked'), true);
      return;
    }
    if (!response.ok) { return; }
    const me = await response.json();
    wasSignedIn = true;
    $('me-name').textContent = me.name || me.username;
    $('me-username').textContent = me.username;
    $('me-email').textContent = me.email || '';
    $('me-pod').textContent = me.sessionPod;
    $('me-issuer').textContent = me.issuer;
    const roles = $('me-roles');
    roles.replaceChildren();
    (me.roles || []).forEach((role) => {
      const chip = document.createElement('li');
      chip.className = roles.dataset.chipClass || '';
      chip.textContent = role;
      roles.appendChild(chip);
    });
    show($('session-notice'), false);
    show($('view-signed-out'), false);
    show($('view-signed-in'), true);
    show($('panels-locked'), false);
    show($('panels'), true);
    loadNotes();
  }

  // ---- Notes on the shared NFS volume ------------------------------------------------

  async function loadNotes() {
    const response = await api('/api/notes');
    if (!response.ok) { return; }
    const notes = await response.json();
    const list = $('notes-list');
    const template = $('note-template');
    list.replaceChildren();
    notes.forEach((note) => {
      const row = template.content.firstElementChild.cloneNode(true);
      // textContent (not innerHTML) keeps text typed by users harmless.
      row.querySelector('[data-field="text"]').textContent = note.text;
      row.querySelector('[data-field="author"]').textContent = note.author;
      row.querySelector('[data-field="app"]').textContent = note.app;
      row.querySelector('[data-field="pod"]').textContent = note.pod;
      row.querySelector('[data-field="time"]').textContent = new Date(note.createdAt).toLocaleString();
      list.appendChild(row);
    });
    show($('notes-empty'), notes.length === 0);
  }

  async function saveNote(event) {
    event.preventDefault();
    const field = $('note-text');
    const status = $('note-status');
    const text = field.value.trim();
    if (!text) { status.textContent = 'Type a note first.'; field.focus(); return; }
    status.textContent = 'Saving...';
    const response = await api('/api/notes', {
      method: 'POST',
      // The anti-forgery token: the server sent it as a cookie and expects it back as a header.
      headers: { 'Content-Type': 'application/json', 'X-XSRF-TOKEN': cookie('XSRF-TOKEN') },
      body: JSON.stringify({ text: text })
    });
    if (response.status === 201) {
      const note = await response.json();
      field.value = '';
      status.textContent = 'Saved by pod ' + note.pod + '.';
      loadNotes();
    } else if (response.status === 401) {
      status.textContent = 'Your session ended. Sign in again.';
      loadMe();
    } else {
      status.textContent = 'Could not save the note (HTTP ' + response.status + ').';
    }
  }

  // ---- Egress and admin buttons ------------------------------------------------------

  async function callAndShow(path, output, forbiddenMessage) {
    output.textContent = 'Calling ' + path + ' ...';
    try {
      const response = await api(path);
      if (response.status === 403) { output.textContent = forbiddenMessage; return; }
      if (response.status === 401) { output.textContent = 'Your session ended. Sign in again.'; loadMe(); return; }
      output.textContent = JSON.stringify(await response.json(), null, 2);
    } catch (error) {
      output.textContent = 'The request failed: ' + error.message;
    }
  }

  // ---- Sign out ----------------------------------------------------------------------

  async function signOut() {
    // A normal form POST (not fetch), because the server answers with a redirect to
    // Keycloak that the browser itself has to follow. The form needs the token as a field.
    const response = await api('/api/csrf');
    if (!response.ok) { window.location.reload(); return; }
    const csrf = await response.json();
    const input = $('logout-token');
    input.name = csrf.parameterName;
    input.value = csrf.token;
    $('logout-form').submit();
  }

  // ---- Wire everything up ------------------------------------------------------------

  document.addEventListener('DOMContentLoaded', () => {
    $('note-form').addEventListener('submit', saveNote);
    $('signout-button').addEventListener('click', signOut);
    $('egress-allowed').addEventListener('click', () =>
      callAndShow('/api/egress', $('egress-result'), ''));
    $('egress-blocked').addEventListener('click', () =>
      callAndShow('/api/egress/blocked', $('egress-result'), ''));
    $('admin-button').addEventListener('click', () =>
      callAndShow('/api/admin', $('admin-result'), '403 - your account does not have the role "admin". Try alice.'));
    refreshInfo();
    loadMe();
    // Ask again every 5 seconds: during an upgrade you can watch the pod name and
    // the version change while the page keeps working.
    setInterval(refreshInfo, 5000);
    // Check the session less often.
    setInterval(loadMe, 20000);
  });
}());
