/* ===== app.js: auth, header, modals ===== */
(function () {
  window.TOKEN = localStorage.getItem('token') || '';
  window.ME = null;

  window.esc = function (s) {
    var out = '';
    var str = String(s == null ? '' : s);
    for (var i = 0; i < str.length; i++) {
      var c = str[i];
      if (c === '&') out += '&amp;';
      else if (c === '<') out += '&lt;';
      else if (c === '>') out += '&gt;';
      else if (c === '"') out += '&quot;';
      else if (c === String.fromCharCode(39)) out += '&#39;';
      else out += c;
    }
    return out;
  };

  window.api = function (path, data) {
    var opts = { method: data ? 'POST' : 'GET', headers: { 'X-Token': TOKEN } };
    if (data) { opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(data); }
    return fetch(path, opts).then(function (r) {
      return r.json().catch(function () { return { error: 'server_error' }; });
    }).then(function (j) {
      if (j && j.error === 'unauthorized') {
        localStorage.removeItem('token'); TOKEN = '';
      }
      return j;
    });
  };

  window.qs = function (s) { return document.querySelector(s); };
  window.roleName = function (r) {
    return ({ user: 'Пользователь', local: 'Местный', moderator: 'Модератор', admin: 'Администратор' })[r] || r;
  };
  window.fmtTime = function (unix) {
    var d = new Date(unix * 1000);
    var h = ('0' + d.getHours()).slice(-2), m = ('0' + d.getMinutes()).slice(-2);
    return h + ':' + m;
  };

  function showBar(text, isErr) {
    var bar = qs('#appbar');
    if (!bar) {
      bar = document.createElement('div'); bar.id = 'appbar'; bar.className = 'msgbar';
      document.body.appendChild(bar);
    }
    bar.textContent = text;
    bar.style.display = 'block';
    bar.style.borderColor = isErr ? 'var(--bad)' : 'var(--ok)';
    clearTimeout(bar._t);
    bar._t = setTimeout(function () { bar.style.display = 'none'; }, 3500);
  }
  window.showBar = showBar;

  function modalHtml() {
    return '<div class="modal-back" id="authmodal"><div class="modal">' +
      '<div class="tabs">' +
      '<button id="tab-login">Вход</button><button id="tab-reg" class="ghost">Регистрация</button>' +
      '</div>' +
      '<div id="pane-login">' +
      '<label>Имя пользователя</label><input id="lg-login">' +
      '<label>Пароль</label><input id="lg-pass" type="password">' +
      '<div class="err" id="lg-err"></div>' +
      '<button id="lg-go">Войти</button> ' +
      '<button class="ghost" id="modal-close">Закрыть</button>' +
      '</div>' +
      '<div id="pane-reg" style="display:none">' +
      '<label>Имя пользователя (латиницей)</label><input id="rg-login">' +
      '<label>ФИО</label><input id="rg-fn">' +
      '<label>Пароль</label><input id="rg-pass" type="password">' +
      '<div class="err" id="rg-err"></div>' +
      '<button id="rg-go">Зарегистрироваться</button> ' +
      '<button class="ghost" id="modal-close2">Закрыть</button>' +
      '</div>' +
      '</div></div>';
  }

  window.showAuthModal = function (reg) {
    if (qs('#authmodal')) { qs('#authmodal').remove(); }
    document.body.insertAdjacentHTML('beforeend', modalHtml());
    var back = qs('#authmodal');
    back.classList.add('show');
    function close() { back.classList.remove('show'); }
    qs('#modal-close').onclick = close;
    qs('#modal-close2').onclick = close;
    function setTab(isReg) {
      qs('#pane-login').style.display = isReg ? 'none' : 'block';
      qs('#pane-reg').style.display = isReg ? 'block' : 'none';
      qs('#tab-login').className = isReg ? 'ghost' : '';
      qs('#tab-reg').className = isReg ? '' : 'ghost';
    }
    qs('#tab-login').onclick = function () { setTab(false); };
    qs('#tab-reg').onclick = function () { setTab(true); };
    if (reg) setTab(true);
    qs('#lg-go').onclick = function () {
      api('/api/login', { login: qs('#lg-login').value, password: qs('#lg-pass').value }).then(function (j) {
        if (j.error) {
          qs('#lg-err').textContent = ({ no_user: 'Пользователь не найден', bad_password: 'Неверный пароль', blocked: 'Учётная запись заблокирована' })[j.error] || 'Ошибка';
          return;
        }
        localStorage.setItem('token', j.token); TOKEN = j.token; location.reload();
      });
    };
    qs('#rg-go').onclick = function () {
      api('/api/register', { login: qs('#rg-login').value.trim(), fullname: qs('#rg-fn').value.trim(), password: qs('#rg-pass').value }).then(function (j) {
        if (j.error) {
          qs('#rg-err').textContent = ({
            bad_login: 'Имя от 3 до 30 символов латиницей',
            bad_password: 'Пароль минимум 3 символа',
            bad_fullname: 'Введите ФИО',
            name_taken: 'Такое имя уже занято',
            ip_forbidden: 'Регистрация с этого IP-адреса запрещена'
          })[j.error] || 'Ошибка';
          return;
        }
        localStorage.setItem('token', j.token); TOKEN = j.token; location.reload();
      });
    };
  };

  window.buildHeader = function (active) {
    var header = qs('#header');
    if (!header) return Promise.resolve();
    return Promise.all([api('/api/me'), api('/api/site')]).then(function (rs) {
      ME = rs[0] && !rs[0].error ? rs[0] : null;
      var site = rs[1] && !rs[1].error ? rs[1] : {};
      if (site.siteTitle) document.title = site.siteTitle;
      var link = function (href, label) {
        return '<a href="' + href + '" class="' + (active === href ? 'active' : '') + '">' + label + '</a>';
      };
      var nav = link('/', 'Главная');
      if (ME) nav += link('/chat.html', 'Чат');
      if (ME) nav += link('/cabinet.html', 'Кабинет');
      if (ME && ME.role !== 'user') nav += link('/games.html', 'Игры');
      if (ME && ME.role === 'admin') nav += link('/admin.html', 'Админ-панель');
      var right = '';
      if (ME) {
        right = '<span class="uname">' + esc(ME.fullname || ME.login) + '</span>' +
          '<span class="role-badge rb-' + esc(ME.role) + '">' + roleName(ME.role) + '</span>' +
          '<a href="#" id="logout">Выйти</a>';
      } else {
        right = '<a href="#" id="show-login">Вход</a><a href="#" id="show-reg">Регистрация</a>';
      }
      header.innerHTML =
        '<a href="/" class="brand" title="На главную">' +
        '<img src="/icon.jpg" alt="На главную">' +
        '<span>' + esc(site.siteTitle || '') + '</span></a>' +
        '<nav>' + nav + '</nav><div class="hright">' + right + '</div>';
      if (ME) {
        qs('#logout').onclick = function (e) {
          e.preventDefault();
          api('/api/logout', {}).then(function () {
            localStorage.removeItem('token'); TOKEN = ''; location.href = '/';
          });
        };
      } else {
        qs('#show-login').onclick = function (e) { e.preventDefault(); showAuthModal(false); };
        qs('#show-reg').onclick = function (e) { e.preventDefault(); showAuthModal(true); };
      }
      if (!ME) {
        header.insertAdjacentHTML('afterend', modalHtml());
        qs('#authmodal').id = 'authmodal-hidden';
        qs('#authmodal-hidden').remove();
      }
    });
  };
})();
