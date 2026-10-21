# satz: Sprechen statt tippen

Erklärvideo (16:9, 1920×1080, 54,5 s), erstellt mit der Skill `erklaervideo` (Stimme, Musik, Mischung, Untertitel) und HyperFrames 0.8.164 (Bild).
Das fertige Video liegt im CDN (siehe projekt.json -> ablage.cdn), hier liegen nur die Rohdateien.

- `skript.json`, `projekt.json`, `marke.json`, `ton_plan.json`: Inhalt und Einstellungen
- `_build/vo/abschnitte/`: die gewählten Sprecheraufnahmen, `_build/musik/`: Musik (Rohdatei + Analyse)
- `film/src/`: die Komposition: `body.html` (Szenen), `style.css` (Farben, Maße der satz-Oberfläche in App-Punkten), `szenen.js` (GSAP-Timeline)
- `film/assets/`: Schriften aus `Resources/Fonts` (OFL), DPA+-Logo und Icons (`icons/`: Mac, Windows, Linux, Slack, Mail, Notizen, Code-Editor, KI-Chat, Lokal) aus dem CDN (Herkunft und Lizenzen in `assets/quellen.json`). Markenzeichen nur neben ihrem Namen, unverändert; KI-Anbieter bleiben reine Namen.
- `werkzeug/baue-film.mjs`: setzt `film/index.html` aus `film/src/`, den Wortzeiten (`_build/timeline.json`) und dem Pegel der Stimme (`_build/mix/stems/stimme.wav`, treibt die Wellenform der Karte) zusammen und bettet die Icons aus `film/assets/icons/` als `<symbol>` ein

Die satz-Oberfläche (Karte, Menü, Einstellungen) ist in HTML nachgebaut, mit Farben, Radien, Größen und Beschriftungen aus `Sources/SatzMac`. Keine Screenshots im Video.
Jede Einblendung hängt an einem Wort der Sprecherspur (`A('zeile:wort')` in `szenen.js`), eine neue Aufnahme zieht das Timing also mit.

## Neu bauen (ohne KI-Kosten)

```bash
zsh ~/.claude/skills/erklaervideo/scripts/bauen.sh .     # Schnitt, Wortzeiten, Untertitel, Mischung
node werkzeug/baue-film.mjs                             # film/index.html
(cd film && npx hyperframes check && npx hyperframes render --quality delivery --output renders/satz-bild-stumm.mp4)
/usr/bin/python3 ~/.claude/skills/erklaervideo/scripts/muxen.py --video film/renders/satz-bild-stumm.mp4 --out satz-erklaervideo.mp4
```

Das Bild wird stumm gerendert, `muxen.py` legt die fertige Mischung (`_build/mix/final_mix.wav`) darunter. Untertitel werden nicht eingebrannt, sie liegen als `Untertitel.srt` / `.vtt` daneben.
