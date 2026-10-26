<div align="center">

<img src="assets/hero.png" alt="satz: Eine Schallwelle fließt in ein Textfeld, in dem der diktierte Satz erscheint." width="100%">

### Taste zweimal tippen, sprechen, und deine Worte erscheinen dort, wo du gerade schreibst.<br>In jeder App, auf Mac, Windows und Linux.

[![Für Mac laden](https://img.shields.io/badge/Laden-macOS-16303c?style=for-the-badge&logo=apple&logoColor=white)](https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest/satz-mac.zip)
[![Für Windows laden](https://img.shields.io/badge/Laden-Windows-16303c?style=for-the-badge&logo=windows&logoColor=white)](#herunterladen)
[![Für Linux laden](https://img.shields.io/badge/Laden-Linux-16303c?style=for-the-badge&logo=linux&logoColor=white)](#herunterladen)

[![Neueste Version](https://img.shields.io/github/v/release/dpa-plus/satz?color=ff6100&label=Version)](https://github.com/dpa-plus/satz/releases/latest)
[![Lizenz: MIT](https://img.shields.io/badge/Lizenz-MIT-ff6100)](LICENSE)

</div>

<br>

<p align="center">
  <img src="assets/showcase.png" alt="Die satz-Karte beim Sprechen, mit dem Satz bisher und einer Live-Wellenform, und das Menü mit den letzten Diktaten." width="90%">
</p>

<p align="center">
  <a href="https://cdn.prozesshub.eu/assets/clients/dpa/videos/marketing/satz-erklaervideo/satz-erklaervideo-de-v2.mp4"><b>▶ Erklärvideo ansehen</b></a> (55 Sekunden, Stimme und Musik KI-generiert)
</p>

## Warum satz

Die meisten Diktier-Apps wollen erst etwas von dir: ein Konto, ein Abo oder eine zweite KI, die umschreibt, was du gesagt hast. satz macht eine Sache. Es nimmt dich auf, macht mit dem Modell deiner Wahl Text aus dem Audio und fügt das Ergebnis dort ein, wo dein Cursor steht. Das Modell läuft bei einem Transkriptionsdienst oder, wenn du magst, auf deinem eigenen Computer.

- **Funktioniert überall, wo du tippst.** Mail, Slack, dein Editor, ein Chat mit einer KI. Wenn es einen Textcursor hat, kann satz es füllen.
- **Sehr genau, sehr günstig.** Standardmäßig nutzt satz Microsofts MAI-Transcribe 2 über OpenRouter: 2,0 % falsche Wörter bei Artificial Analysis (September 2026), gegen 3,3 % bei OpenAIs GPT Transcribe, zu einem Drittel des Preises. Du bezahlst den Anbieter direkt, für das, was du nutzt.
- **Text aufräumen, wenn du willst.** Standardmäßig aus. Schalte es ein, um Zeichensetzung zu korrigieren, Formulierungen zu glätten oder eigene Anweisungen zu nutzen.
- **Du siehst es beim Sprechen.** Eine kleine Karte zeigt deinen Text, während du sprichst. Klick hinein, um zu ändern, wohin die nächsten Worte kommen, mach eine Pause zum Nachdenken, oder wirf alles weg und mach es rückgängig.
- **Nichts, was du auf einem Server einrichten musst.** Kein Konto, keine Telemetrie. Dein Schlüssel bleibt auf deinem Computer.
- **Auf Wunsch offline.** Der Anbieter *Lokal* lässt Whisper auf deinem Computer laufen: ein einmaliger Download, danach kostenlos, und nichts verlässt den Rechner.

## Herunterladen

| System | Datei | Größe | |
|---|---|---|---|
| **macOS 14 oder neuer** (Apple-Chip und Intel) | [satz-mac.zip](https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest/satz-mac.zip) | 26 MB | Entpacken, satz in „Programme“ ziehen |
| **Windows** (Intel und AMD) | [satz-windows-x64.zip](https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest/satz-windows-x64.zip) | 192 MB | Irgendwo entpacken, `satz.exe` starten |
| **Windows 11 auf ARM** | [satz-windows-arm64.zip](https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest/satz-windows-arm64.zip) | 183 MB | Irgendwo entpacken, `satz.exe` starten |
| **Ubuntu, Debian** (x64) | [satz-linux-amd64.deb](https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest/satz-linux-amd64.deb) | 124 MB | `sudo apt install ./satz-linux-amd64.deb` |
| **Ubuntu, Debian** (ARM) | [satz-linux-arm64.deb](https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest/satz-linux-arm64.deb) | 114 MB | `sudo apt install ./satz-linux-arm64.deb` |
| **Anderes Linux** | [x64](https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest/satz-linux-x64.tar.gz) · [ARM](https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest/satz-linux-arm64.tar.gz) | 149 MB · 145 MB | Entpacken, `./satz` starten |

Ältere Versionen und den Quellcode findest du auf der [Releases-Seite](https://github.com/dpa-plus/satz/releases/latest) auf GitHub. Die SHA-256-Prüfsummen aller Dateien stehen in [SHA256SUMS.txt](https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/latest/SHA256SUMS.txt).

**Beim ersten Start fragt dein Computer einmal nach.** satz ist noch nicht mit einem bezahlten Apple- oder Microsoft-Zertifikat signiert, deshalb fragt dein Computer, bevor er es zum ersten Mal öffnet:

- **Mac:** Öffne satz und schließe die Warnung, geh dann in die *Systemeinstellungen → Datenschutz & Sicherheit* und klick auf *Trotzdem öffnen*.
- **Windows:** SmartScreen meldet, dass es deinen PC geschützt hat. Klick auf *Weitere Informationen*, dann auf *Trotzdem ausführen*.

## Loslegen

1. **Schlüssel holen.** Leg unter [openrouter.ai/keys](https://openrouter.ai/keys) einen an und lade ein paar Dollar Guthaben auf. Mit MAI-Transcribe 2 kostet eine Stunde Sprechen etwa 10 Cent, fünf Dollar reichen also lange. Schlüssel von OpenAI und Groq funktionieren auch.
2. **satz öffnen.** Auf dem Mac fragt die Einrichtung nach dem Schlüssel, dem Mikrofon und der Erlaubnis zum Einfügen und endet mit einem Probesatz. Unter Windows und Linux öffnen sich die Einstellungen für den Schlüssel.
3. **Diktieren.** Klick in ein beliebiges Textfeld und tippe den Kurzbefehl zweimal:

| | Starten und beenden | Verwerfen |
|---|---|---|
| Mac | rechte **⌘** zweimal | **Esc** |
| Windows, Linux | rechte **Strg** zweimal | **Esc** |

Sprich, tippe wieder zweimal, und der Text wird eingefügt. satz startet von selbst, wenn du dich anmeldest. In den Einstellungen kannst du das ausschalten.

## Was du tun kannst

**Beim Sprechen**
- **Pausiere** mit dem Mikrofon-Knopf, um nachzudenken. Dein Text erscheint bei jeder Pause.
- **Klick irgendwo in den Text**, und was du als Nächstes sagst, kommt dorthin. Auf dem Mac kannst du auch von Hand darin tippen.
- **Blende den Text aus** mit dem Auge, wenn du nur die kleine Wellenform willst.
- **Wirf ihn weg** mit ×, dann kannst du ein paar Sekunden lang *Rückgängig* klicken, danach *Zurückholen* in der Menüleiste.
- **Verschieb die Karte** wohin du willst. Sie bleibt dort, wo du sie hingelegt hast, und verlässt nie den Bildschirm.
- **Musik pausiert von selbst**, während du sprichst (Spotify, Apple Music, YouTube im Browser, alles, was das System als laufend meldet), und spielt weiter, wenn du fertig bist. Nur das, was lief, und nur das, was satz pausiert hat.

**Wiederfinden**
- **Öffne satz** noch einmal (auf dem Mac aus „Programme“ oder per Spotlight, unter Windows und Linux, indem du satz erneut startest), und du bekommst sein Fenster: **Verlauf** und **Einstellungen**, einen Klick (oder ⌘1 / ⌘2) voneinander entfernt. Der Verlauf enthält alles, was du diktiert hast, nach Tagen sortiert und mit Suche. Ein Klick kopiert, × vergisst einen Eintrag.
- **Behalten** werden die letzten 10, 50, 200 oder alle Diktate, oder keins. Die Menüleiste zeigt die letzten vier.
- **Einfügen** (Mac): Der Knopf neben *Kopieren* in der Menüleiste setzt deinen letzten Text in das Textfeld, in dem du gerade bist. Das geht nur, solange ein Textfeld den Cursor hat.

**In den Einstellungen**
- **Wortschatz:** Namen und Begriffe, die das Modell so schreiben soll, wie du es willst („Kubernetes“, der Name eines Kollegen).
- **Ersetzungen:** Sag „Klammer auf“ und du bekommst `(`, sag „neue Zeile“ für einen Zeilenumbruch. Eigene Auslösewörter kannst du hinzufügen.
- **Gesprochen auf:** Deutsch oder English, getrennt von der Sprache der App.
- **Kurzbefehl:** Tippen zum Starten und Beenden, oder halten, solange du sprichst. Auf dem Mac auch eine eigene Tastenkombination oder eine Maustaste.
- **Text aufräumen** (aus, bis du es einschaltest): Ein Sprachmodell entfernt die „Ähms“ oder schreibt deinen Text um, bevor er eingefügt wird, so stark, wie du es wählst. Siehe [Text aufräumen](#text-aufräumen).
- **Text in der Zwischenablage behalten:** Standardmäßig aus, damit alles, was du kopiert hattest, nach dem Einfügen zurückkommt. Ist es an, bleibt der diktierte Text dort und du kannst ihn nochmal einfügen.
- **Farbe** (Mac): vier Farben, hell und dunkel, Liquid Glass ab macOS 26.

## Gebaut, damit keine Worte verloren gehen

| Was in anderen Apps schiefgeht | Was satz tut |
|---|---|
| Das letzte Wort wird abgeschnitten | Das Mikrofon bleibt 400 ms nach deinem Stopp offen |
| Zerstückeltes Audio verstümmelt Wörter | Die Cloud-Transkription bekommt die ganze Aufnahme; die Grenzen lokaler Modelle stehen weiter unten |
| Es dreht sich endlos | Jede Anfrage hat ein Zeitlimit; ein Fehler bleibt mit *Nochmal* auf der Karte |
| Eine abgebrochene Verbindung verliert deine Sprache | Das Audio bleibt erhalten, bis es gesendet ist |
| Das Einfügen scheitert stillschweigend | satz sagt es und lässt den Text auf der Zwischenablage |
| Es fügt in die falsche App ein | Der Text geht zurück in die App, in der du angefangen hast |
| Es frisst deine Zwischenablage | Was du kopiert hattest, kommt nach dem Einfügen zurück |

## Anbieter und Modelle

| Anbieter | Standardmodell | Hinweise |
|---|---|---|
| **OpenRouter** (empfohlen) | Microsoft MAI-Transcribe 2 | Ein Schlüssel, jedes Sprachmodell, das OpenRouter hat |
| OpenAI | GPT Transcribe | Auch GPT-4o (mini) Transcribe, Whisper |
| Groq | Whisper Large v3 Turbo | Sehr schnell |
| Microsoft | MAI-Transcribe 2 | Direkt von Azure AI Speech: der Schlüssel deiner Speech-Ressource und ihre Region (standardmäßig North Europe, in der EU) oder die Adresse deiner eigenen Ressource. Auch normales Azure Speech |
| Google | Gemini 3.5 Transcribe | Direkt von der Gemini API: ein Schlüssel aus [Google AI Studio](https://aistudio.google.com/apikey). Mit einem kostenlosen Schlüssel darf Google dein Audio nutzen, um seine Produkte zu verbessern; schalte die Abrechnung ein, um das zu verhindern. Eine Aufnahme von über etwa 7 Minuten wird abgelehnt, bevor sie gesendet wird |
| Eigener | deine URL und dein Modell | Jeder OpenAI-kompatible Endpunkt |
| Lokal | Whisper Large v3 Turbo | Auf deinem eigenen Computer, ohne Schlüssel, siehe unten |

Das Modellmenü ist die **Live-Liste** des Anbieters, neue Modelle erscheinen also ohne neues satz. Neben jedem steht, wie viele Wörter es falsch versteht, nach der Wortfehlerrate von [Artificial Analysis](https://artificialanalysis.ai/speech-to-text) (für jedes Modell dieselben rund 8 Stunden Sprache, niedriger ist besser), und was eine Stunde Sprechen kostet. Die besten stehen oben. Preise, wie satz sie im Oktober 2026 gemessen hat:

| Modell | Falsche Wörter | pro Stunde |
|---|---|---|
| Microsoft MAI-Transcribe 2 (Standard, Clean-Modus, nutzt deinen Wortschatz) | 2,0 % | 0,10 $ |
| Microsoft MAI-Transcribe 2, direkt von Microsoft | 2,0 % | 0,10 $ bis 31.12.2026, danach 0,36 $ |
| Google Gemini 3.5 Transcribe, direkt von Google (Smart-Modus, nutzt deinen Wortschatz) | 2,6 % | 0,30 $ |
| Microsoft Azure Speech, direkt von Microsoft | nicht gemessen | 0,36 $ |
| Microsoft MAI-Transcribe 1.5 | 2,4 % | 0,36 $ |
| Mistral Voxtral Small | 2,8 % | 0,18 $ |
| OpenAI GPT Transcribe | 3,3 % | 0,28 $ |
| Mistral Voxtral Mini 3B | 3,8 % | 0,06 $ |
| OpenAI GPT-4o Transcribe | 4,0 % | 0,23 $ |
| xAI Grok STT | 4,0 % | 0,10 $ |
| OpenAI Whisper | 4,1 % | 0,37 $ |
| Google Chirp 3 | 4,3 % | 1,00 $ |
| OpenAI GPT-4o mini Transcribe | 4,5 % | 0,12 $ |
| OpenAI Whisper Large v3 Turbo | 4,6 % | 0,01 $ |
| Qwen3 ASR, Voxtral Mini Transcribe, Universal-3.5 Pro, Whisper Large v3, Fish Audio | nicht gemessen | 0,01 $ bis 0,44 $ |

Ein paar Modelle, die OpenRouter listet, fehlen, weil sie beim Diktieren versagen (kein Deutsch, Sprecher-Tags im Text, abgelehnte Anfragen). *Anderes Modell …* nimmt jede Modell-ID von Hand. Jeder Anbieter behält seinen eigenen Schlüssel und sein eigenes Modell, du kannst also hin- und herwechseln.

**Auf deinem eigenen Computer.** Wähl *Lokal*, und die Einstellungen zeigen die Modelle als Karten, so wie [Handy](https://github.com/cjpais/Handy) es tut: *Deine Modelle* (auf diesem Computer, das benutzte zuerst) und *Verfügbare Modelle*. Jede Karte sagt in einem Satz, wofür das Modell gut ist, hat einen Balken für die Genauigkeit und einen fürs Tempo und nennt die Sprachen, die es versteht, und seine Größe. Klick auf eine verfügbare Karte, um sie zu laden (mit Fortschrittsbalken und *Abbrechen*), klick auf eine von deinen, um sie zu benutzen. Der Tempo-Balken kommt aus einer Messung, die satz direkt nach dem Download auf deinem Computer macht, mit einem 10 s langen gemeinfreien Hörbuch-Ausschnitt; davor nutzt der Mac eine Schätzung nach Argmax' Messungen auf dem nächstliegenden Apple-Chip, oder eine grobe Einschätzung. Zeig auf einen Balken, dann siehst du die Zahlen dahinter. Ein Klick auf einen Anbieter in den Einstellungen zeigt ihn nur an; *Lokal benutzen* oder ein Klick auf eines deiner Modelle schaltet auf ihn um.

| | Mac | Windows und Linux |
|---|---|---|
| Whisper Large v3 Turbo | 646 MB, über WhisperKit auf der Neural Engine. Der Standard. Auf einem M1 eine Fassung mit 627 MB, die dort läuft. | 981 MB, auf dem Prozessor. Der Standard. |
| Whisper Large v3 Turbo, volle Größe | 1,6 GB, etwas genauer. | |
| Whisper Large v3 | 3,1 GB, langsam. | 1,4 GB, am genauesten, langsam. |
| Whisper Medium | | 786 MB |
| Whisper Small | 486 MB, meist für Englisch. | 328 MB |
| Whisper Base | 147 MB, grob. | 149 MB, schnell, grob. |
| Whisper Tiny | 77 MB, sehr grob. | 99 MB, sehr grob. |
| Distil-Whisper Large v3 | 607 MB, nur Englisch, schnell. | 950 MB (v3.5), nur Englisch. |
| Cohere Transcribe | 2,9 GB, über sherpa-onnx. Auf Deutsch am genauesten im Open ASR Leaderboard, 14 Sprachen: versteht die Sprache, die bei *Gesprochen auf* eingestellt ist. | 2,9 GB, dasselbe. |
| Parakeet Ultra | 632 MB, über FluidAudio/CoreML auf Apples Neural Engine. Erkennt 25 Sprachen automatisch, darunter Deutsch und Englisch. | Nicht verfügbar: dieser CoreML-Build benötigt macOS. |
| Parakeet V3 | 670 MB, über sherpa-onnx. Schnell und genau, 25 europäische Sprachen, darunter Deutsch. | 670 MB, dasselbe. |
| Parakeet German (primeLine) | 671 MB, Parakeet V3, von primeLine für Deutsch nachtrainiert (ein Community-Export), nur Deutsch. | 671 MB, dasselbe. |
| Canary 1B v2 | 1,4 GB (ein Community-Export), genau. Englisch, Deutsch, Spanisch, Französisch: versteht die bei *Gesprochen auf* eingestellte Sprache. | 1,4 GB, dasselbe. |
| Qwen3-ASR 0.6B | 987 MB, klein, 30 Sprachen, findet die Sprache selbst, auf Deutsch etwas hinter Parakeet V3. | 987 MB, dasselbe. |
| Canary 180M Flash | 207 MB, sehr schnell. Englisch, Deutsch, Spanisch, Französisch: versteht die bei *Gesprochen auf* eingestellte Sprache. | 207 MB, dasselbe. |
| Parakeet V2 | 661 MB, nur Englisch, das beste für Englisch. | 661 MB |
| Moonshine Base | 287 MB, nur Englisch, sehr schnell. | 287 MB |
| Moonshine Tiny | 124 MB, nur Englisch, extrem schnell. | 124 MB |
| SenseVoice | 240 MB, sehr schnell. Chinesisch, Englisch, Japanisch, Koreanisch, Kantonesisch. | 240 MB |
| Whisper Large v3 Turbo German | | 983 MB, nur Deutsch. |
| Apples Spracherkennung | Eingebaut in macOS 26; macOS holt sich eventuell einmal sein Sprachpaket. Sofort da, versteht aber nur die bei *Gesprochen auf* eingestellte Sprache und nutzt deinen Wortschatz kaum. | |

Parakeet Ultra nutzt auf dem Mac [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.3. Die 632 MB werden von einem festen Commit geladen und per SHA-256 geprüft. Nach dem Download läuft die Erkennung offline; die Sprache wird nicht erzwungen. Der CoreML-Build ist nur auf dem Mac verfügbar. Ultra stammt von [Moondream](https://huggingface.co/moondream/parakeet-ultra), basiert auf NVIDIA Parakeet V3 und steht unter CC-BY-4.0; den CoreML-Export erstellt FluidInference.

Die anderen Parakeet-Modelle, Canary, Moonshine, SenseVoice, Cohere Transcribe und Qwen3-ASR laufen über [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx); Windows auf ARM hat nur die Whisper-Modelle, weil sherpa-onnx dafür keinen Build hat. Die vier neuesten werden wie die anderen angeboten und laden nichts, bis du sie anklickst.

Auf dem Mac stammen die Fehlerraten von Argmax, für genau die Fassungen, die satz lädt (Englisch, und Deutsch, wo sie es gemessen haben); unter Windows und Linux ist es Deutsch auf FLEURS, für die Originalmodelle. Beide werden einmal am Tag geholt, mit den Zahlen, die satz mitbringt, als Rückfall. Bei den übrigen Modellen ist der Genauigkeits-Balken eine grobe Einschätzung (die von Handy). Klick auf den Tempo-Balken eines Modells auf deinem Computer, um es neu zu messen.

Parakeet, Canary, Moonshine, SenseVoice, Cohere Transcribe und Qwen3-ASR laufen über [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0) auf ONNX Runtime, das die Mac-App mitbringt (etwa 19 MB mehr im Download). Ihre Dateien kommen einzeln, jede von einem festgelegten Commit und gegen ihre SHA-256 geprüft, aus den Exporten von [csukuangfj](https://huggingface.co/csukuangfj) und [csukuangfj2](https://huggingface.co/csukuangfj2) (den neuesten) auf Hugging Face; Parakeet German und Canary 1B v2 sind Community-Exporte, von [x-ian](https://huggingface.co/x-ian/sherpa-onnx-parakeet-primeline-de-int8) und von [Sarphix](https://huggingface.co/Sarphix/canary-1b-v2-sherpa-onnx-int8). Lizenzen: [Parakeet V3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [Parakeet V2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), [Canary 180M Flash](https://huggingface.co/nvidia/canary-180m-flash) und [Canary 1B v2](https://huggingface.co/nvidia/canary-1b-v2) von NVIDIA, CC-BY-4.0; [Parakeet German](https://huggingface.co/primeline/parakeet-primeline) von primeLine, CC-BY-4.0; [Cohere Transcribe](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) von Cohere, Apache-2.0; [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) vom Qwen-Team von Alibaba, Apache-2.0; [Moonshine](https://huggingface.co/UsefulSensors/moonshine-base) von Useful Sensors, MIT; [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) von FunAudioLLM, [Modelllizenz von FunASR](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE). Dein Wortschatz geht nicht an diese Modelle (deine Ersetzungen gelten trotzdem), außer an Qwen3-ASR, das ihn als Hotwords nimmt und wie Whisper geprüft wird: Der Text mit dem Wortschatz bleibt nur, wenn er kein Wort verloren hat. Moonshine, SenseVoice, Canary und Cohere Transcribe hören etwa 30 Sekunden gut, und der Decoder von Qwen3-ASR fasst nur etwa 15 Sekunden Sprache. Eine längere Aufnahme geht deshalb in Stücken durch sie hindurch, geschnitten an ihren leisesten Stellen, nie mitten im Wort; es bleibt trotzdem eine Aufnahme und ein Text. Cohere Transcribe und Canary muss man die Sprache sagen (*Gesprochen auf*): Bei der falschen übersetzt Cohere oder hängt in einer Schleife. Cohere schreibt außerdem Sätze für gleichmäßiges Rauschen wie bei einem Lüfter, deshalb geht ein Stück, das nur ein gleichmäßiger Pegel ist, nicht an Cohere. Parakeet German schreibt „ss“ für „ß“.

Whisper erkennt von selbst, ob du Deutsch oder Englisch sprichst. Beim ersten Mal nach dem Download bereitet der Mac das Modell für seinen Chip vor, das dauert einige Minuten, einmal. Dein Wortschatz geht als Hinweis an Whisper, aber nur, wenn das höchstens ein Wort hier und da ändert: Mit Hinweis ließ Whisper manchmal einen Satz in einer anderen Sprache aus oder wiederholte einen früheren. Deshalb vergleicht satz den Text Wort für Wort mit einem ohne Hinweis und behält diesen, wenn Wörter fehlten oder dazukamen. Stille geht nie an Whisper, das sich dafür etwas ausdenkt. Ein Satz in einer anderen Sprache mitten in einer langen Aufnahme kann lokal trotzdem verloren gehen; die Cloud-Modelle kommen damit besser zurecht. *Löschen* legt das Modell in den Papierkorb.

**Tempo.** MAI-Transcribe antwortet meist in ein bis zwei Sekunden, aber ab und zu hängt eine Anfrage zehn. Kommt nach 2,5 Sekunden keine Antwort, fragt satz ein zweites Mal und nimmt die Antwort, die zuerst kommt, für einen Bruchteil eines Cents.

## Text aufräumen

Aus, bis du es einschaltest. Mit *Text aufräumen* in den Einstellungen überarbeitet ein Sprachmodell, was du gesagt hast, bevor satz es einfügt. Du wählst, wie stark (*Stärke*):

| | Was sich ändert |
|---|---|
| **Nur Zeichensetzung** | Satzzeichen und Großschreibung. Jedes Wort bleibt. |
| **Leicht** (der Standard) | Dazu keine „Ähms“, kein Stottern und keine Wörter, die du zurückgenommen hast: „Montag, nein, Dienstag“ wird zu „Dienstag“. |
| **Glatt** | Dazu Grammatik und holprige Sätze. |
| **Ausformuliert** | Neu geschrieben, als hättest du es getippt, mit Absätzen und Listen. |
| **Eigener Prompt** | Deine eigene Anweisung, zum Beispiel „ins Englische übersetzen“ oder „als Aufzählung schreiben“. |

Die Anweisungen der gewählten Stufe sind immer sichtbar. Der Eintrag *Vollständigen Prompt für „…“ ansehen* zeigt den ganzen Prompt. Dein Wortschatz geht mit, damit Namen so geschrieben bleiben, wie du sie willst. Englische Wörter in deutschen Sätzen bleiben englisch.

**Die vier eingebauten Stufen bearbeiten ein Diktat, ohne darauf zu antworten.** „Wie spät ist es?“ soll eine Frage bleiben, und „Schreib eine Mail an Jonas“ soll ein Satz bleiben. Bei diesen Stufen prüft satz das Ergebnis gegen das, was du gesagt hast: Erkennt es eine Antwort, eine Übersetzung, die niemand wollte, oder einen Kommentar, eine geänderte Zahl, ein geändertes Vorzeichen oder „nicht“, oder bei *Nur Zeichensetzung* ein geändertes Wort, fügt es ein, was du gesagt hast, und die Karte sagt *Nicht aufgeräumt*. *Eigener Prompt* erlaubt die Umwandlung, die du verlangst, und wendet diese Sinnprüfungen nicht an. Bei jeder Stufe fällt eine fehlgeschlagene, leere, abgeschnittene oder zu späte Antwort auf das zurück, was du gesagt hast. Der Verlauf behält, was du gesagt hast, neben dem aufgeräumten Text (*Original* an der Zeile), es sei denn, du hast den Verlauf ausgeschaltet.

**Was dazukommt.** Jedes Modell im Menü zeigt die Sekunden, die es einem Diktat hinzufügt, und was es pro Stunde Sprechen kostet, geschätzt für die Länge deiner eigenen Diktate und gemessen, sobald du es benutzt oder auf *Ausprobieren* geklickt hast. *Ausprobieren* schickt einen Beispieltext (oder deinen eigenen) durch das Modell, das du dir gerade ansiehst, bevor du zu ihm wechselst.

| Anbieter | Standardmodell | Dazu pro Diktat | Pro Stunde Sprechen |
|---|---|---|---|
| **OpenRouter** (dein vorhandener Schlüssel) | Gemini 3.5 Flash-Lite | etwa 0,8 s | etwa 0,05 $ |
| OpenAI | GPT-6 Luna | etwa 1,5 s | etwa 0,01 $ |
| Anthropic | Claude Haiku 5.5 | etwa 1,6 s | etwa 0,02 $ |
| Google (dein Gemini-Schlüssel) | Gemini 3.5 Flash-Lite | etwa 0,8 s | etwa 0,05 $ |
| Groq | gpt-oss-120b | etwa 0,7 s | etwa 0,02 $ |
| Cerebras | Qwen3.8 27B | etwa 0,5 s | etwa 0,08 $ |
| Mistral | Mistral Small | etwa 0,9 s | etwa 0,02 $ |
| DeepSeek | DeepSeek V4.1 Flash | etwa 1,1 s | etwa 0,03 $ |
| xAI | Grok 4.7 | etwa 4,6 s | etwa 0,20 $ |
| Microsoft Azure | deine Bereitstellung | | wie bei OpenAI |
| Apple (auf dem Mac) | Apple Intelligence, auf deinem Mac | gemessen | kostenlos |
| Ollama, LM Studio | die Modelle, die du installiert hast | gemessen | kostenlos |
| Eigener | jede OpenAI-kompatible Adresse | gemessen | |

Über OpenRouter kannst du außerdem Qwen3.8 27B wählen (das schnellste, 0,6 s), DeepSeek V4.1 Flash, Claude Haiku 5.5 (schreibt für den Preis am besten um), GPT-6 Luna, GLM-5.3, MiniMax M3, Mistral Large 4, Gemini 3.8 Flash, Kimi K3, DeepSeek V4 Pro, und für die beste Qualität Claude Sonnet 5.5, GPT-6 Sol, GPT-6.1 Sol, Gemini 4 Argon, Claude Opus 5.5 oder Grok 4.7. Alle liefen durch den eigenen Testsatz von satz (Fragen, „ignoriere deine Anweisungen“, gemischtes Deutsch und Englisch, Selbstkorrekturen, Listen), bevor sie auf die Liste kamen; Modelle, die geantwortet, übersetzt oder ihre Überlegungen in den Text geschrieben haben, blieben draußen.

Apples Modell ist kostenlos und verlässt nie deinen Mac (macOS 26 mit eingeschalteter Apple Intelligence), aber es ist klein: Im Test hat es eine Frage im Text beantwortet und Englisch ins Deutsche übersetzt. satz fügt dann meist das Original ein, deshalb eignet es sich am besten für *Nur Zeichensetzung* und *Leicht*. Kleine Modelle in Ollama oder LM Studio verhalten sich genauso.

Die Zeiten wurden im Oktober 2026 von Deutschland aus über OpenRouter gemessen; die Preise sind die Listenpreise der Anbieter, die von OpenRouter werden live geholt.

## Dein Schlüssel und deine Daten

- Dein Audio geht direkt von deinem Computer an den Anbieter, den du gewählt hast. Es gibt keinen satz-Server. Mit *Lokal* verlässt es deinen Computer nie.
- Der Schlüssel liegt nur auf deinem Computer: auf dem Mac in `~/Library/Application Support/satz/keys`, nur für deinen Benutzer lesbar. satz zeigt ihn dir nach dem Sichern nie wieder an.
- Ist *Text aufräumen* an, geht der Text (nie das Audio) mit deinem Wortschatz auch an das Modell, das du dafür gewählt hast; mit Apples Modell bleibt er auf deinem Mac.
- Der Verlauf behält die letzten Diktate in einer Datei, die nur du lesen kannst. *Leeren* in den Einstellungen löscht ihn.

## Fragen

**Ist es kostenlos?** satz ist kostenlos und Open Source (MIT). Du bezahlst den Transkriptionsanbieter für das, was du nutzt: etwa 10 Cent pro Stunde Sprechen mit MAI-Transcribe 2 über OpenRouter. Mit *Lokal* kostet es gar nichts.

**Geht es offline?** Mit dem Anbieter *Lokal* ja: Whisper läuft nach einem einmaligen Download auf deinem Computer. Die anderen Anbieter brauchen das Internet.

**Welche Sprachen?** Alle, die das Modell versteht. MAI-Transcribe 2 und Whisper kommen mit Dutzenden zurecht. Die App selbst gibt es auf Englisch und Deutsch.

**Linux mit Wayland?** Wayland lässt Apps weder die Tastatur beobachten noch in andere Apps tippen. satz funktioniert trotzdem: siehe [die Hinweise für Linux](desktop/README.md#linux-und-wayland).

<details>
<summary><b>Selbst bauen</b></summary>

<br>

**Mac** (Xcode 27 oder neuer, mit Swift 6.4 und dem macOS-SDK):

    make app                     baut dist/satz.app
    make run                     baut und startet
    make share                   Universal-Build als dist/satz.zip und dist/satz-mac.dmg
    make test                    holt native Abhängigkeiten, falls nötig, und führt dann die Offline-Tests aus

Die Mac-Pakete bleiben bei `make share` lokal signiert. Für Developer ID und
Notarisierung gibt es den getrennten [Release-Ablauf](scripts/macos/README.md).
Der neue Updater nutzt Sparkle: ein Hinweis im geöffneten Fenster, dann auf
Wunsch installieren und neu starten. Ein laufendes oder fehlgeschlagenes Diktat
wartet, bis es beendet oder verworfen wurde. Bestehende Versionen bis 0.4.5
brauchen einmal einen manuellen Download, um den Updater zu bekommen.
Der [signierte Update-Feed](scripts/updates/README.md) gehört zu jedem künftigen
Release. Windows und Linux zeigen ebenfalls einen Hinweis und öffnen den
passenden Download; die Installation erfolgt dort weiterhin von Hand.

**Windows und Linux** (Electron, baut auch auf einem Mac): siehe [desktop/README.md](desktop/README.md).

    cd desktop && npm install
    npm test
    npm run dist:win             release/*.zip
    npm run dist:linux           release/*.deb, *.tar.gz

**Aufbau**

    Sources/SatzKit    Audio, WAV, Transkriptions-Client, Ersetzungen, Schlüssel
    Sources/SatzMac    die Mac-App: Kurzbefehl, Karte, Einfügen, Menü, Einstellungen, Einrichtung
    Tests/             Tests für SatzKit
    desktop/           die Windows- und Linux-App, mit demselben Kern in TypeScript

Der **Testmodus** spielt ein echtes Diktat ohne Mikrofon und Tastatur durch und fügt nie in die App ein, die du gerade benutzt:

    satz --test-audio a.wav:b.wav --dev-control /tmp/state.json

Befehle kommen als verteilte Benachrichtigungen mit dem Namen `plus.dpa.satz.dev` (`press`, `mic`, `caret:<index>`, `discard`, `undo`, `dump`, `picture`, `settings`, `close`). Der fertige Text geht in die Statusdatei.

    satz --snapshot <dir>        jede Oberfläche als PNG, hell und dunkel
    make hero / make showcase    die Bilder in dieser README

Live-Tests sprechen mit einem echten Endpunkt und werden ohne Schlüssel übersprungen:

    SATZ_TEST_API_KEY=... SATZ_TEST_BASE_URL=https://openrouter.ai/api/v1 make test

</details>

## Lizenz

Der Quellcode von satz selbst steht unter MIT. Siehe [LICENSE](LICENSE). Gemacht von [DPA Plus](https://dpa.plus).

Mitgelieferte Abhängigkeiten behalten ihre eigenen Lizenzen. Die Pakete für Windows x64 und Linux enthalten eine native Bibliothek unter GPL-3.0-or-later. Die Lizenzen, den Quellcode und die Bauanleitung findest du in den [Hinweisen zur mitgelieferten Software](Resources/Licenses/README.md) und im [zugehörigen Quellcode-Download](https://github.com/dpa-plus/satz/releases/download/v0.4.5/satz-0.4.5-source.tar.gz).
