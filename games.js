/* ===== games.js: lobby, challenges, battleship, stats ===== */
(function () {
  buildHeader('/games.html').then(function () {
    if (!ME) {
      qs('#games-need-auth').style.display = 'block';
      return;
    }
    if (ME.role === 'user') {
      qs('#games-no-access').style.display = 'block';
      return;
    }
    qs('#games-area').style.display = 'block';
    start();
  });

  var localBoard = null;
  var myPlaced = false;
  var inGame = false;
  var lobbyTimer = null;
  var stateTimer = null;
  var statsTimer = null;

  function start() {
    lobbyTimer = setInterval(pollLobby, 3000);
    pollLobby();
    loadStats();
    statsTimer = setInterval(loadStats, 10000);
  }

  /* ---------- board generator (client side) ---------- */
  function genBoard() {
    for (var attempt = 0; attempt < 50; attempt++) {
      var grid = new Array(100);
      for (var i = 0; i < 100; i++) grid[i] = 0;
      var sizes = [4, 3, 3, 2, 2, 2, 1, 1, 1, 1];
      var okAll = true;
      for (var s = 0; s < sizes.length; s++) {
        var placed = false;
        for (var tr = 0; tr < 400 && !placed; tr++) {
          var horiz = Math.random() < 0.5;
          var x0, y0;
          if (horiz) { x0 = Math.floor(Math.random() * (10 - sizes[s] + 1)); y0 = Math.floor(Math.random() * 10); }
          else { x0 = Math.floor(Math.random() * 10); y0 = Math.floor(Math.random() * (10 - sizes[s] + 1)); }
          var cells = [];
          for (var k = 0; k < sizes[s]; k++) {
            cells.push(horiz ? (y0 * 10 + x0 + k) : ((y0 + k) * 10 + x0));
          }
          var free = true;
          for (var c = 0; c < cells.length; c++) {
            var cx = cells[c] % 10, cy = Math.floor(cells[c] / 10);
            for (var dy = -1; dy <= 1; dy++) {
              for (var dx = -1; dx <= 1; dx++) {
                var nx = cx + dx, ny = cy + dy;
                if (nx < 0 || nx > 9 || ny < 0 || ny > 9) continue;
                if (grid[ny * 10 + nx] !== 0) free = false;
              }
            }
          }
          if (free) {
            for (var c2 = 0; c2 < cells.length; c2++) grid[cells[c2]] = s + 1;
            placed = true;
          }
        }
        if (!placed) { okAll = false; break; }
      }
      if (okAll) return grid;
    }
    return null;
  }

  /* ---------- board rendering ---------- */
  function renderBoard(container, arr, opts) {
    opts = opts || {};
    container.innerHTML = '';
    var table = document.createElement('table');
    table.className = 'board' + (opts.enemy ? ' enemy' : '');
    for (var y = 0; y < 10; y++) {
      var tr = document.createElement('tr');
      for (var x = 0; x < 10; x++) {
        var td = document.createElement('td');
        var v = arr[y * 10 + x] || 0;
        if (v === 1) td.className = 'ship';
        if (v === 2) td.className = 'hit';
        if (v === 3) td.className = 'miss';
        if (v === 4) td.className = 'sunk';
        if (opts.canShoot) td.classList.add('clickable');
        if (opts.canShoot) {
          (function (x, y, td) {
            td.onclick = function () { shootAt(x, y, td); };
          })(x, y, td);
        }
        tr.appendChild(td);
      }
      table.appendChild(tr);
    }
    container.appendChild(table);
  }

  function shootAt(x, y, td) {
    if (td._done) return;
    td._done = true;
    api('/api/games/shoot', { x: x, y: y }).then(function (j) {
      if (j.error) {
        if (j.error === 'not_your_turn') showBar('Сейчас ход соперника', true);
        else if (j.error === 'already') showBar('Здесь уже стреляли', true);
        else showBar('Ошибка: ' + j.error, true);
        return;
      }
      var txt = { miss: 'Мимо!', hit: 'Попадание!', sunk: 'Потоплен!' }[j.lastResult] || '';
      if (txt) showBar(txt);
      renderGameState(j);
    });
  }

  /* ---------- lobby ---------- */
  function renderLobby(j) {
    var box = qs('#lobby-list');
    box.innerHTML = '';
    if (j.challenge) {
      var bar = document.createElement('div');
      bar.className = 'private-mode';
      bar.style.display = 'block';
      bar.innerHTML = 'Вас вызывает: <b>' + esc(j.challenge.name) + '</b> ';
      var acc = document.createElement('button');
      acc.className = 'small'; acc.textContent = 'Принять';
      acc.onclick = function () {
        api('/api/games/respond', { accept: true }).then(function (r) {
          if (r.error) { showBar('Ошибка: ' + r.error, true); return; }
          enterGameMode();
        });
      };
      var dec = document.createElement('button');
      dec.className = 'small ghost'; dec.textContent = 'Отклонить';
      dec.onclick = function () {
        api('/api/games/respond', { accept: false }).then(pollLobby);
      };
      bar.appendChild(acc); bar.appendChild(dec);
      box.appendChild(bar);
    }
    if (j.outgoing) {
      var ob = document.createElement('div');
      ob.className = 'private-mode';
      ob.style.display = 'block';
      ob.innerHTML = 'Вызов отправлен: <b>' + esc(j.outgoing.name) + '</b> ';
      var can = document.createElement('button');
      can.className = 'small ghost'; can.textContent = 'Отменить';
      can.onclick = function () { api('/api/games/cancel').then(pollLobby); };
      ob.appendChild(can);
      box.appendChild(ob);
    }
    if (!j.players || j.players.length === 0) {
      box.insertAdjacentHTML('beforeend', '<p class="muted">Пока никого нет. Пригласите коллег открыть страницу «Игры».</p>');
    }
    var tbl = document.createElement('table');
    tbl.innerHTML = '<tr><th>Игрок</th><th>Роль</th><th>Статус</th><th></th></tr>';
    j.players.forEach(function (p) {
      var tr = document.createElement('tr');
      var btn = '';
      if (p.isMe) btn = '<span class="muted">это вы</span>';
      else if (p.status === 'busy') btn = '<span class="muted">в игре</span>';
      else if (j.outgoing && j.outgoing.to === p.login) btn = '<span class="muted">ожидает ответа</span>';
      else btn = '<button class="small chal-btn" data-login="' + esc(p.login) + '">Вызвать</button>';
      tr.innerHTML =
        '<td>' + esc(p.fullname || p.login) + ' <span class="role-badge rb-' + esc(p.role) + '">' + roleName(p.role) + '</span></td>' +
        '<td>' + roleName(p.role) + '</td>' +
        '<td>' + (p.status === 'busy' ? 'в игре' : 'свободен') + '</td>' +
        '<td>' + btn + '</td>';
      tbl.appendChild(tr);
    });
    box.appendChild(tbl);
    box.querySelectorAll('.chal-btn').forEach(function (b) {
      b.onclick = function () {
        api('/api/games/challenge', { to: b.getAttribute('data-login') }).then(function (r) {
          if (r.error) {
            var m = { busy: 'Вы уже в игре', busy_target: 'Соперник уже занят', no_user: 'Игрок недоступен' };
            showBar(m[r.error] || 'Ошибка: ' + r.error, true);
            return;
          }
          showBar('Вызов отправлен, ждём ответа…');
          pollLobby();
        });
      };
    });
  }

  function pollLobby() {
    api('/api/games/presence').then(function (j) {
      if (j.error === 'forbidden') { qs('#games-area').style.display = 'none'; qs('#games-no-access').style.display = 'block'; return; }
      if (j.error) return;
      var g = qs('#lobby-view');
      if (inGame) return; /* game screen takes over */
      g.style.display = 'block';
      renderLobby(j);
    });
  }

  /* ---------- stats ---------- */
  function loadStats() {
    api('/api/games/stats').then(function (j) {
      if (!j || !j.stats) return;
      var tb = qs('#stats-tbody');
      tb.innerHTML = '';
      if (j.stats.length === 0) {
        tb.innerHTML = '<tr><td colspan="5" class="muted">Ещё не было сыграно ни одной партии</td></tr>';
        return;
      }
      j.stats.forEach(function (s, i) {
        var tr = document.createElement('tr');
        tr.innerHTML = '<td>' + (i + 1) + '</td><td>' + esc(s.name || s.login) + '</td><td>' +
          esc(s.wins) + '</td><td>' + esc(s.losses) + '</td><td>' +
          (s.wins + s.losses > 0 ? Math.round(100 * s.wins / (s.wins + s.losses)) + '%' : '-') + '</td>';
        tb.appendChild(tr);
      });
    });
  }

  /* ---------- game mode ---------- */
  function enterGameMode() {
    inGame = true;
    qs('#lobby-view').style.display = 'none';
    qs('#game-view').style.display = 'block';
    if (stateTimer) clearInterval(stateTimer);
    stateTimer = setInterval(pollState, 1500);
    pollState();
  }

  function leaveGame() {
    if (stateTimer) clearInterval(stateTimer);
    inGame = false;
    myPlaced = false;
    localBoard = null;
    qs('#game-view').style.display = 'none';
    qs('#lobby-view').style.display = 'block';
    loadStats();
    pollLobby();
  }

  function pollState() {
    api('/api/games/state').then(function (j) {
      if (j.error) return;
      if (j.state === 'none') {
        if (inGame) leaveGame();
        return;
      }
      renderGameState(j);
    });
  }

  function renderGameState(st) {
    inGame = true;
    qs('#lobby-view').style.display = 'none';
    qs('#game-view').style.display = 'block';

    var status = qs('#game-status');
    if (st.state === 'placing') {
      if (!localBoard) localBoard = genBoard() || genBoard();
      renderBoard(qs('#board-mine'), localBoard, {});
      renderBoard(qs('#board-enemy'), new Array(100).fill(0), {});
      status.textContent = 'Расстановка. Соперник: ' + (st.enemyName || st.enemyLogin) +
        ' — ' + (st.readyEnemy ? 'готов' : 'ещё расставляет');
      qs('#place-buttons').style.display = st.readyMe ? 'none' : 'block';
      if (st.readyMe) status.textContent += '. Вы готовы, ждём соперника.';
    } else if (st.state === 'playing') {
      renderBoard(qs('#board-mine'), st.myBoard, {});
      renderBoard(qs('#board-enemy'), st.enemyBoard, { enemy: true, canShoot: st.turn === ME.login });
      var myTurn = st.turn === ME.login;
      status.textContent = myTurn
        ? 'ВАШ ХОД — стреляйте по правому полю'
        : 'Ход соперника (' + (st.enemyName || st.enemyLogin) + ')';
      qs('#place-buttons').style.display = 'none';
    } else if (st.state === 'done') {
      renderBoard(qs('#board-mine'), st.myBoard, {});
      renderBoard(qs('#board-enemy'), st.enemyBoard, { enemy: true });
      var won = st.winner === ME.login;
      status.textContent = won ? 'ПОБЕДА! Флот соперника уничтожен.' : 'Поражение. Ваш флот уничтожен.';
      status.style.color = won ? 'var(--ok)' : 'var(--bad)';
      qs('#place-buttons').style.display = 'none';
    }
    qs('#ships-left').textContent = 'Ваши корабли: ' + st.myLeft + ' | Корабли соперника: ' + st.enemyLeft;
  }

  qs('#btn-regen').onclick = function () { localBoard = genBoard(); renderGameStateCurrent(); };
  qs('#btn-ready').onclick = function () {
    if (!localBoard) localBoard = genBoard();
    api('/api/games/place', { cells: localBoard }).then(function (j) {
      if (j.error) {
        showBar('Расстановка не принята, генерирую заново', true);
        localBoard = genBoard();
        return;
      }
      myPlaced = true;
      renderGameState(j);
    });
  };
  qs('#btn-leave').onclick = function () {
    if (!confirm('Покинуть игру? Если идёт бой — это будет поражение.')) return;
    api('/api/games/leave').then(leaveGame);
  };

  function renderGameStateCurrent() {
    api('/api/games/state').then(function (j) {
      if (j && j.state && j.state !== 'none') renderGameState(j);
    });
  }
})();
