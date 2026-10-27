(() => {
    const $ = (id) => document.getElementById(id);
    const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'busjob';

    const post = (name, data = {}) =>
        fetch(`https://${RES}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data)
        }).then(r => r.json()).catch(() => null);

    const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c =>
        ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

    let mode = null;          // 'driver' | 'admin'
    let isAdmin = false;
    let users = [];
    let routes = [];
    let logs = [];
    let editUserId = null;
    let editRouteId = null;
    let stops = [];
    let confirmCb = null;

    // Fahrer-Terminal
    const drv = { screen: 'login', field: 'line', line: '', course: '', session: null, leitOpen: false, panicEnabled: true };
    const MAX = { line: 4, course: 3 };

    // ------------------------------------------------------------------
    // Uhr
    // ------------------------------------------------------------------
    const tick = () => {
        const d = new Date();
        $('clock').textContent = d.toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit' });
        $('ibClock').textContent = d.toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    };
    setInterval(tick, 1000); tick();

    // ------------------------------------------------------------------
    // Terminal-Skalierung (Designgröße 626x421)
    // ------------------------------------------------------------------
    function fit() {
        const s = Math.min(window.innerWidth * 0.9 / 626, window.innerHeight * 0.9 / 421, 2.0);
        $('ibis').style.transform = `scale(${s})`;
    }
    window.addEventListener('resize', fit); fit();

    // ------------------------------------------------------------------
    // Helfer
    // ------------------------------------------------------------------
    let toastTimer;
    function toast(msg, err) {
        const t = $('toast');
        t.textContent = msg;
        t.classList.toggle('err', !!err);
        t.classList.remove('hidden');
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => t.classList.add('hidden'), 2600);
    }

    function setMsg(id, text, ok) {
        const el = $(id);
        el.textContent = text || '';
        el.classList.toggle('ok', !!ok);
    }

    function confirmBox(title, text, cb) {
        $('confirmTitle').textContent = title;
        $('confirmText').textContent = text;
        confirmCb = cb;
        $('modalConfirm').classList.remove('hidden');
    }

    // ==================================================================
    //  HALTESTELLEN-HUD (oben links)
    // ==================================================================
    let hudOn = true;
    let hudData = null;

    function renderHud() {
        const el = $('hud');
        if (!hudData || !hudData.show || !hudOn) { el.classList.add('hidden'); return; }

        $('hudLine').textContent  = hudData.line;
        $('hudTitle').textContent = `Linie ${hudData.line} / Kurs ${hudData.course}`;
        $('hudName').textContent  = hudData.name || '';

        const cur = hudData.current || 0, next = hudData.next || 1;
        const wrapped = next <= cur;   // Runde war gerade zu Ende -> alle außer der letzten wieder offen

        $('hudStops').innerHTML = (hudData.stops || []).map((name, i) => {
            const n = i + 1;
            let cls = '', tag = '', dot = n;
            if (n === next)      { cls = 'next'; tag = 'Nächste'; }
            else if (n === cur)  { cls = 'cur';  tag = 'Aktuell'; dot = '✓'; }
            else if (!wrapped && n < cur) { cls = 'done'; dot = '✓'; }
            return `<div class="hs ${cls}" data-n="${n}">
                        <span class="dot">${dot}</span>
                        <span class="nm">${esc(name)}</span>
                        <span class="tg">${tag}</span>
                    </div>`;
        }).join('');

        el.classList.remove('hidden');
        const target = $('hudStops').querySelector('.hs.next');
        if (target) {
            const box = $('hudStops');
            box.scrollTop = Math.max(0, target.offsetTop - box.clientHeight / 2 + target.clientHeight / 2);
        }
    }

    // ==================================================================
    //  FAHRER-TERMINAL (IBIS)
    // ==================================================================
    const TITLES = { login: 'Anmeldung', start: 'Startseite', route: 'Fahrplan', active: 'Schicht aktiv' };

    function ibMsg(text, ok) {
        $('ibMsg').textContent = text || '';
        $('ibMsg').classList.toggle('ok', !!ok);
    }

    function updateLcd() {
        const r = drv.session && drv.session.route;
        $('lcdA').textContent = r ? String(r.line)   : '---';
        $('lcdB').textContent = r ? String(r.course) : '--';
        $('icoLogout').classList.toggle('on', !!drv.session);
    }

    function renderFields() {
        $('fldLine').textContent   = drv.line;
        $('fldCourse').textContent = drv.course;
        $('fldLine').classList.toggle('active', drv.field === 'line');
        $('fldCourse').classList.toggle('active', drv.field === 'course');
    }

    function renderActive() {
        const r = drv.session && drv.session.route;
        if (!r) return;
        const cur = r.current > 0 ? r.stops[r.current - 1] : null;
        const nxt = r.stops[r.nextStop - 1];
        $('actLine').textContent = `Linie ${r.line} / Kurs ${r.course}`;
        $('actName').textContent = r.name;
        $('actCur').textContent  = cur ? cur.name : 'Fahrtbeginn';
        $('actNext').textContent = nxt ? nxt.name : '-';
        $('actUser').textContent = drv.session.user;
    }

    function setScreen(name) {
        drv.screen = name;
        ['Login', 'Start', 'Route', 'Active'].forEach(n =>
            $('scr' + n).classList.toggle('hidden', n.toLowerCase() !== name));
        $('ibTitle').textContent = TITLES[name];
        ibMsg('');

        if (name === 'login') {
            $('inPass').value = '';
            setTimeout(() => ($('inName').value ? $('inPass') : $('inName')).focus(), 50);
        } else if (name === 'route') {
            drv.line = ''; drv.course = ''; drv.field = 'line';
            renderFields();
            if (document.activeElement) document.activeElement.blur();
        } else if (name === 'active') {
            renderActive();
        } else if (name === 'start') {
            renderStart();
        }
        updateLcd();
    }

    function renderStart() {
        const sess = drv.session || {};
        $('stUser').textContent = sess.user || '-';
        $('stLeitInfo').textContent = sess.leit
            ? 'Leitstelle: von dir besetzt'
            : (drv.leitOpen ? 'Leitstelle: besetzt' : 'Leitstelle: frei');
        $('btnStartLeit').textContent = sess.leit ? 'Leitstelle verlassen' : 'Leitstelle besetzen';
    }

    function updateSideIcons() {
        const sess = drv.session;
        $('icoWarn').classList.toggle('off', !drv.panicEnabled || !sess || (!!sess.leit && !sess.route));
        $('icoPhone').classList.toggle('off', !sess || !!sess.leit || !drv.leitOpen);
        $('icoPhone').classList.toggle('calling', !!(sess && sess.talk));
    }

    function showDriverState(state) {
        state = state || {};
        drv.session = state.session || null;
        drv.leitOpen = !!state.leitOpen;
        drv.panicEnabled = state.panicEnabled !== false;
        if (!drv.session) setScreen('login');
        else if (drv.session.route) setScreen('active');
        else setScreen('start');
        updateSideIcons();
    }

    // ---- Tastenfeld ---------------------------------------------------
    function pressDigit(d) {
        const f = drv.field;
        if (drv[f].length >= MAX[f]) return;
        drv[f] = (drv[f] === '0' ? '' : drv[f]) + d;
        renderFields();
        ibMsg('');
    }

    function pressClear() {
        const f = drv.field;
        if (drv[f] !== '') drv[f] = '';
        else if (f === 'course') drv.field = 'line';
        renderFields();
        ibMsg('');
    }

    function pressBackspace() {
        const f = drv.field;
        if (drv[f] !== '') drv[f] = drv[f].slice(0, -1);
        else if (f === 'course') drv.field = 'line';
        renderFields();
    }

    async function pressEnter() {
        // ">" : Linie bestätigen -> Kurs, danach absenden
        if (drv.field === 'line') {
            if (!drv.line) return ibMsg('Bitte Linie eingeben.');
            drv.field = 'course';
            renderFields();
            return ibMsg('');
        }
        if (!drv.line)   { drv.field = 'line'; renderFields(); return ibMsg('Bitte Linie eingeben.'); }
        if (!drv.course) return ibMsg('Bitte Kurs eingeben.');

        $('btnGo').disabled = true;
        const res = await post('selectRoute', { line: Number(drv.line), course: Number(drv.course) });
        $('btnGo').disabled = false;

        if (!res || !res.ok) return ibMsg((res && res.msg) || 'Fahrplan nicht vorhanden.');

        drv.session.route = res.route;
        updateLcd();
        ibMsg(`Fahrplan ${res.route.line}/${res.route.course} geladen`, true);
        // Das Terminal wird vom Client automatisch geschlossen
    }

    $('keypad').addEventListener('click', (e) => {
        const k = e.target.closest('.ib-key');
        if (!k) return;
        const v = k.dataset.k;
        if (v === 'C') pressClear();
        else if (v === '>') pressEnter();
        else pressDigit(v);
    });
    $('fldLine').addEventListener('click',   () => { drv.field = 'line';   renderFields(); });
    $('fldCourse').addEventListener('click', () => { drv.field = 'course'; renderFields(); });

    // ---- Login --------------------------------------------------------
    async function doLogin() {
        const name = $('inName').value.trim();
        const password = $('inPass').value;
        if (!name || !password) return ibMsg('Bitte Name und Passwort eingeben.');

        $('btnLogin').disabled = true;
        const res = await post('login', { name, password });
        $('btnLogin').disabled = false;

        if (!res || !res.ok) {
            $('inPass').value = '';
            return ibMsg((res && res.msg) || 'Anmeldung fehlgeschlagen.');
        }
        const st = await post('getState');
        showDriverState(st && st.session ? st : { session: { user: res.user, route: null } });
    }
    $('btnLogin').addEventListener('click', doLogin);
    ['inName', 'inPass'].forEach(id =>
        $(id).addEventListener('keydown', e => { if (e.key === 'Enter') doLogin(); }));

    // ---- Aktiv-Bildschirm / Seitentasten --------------------------------
    async function doLogout() {
        if (!drv.session) return;
        await post('logout');
        drv.session = null;
        updateLcd();
        setScreen('login');
        updateSideIcons();
    }
    $('btnLogout').addEventListener('click', doLogout);
    $('icoLogout').addEventListener('click', doLogout);
    $('btnChange').addEventListener('click', () => setScreen('route'));
    $('btnToStart').addEventListener('click', async () => {
        const st = await post('getState');
        if (st) { drv.session = st.session; drv.leitOpen = !!st.leitOpen; }
        setScreen('start');
        updateSideIcons();
    });

    // ---- Startseite -----------------------------------------------------
    $('btnStartRoute').addEventListener('click', () => {
        setScreen('route');
    });
    $('btnStartLogout').addEventListener('click', doLogout);
    $('btnStartLeit').addEventListener('click', async () => {
        const inLeit = !!(drv.session && drv.session.leit);
        const res = await post(inLeit ? 'leitLeave' : 'leitEnter');
        if (!res || !res.ok) return ibMsg((res && res.msg) || 'Fehler.');
        if (inLeit) {
            drv.session.leit = false;
            const st = await post('getState');
            if (st) { drv.leitOpen = !!st.leitOpen; }
            renderStart();
            updateSideIcons();
            ibMsg('Leitstelle verlassen.', true);
        } else {
            drv.session.leit = true;   // das Terminal wird vom Client automatisch geschlossen
            renderStart();
            updateSideIcons();
            ibMsg('Leitstelle besetzt.', true);
        }
    });

    // ---- Panik (Warnsymbol) + Sprechwunsch (gelbes Telefon) ---------------
    let panicLock = false;
    $('icoWarn').addEventListener('click', async () => {
        if (!drv.session) return ibMsg('Bitte zuerst anmelden.');
        if (drv.session.leit && !drv.session.route) return ibMsg('In der Leitstelle ohne Fahrt nicht verfügbar.');
        if (!drv.panicEnabled || panicLock) return;
        panicLock = true;
        const el = $('icoWarn');
        el.classList.remove('fired'); void el.offsetWidth; el.classList.add('fired');
        await post('panic');
        ibMsg('PANIK-ALARM gesendet!');
        setTimeout(() => { panicLock = false; el.classList.remove('fired'); }, 3000);
    });

    $('icoPhone').addEventListener('click', async () => {
        if (!drv.session) return ibMsg('Bitte zuerst anmelden.');
        if (drv.session.leit) return ibMsg('In der Leitstelle nicht verfügbar.');
        const res = await post('requestTalk');
        if (!res) return;
        if (res.ok) { drv.session.talk = !!res.talk; updateSideIcons(); }
        ibMsg(res.msg || '', !!res.ok);
    });

    $('icoHud').addEventListener('click', () => {
        hudOn = !hudOn;
        $('icoHud').classList.toggle('off', !hudOn);
        renderHud();
    });
    $('icoBack').addEventListener('click', () => post('close'));

    // Tastatureingaben im Fahrplan-Bildschirm
    document.addEventListener('keydown', (e) => {
        if (mode !== 'driver' || $('ibisWrap').classList.contains('hidden') || drv.screen !== 'route') return;
        if (/^[0-9]$/.test(e.key)) { pressDigit(e.key); e.preventDefault(); }
        else if (e.key === 'Backspace') { pressBackspace(); e.preventDefault(); }
        else if (e.key === 'Delete' || e.key.toLowerCase() === 'c') { pressClear(); e.preventDefault(); }
        else if (e.key === 'Enter') { pressEnter(); e.preventDefault(); }
        else if (e.key === 'Tab') {
            drv.field = drv.field === 'line' ? 'course' : 'line';
            renderFields(); e.preventDefault();
        }
    });

    // ==================================================================
    //  Öffnen / Schließen / NUI-Nachrichten
    // ==================================================================
    function openUI(data) {
        mode = data.mode;
        ['modalUser', 'modalRoute', 'modalConfirm'].forEach(m => $(m).classList.add('hidden'));

        if (mode === 'driver') {
            $('app').classList.add('hidden');
            $('ibisWrap').classList.remove('hidden');
            fit();
            showDriverState(data.state || {});
        } else {
            isAdmin = !!data.isAdmin;
            $('ibisWrap').classList.add('hidden');
            $('app').classList.remove('hidden');
            $('tabRoutes').classList.toggle('hidden', !isAdmin);
            $('tabSettings').classList.toggle('hidden', !isAdmin);
            switchTab('users');
        }
    }

    function closeUI() {
        $('app').classList.add('hidden');
        $('ibisWrap').classList.add('hidden');
    }

    // ==================================================================
    //  LEITSTELLE (Anzeige rechts)
    // ==================================================================
    const PHONE_SVG = '<svg viewBox="0 0 32 32"><path d="M9 6.5c-1.5.5-3 2-2.7 4 1.4 7.8 8 14.3 15.7 15.7 2 .3 3.5-1.2 4-2.7l-4.6-3.3-2.4 2c-3-1.4-5.3-3.8-6.7-6.7l2-2.4z" fill="#ffe600" stroke="#ffe600" stroke-width="1.5" stroke-linejoin="round"/></svg>';
    const BUS_SVG = '<svg width="14" height="14" viewBox="0 0 24 24" style="vertical-align:-2px"><path d="M4 4h16a1 1 0 0 1 1 1v11a2 2 0 0 1-2 2v2h-2v-2H7v2H5v-2a2 2 0 0 1-2-2V5a1 1 0 0 1 1-1zm1 2v5h14V6H5zm2 8.5a1.2 1.2 0 1 0 0 .01zm10 0a1.2 1.2 0 1 0 0 .01z" fill="#c44bc4"/></svg>';

    const fmtTime = (sec) => {
        const m = Math.floor(sec / 60), r = sec % 60;
        return `${m}:${String(r).padStart(2, '0')}`;
    };

    let leitRows = [];
    function renderLeit() {
        const el = $('leitList');
        if (!leitRows.length) { el.innerHTML = '<div class="leit-empty">Keine Fahrer angemeldet.</div>'; return; }
        el.innerHTML = leitRows.map(r => {
            const hasTrip = !!r.from;
            let badge = '<div class="badge">--:--</div>';
            if (r.panic) badge = '<div class="badge panic">PANIK</div>';
            else if (hasTrip) {
                const cls = r.since >= 600 ? 'late' : (r.since >= 300 ? 'warn' : '');
                badge = `<div class="badge ${cls}">${fmtTime(r.since)}</div>`;
            }
            const trip = hasTrip ? `${esc(r.from)} \u2192 ${esc(r.to)}` : 'keine Fahrt';
            const loc  = hasTrip ? `${esc(r.cur || 'Fahrtbeginn')} \u2192 ${esc(r.nxt || '-')}` : '–';
            const talkBtn = r.talk
                ? `<button class="lbtn talk" data-accept="${r.src}">Sprechwunsch</button>`
                : '<button class="lbtn" disabled>-</button>';
            const clearBtn = r.panic ? `<button class="lbtn clear" data-clear="${r.src}">Quittieren</button>` : '';
            return `<div class="lrow ${r.panic ? 'panic' : ''}">
                <div class="top">
                    <div class="nr">${BUS_SVG} Nr. ${esc(r.nr)}<small>${esc(r.name)}</small></div>
                    ${badge}
                </div>
                <div class="lc">${esc(r.line)} / ${esc(r.course)}</div>
                <div class="tx">Aktuelle Fahrt: ${trip}</div>
                <div class="loc">\ud83d\udccd ${loc}</div>
                <div class="acts">${talkBtn}<button class="lphone" data-call="${r.src}" title="Fahrer anrufen">${PHONE_SVG}</button>${clearBtn}</div>
            </div>`;
        }).join('');
    }

    $('leitList').addEventListener('click', (e) => {
        const b = e.target.closest('[data-accept],[data-call],[data-clear]');
        if (!b || !$('leit').classList.contains('mouse')) return;
        if (b.dataset.accept) post('leitAccept', { src: Number(b.dataset.accept) });
        else if (b.dataset.call) post('leitCall', { src: Number(b.dataset.call) });
        else if (b.dataset.clear) post('leitClearPanic', { src: Number(b.dataset.clear) });
    });

    // Sekundenzähler zwischen den Server-Updates
    setInterval(() => {
        if ($('leit').classList.contains('hidden')) return;
        leitRows.forEach(r => { if (r.since != null) r.since += 1; });
        renderLeit();
    }, 1000);

    window.addEventListener('message', (e) => {
        const d = e.data;
        if (d.action === 'leit') {
            $('leit').classList.toggle('hidden', !d.active);
            if (!d.active) { leitRows = []; $('leit').classList.remove('mouse'); }
            else renderLeit();
        }
        else if (d.action === 'leitList') { leitRows = d.list || []; renderLeit(); }
        else if (d.action === 'leitMouse') {
            $('leit').classList.toggle('mouse', !!d.on);
            $('leitHint').textContent = d.on ? 'Numpad 0: Maus aus' : 'Numpad 0: Maus';
        }
        else if (d.action === 'open') openUI(d);
        else if (d.action === 'close') closeUI();
        else if (d.action === 'state' && mode === 'driver') showDriverState(d.state || {});
        else if (d.action === 'hud') { hudData = d; renderHud(); }
    });

    $('btnClose').addEventListener('click', () => post('close'));
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' || e.key === 'F3') {
            if (!$('modalConfirm').classList.contains('hidden')) return $('modalConfirm').classList.add('hidden');
            if (!$('modalUser').classList.contains('hidden')) return $('modalUser').classList.add('hidden');
            if (!$('modalRoute').classList.contains('hidden')) return $('modalRoute').classList.add('hidden');
            post('close');
        }
    });

    // ==================================================================
    //  VERWALTUNG
    // ==================================================================
    function switchTab(tab) {
        document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
        document.querySelectorAll('.panel').forEach(p => p.classList.add('hidden'));
        $('panel-' + tab).classList.remove('hidden');
        if (tab === 'users') loadUsers();
        if (tab === 'logs') loadLogs();
        if (tab === 'routes') loadRoutes();
        if (tab === 'settings') loadSettings();
    }
    document.querySelectorAll('.tab').forEach(t =>
        t.addEventListener('click', () => switchTab(t.dataset.tab)));

    // ---------------- Userverwaltung ----------------
    async function loadUsers() {
        users = (await post('adminUsers')) || [];
        renderUsers();
    }

    function renderUsers() {
        const q = $('userSearch').value.trim().toLowerCase();
        const list = users.filter(u => u.name.toLowerCase().includes(q));
        const el = $('userList');
        if (!list.length) { el.innerHTML = '<div class="empty">Keine Benutzer gefunden.</div>'; return; }
        el.innerHTML = list.map(u => `
            <div class="item">
                <div class="info"><b>${esc(u.name)}</b><span>Erstellt von ${esc(u.created_by || '-')} · ${esc(u.created)}</span></div>
                <div class="actions">
                    <button class="btn small" data-edit="${u.id}">Bearbeiten</button>
                    <button class="btn small danger" data-del="${u.id}">Löschen</button>
                </div>
            </div>`).join('');
    }
    $('userSearch').addEventListener('input', renderUsers);

    $('userList').addEventListener('click', (e) => {
        const edit = e.target.dataset.edit, del = e.target.dataset.del;
        if (edit) {
            const u = users.find(x => x.id == edit);
            if (u) openUserModal(u);
        } else if (del) {
            const u = users.find(x => x.id == del);
            if (!u) return;
            confirmBox('Benutzer löschen', `Soll "${u.name}" wirklich gelöscht werden?`, async () => {
                const res = await post('adminDeleteUser', { id: u.id });
                if (res && res.ok) { toast('Benutzer gelöscht'); loadUsers(); }
                else toast((res && res.msg) || 'Fehler', true);
            });
        }
    });

    function openUserModal(u) {
        editUserId = u ? u.id : null;
        $('userModalTitle').textContent = u ? 'Benutzer bearbeiten' : 'Neuer Benutzer';
        $('mName').value = u ? u.name : '';
        $('mPass').value = '';
        $('mPass').placeholder = u ? 'Leer lassen = Passwort behalten' : 'Passwort (min. 4 Zeichen)';
        setMsg('userMsg', '');
        $('modalUser').classList.remove('hidden');
        $('mName').focus();
    }
    $('btnNewUser').addEventListener('click', () => openUserModal(null));
    $('userCancel').addEventListener('click', () => $('modalUser').classList.add('hidden'));
    $('userSave').addEventListener('click', async () => {
        const res = await post('adminSaveUser', {
            id: editUserId, name: $('mName').value.trim(), password: $('mPass').value
        });
        if (res && res.ok) {
            $('modalUser').classList.add('hidden');
            toast(editUserId ? 'Benutzer gespeichert' : 'Benutzer erstellt');
            loadUsers();
        } else setMsg('userMsg', (res && res.msg) || 'Fehler beim Speichern.');
    });

    // ---------------- Aktionslog ----------------
    async function loadLogs() {
        logs = (await post('adminLogs')) || [];
        renderLogs();
    }
    function renderLogs() {
        const q = $('logSearch').value.trim().toLowerCase();
        const list = logs.filter(l => (l.actor + l.action + l.details).toLowerCase().includes(q));
        const el = $('logList');
        if (!list.length) { el.innerHTML = '<div class="empty">Keine Einträge vorhanden.</div>'; return; }
        el.innerHTML = '<div class="logrow head"><span>Zeit</span><span>Von</span><span>Aktion</span><span>Details</span></div>' +
            list.map(l => `
            <div class="logrow">
                <span class="muted">${esc(l.time)}</span>
                <span class="a">${esc(l.actor)}</span>
                <span>${esc(l.action)}</span>
                <span class="muted">${esc(l.details)}</span>
            </div>`).join('');
    }
    $('logSearch').addEventListener('input', renderLogs);
    $('btnRefreshLogs').addEventListener('click', loadLogs);

    // ---------------- Routen (Admin) ----------------
    async function loadRoutes() {
        routes = (await post('adminRoutes')) || [];
        const el = $('routeList');
        if (!routes.length) { el.innerHTML = '<div class="empty">Noch keine Routen erstellt.</div>'; return; }
        el.innerHTML = routes.map(r => `
            <div class="item">
                <div class="info">
                    <b><span class="tag">${esc(r.line)} / ${esc(r.course)}</span>${esc(r.name)}</b>
                    <span>Linie ${esc(r.line)} · Kurs ${esc(r.course)} · ${r.stops.length} Haltestellen · ${esc(r.pay)}$ pro Haltestelle</span>
                </div>
                <div class="actions">
                    <button class="btn small" data-edit="${r.id}">Bearbeiten</button>
                    <button class="btn small danger" data-del="${r.id}">Löschen</button>
                </div>
            </div>`).join('');
    }

    $('routeList').addEventListener('click', (e) => {
        const edit = e.target.dataset.edit, del = e.target.dataset.del;
        if (edit) {
            const r = routes.find(x => x.id == edit);
            if (r) openRouteModal(r);
        } else if (del) {
            const r = routes.find(x => x.id == del);
            if (!r) return;
            confirmBox('Route löschen', `Soll die Route "${r.name}" (Linie ${r.line} / Kurs ${r.course}) wirklich gelöscht werden?`, async () => {
                const res = await post('adminDeleteRoute', { id: r.id });
                if (res && res.ok) { toast('Route gelöscht'); loadRoutes(); }
                else toast((res && res.msg) || 'Fehler', true);
            });
        }
    });

    function renderStops() {
        const el = $('stopList');
        if (!stops.length) { el.innerHTML = '<div class="empty" style="padding:18px">Noch keine Haltestellen. Stelle dich an die gewünschte Stelle und füge sie hinzu.</div>'; return; }
        el.innerHTML = stops.map((s, i) => `
            <div class="stop">
                <div class="n">${i + 1}</div>
                <input type="text" maxlength="50" value="${esc(s.name)}" data-name="${i}">
                <button class="rm" data-rm="${i}" title="Entfernen">✕</button>
                <div class="coords">${s.x.toFixed(1)}, ${s.y.toFixed(1)}, ${s.z.toFixed(1)}</div>
            </div>`).join('');
    }

    $('stopList').addEventListener('input', (e) => {
        if (e.target.dataset.name !== undefined) stops[e.target.dataset.name].name = e.target.value;
    });
    $('stopList').addEventListener('click', (e) => {
        if (e.target.dataset.rm !== undefined) { stops.splice(+e.target.dataset.rm, 1); renderStops(); }
    });

    function openRouteModal(r) {
        editRouteId = r ? r.id : null;
        $('routeModalTitle').textContent = r ? 'Route bearbeiten' : 'Neue Route';
        $('rName').value = r ? r.name : '';
        $('rLine').value = r ? r.line : '';
        $('rCourse').value = r ? r.course : '';
        $('rPay').value = r ? r.pay : 150;
        stops = r ? r.stops.map(s => ({ ...s })) : [];
        renderStops();
        setMsg('routeMsg', '');
        $('modalRoute').classList.remove('hidden');
    }
    $('btnNewRoute').addEventListener('click', () => openRouteModal(null));
    $('routeCancel').addEventListener('click', () => $('modalRoute').classList.add('hidden'));

    $('btnAddStop').addEventListener('click', async () => {
        const c = await post('getCoords');
        if (!c) return;
        stops.push({
            name: c.street ? `${c.street}` : `Haltestelle ${stops.length + 1}`,
            x: c.x, y: c.y, z: c.z
        });
        renderStops();
        const el = $('stopList'); el.scrollTop = el.scrollHeight;
    });

    $('routeSave').addEventListener('click', async () => {
        const res = await post('adminSaveRoute', {
            id: editRouteId,
            name: $('rName').value.trim(),
            line: Number($('rLine').value),
            course: Number($('rCourse').value),
            pay: Number($('rPay').value),
            stops
        });
        if (res && res.ok) {
            $('modalRoute').classList.add('hidden');
            toast(editRouteId ? 'Route gespeichert' : 'Route erstellt');
            loadRoutes();
        } else setMsg('routeMsg', (res && res.msg) || 'Fehler beim Speichern.');
    });

    // ---------------- Einstellungen (Admin) ----------------
    async function loadSettings() {
        const st = await post('adminSettings');
        const sel = $('sLeitGrade');
        if (!st || st.leitGrade === undefined) { sel.innerHTML = ''; return setMsg('settingsMsg', 'Keine Berechtigung.'); }
        const grades = (st.grades && st.grades.length)
            ? st.grades
            : Array.from({ length: 11 }, (_, i) => ({ grade: i, label: `Rang ${i}` }));
        sel.innerHTML = grades.map(g =>
            `<option value="${esc(g.grade)}">${esc(g.label)} (Rang ${esc(g.grade)})</option>`).join('');
        if (!grades.some(g => g.grade == st.leitGrade))
            sel.insertAdjacentHTML('beforeend', `<option value="${esc(st.leitGrade)}">Rang ${esc(st.leitGrade)}</option>`);
        sel.value = String(st.leitGrade);
        $('sJobInfo').textContent = `Job: ${st.job} \u2013 dieser Rang und höher dürfen die Leitstelle besetzen.`;
        setMsg('settingsMsg', '');
    }
    $('settingsSave').addEventListener('click', async () => {
        const res = await post('adminSaveSettings', { leitGrade: Number($('sLeitGrade').value) });
        if (res && res.ok) toast('Einstellungen gespeichert');
        else setMsg('settingsMsg', (res && res.msg) || 'Fehler beim Speichern.');
    });

    // ---------------- Bestätigen ----------------
    $('confirmNo').addEventListener('click', () => $('modalConfirm').classList.add('hidden'));
    $('confirmYes').addEventListener('click', () => {
        $('modalConfirm').classList.add('hidden');
        if (confirmCb) confirmCb();
        confirmCb = null;
    });
})();
