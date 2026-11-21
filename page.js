/* ===== page.js: index, chat, cabinet, admin ===== */
(function () {
  var page = document.body.getAttribute('data-page');
  var active = { index: '/', chat: '/chat.html', cabinet: '/cabinet.html', admin: '/admin.html' }[page] || '/';

  buildHeader(active).then(function () {
    if (page === 'index') initIndex();
    if (page === 'chat') initChat();
    if (page === 'cabinet') initCabinet();
    if (page === 'admin') initAdmin();
  });

  /* ---------- INDEX ---------- */
  function initIndex() {
    api('/api/site').then(function (s) {
      if (s.error) return;
      qs('#site-title').textContent = s.siteTitle || '';
      qs('#site-desc').textContent = s.siteDesc || '';
      var c = qs('#contacts');
      c.innerHTML = '';
      (s.contacts || '').split(/\r?\n/).forEach(function (line) {
        if (line.trim()) {
          var p = document.createElement('div');
          p.textContent = line;
          c.appendChild(p);
        }
      });
    });
  }

  /* ---------- CHAT ---------- */
  function initChat() {
    if (!ME) {
      qs('#chat-need-auth').style.display = 'block';
      return;
    }
    qs('#chat-area').style.display = 'block';
    var privateTo = null;
    var isAdmin = ME.role === 'admin' || ME.role === 'moderator';

    function renderMessages(msgs) {
      var box = qs('#messages');
      var wasBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 40;
      box.innerHTML = '';
      msgs.forEach(function (m) {
        var div = document.createElement('div');
        var mine = m.user === ME.login;
        div.className = 'msg' + (mine ? ' mine' : '');
        var html = '';
        if (isAdmin) {
          html += '<span class="del" data-id="' + m.id + '" title="Удалить">✕</span>';
        }
        html += '<span class="who">' + esc(m.fullname || m.user) + '</span>';
        html += '<span class="time">' + fmtTime(m.time) + '</span>';
        if (m.to) {
          var label = mine ? 'Личное для ' : 'Личное от ';
          html += '<span class="private-tag">' + label + esc(m.to) + '</span>';
        }
        html += '<div>' + esc(m.text) + '</div>';
        div.innerHTML = html;
        box.appendChild(div);
      });
      if (wasBottom) box.scrollTop = box.scrollHeight;
      box.querySelectorAll('.del').forEach(function (el) {
        el.onclick = function () {
          api('/api/chat/delete', { id: parseInt(el.getAttribute('data-id'), 10) }).then(refresh);
        };
      });
    }

    function refresh() {
      api('/api/chat').then(function (j) {
        if (j && j.messages) renderMessages(j.messages);
      });
    }

    function renderOnline(list) {
      var box = qs('#online-list');
      qs('#online-count').textContent = list.length;
      box.innerHTML = '';
      list.forEach(function (u) {
        var div = document.createElement('div');
        div.className = 'online-user';
        div.innerHTML = '<span><span class="dot"></span>' + esc(u.fullname || u.login) +
          ' <span class="role-badge rb-' + esc(u.role) + '">' + roleName(u.role) + '</span></span>';
        div.title = 'Нажмите, чтобы написать лично';
        div.onclick = function () {
          privateTo = u.login;
          qs('#private-mode').style.display = 'block';
          qs('#private-mode').textContent = 'Личное сообщение: ' + (u.fullname || u.login) + '  ✕';
          qs('#chat-text').focus();
        };
        box.appendChild(div);
      });
    }

    qs('#private-mode').onclick = function () {
      privateTo = null;
      qs('#private-mode').style.display = 'none';
    };

    qs('#chat-form').onsubmit = function (e) {
      e.preventDefault();
      var t = qs('#chat-text').value.trim();
      if (!t) return;
      var payload = { text: t };
      if (privateTo) payload.to = privateTo;
      api('/api/chat/send', payload).then(function (j) {
        if (j.error) { showBar('Ошибка отправки: ' + j.error, true); return; }
        qs('#chat-text').value = '';
        refresh();
      });
    };

    function tick() {
      api('/api/chat/online').then(function (j) {
        if (j && j.online) renderOnline(j.online);
      });
    }
    refresh(); tick();
    setInterval(tick, 3000);
    setInterval(refresh, 3000);
  }

  /* ---------- CABINET ---------- */
  function initCabinet() {
    if (!ME) {
      qs('#cab-need-auth').style.display = 'block';
      return;
    }
    qs('#cab-area').style.display = 'block';
    qs('#ip-note').textContent = 'Ваша учётная запись привязана к IP: ' + (ME.ip || '-');
    qs('#cab-fn').value = ME.fullname || '';
    qs('#cab-birth').value = ME.birth || '';
    qs('#cab-unit').value = ME.unit || '';
    qs('#cab-phone').value = ME.phone || '';
    qs('#cab-form').onsubmit = function (e) {
      e.preventDefault();
      api('/api/profile', {
        fullname: qs('#cab-fn').value.trim(),
        birth: qs('#cab-birth').value,
        unit: qs('#cab-unit').value.trim(),
        phone: qs('#cab-phone').value.trim()
      }).then(function (j) {
        if (j.error) { showBar('Ошибка: ' + j.error, true); return; }
        showBar('Профиль сохранён');
        buildHeader(active);
      });
    };
  }

  /* ---------- ADMIN ---------- */
  function initAdmin() {
    if (!ME || ME.role !== 'admin') {
      qs('#admin-need-auth').style.display = 'block';
      return;
    }
    qs('#admin-area').style.display = 'block';
    var tab = 'users';
    function setTab(t) {
      tab = t;
      ['users', 'settings', 'images', 'data'].forEach(function (x) {
        qs('#tabbtn-' + x).className = (x === t) ? '' : 'ghost';
        qs('#tab-' + x).style.display = (x === t) ? 'block' : 'none';
      });
    }
    qs('#tabbtn-users').onclick = function () { setTab('users'); };
    qs('#tabbtn-settings').onclick = function () { setTab('settings'); };
    qs('#tabbtn-images').onclick = function () { setTab('images'); };
    qs('#tabbtn-data').onclick = function () { setTab('data'); };

    /* users */
    function loadUsers() {
      api('/api/admin/users').then(function (j) {
        if (j.error) return;
        var body = qs('#users-tbody');
        body.innerHTML = '';
        j.users.forEach(function (u) {
          var tr = document.createElement('tr');
          var isSelf = u.login === ME.login;
          var roleOpts = ['user', 'local', 'moderator', 'admin'].map(function (r) {
            return '<option value="' + r + '"' + (r === u.role ? ' selected' : '') + '>' + roleName(r) + '</option>';
          }).join('');
          tr.innerHTML =
            '<td>' + esc(u.login) + (isSelf ? ' <span class="muted">(вы)</span>' : '') + '</td>' +
            '<td>' + esc(u.fullname) + '</td>' +
            '<td>' + esc(u.ip) + '</td>' +
            '<td><select data-login="' + esc(u.login) + '" class="role-sel"' + (isSelf ? ' disabled' : '') + '>' + roleOpts + '</select></td>' +
            '<td>' + (u.blocked ? '<span style="color:var(--bad)">заблокирован</span>' : 'активен') + '</td>' +
            '<td>' + (isSelf ? '' :
              '<button class="small ghost block-btn" data-login="' + esc(u.login) + '" data-blocked="' + (u.blocked ? '1' : '0') + '">' +
              (u.blocked ? 'Разблокировать' : 'Заблокировать') + '</button> ' +
              '<button class="small danger del-btn" data-login="' + esc(u.login) + '">Удалить</button>') + '</td>';
          body.appendChild(tr);
        });
        body.querySelectorAll('.role-sel').forEach(function (sel) {
          sel.onchange = function () {
            api('/api/admin/user', { login: sel.getAttribute('data-login'), role: sel.value })
              .then(function (j) { if (j.error) { showBar('Ошибка: ' + j.error, true); loadUsers(); } else showBar('Роль обновлена'); });
          };
        });
        body.querySelectorAll('.block-btn').forEach(function (btn) {
          btn.onclick = function () {
            api('/api/admin/user', {
              login: btn.getAttribute('data-login'),
              blocked: btn.getAttribute('data-blocked') !== '1'
            }).then(function (j) { if (j.error) { showBar('Ошибка: ' + j.error, true); } loadUsers(); });
          };
        });
        body.querySelectorAll('.del-btn').forEach(function (btn) {
          btn.onclick = function () {
            if (!confirm('Удалить пользователя ' + btn.getAttribute('data-login') + '?')) return;
            api('/api/admin/user', { login: btn.getAttribute('data-login'), del: true })
              .then(function (j) { if (j.error) showBar('Ошибка: ' + j.error, true); loadUsers(); });
          };
        });
      });
    }

    /* settings */
    function loadSettings() {
      api('/api/admin/settings').then(function (j) {
        if (j.error) return;
        qs('#st-title').value = j.siteTitle || '';
        qs('#st-desc').value = j.siteDesc || '';
        qs('#st-contacts').value = j.contacts || '';
        qs('#st-port').value = j.port || 80;
        qs('#st-allowed').value = (j.allowedIps || []).join('\n');
        qs('#st-adminips').value = (j.adminIps || []).join('\n');
        qs('#st-currentip').textContent = 'Ваш текущий IP: ' + (j.currentIp || '-');
      });
    }
    qs('#st-form').onsubmit = function (e) {
      e.preventDefault();
      api('/api/admin/settings/save', {
        siteTitle: qs('#st-title').value,
        siteDesc: qs('#st-desc').value,
        contacts: qs('#st-contacts').value,
        port: parseInt(qs('#st-port').value, 10) || 80,
        allowedIpsText: qs('#st-allowed').value,
        adminIpsText: qs('#st-adminips').value
      }).then(function (j) {
        if (j.error) { showBar('Ошибка: ' + j.error, true); return; }
        showBar(j.restartNeeded ? 'Сохранено. Перезапустите сервер для смены порта' : 'Сохранено');
      });
    };

    /* images */
    function wireUpload(kind, inputId, prevId) {
      qs(inputId).onchange = function () {
        var f = this.files[0];
        if (!f) return;
        if (f.size > 5 * 1024 * 1024) { showBar('Файл больше 5 МБ', true); return; }
        var reader = new FileReader();
        reader.onload = function () {
          api('/api/admin/upload', { kind: kind, data: reader.result }).then(function (j) {
            if (j.error) { showBar('Ошибка загрузки: ' + j.error, true); return; }
            showBar('Картинка обновлена. Обновите страницу по Ctrl+F5');
            var v = Date.now();
            qs(prevId).src = (kind === 'hero' ? '/img/hero.jpg?v=' : '/icon.jpg?v=') + v;
            document.body.style.backgroundImage =
              'linear-gradient(rgba(10,14,26,.86),rgba(10,14,26,.94)),url("/img/hero.jpg?v=' + v + '")';
          });
        };
        reader.readAsDataURL(f);
      };
    }
    wireUpload('hero', '#up-hero', '#prev-hero');
    wireUpload('icon', '#up-icon', '#prev-icon');

    /* export */
    qs('#exp-settings').onclick = function () { exportFile('settings'); };
    qs('#exp-users').onclick = function () { exportFile('users'); };
    qs('#exp-chat').onclick = function () { exportFile('chat'); };
    qs('#exp-stats').onclick = function () { exportFile('stats'); };
    function exportFile(name) {
      fetch('/api/admin/export?name=' + name, { headers: { 'X-Token': TOKEN } })
        .then(function (r) { return r.blob(); })
        .then(function (blob) {
          var a = document.createElement('a');
          a.href = URL.createObjectURL(blob);
          a.download = name + '.json';
          a.click();
        });
    }

    setTab('users');
    loadUsers();
    loadSettings();
  }
})();
