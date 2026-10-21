/* satz: Erklärvideo. Eine pausierte, seekbare Timeline.
   Jede Bewegung hängt an den Wortzeiten der Sprecherspur (VO.lines, aus _build/timeline.json);
   die Wellenformen der Karte folgen dem Pegel der Stimme (VO.level).
   Ablauf: erst DOM bauen, dann alles messen, dann die Timeline. Gemessen wird nur hier beim Aufbau. */
document.fonts.ready.then(function () {
  const tl = gsap.timeline({ paused: true });
  const $ = (s, r) => (r || document).querySelector(s);
  const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
  const DUR = VO.duration;
  const R0 = $('#root').getBoundingClientRect();
  const rect = (el) => {
    const r = (typeof el === 'string' ? $(el) : el).getBoundingClientRect();
    return { l: r.left - R0.left, t: r.top - R0.top, r: r.right - R0.left, b: r.bottom - R0.top, w: r.width, h: r.height, cx: r.left - R0.left + r.width / 2, cy: r.top - R0.top + r.height / 2 };
  };

  // ---------- Zeitanker: "zeile", "zeile:wort", "zeile:wort#2", "zeile:ende", jeweils mit +/-Versatz ----------
  const norm = (s) => s.toLowerCase().replace(/[^a-zäöüß0-9]/g, '');
  function A(expr) {
    let s = String(expr), off = 0;
    const mo = s.match(/([+-]\d+(?:\.\d+)?)$/);
    if (mo) {
      off = parseFloat(mo[1]);
      s = s.slice(0, s.length - mo[1].length);
    }
    let nth = 1;
    const mh = s.match(/#(\d+)$/);
    if (mh) {
      nth = +mh[1];
      s = s.slice(0, s.length - mh[0].length);
    }
    const i = s.indexOf(':');
    const L = VO.lines[i === -1 ? s : s.slice(0, i)];
    if (!L) throw new Error('Zeile fehlt: ' + expr);
    if (i === -1) return L.start + off;
    const wp = s.slice(i + 1);
    if (wp === 'ende') return L.end + off;
    const hits = L.words.filter((x) => norm(x[0]).startsWith(norm(wp)));
    if (hits.length < nth) throw new Error('Zeitanker ohne Treffer: ' + expr);
    return hits[nth - 1][1] + off;
  }
  const verteilt = (n, a, b) => Array.from({ length: n }, (_, i) => (n === 1 ? a : a + ((b - a) * i) / (n - 1)));

  // ---------- Helfer ----------
  const NEUTRAL = { opacity: 1, x: 0, y: 0, scale: 1, scaleX: 1, scaleY: 1, rotation: 0, filter: 'blur(0px)' };
  function go(el, from, to, t) {
    tl.fromTo(el, from, Object.assign({ immediateRender: false }, to), t);
  }
  function inn(el, t, from, dur, ease) {
    const f = Object.assign({ opacity: 0 }, from || {});
    const to = { duration: dur || 0.5, ease: ease || 'power3.out' };
    for (const k in f) to[k] = k in NEUTRAL ? NEUTRAL[k] : f[k];
    go(el, f, to, t);
  }
  const op = (el, a, b, t, d) => go(el, { opacity: a }, { opacity: b, duration: d || 0.2, ease: 'power1.inOut' }, t);
  // Szenenwechsel: erst geht die alte Szene, dann kommt die neue. Nie zwei lesbare Texte übereinander.
  const AUS = 0.24;
  function szene(alt, neu, t) {
    if (alt) go(alt, { opacity: 1, y: 0, filter: 'blur(0px)' }, { opacity: 0, y: -16, filter: 'blur(6px)', duration: AUS, ease: 'power2.in' }, t);
    go(neu, { opacity: 0, y: 22, filter: 'blur(8px)' }, { opacity: 1, y: 0, filter: 'blur(0px)', duration: 0.45, ease: 'power2.out' }, t + AUS);
  }
  // Cursor blinkt: sichtbar, unsichtbar, … und endet sichtbar.
  function blinke(el, t0, t1, per) {
    const h = (per || 1.0) / 2;
    let k = 1;
    for (; t0 + k * h < t1 - 0.05; k++) tl.set(el, { opacity: k % 2 ? 0 : 1 }, t0 + k * h);
    if (k % 2 === 0) tl.set(el, { opacity: 1 }, t1);
  }
  // Drei Punkte, die nacheinander aufleuchten (Karte "Schreibt" / "Räumt auf").
  function punkte(dots, t0, t1) {
    for (let k = 0; t0 + k * 0.3 < t1; k++) dots.forEach((d, j) => tl.set(d, { opacity: j === k % 3 ? 1 : 0.35 }, t0 + k * 0.3));
  }

  // ---------- Pegel der Stimme -> Wellenform (neuester Balken rechts, wie in der App) ----------
  const LV = VO.level.values, LR = VO.level.rate, DT = 1 / LR;
  const lvl = (t) => {
    const i = Math.floor(t * LR + 1e-6);
    return i < 0 || i >= LV.length ? 0 : LV[i];
  };
  function welle(bars, t0, t1, hMin, hMax) {
    const N = bars.length, steps = Math.max(1, Math.round((t1 - t0) * LR));
    bars.forEach((b, i) => {
      const lag = (N - 1 - i) * DT;
      const vals = [];
      for (let k = 0; k <= steps; k++) vals.push(+(hMin + (hMax - hMin) * lvl(t0 + k * DT - lag)).toFixed(2));
      tl.to(b, { keyframes: { height: vals, easeEach: 'sine.inOut' }, duration: steps * DT, ease: 'none' }, t0);
    });
  }

  // ---------- Mauszeiger ----------
  function zeiger(sel) {
    const z = $(sel);
    let pos = null;
    const spitze = (p) => ({ x: p.x - 5, y: p.y - 4 });
    return {
      hin(t, p) {
        pos = spitze(p);
        go(z, { opacity: 0, x: pos.x + 50, y: pos.y + 60 }, { opacity: 1, x: pos.x, y: pos.y, duration: 0.45, ease: 'power2.out' }, t);
      },
      zu(t, p, d) {
        const n = spitze(p);
        go(z, { x: pos.x, y: pos.y }, { x: n.x, y: n.y, duration: d || 0.45, ease: 'power2.inOut' }, t);
        pos = n;
      },
      klick(t) {
        go(z.querySelector('.klick'), { opacity: 0.95, scale: 0.4 }, { opacity: 0, scale: 1.35, duration: 0.45, ease: 'power2.out' }, t);
        go(z.querySelector('svg'), { scale: 1 }, { scale: 0.86, duration: 0.07, ease: 'power1.in', yoyo: true, repeat: 1, transformOrigin: '10% 6%' }, t);
      },
      weg(t) {
        go(z, { opacity: 1 }, { opacity: 0, duration: 0.3, ease: 'power1.in' }, t);
      },
    };
  }

  // =====================================================================
  // DOM: die satz-Karte (Card/CardView.swift), in Punkten der App (--u)
  // =====================================================================
  const BARS = (n) => '<span><i></i></span>'.repeat(n);
  const worte = (s, cls) => s.split(' ').map((w) => '<span class="w' + (cls ? ' ' + cls : '') + '">' + w + '</span>').join(' ');
  function karte(o) {
    const u = o.u;
    const el = document.createElement('div');
    el.className = 'karte';
    el.id = o.id;
    el.setAttribute('data-layout-allow-overlap', '');
    el.style.setProperty('--u', u + 'px');
    el.style.right = o.right + 'px';
    el.style.bottom = o.bottom + 'px';
    el.style.width = (o.voll ? 380 : 200) * u + 'px';
    el.style.opacity = '0';
    el.innerHTML =
      '<div class="ktext"><p>' + o.html + '<span class="ell">…</span><i class="kcaret"></i></p></div><div class="krule"></div>' +
      '<div class="strip"><div class="mid">' +
      '<div class="welle welle-kurz">' + BARS(12) + '</div><div class="welle welle-lang">' + BARS(32) + '</div><div class="welle welle-flach">' + BARS(24) + '</div>' +
      '<div class="lbl l-pause">Pausiert</div>' +
      '<div class="lbl l-schreibt"><div class="punkte"><i></i><i></i><i></i></div><span>Schreibt</span></div>' +
      '<div class="lbl l-raeumt"><div class="punkte"><i></i><i></i><i></i></div><span>Räumt auf</span></div>' +
      '<div class="lbl l-verworfen"><span>Verworfen</span><span class="undo">Rückgängig</span></div>' +
      '</div>' +
      '<div class="knopf mic"><div class="bg bg-an"></div><div class="bg bg-aus"></div><svg class="i-pause"><use href="#i-pause"/></svg><svg class="i-mic"><use href="#i-mic"/></svg><svg class="i-mic-aus"><use href="#i-mic"/></svg></div>' +
      '<div class="knopf auge"><svg><use href="#i-auge"/></svg></div>' +
      '<div class="knopf zu"><svg><use href="#i-x"/></svg></div></div>';
    $(o.host).appendChild(el);
    const q = (s) => el.querySelector(s), qa = (s) => Array.from(el.querySelectorAll(s));
    const C = {
      el, u, ktext: q('.ktext'), p: q('.ktext p'), ell: q('.ell'), kcaret: q('.kcaret'), rule: q('.krule'),
      kurz: q('.welle-kurz'), lang: q('.welle-lang'), flach: q('.welle-flach'),
      barsK: qa('.welle-kurz i'), barsL: qa('.welle-lang i'), barsF: qa('.welle-flach i'),
      lPause: q('.l-pause'), lSchreibt: q('.l-schreibt'), lRaeumt: q('.l-raeumt'), lVerw: q('.l-verworfen'),
      bgAn: q('.bg-an'), bgAus: q('.bg-aus'), iPause: q('.i-pause'), iMic: q('.i-mic'), iMicAus: q('.i-mic-aus'),
      words: qa('.ktext .w'),
      LH: 20.5 * u, PAD: 9 * u, hMin: 2.5 * u, hMax: 16 * u, pill: 200 * u, full: 380 * u,
      unten: 1080 - o.bottom, rechts: 1920 - o.right,
    };
    C.H = (n) => (n ? n * C.LH + 2 * C.PAD : 0);
    // In welcher Zeile steht jedes Wort (für das Wachsen der Karte Zeile um Zeile)?
    C.messen = () => {
      const tops = C.words.map((w) => w.offsetTop);
      const zeilen = [...new Set(tops)].sort((a, b) => a - b);
      C.zeile = tops.map((tp) => zeilen.indexOf(tp) + 1);
      // y = Oberkante der Zeile (die Spanne selbst sitzt etwas tiefer in der Zeile)
      C.nach = C.words.map((w) => ({ x: w.offsetLeft + w.offsetWidth + 5 * u, y: w.offsetTop - (C.LH - w.offsetHeight) / 2 }));
    };
    C.messen();
    // Breite der Pille "Verworfen · Rückgängig": Polster, Text, Abstand, drei Knöpfe.
    C.discW = 14 * u + C.lVerw.offsetWidth + 4 * u + 8 * u + 26 * u + 8 * u + 22 * u + 8 * u + 24 * u + 7 * u;
    C.posMic = rect(q('.mic'));
    C.posZu = rect(q('.zu'));
    C.posMid = rect(q('.mid'));
    // Punkt im Text (p-Koordinaten) -> Bildkoordinaten, bei Texthöhe H.
    C.global = (x, y, H) => ({ x: C.rechts - C.full + x, y: C.unten - 41 * u - H + y });
    return C;
  }
  // Zustände der Karte als Bausteine der Timeline
  // Die dunkle Karte blendet kurz ein und aus (sonst steht sie lange grau auf dem hellen Grund), die Bewegung darf länger dauern.
  function zeig(C, t) {
    go(C.el, { y: 14 * C.u, scale: 0.94 }, { y: 0, scale: 1, duration: 0.42, ease: 'power3.out' }, t);
    go(C.el, { opacity: 0 }, { opacity: 1, duration: 0.14, ease: 'power1.out' }, t);
  }
  function verschwinde(C, t) {
    go(C.el, { y: 0, scale: 1 }, { y: 10 * C.u, scale: 0.96, duration: 0.26, ease: 'power2.in' }, t);
    go(C.el, { opacity: 1 }, { opacity: 0, duration: 0.12, ease: 'power1.in' }, t + 0.12);
  }
  function aufziehen(C, t, zeilen) {
    go(C.el, { width: C.pill }, { width: C.full, duration: 0.34, ease: 'power2.inOut' }, t);
    go(C.ktext, { height: 0 }, { height: C.H(zeilen), duration: 0.34, ease: 'power2.inOut' }, t);
    op(C.rule, 0, 1, t + 0.1, 0.2);
    op(C.kurz, 1, 0, t, 0.18);
    op(C.lang, 0, 1, t + 0.12, 0.24);
  }
  // Wörter erscheinen; die Karte wächst Zeile um Zeile, die Pünktchen laufen hinterher.
  function sprich(C, idx, zeiten, ab) {
    let z = ab;
    idx.forEach((wi, k) => {
      const t = zeiten[k];
      if (C.zeile[wi] > z) {
        go(C.ktext, { height: C.H(z) }, { height: C.H(C.zeile[wi]), duration: 0.22, ease: 'power2.out' }, t - 0.04);
        z = C.zeile[wi];
      }
      go(C.words[wi], { opacity: 0 }, { opacity: 1, duration: 0.14, ease: 'power1.out' }, t);
      tl.set(C.ell, { x: C.nach[wi].x, y: C.nach[wi].y, opacity: 1 }, t);
    });
    return z;
  }
  function pausiere(C, t) {
    op(C.bgAn, 1, 0, t, 0.15);
    op(C.bgAus, 0, 1, t, 0.15);
    op(C.iPause, 1, 0, t, 0.12);
    op(C.iMic, 0, 1, t + 0.05, 0.15);
    op(C.lang, 1, 0, t, 0.2);
    op(C.flach, 0, 1, t + 0.08, 0.2);
    op(C.lPause, 0, 1, t + 0.08, 0.2);
    tl.set(C.ell, { opacity: 0 }, t);
  }
  function weiter(C, t) {
    op(C.bgAn, 0, 1, t, 0.15);
    op(C.bgAus, 1, 0, t, 0.15);
    op(C.iMic, 1, 0, t, 0.12);
    op(C.iPause, 0, 1, t + 0.05, 0.15);
    op(C.flach, 1, 0, t, 0.15);
    op(C.lPause, 1, 0, t, 0.15);
    op(C.lang, 0, 1, t + 0.08, 0.2);
  }
  function arbeitet(C, t, t1, label, ausWelle) {
    op(ausWelle, 1, 0, t, 0.18);
    op(C.bgAn, 1, 0, t, 0.15);
    op(C.bgAus, 0, 1, t, 0.15);
    op(C.iPause, 1, 0, t, 0.12);
    op(C.iMicAus, 0, 1, t + 0.05, 0.15);
    op(label, 0, 1, t + 0.1, 0.2);
    tl.set(C.ell, { opacity: 0 }, t);
    punkte($$('.punkte i', label), t + 0.1, t1);
  }

  // =====================================================================
  // DOM bauen und messen (vor jeder Tween)
  // =====================================================================
  // ---- Mail ----
  const TIPP = 'Hallo zusmamen';
  const typed = $('#typed');
  TIPP.split('').forEach((ch) => {
    const s = document.createElement('span');
    s.textContent = ch;
    typed.appendChild(s);
  });
  const chars = $$('#typed span');
  const MAIL = 'Hallo zusammen, wir treffen uns am Dienstag im großen Raum. Bringt gern eure Ideen mit.';
  $('#mtext').innerHTML = worte(MAIL);
  const mw = $$('#mtext .w');
  const welleHook = $('#hook-welle');
  welleHook.innerHTML = '<i></i>'.repeat(24);
  const hookBars = $$('#hook-welle i');

  const kIdee = karte({ host: '#s-mail', id: 'k-idee', u: 2.5, html: worte(MAIL), right: 485, bottom: 780 });

  // ---- So geht's ----
  const NOTIZ = 'Kannst du mir die Folien noch heute schicken?';
  $('#ntext').innerHTML = worte(NOTIZ);
  const nw = $$('#ntext .w');
  const kSo = karte({ host: '#s-so', id: 'k-so', u: 2.2, html: worte(NOTIZ), right: 140, bottom: 580 });

  // ---- Apps ----
  const KI = 'Fasse den Text kurz zusammen.';
  $('#ki-text').innerHTML = worte(KI);
  const kw = $$('#ki-text .w');

  // ---- Karte (Nahaufnahme) ----
  const K_A = 'Kannst du mir die Folien';
  const K_B = 'bis Freitag schicken? Dann schaue ich sie mir am Wochenende an.';
  const kKarte = karte({
    host: '#s-karte', id: 'k-karte', u: 3.2, right: 352, bottom: 340,
    html: worte(K_A) + '<span class="ins" id="k-ins">&nbsp;' + worte('und die Notizen', 'wi') + '</span><span class="ins ph" id="k-ph">&nbsp;<b>…</b></span> ' + worte(K_B),
  });
  const ins = $('#k-ins'), ph = $('#k-ph');
  const kWi = kKarte.words.map((w, i) => (w.classList.contains('wi') ? i : -1)).filter((i) => i >= 0);
  const kA = kKarte.words.map((w, i) => (w.classList.contains('wi') ? -1 : i)).filter((i) => i >= 0);
  const kFolien = kKarte.words.findIndex((w) => w.textContent === 'Folien');
  const kZeileA = Math.max(...kA.map((i) => kKarte.zeile[i]));
  const kNachFolien = Object.assign({}, kKarte.nach[kFolien]);
  ins.style.maxWidth = 'none';
  ph.style.maxWidth = 'none';
  const insW = ins.offsetWidth, phW = ph.offsetWidth;
  kKarte.messen();
  const kZeileB = Math.max(...kKarte.zeile);
  ins.style.maxWidth = '';
  ph.style.maxWidth = '';
  kKarte.messen();

  // ---- Aufräumen ----
  const kAuf = karte({
    host: '#s-auf', id: 'k-auf', u: 3.6, right: 276, bottom: 280, voll: true,
    html: '<span class="roh"><span class="mark" id="m-fw">ähm also<i class="durch"></i></span> <span class="mark" id="m-w">w<i class="hell"></i></span>ir treffen uns <span class="mark" id="m-vs">Montag nein<i class="durch"></i></span> Dienstag<span class="neu-punkt">.</span></span>' +
      '<span class="final" style="position:absolute; left: calc(17 * var(--u)); top: calc(9 * var(--u)); white-space: nowrap">Wir treffen uns Dienstag.</span>',
  });
  kAuf.ktext.style.height = kAuf.H(1) + 'px';
  kAuf.rule.style.opacity = '1';
  kAuf.kurz.style.opacity = '0';
  kAuf.lang.style.opacity = '1';

  // ---- Messen: Mail ----
  const mLH = 60, mCH = 50;
  const nachZeichen = (el, lh, ch) => ({ x: el.offsetLeft + el.offsetWidth + 2, y: el.offsetTop + el.offsetHeight / 2 - ch / 2 });
  const caretStartMail = { x: 0, y: (mLH - mCH) / 2 };
  const tippPos = chars.map((c) => nachZeichen(c, mLH, mCH));
  const mailPos = mw.map((w) => nachZeichen(w, mLH, mCH));
  const zIdx = TIPP.indexOf('z');
  const kringelL = chars[zIdx].offsetLeft, kringelW = chars[chars.length - 1].offsetLeft + chars[chars.length - 1].offsetWidth - kringelL;
  const selW = chars[chars.length - 1].offsetLeft + chars[chars.length - 1].offsetWidth + 4;
  const hookR = rect(welleHook);
  const pillMid = kIdee.posMid;

  // ---- Messen: Notizen, KI-Chat ----
  const nCH = 46;
  const notizPos = nw.map((w) => nachZeichen(w, 56, nCH));
  const kiCaret = $('#ki-caret');
  const kiBase = { x: 26, y: 19 };
  const kiPos = kw.map((w) => ({ x: 26 + w.offsetLeft + w.offsetWidth + 2 - kiBase.x, y: 12 + w.offsetTop + w.offsetHeight / 2 - 23 - kiBase.y }));

  // ---- Messen: Einstellungen ----
  const einst = $('#einst'), U = 2.45;
  const vari = $('#varianten');
  const vH = Math.max($('#v1').offsetHeight, $('#v2').offsetHeight, $('#v3').offsetHeight);
  vari.style.height = vH + 'px';
  const inhalt = $('#einst .inhalt');
  const einstH = Math.round(inhalt.offsetTop + inhalt.offsetHeight + 30 * U);
  einst.style.height = einstH + 'px';
  einst.style.top = Math.round((1080 - einstH) / 2) + 'px';
  const menu = $('#anb-menu');
  const knopfR = rect('#anb-knopf');
  // Das Menü klappt über dem Anbieter-Feld auf (Oberkante knapp über dem Feld, unter der Überschrift "Anbieter"),
  // die Einträge stehen bündig mit dem Knopftext. So bleibt es ganz im Bild.
  menu.style.left = Math.round(knopfR.l + 15 * U - 34 * U) + 'px';
  menu.style.top = Math.round(rect('#v1').t - 4 * U) + 'px';
  menu.style.transformOrigin = '30% 0';
  const items = $$('#anb-menu .item');
  const itemR = items.map((it) => rect(it));
  const itemTop = items.map((it) => it.offsetTop - items[0].offsetTop);
  const keyR = rect('#key-row'), variR = rect(vari);
  const ring = $('#key-ring');
  ring.style.top = Math.round(keyR.t - variR.t + 3 * U) + 'px';
  ring.style.height = Math.round(keyR.h - 6 * U) + 'px';
  const knopfP = { x: knopfR.l + 60, y: knopfR.cy };
  const benutzenR = rect('#benutzen');
  const offline = $('#offline');

  // ---- Messen: Aufräumen ----
  const tagUeber = (tagSel, markEl) => {
    const tag = $(tagSel), m = rect(markEl);
    tag.style.left = Math.round(m.cx - tag.offsetWidth / 2) + 'px';
    tag.style.top = Math.round(m.t - tag.offsetHeight + 4) + 'px';
  };
  tagUeber('#tag-fw', '#m-fw');
  tagUeber('#tag-vs', '#m-vs');
  tagUeber('#tag-sz', '#k-auf .neu-punkt');
  // Nach dem Aufräumen rücken die drei Schilder (ohne Stiel) in eine Reihe über der Karte und bleiben stehen.
  const tagReihe = ['#tag-fw', '#tag-vs', '#tag-sz'].map((s) => {
    const el = $(s);
    return { el, l: el.offsetLeft, t: el.offsetTop, w: el.offsetWidth };
  }).sort((a, b) => a.l - b.l);
  {
    const GAP = 24, mitte = kAuf.rechts - kAuf.full / 2;
    let x = mitte - (tagReihe.reduce((s, r) => s + r.w, 0) + GAP * (tagReihe.length - 1)) / 2;
    const oben = Math.min(...tagReihe.map((r) => r.t));
    tagReihe.forEach((r) => {
      r.dx = Math.round(x - r.l);
      r.dy = oben - r.t;
      x += r.w + GAP;
    });
  }

  const kr = $('#m-kringel');
  kr.style.left = kringelL + 'px';
  kr.style.width = kringelW + 'px';
  $('#m-sel').style.width = selW + 'px';

  // =====================================================================
  // Szenengrenzen
  // =====================================================================
  const T = {
    so: A('i1:ende') + 0.02,
    apps: A('s2:Ob') - 0.3,
    karte: A('s2:ende') + 0.1,
    wahl: A('k1:ende') + 0.25,
    w2: A('w1:ende') - 0.12,
    auf: A('w2:ende') + 0.05,
    cta: A('a1:ende') + 0.27,
  };

  // Startlagen (aus den Messungen), sofort gesetzt, damit schon Bild 0 stimmt
  gsap.set('#mcaret', caretStartMail);
  gsap.set('#ncaret', { x: 0, y: 5 });
  gsap.set(['#fn-strich', '#url-strich', '#m-fw .durch', '#m-vs .durch', '#nichts-strich'], { scaleX: 0 });
  gsap.set('#wortmarke .marke i', { scaleY: 0 });
  gsap.set(['#strich1', '#strich2'], { strokeDasharray: 104, strokeDashoffset: 104 });

  // Hintergrund atmet ganz leicht
  go('#bg .glow-a', { x: 0, y: 0 }, { x: 120, y: 60, duration: DUR, ease: 'sine.inOut' }, 0);
  go('#bg .glow-b', { x: 0, y: 0 }, { x: -140, y: -50, duration: DUR, ease: 'sine.inOut' }, 0);

  // =====================================================================
  // Szene 1: Hook. Leere Mail, Cursor blinkt, mühsames Tippen mit Tippfehler.
  // =====================================================================
  go('#mail', { y: 18 }, { y: 0, duration: 1.2, ease: 'power2.out' }, 0);
  const TT = [0.42, 0.57, 0.7, 0.81, 0.99, 1.14, 1.32, 1.43, 1.57, 1.68, 1.77, 1.89, 2.0, 2.1];
  chars.forEach((c, i) => {
    tl.set(c, { opacity: 1 }, TT[i]);
    tl.set('#mcaret', tippPos[i], TT[i]);
  });
  go('#m-kringel', { opacity: 0, clipPath: 'inset(0 100% 0 0)' }, { opacity: 1, clipPath: 'inset(0 0% 0 0)', duration: 0.35, ease: 'power2.out' }, 2.22);
  // Tippen hört auf, der Cursor blinkt.
  blinke('#mcaret', 2.1, 3.86, 1.0);
  // Eine Tonwelle erscheint, auf "sprechen".
  const tWelle = A('h2:sprechen') - 0.06;
  go(welleHook, { opacity: 0, scale: 0.5 }, { opacity: 1, scale: 1, duration: 0.42, ease: 'back.out(1.6)' }, tWelle);
  welle(hookBars, tWelle, 4.7, 10, 104);
  // Der getippte Versuch wird markiert und gelöscht.
  op('#m-sel', 0, 1, 3.86, 0.1);
  tl.set(chars, { opacity: 0 }, 4.06);
  tl.set('#m-kringel', { opacity: 0 }, 4.06);
  tl.set('#m-sel', { opacity: 0 }, 4.06);
  tl.set('#mcaret', caretStartMail, 4.06);

  // =====================================================================
  // Szene 2: Idee. Die satz-Karte erscheint, der Satz fließt in die Mail.
  // =====================================================================
  const tPill = A('i1:Mit') - 0.06;
  go(welleHook, { x: 0, y: 0, scale: 1, opacity: 1 }, {
    x: pillMid.cx - hookR.cx, y: pillMid.cy - hookR.cy, scale: pillMid.w / hookR.w, opacity: 0, duration: 0.5, ease: 'power3.inOut',
  }, tPill - 0.12);
  zeig(kIdee, tPill + 0.12);
  const tAuf = A('i1:sprichst') - 0.08;
  welle(kIdee.barsK, tPill, tAuf + 0.4, kIdee.hMin, kIdee.hMax);
  welle(kIdee.barsL, tAuf, A('i1:steht') + 0.4, kIdee.hMin, kIdee.hMax);
  aufziehen(kIdee, tAuf, 1);
  const iWorte = mw.map((_, i) => i);
  sprich(kIdee, iWorte, verteilt(iWorte.length, tAuf + 0.14, A('i1:steht') - 0.14), 1);
  blinke('#mcaret', 4.06, A('i1:steht') + 0.02, 1.0);
  // Der Text landet dort, wo der Cursor blinkt.
  const tLand = A('i1:steht') + 0.02;
  op(kIdee.p, 1, 0, tLand, 0.18);
  go(kIdee.ktext, { height: kIdee.H(Math.max(...kIdee.zeile)) }, { height: 0, duration: 0.3, ease: 'power2.inOut' }, tLand + 0.12);
  go(kIdee.el, { width: kIdee.full }, { width: kIdee.pill, duration: 0.3, ease: 'power2.inOut' }, tLand + 0.12);
  op(kIdee.rule, 1, 0, tLand + 0.1, 0.15);
  op(kIdee.lang, 1, 0, tLand + 0.1, 0.15);
  verschwinde(kIdee, tLand + 0.42);
  mw.forEach((w, i) => {
    const t = tLand + 0.06 + i * 0.034;
    go(w, { opacity: 0 }, { opacity: 1, duration: 0.12, ease: 'power1.out' }, t);
    tl.set('#mcaret', mailPos[i], t);
  });
  const tGelandet = tLand + 0.06 + mw.length * 0.034;
  // "wo dein Cursor blinkt": der Cursor wird kurz orange.
  const tCursor = A('i1:Cursor') - 0.05;
  blinke('#mcaret', tGelandet, tCursor, 1.0);
  go('#mcaret', { backgroundColor: '#16303c', scaleY: 1 }, { backgroundColor: '#ff6100', scaleY: 1.12, duration: 0.2, ease: 'power2.out' }, tCursor);
  blinke('#mcaret', tCursor, A('i1:Auf') + 0.4, 0.84);
  go('#mcaret', { backgroundColor: '#ff6100', scaleY: 1.12 }, { backgroundColor: '#16303c', scaleY: 1, duration: 0.3, ease: 'power1.inOut' }, A('i1:Auf') + 0.4);
  blinke('#mcaret', A('i1:Auf') + 0.4, T.so, 1.0);
  // Mac · Windows · Linux
  [['#chip-mac', 'i1:Mac'], ['#chip-win', 'i1:Windows'], ['#chip-lin', 'i1:Linux']].forEach(([s, a]) => inn(s, A(a) - 0.1, { y: 26, scale: 0.9 }, 0.45, 'back.out(1.7)'));

  // =====================================================================
  // Szene 3: So geht's. Rechte Befehlstaste zweimal, sprechen, nochmal tippen.
  // =====================================================================
  szene('#s-mail', '#s-so', T.so);
  function tippe(t, ring) {
    go('#taste-cmd', { y: 0, backgroundColor: '#ffffff' }, { y: 10, backgroundColor: '#ffe3d1', duration: 0.07, ease: 'power1.in', yoyo: true, repeat: 1 }, t);
    go(ring, { opacity: 0.95, scale: 0.94 }, { opacity: 0, scale: 1.16, duration: 0.6, ease: 'power2.out' }, t);
  }
  const tTipp1 = A('s1:Zweimal');
  tippe(tTipp1, '#taste-ring');
  tippe(tTipp1 + 0.22, '#taste-ring2');
  const tSoPill = tTipp1 + 0.36;
  zeig(kSo, tSoPill);
  const tLos = A('s1:lossprechen') - 0.04;
  const tTipp3 = A('s1:einmal') - 0.1;
  welle(kSo.barsK, tSoPill, tLos + 0.4, kSo.hMin, kSo.hMax);
  welle(kSo.barsL, tLos, tTipp3 + 0.1, kSo.hMin, kSo.hMax);
  aufziehen(kSo, tLos, 1);
  sprich(kSo, nw.map((_, i) => i), verteilt(nw.length, tLos + 0.12, A('s1:noch') - 0.1), 1);
  tippe(tTipp3, '#taste-ring');
  const tFertig = A('s1:tippen#2') + 0.08;
  arbeitet(kSo, tTipp3 + 0.05, tFertig, kSo.lSchreibt, kSo.lang);
  op(kSo.p, 1, 0, tFertig, 0.16);
  verschwinde(kSo, tFertig + 0.05);
  blinke('#ncaret', T.so + 0.2, tFertig, 1.0);
  nw.forEach((w, i) => {
    const t = tFertig + 0.08 + i * 0.04;
    go(w, { opacity: 0 }, { opacity: 1, duration: 0.12, ease: 'power1.out' }, t);
    tl.set('#ncaret', notizPos[i], t);
  });
  blinke('#ncaret', tFertig + 0.08 + nw.length * 0.04, T.apps + 0.4, 1.0);

  // =====================================================================
  // Szene 4: Überall, wo ein Cursor ist. Mail, Slack, Code-Editor, KI-Chat.
  // =====================================================================
  szene('#s-so', '#s-apps', T.apps);
  // Vier Fenster im Raster, jedes auf seinem Wort. "Wo ein Cursor ist": alle vier Cursor leuchten orange.
  const appsAn = [['#app-mail', 's2:Mail'], ['#app-slack', 's2:Slack'], ['#app-code', 's2:Code'], ['#app-ki', 's2:Chat']];
  const tKiAn = A('s2:Chat') - 0.12;
  const tCursor2 = A('s2:Cursor') - 0.05;
  const tSchreibt = A('s2:schreibt') - 0.02;
  appsAn.forEach(([s, a]) => {
    const t = A(a) - 0.12;
    inn(s, t, { y: 50, scale: 0.97 }, 0.5, 'power3.out');
    if (s === '#app-ki') return;
    const c = $(s + ' .caret');
    blinke(c, t + 0.5, tCursor2, 1.0);
    // Während "wo ein Cursor ist" stehen die Cursor ruhig und orange, damit man sie sicher sieht.
    tl.set(c, { opacity: 1 }, tCursor2);
    go(c, { backgroundColor: '#16303c', scaleY: 1 }, { backgroundColor: '#ff6100', scaleY: 1.15, duration: 0.2, ease: 'power2.out' }, tCursor2);
    go(c, { backgroundColor: '#ff6100', scaleY: 1.15 }, { backgroundColor: '#16303c', scaleY: 1, duration: 0.25 }, tSchreibt);
    blinke(c, tSchreibt, T.karte + 0.3, 1.0);
  });
  blinke(kiCaret, tKiAn + 0.5, tCursor2, 1.0);
  go(kiCaret, { backgroundColor: '#16303c', scaleY: 1 }, { backgroundColor: '#ff6100', scaleY: 1.15, duration: 0.2, ease: 'power2.out' }, tCursor2);
  tl.set(kiCaret, { opacity: 1 }, tCursor2);
  go(kiCaret, { backgroundColor: '#ff6100', scaleY: 1.15 }, { backgroundColor: '#16303c', scaleY: 1, duration: 0.25 }, tSchreibt);
  kw.forEach((w, i) => {
    const t = tSchreibt + i * 0.07;
    go(w, { opacity: 0 }, { opacity: 1, duration: 0.12, ease: 'power1.out' }, t);
    tl.set(kiCaret, kiPos[i], t);
  });
  blinke(kiCaret, tSchreibt + kw.length * 0.07, T.karte + 0.3, 1.0);
  // Das Menü der Menüleiste zeigt, was satz zuletzt geschrieben hat.
  const tPop = tSchreibt + 0.16;
  op('#menu-satz .hl', 0, 1, tPop - 0.06, 0.15);
  go('#pop', { y: -18, scale: 0.97 }, { y: 0, scale: 1, duration: 0.4, ease: 'power3.out' }, tPop);
  go('#pop', { opacity: 0 }, { opacity: 1, duration: 0.14, ease: 'power1.out' }, tPop);

  // =====================================================================
  // Szene 5: Die Karte. Pausieren, Einfügestelle wählen, verwerfen.
  // =====================================================================
  szene('#s-apps', '#s-karte', T.karte);
  const C = kKarte;
  const tKPill = T.karte + AUS + 0.04;
  zeig(C, tKPill);
  const tKAuf = A('k1:Sprechen') - 0.04;
  welle(C.barsK, tKPill, tKAuf + 0.4, C.hMin, C.hMax);
  const tPause = A('k1:pausieren') + 0.05;
  welle(C.barsL, tKAuf, tPause + 0.2, C.hMin, C.hMax);
  aufziehen(C, tKAuf, 1);
  sprich(C, kA, verteilt(kA.length, tKAuf + 0.12, A('k1:Text') + 0.1), 1);
  const zk = zeiger('#zeiger-k');
  zk.hin(tPause - 0.82, { x: C.posMic.cx + 120, y: C.posMic.cy + 150 });
  zk.zu(tPause - 0.33, { x: C.posMic.cx, y: C.posMic.cy }, 0.26);
  zk.klick(tPause - 0.03);
  pausiere(C, tPause);
  // Klick in den Text: hier landen die nächsten Wörter.
  const HA = C.H(kZeileA), HB = C.H(kZeileB);
  const spot = C.global(kNachFolien.x - 5 * C.u + 2, kNachFolien.y + C.LH / 2, HA);
  const tStelle = A('k1:bestimmen') + 0.02;
  zk.zu(tPause + 0.3, spot, 0.45);
  zk.klick(tStelle);
  zk.zu(tStelle + 0.12, { x: spot.x + 46, y: spot.y + 64 }, 0.26);
  tl.set(C.kcaret, { x: kNachFolien.x - 5 * C.u + 2, y: kNachFolien.y + (C.LH - 17 * C.u) / 2, opacity: 1 }, tStelle + 0.03);
  const tWeiter = A('k1:nächsten');
  blinke(C.kcaret, tStelle + 0.03, tWeiter - 0.05, 1.0);
  zk.zu(tWeiter - 0.42, { x: C.posMic.cx, y: C.posMic.cy }, 0.36);
  zk.klick(tWeiter - 0.03);
  weiter(C, tWeiter);
  tl.set(C.kcaret, { opacity: 0 }, tWeiter);
  // Die Pünktchen sitzen jetzt an der gewählten Stelle, der Text dahinter rückt auf.
  go(ph, { maxWidth: 0 }, { maxWidth: phW, duration: 0.25, ease: 'power2.out' }, tWeiter + 0.02);
  const tVerwirf = A('k1:verwerfen') - 0.04;
  welle(C.barsL, tWeiter, tVerwirf, C.hMin, C.hMax);
  // Die neuen Wörter landen an der gewählten Stelle, der Rest macht Platz.
  const tIns = A('k1:Wörter') - 0.08;
  go(ins, { maxWidth: 0 }, { maxWidth: insW, duration: 0.55, ease: 'power2.out' }, tIns);
  if (HB > HA) go(C.ktext, { height: HA }, { height: HB, duration: 0.3, ease: 'power2.out' }, tIns);
  kWi.forEach((wi, k) => go(C.words[wi], { opacity: 0 }, { opacity: 1, duration: 0.16, ease: 'power1.out' }, tIns + 0.08 + k * 0.17));
  // … oder alles verwerfen.
  zk.zu(tVerwirf - 0.5, { x: C.posZu.cx, y: C.posZu.cy }, 0.42);
  zk.klick(tVerwirf - 0.03);
  op(C.p, 1, 0, tVerwirf, 0.16);
  go(C.ktext, { height: HB }, { height: 0, duration: 0.3, ease: 'power2.inOut' }, tVerwirf + 0.08);
  op(C.rule, 1, 0, tVerwirf + 0.08, 0.15);
  op(C.lang, 1, 0, tVerwirf, 0.15);
  go(C.el, { width: C.full }, { width: C.discW, duration: 0.36, ease: 'power2.inOut' }, tVerwirf + 0.08);
  op(C.bgAn, 1, 0, tVerwirf, 0.15);
  op(C.bgAus, 0, 1, tVerwirf, 0.15);
  op(C.iPause, 1, 0, tVerwirf, 0.12);
  op(C.iMicAus, 0, 1, tVerwirf + 0.05, 0.15);
  op(C.lVerw, 0, 1, tVerwirf + 0.16, 0.14);
  zk.zu(tVerwirf + 0.35, { x: C.posZu.cx + 110, y: C.posZu.cy + 120 }, 0.5);
  zk.weg(tVerwirf + 0.75);

  // =====================================================================
  // Szene 6: Wahl. Dienst mit eigenem Schlüssel oder lokal, ohne Internet.
  // =====================================================================
  szene('#s-karte', '#s-wahl', T.wahl);
  const zw = zeiger('#zeiger-w');
  const tMenu1 = A('w1:wer') - 0.02;
  zw.hin(tMenu1 - 0.62, { x: knopfP.x + 160, y: knopfP.y + 140 });
  zw.zu(tMenu1 - 0.17, knopfP, 0.3);
  zw.klick(tMenu1 - 0.03);
  go(menu, { scale: 0.96, y: -8 }, { scale: 1, y: 0, duration: 0.2, ease: 'power2.out' }, tMenu1);
  op(menu, 0, 1, tMenu1, 0.08);
  // "ein Dienst deiner Wahl": die Markierung wandert über die Dienste.
  const hl = $('#anb-hl');
  const stufen = [[0, A('w1:Dienst') - 0.25], [1, A('w1:Dienst')], [2, A('w1:deiner')], [3, A('w1:Wahl') - 0.08], [4, A('w1:mit') - 0.05]];
  op(hl, 0, 1, stufen[0][1], 0.12);
  tl.set(hl, { y: itemTop[0] }, stufen[0][1]);
  let hlY = itemTop[0];
  stufen.slice(1).forEach(([i, t]) => {
    go(hl, { y: hlY }, { y: itemTop[i], duration: 0.14, ease: 'power2.out' }, t);
    hlY = itemTop[i];
  });
  zw.zu(stufen[0][1] - 0.15, { x: itemR[0].l + 150, y: itemR[0].cy }, 0.2);
  stufen.slice(1).forEach(([i, t]) => zw.zu(t, { x: itemR[i].l + 150, y: itemR[i].cy }, 0.14));
  const tZu1 = A('w1:deinem#1') - 0.08;
  op(menu, 1, 0, tZu1, 0.08);
  // "mit deinem eigenen Schlüssel"
  const tKey = A('w1:eigenen') - 0.1;
  go(ring, { opacity: 0, scale: 1.03 }, { opacity: 1, scale: 1, duration: 0.3, ease: 'power2.out' }, tKey);
  zw.zu(tZu1 + 0.05, { x: keyR.r - 120, y: keyR.cy + 30 }, 0.4);
  const tOder = A('w1:oder') + 0.05;
  op(ring, 1, 0, tOder, 0.2);
  // "oder ein Modell direkt auf deinem Rechner": Lokal ansehen, dann benutzen.
  zw.zu(tOder, knopfP, 0.32);
  zw.klick(tOder + 0.34);
  const tMenu2 = tOder + 0.37;
  go(menu, { scale: 0.96, y: -8 }, { scale: 1, y: 0, duration: 0.2, ease: 'power2.out' }, tMenu2);
  op(menu, 0, 1, tMenu2, 0.08);
  tl.set(hl, { y: itemTop[1] }, tMenu2);
  const tLokal = A('w1:Modell') - 0.1;
  go(hl, { y: itemTop[1] }, { y: itemTop[6], duration: 0.3, ease: 'power2.inOut' }, tLokal);
  zw.zu(tMenu2 + 0.05, { x: itemR[1].l + 150, y: itemR[1].cy }, 0.2);
  zw.zu(tLokal, { x: itemR[6].l + 110, y: itemR[6].cy }, 0.3);
  const tKlickLokal = A('w1:direkt') - 0.02;
  zw.klick(tKlickLokal);
  op(menu, 1, 0, tKlickLokal + 0.06, 0.08);
  op('#v1', 1, 0, tKlickLokal + 0.08, 0.2);
  op('#v2', 0, 1, tKlickLokal + 0.08, 0.2);
  const tBenutzen = A('w1:Rechner') - 0.05;
  zw.zu(tKlickLokal + 0.25, { x: benutzenR.cx, y: benutzenR.cy }, 0.4);
  zw.klick(tBenutzen);
  op('#v2', 1, 0, tBenutzen + 0.04, 0.2);
  op('#v3', 0, 1, tBenutzen + 0.04, 0.2);
  zw.zu(tBenutzen + 0.3, { x: benutzenR.cx + 140, y: benutzenR.cy + 220 }, 0.5);
  zw.weg(tBenutzen + 0.55);
  // "ganz ohne Internet"
  const tOffline = A('w1:ohne') - 0.06;
  go('#fn-strich', { scaleX: 0 }, { scaleX: 1, duration: 0.45, ease: 'power2.out' }, tOffline);
  inn(offline, tOffline + 0.12, { x: -16, scale: 0.9 }, 0.45, 'back.out(1.6)');

  // =====================================================================
  // Szene 7: Kein satz-Konto, kein satz-Server.
  // =====================================================================
  szene('#s-wahl', '#s-w2', T.w2);
  const tS1 = A('w2:Satzkonto') - 0.16;
  inn('#satz1', tS1, { y: 34, filter: 'blur(8px)' }, 0.65, 'power3.out');
  go('#strich1', { strokeDasharray: 104, strokeDashoffset: 104 }, { strokeDasharray: 104, strokeDashoffset: 0, duration: 0.45, ease: 'power2.inOut' }, tS1 + 0.35);
  const tS2 = A('w2:nicht') + 0.2;
  inn('#satz2', tS2, { y: 34, filter: 'blur(8px)' }, 0.65, 'power3.out');
  go('#strich2', { strokeDasharray: 104, strokeDashoffset: 104 }, { strokeDasharray: 104, strokeDashoffset: 0, duration: 0.45, ease: 'power2.inOut' }, tS2 + 0.35);
  // "Du zahlst nur, was du beim Dienst verbrauchst, und lokal gar nichts": die zwei Sätze rücken nach oben, darunter Dienst und Lokal.
  const tHoch = A('w2:nur') - 0.05;
  go('#saetze', { y: 0, scale: 1 }, { y: -135, scale: 0.75, duration: 0.6, ease: 'power3.inOut' }, tHoch);
  inn('#ko-dienst', tHoch + 0.3, { y: 30 }, 0.5, 'power3.out');
  inn('#ko-lokal', A('w2:lokal') - 0.15, { y: 30 }, 0.5, 'power3.out');
  go('#nichts-strich', { scaleX: 0 }, { scaleX: 1, duration: 0.4, ease: 'power2.out' }, A('w2:gar') - 0.02);

  // =====================================================================
  // Szene 8: Aufräumen. Satzzeichen, Füllwörter, Versprecher.
  // =====================================================================
  szene('#s-w2', '#s-auf', T.auf);
  inn('#auf-block', T.auf + AUS, { y: 20 }, 0.5, 'power3.out');
  zeig(kAuf, T.auf + AUS + 0.06);
  const tRaeumt = A('a1:räumt') - 0.05;
  welle(kAuf.barsL, T.auf + 0.2, tRaeumt + 0.2, kAuf.hMin, kAuf.hMax);
  const tToggle = A('a1:willst') - 0.02;
  // Weg des Knaufs: Schalter 38 minus Knauf 18 minus 2 × 2 Rand = 16 Punkte (--u des Blocks: 2.8)
  go('#toggle .knauf', { x: 0 }, { x: 16 * 2.8, duration: 0.24, ease: 'power2.inOut' }, tToggle);
  op('#toggle .an', 0, 1, tToggle, 0.2);
  const tFinal = A('a1:Versprecher') + 0.4;
  arbeitet(kAuf, tRaeumt, tFinal, kAuf.lRaeumt, kAuf.lang);
  const tSZ = A('a1:Satzzeichen') - 0.06;
  op('#m-w .hell', 0, 1, tSZ, 0.2);
  go('#m-w', { color: '#eef4f6' }, { color: '#ffb27a', duration: 0.25 }, tSZ);
  go('#k-auf .neu-punkt', { opacity: 0, scale: 0.4 }, { opacity: 1, scale: 1, duration: 0.3, ease: 'back.out(2)' }, tSZ + 0.08);
  inn('#tag-sz', tSZ, { y: 16 }, 0.4, 'power3.out');
  const tFW = A('a1:Füllwörter') - 0.06;
  go('#m-fw .durch', { scaleX: 0 }, { scaleX: 1, duration: 0.3, ease: 'power2.out' }, tFW);
  go('#m-fw', { color: '#eef4f6' }, { color: 'rgba(238,244,246,0.42)', duration: 0.3 }, tFW + 0.1);
  inn('#tag-fw', tFW, { y: 16 }, 0.4, 'power3.out');
  const tVS = A('a1:Versprecher') - 0.06;
  go('#m-vs .durch', { scaleX: 0 }, { scaleX: 1, duration: 0.34, ease: 'power2.out' }, tVS);
  go('#m-vs', { color: '#eef4f6' }, { color: 'rgba(238,244,246,0.42)', duration: 0.3 }, tVS + 0.1);
  inn('#tag-vs', tVS, { y: 16 }, 0.4, 'power3.out');
  // Nachher: nur noch der Satz.
  op('#k-auf .roh', 1, 0, tFinal, 0.14);
  go('#k-auf .final', { opacity: 0, x: 8 }, { opacity: 1, x: 0, duration: 0.28, ease: 'power2.out' }, tFinal + 0.14);
  tagReihe.forEach((r) => {
    op(r.el.querySelector('i'), 1, 0, tFinal, 0.15);
    go(r.el, { x: 0, y: 0 }, { x: r.dx, y: r.dy, duration: 0.45, ease: 'power2.inOut' }, tFinal + 0.05);
  });
  op(kAuf.lRaeumt, 1, 0, tFinal, 0.2);

  // =====================================================================
  // Szene 9: Schluss. Wortmarke, Link, Plattformen, DPA+.
  // =====================================================================
  szene('#s-auf', '#s-cta', T.cta);
  const tWM = T.cta + AUS;
  $$('#wortmarke .marke i').forEach((b, i) => go(b, { scaleY: 0 }, { scaleY: 1, duration: 0.5, ease: 'back.out(1.8)' }, tWM + i * 0.05));
  inn('#wortmarke b', tWM + 0.1, { y: 30, filter: 'blur(8px)' }, 0.6, 'power3.out');
  inn('#claim-a', Math.max(A('c1:Kostenlos') - 0.05, tWM + 0.05), { y: 18 }, 0.45, 'power3.out');
  inn('#claim-b', A('c1:Open') - 0.1, { y: 18 }, 0.45, 'power3.out');
  const tHol = A('c2:Hol') - 0.05;
  go('#cta-oben', { y: 0 }, { y: -196, duration: 0.7, ease: 'power3.inOut' }, tHol - 0.42);
  inn('#url', tHol, { y: 40, filter: 'blur(8px)' }, 0.65, 'power3.out');
  go('#url-strich', { scaleX: 0 }, { scaleX: 1, duration: 0.6, ease: 'power2.inOut' }, tHol + 0.45);
  inn('#plattformen', A('c2:probier') - 0.12, { y: 18 }, 0.5, 'power3.out');
  inn('#dpa-logo', A('c2:aus') - 0.1, { y: 12 }, 0.5, 'power2.out');
  inn('#ki-hinweis', A('c2:aus') - 0.05, {}, 0.3, 'power1.out');

  window.__timelines['main'] = tl;
  if (window.__hfForceTimelineRebind) window.__hfForceTimelineRebind();
});
