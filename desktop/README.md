# satz für Windows und Linux

Das Diktieren der Mac-App, für Windows und Linux, auf Electron: Tippe **zweimal die rechte Strg-Taste**, sprich, tippe sie wieder zweimal, und der Text landet dort, wo du gerade geschrieben hast. Dieselbe Karte (Pause, Auge, Verwerfen mit Rückgängig, Klick in den Text, um zu verschieben, wohin die Sprache geht), dieselbe Transkription (MAI-Transcribe 2 über OpenRouter oder direkt von Microsoft, Clean-Modus, Wortschatz, Ersetzungen).

## Installation

| System | Datei | So geht's |
|---|---|---|
| Windows (ARM oder Intel/AMD) | `satz-windows-arm64.zip` / `satz-windows-x64.zip` | Irgendwo entpacken, `satz.exe` starten. Noch nicht signiert, SmartScreen fragt deshalb vielleicht einmal („Weitere Informationen“, „Trotzdem ausführen“). |
| Ubuntu / Debian | `satz-linux-arm64.deb` / `satz-linux-amd64.deb` | `sudo apt install ./satz-linux-…deb`, dann „satz“ im Anwendungsmenü starten. |
| Anderes Linux | `satz-linux-arm64.tar.gz` / `satz-linux-x64.tar.gz` | Entpacken, `./satz` starten. |

Beim ersten Start öffnet satz seine Einstellungen für den API-Schlüssel und schaltet „Beim Anmelden starten“ ein (dort lässt es sich ausschalten).

## Anbieter

Die Einstellungen haben dafür ein Menü. Einen Anbieter darin zu wählen, zeigt ihn nur an (Schlüssel, Modelle, Felder); Diktate gehen weiter an den, der mit „(in Benutzung)“ markiert ist, bis du in der Zeile unter dem Menü auf *… benutzen* klickst. Diese Zeile erscheint, sobald der Anbieter hat, was er braucht: einen Schlüssel, bei Microsoft eine Region (oder eine eigene Adresse), bei Eigener außerdem eine Adresse und ein Modell, bei Lokal ein Modell auf dem Computer (`src/core/browse.ts`, dieselbe Regel wie `ProviderReadiness` auf dem Mac). Jeder Anbieter behält seinen eigenen Schlüssel (eine Datei in `keys/`, nur für den Benutzer lesbar, nie ausgegeben oder geloggt) und sein eigenes Modell.

| Anbieter | Anfrage | Modelle (Preis pro Stunde Sprache) |
|---|---|---|
| OpenRouter | `POST /api/v1/audio/transcriptions`, JSON | die Liste des Anbieters: MAI-Transcribe 2 (0,10 $, der Standard) und andere |
| OpenAI, Groq | `POST /audio/transcriptions`, multipart | ihre Transkriptionsmodelle |
| Microsoft | `POST https://{region}.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15`, multipart mit `audio` (die WAV) und `definition` (JSON), Schlüssel in `Ocp-Apim-Subscription-Key` | **MAI-Transcribe 2** (0,10 $ bis 31.12.2026, danach 0,36 $; `enhancedMode` mit dem genannten Modell) und **Azure Speech** (0,36 $; dieselbe Anfrage ohne `enhancedMode`) |
| Google | `POST https://generativelanguage.googleapis.com/v1beta/interactions`, JSON mit der WAV inline als Base64, Schlüssel in `x-goog-api-key` | **Gemini 3.5 Transcribe** (etwa 0,30 $) |
| Eigener | `POST {address}/audio/transcriptions`, multipart | das eingetippte Modell |
| Lokal | keine: läuft auf diesem Computer | siehe unten |

**Microsoft** braucht den Schlüssel einer Azure-*Speech*-Ressource (Standard, S0) und ihre Region, die die Einstellungen als Menü der sechs anbieten, die MAI-Transcribe ausführen: North Europe (der Standard, in der EU), East US, West US, West US 2, Central India, Southeast Asia. Ein Schlüssel gilt nur in der Region seiner eigenen Ressource, deshalb steht bei einem 401 „Schlüssel oder Region falsch“. *Eigene Adresse* (`https://<name>.cognitiveservices.azure.com`) gilt vor der Region, wenn sie ausgefüllt ist; für sie gilt die Regel für Adressen weiter unten. „Füllwörter weglassen“ ist `transcribeStyle` `clean` (an) oder `verbatim` (aus) für MAI-Transcribe 2. Der Wortschatz und die Auslösewörter der Ersetzungen gehen in `definition.phraseList`. Kein `locales`: Deutsch und Englisch unterscheidet Microsoft selbst.

**Google** braucht einen Gemini-API-Schlüssel aus [Google AI Studio](https://aistudio.google.com/apikey). „Füllwörter weglassen“ ist `mode: "smart"`; ohne es ist der Text wörtlich. Der Wortschatz ist `custom_vocabulary` (höchstens 1000). Das Audio reist inline, und eine Anfrage darf insgesamt 20 MB groß sein: Eine Aufnahme von mehr als etwa 7,8 Minuten scheitert sofort als „too long“ und wird nie gesendet. Mit einem Schlüssel der kostenlosen Stufe darf Google das Audio nutzen, um seine Produkte zu verbessern; die Faktenzeile des Modells sagt das, und dass das Einschalten der Abrechnung es vermeidet.

**Adressen, Weiterleitungen und Zeit.** Der Schlüssel reist mit dem Audio, deshalb müssen die Adresse von Eigener und die eigene Adresse von Microsoft https sein, oder http im eigenen Netz des Benutzers: dieser Computer (`localhost`, `127.0.0.0/8`, `[::1]`), eine private oder Link-Local-Adresse (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `fc00::/7`, `fe80::/10`), ein Name ohne Punkt (`nas`) oder ein Name, der auf `.local`, `.lan`, `.home.arpa` oder `.internal` endet. Alles andere wird abgelehnt, und die Einstellungen sagen es („Diese Adresse geht nicht: https, oder http nur im eigenen Netz.“), statt nach einer Adresse zu fragen, die schon da ist. Die Tabelle ist `src/core/address.ts`, dieselbe wie `ProviderAddress` auf dem Mac. Eine Weiterleitung wird befolgt, wenn sie bei dem Ursprung bleibt, an dem die Anfrage begann (höchstens drei, mit denselben Headern und demselben Audio), und abgelehnt, wenn sie ihn verlässt („Adresse leitet um“), damit ein Schlüssel nie an eine zweite Adresse geht. Electrons `net.fetch` lässt sich dazu nicht bringen (mit `redirect: 'manual'` bricht es die Anfrage ab, sich selbst überlassen leitet es `Authorization` an den anderen Ursprung weiter), deshalb gehen Anfragen, die einen Schlüssel tragen, über `net.request` (`src/main/manualFetch.ts`; `src/core/redirect.ts` entscheidet). Eine Anfrage darf das Basis-Zeitlimit (30 s) plus eine Sekunde je zwei Sekunden Audio dauern, Upload und Antwort zusammen, fünf Minuten Sprache bekommen also 180 s; der Mac erlaubt dasselbe.

Beide Anfragen, ihre Antworten und ihre Fehler wurden nach der Dokumentation geschrieben und gegen einen Ersatz-Server auf diesem Computer getestet (`test/providers.test.ts`: genaue Adresse, Header und Body; die dokumentierten Antworten; 401, 429, 413 und die übrigen). **Die echten Dienste wurden nicht aufgerufen: Es gab keinen Schlüssel.** Der Parser für Googles Antwort nimmt jede Form, die die Dokumentation zeigt (`steps[].content[]`-Text, `output_text`, `candidates[].content.parts[]`), weil sich die Dokumentation selbst darüber widerspricht, welche der Endpunkt liefert.

## Updates

Der neue Update-Hinweis erscheint unter den Tabs, wenn ein neueres Release
verfügbar ist. Geprüft wird beim Start und beim Öffnen des Fensters, mit
30 Minuten Cache und einem Zeitlimit von 5 Sekunden. „Später“ blendet ihn
für dieses Öffnen aus. Im Tray gibt es „Nach Updates suchen…“.
„Herunterladen“ öffnet das Paket für die eigene Plattform und Architektur.
Die ZIP-, DEB- und tar.gz-Pakete werden weiterhin von Hand installiert.
Bestehende Downloads bis 0.4.5 erhalten diesen Hinweis erst nach einem
manuellen Update auf die nächste veröffentlichte Version.

## Bereit, Status und „Kein Schlüssel“

Der Tooltip des Tray-Symbols sagt die Version und ob satz bereit ist („satz 0.4.6: bereit (rechte Strg zweimal)“), sonst was fehlt; dann steht es auch als erste Zeile im Tray-Menü, ein Klick öffnet die Einstellungen. Bis 0.4.5 sah man ein Problem erst auf der Karte, nach dem Kurzbefehl.

„Kein Schlüssel“ heißt jetzt nur noch: keine Schlüsseldatei, oder eine leere. Ist die Datei da, lässt sich aber nicht lesen, sagt die Karte „Schlüssel nicht lesbar“ und die Einstellungen nennen unter dem Schlüsselfeld den Fehlercode des Systems (`EPERM`, `EBUSY` …). Eine Datei, die ein anderes Programm gerade offen hat (Virenscanner, Sicherung, die Anmeldung selbst), wird kurz hintereinander dreimal gelesen, bevor sie als unlesbar gilt, und bei jedem Diktat wieder. Das Protokoll sagt jedes Schlüsselproblem einmal, mit dem Pfad der Datei, nie mit dem Schlüssel, und dass ein Diktat deshalb nicht begann.

`preferences.json`, das sich beim Start nicht lesen lässt, wurde bis 0.4.5 für „keine Einstellungen“ gehalten und bei der nächsten Änderung mit den Standardwerten überschrieben. Jetzt bleibt die Datei, wie sie ist: satz läuft auf den Standardwerten, speichert nichts und liest sie fünf Minuten lang alle fünf Sekunden neu. Eine, die kein JSON ist, wird wie der Verlauf beiseitegelegt (`preferences.json.broken-…`).

Lehnt der satz-Ordner eine Zeile des Protokolls ab, geht sie nach `satz.log` im Temp-Ordner, und die erste dort sagt, warum. Bis 0.4.5 ging sie verloren. Die Einstellungen haben unten einen Abschnitt **Status**: Version, System, wie satz gestartet wurde, und nur wenn etwas nicht stimmt, was (Protokoll umgeleitet, Einstellungen unlesbar, Autostart in Windows ausgeschaltet), dazu *Protokoll öffnen* und *Ordner öffnen*. Die erste Zeile des Protokolls nach jedem Start nennt das Konto, unter dem satz läuft, den Datenordner und ob es beim Anmelden, mit `--toggle` oder von Hand gestartet wurde.

**Beim Anmelden starten** trägt satz unter Windows in `HKCU\…\Run` ein, unter Linux in `~/.config/autostart/satz.desktop`, beide jetzt mit `--login`. Ein zweiter Start mit `--login` öffnet nichts. Ist der Eintrag unter *Einstellungen › Apps › Autostart* (oder im Task-Manager) ausgeschaltet, sagt **Status** das, und satz lässt es so: Bis 0.4.5 schaltete satz ihn bei jedem Start stillschweigend wieder ein. Das Häkchen in satz aus- und wieder einzuschalten schaltet ihn auch in Windows wieder ein.

**Andere Auslöser.** `satz --toggle` startet und beendet ein Diktat wie der Kurzbefehl, `satz --settings` öffnet die Einstellungen. So lässt sich satz von jedem Programm aus auslösen, das einen Befehl ausführen kann, etwa einer Maustaste über die Software der Maus oder AutoHotkey. Ein `--toggle`, der kommt, während satz noch startet, wird jetzt ausgeführt, sobald satz bereit ist; bis 0.4.5 ging er verloren. Das Programm muss satz als derselbe Windows-Benutzer starten: Läuft es als Administrator, kann Windows (mit dem „Administratorschutz“ neuerer Builds) satz unter einem anderen Konto starten, mit eigenem Datenordner, also ohne Schlüssel. Das Protokoll nennt dann ein anderes Konto und einen anderen Ordner.

## Ohne Internet

Der Anbieter **Lokal** macht die Spracherkennung auf dem Computer selbst, auf dem Prozessor, mit zwei Engines: Whisper auf transformers.js und ONNX Runtime, und [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0) für die Modelle, die [Handy](https://github.com/cjpais/Handy) anbietet, und vier neuere. Die Einstellungen zeigen sie so wie Handy: **Deine Modelle** (auf diesem Computer, das benutzte zuerst) und **Verfügbare Modelle**, je eine Karte mit einem Satz dazu, wofür das Modell gut ist, einem Genauigkeits-Balken und einem Tempo-Balken, seinen Sprachen und seiner Größe. Klick auf eine verfügbare Karte, um sie zu laden (eine nach der anderen, mit Fortschritt und Abbrechen); klick auf eine von deinen, um sie zu benutzen; *Löschen* legt sie in den Papierkorb. Der Katalog ist `src/core/localModels.ts`:

| Modell | Engine | Größe | Sprachen |
|---|---|---|---|
| Whisper Large v3 Turbo (der Standard) | Whisper | 981 MB | Deutsch und Englisch |
| **Cohere Transcribe** | sherpa-onnx | 2,9 GB | 14 Sprachen, die Sprache wird wie bei Canary gesagt (Deutsch und Englisch zuerst) |
| Whisper Large v3 | Whisper | 1,4 GB | Deutsch und Englisch |
| **Canary 1B v2** | sherpa-onnx | 1,4 GB | Englisch, Deutsch, Spanisch, Französisch: die Sprache wird wie beim kleinen Canary gesagt |
| Parakeet V3 | sherpa-onnx | 670 MB | 25 europäische Sprachen, von selbst erkannt |
| Whisper Medium | Whisper | 786 MB | Deutsch und Englisch |
| Canary 180M Flash | sherpa-onnx | 207 MB | Englisch, Deutsch, Spanisch, Französisch: die Sprache wird unter seinem eigenen „Gesprochen auf“ gesagt, getrennt vom Deutsch oder Englisch der App |
| **Qwen3-ASR 0.6B** | sherpa-onnx | 987 MB | 30 Sprachen, von selbst erkannt |
| Whisper Small, Base, Tiny | Whisper | 328, 149, 99 MB | Deutsch und Englisch |
| **Parakeet V3 German** (primeLine) | sherpa-onnx | 671 MB | nur Deutsch |
| Whisper Large v3 Turbo German (primeLine) | Whisper | 983 MB | nur Deutsch |
| Parakeet V2 | sherpa-onnx | 661 MB | nur Englisch |
| Distil-Whisper Large v3.5 | Whisper | 950 MB | nur Englisch |
| Moonshine Base, Moonshine Tiny | sherpa-onnx | 287, 124 MB | nur Englisch |
| SenseVoice | sherpa-onnx | 240 MB | Chinesisch, Englisch, Japanisch, Koreanisch, Kantonesisch |

**Andere Sprachen, etwa Arabisch.** Die Whisper-Modelle schreiben in satz nur Deutsch oder Englisch: satz lässt Whisper zwischen diesen beiden wählen, und arabische Sprache kommt dann übersetzt oder verstümmelt heraus. Arabisch schreiben lokal nur **Qwen3-ASR 0.6B** (erkennt die Sprache selbst) und **Cohere Transcribe** (unter seinem „Gesprochen auf“ Arabisch wählen; dann schreibt es nur Arabisch, und es ist mit 2,9 GB groß und langsam). Für Dialekte wie Ägyptisch-Arabisch ist keines der beiden geprüft; ein Anbieter im Netz (MAI-Transcribe 2 über OpenRouter oder Microsoft) ist dafür die sichere Wahl.

Die vier fett gedruckten kamen am 10.10.2026 dazu und werden nur angeboten, nie für den Benutzer geladen. **Cohere Transcribe** ist das genaueste Modell auf Deutsch im Open ASR Leaderboard (3,3 % Fehler auf FLEURS, 2,9 % auf Common Voice), 2 Milliarden Parameter, Apache-2.0. Die drei anderen sind Canary 1B v2 (3,4 % auf FLEURS, ein Community-Export), Qwen3-ASR 0.6B (5,4 %, klein, nimmt den Wortschatz als Hinweise) und ein deutsches Fine-Tuning von Parakeet V3 (es schreibt „ss“, wo das Deutsche „ß“ hat, wie es seine eher schweizerisch geprägten Trainingsdaten tun). Ihre Repos sind nicht die von csukuangfj: `csukuangfj2` (die neueren Builds von sherpa-onnx), `Sarphix` und `x-ian` (Community-Exporte), deshalb nennt der Katalog den Hugging-Face-Besitzer je Modell (`owner` in `SherpaSource`).

Der Genauigkeits-Balken ist Handys Wertung für das Modell (beim deutschen Fine-Tuning eine Schätzung); sein Hilfetext nennt die Fehlerrate auf Deutsch auf FLEURS, wo eine veröffentlicht ist, mit der Quelle: die Datei des Open ASR Leaderboards (einmal am Tag geholt, oder die mitgelieferten Zahlen) oder das Whisper-Paper. Der Tempo-Balken kommt aus dem eigenen Tempotest von satz, sobald das Modell auf diesem Computer gemessen wurde (Sekunden pro 10 s Sprache auf einer logarithmischen Skala: 0,2 s füllt ihn, 1 s sind 70 %, 3 s 40 %, 10 s 10 %), und bis dahin aus Handys Wertung. Der Test läuft auf einem mitgelieferten 10-s-Clip (`assets/speedtest.wav`) direkt nach einem Download, zweimal durch den Diktierweg, der zweite Lauf zählt, und erst, wenn kein Diktat läuft (`src/main/speedTests.ts`); das Ergebnis wird als `<id>.speed.json` aufbewahrt.

Modelle werden einmal von Hugging Face in den eigenen Ordner von satz geladen, neben das benutzte Modell, das geladen bleibt: Whisper aus den onnx-community-Repos, sherpa-onnx Datei für Datei aus dem Repo des im Katalog genannten Besitzers ([csukuangfj](https://huggingface.co/csukuangfj) für Handys Modelle) bei einem festen Commit, jede Datei gegen ihre SHA-256 geprüft und erst mit ihrem endgültigen Namen versehen, wenn sie vollständig ist (eine von einem früheren Versuch bleibt nur, wenn ihre Prüfsumme stimmt), nach `<models>/sherpa/<name>/`. Eine Markierung neben dem Ordner wird nur geschrieben, wenn das Modell auch einmal geladen werden konnte. Ein Download wird von selbst zum Modell von Lokal, nur wenn das benutzte Modell nicht auf dem Computer ist, und schaltet nie den Anbieter um. Einen Anbieter im Menü zu wählen zeigt ihn nur an: Diktate gehen weiter an den, der mit „(in Benutzung)“ markiert ist, bis du in der Zeile unter dem Menü auf *… benutzen* klickst, oder auf eines deiner Modelle, solange Lokal angezeigt wird.

Whisper findet die Sprache pro Aufnahme selbst, zwischen Deutsch und Englisch; die beiden Ein-Sprachen-Modelle decodieren immer in ihrer. Der Wortschatz geht nur dort als Prompt an Whisper, wo er kein Wort kostet (satz decodiert mit und ohne ihn und behält den Text mit Prompt nur, wenn er gleich lang ist). Die sherpa-onnx-Modelle nehmen keinen Prompt (die Ersetzungen gelten trotzdem), außer Qwen3-ASR: Es nimmt den Wortschatz als Hotwords (eine kommagetrennte Zeichenkette vor dem Audio, höchstens 24 Wörter), auf dieselbe Weise mit und ohne decodiert und nur behalten, wenn kein Wort verloren ging. Canary und Cohere Transcribe können die Sprache nicht erkennen: Solange eines das benutzte Modell ist, bietet eine Zeile „Gesprochen auf“ unter den Karten die Sprachen an, die es schreibt (Canary vier, Cohere vierzehn), getrennt vom Deutsch oder Englisch der App (danach richten sich Whisper und die Ersetzungen). Canary wird mit der Sprache konfiguriert; Cohere bekommt sie für jedes Stück über eine Stream-Option mitgeteilt (`stream.setOption('language', …)`), das Ändern lädt also nichts neu. Parakeet nimmt ein ganzes Diktat; Moonshine, SenseVoice, Canary und Cohere bekommen es in Stücken von höchstens 30 s (bei Cohere liegt die Grenze bei 35 s), am leisesten Moment geschnitten (`src/core/windows.ts`), wie Whisper es macht. Der Decoder von Qwen3-ASR fasst 512 Tokens für den Prompt, 13 pro Sekunde Audio und den Text, deshalb sind seine Stücke 15 s: Ein 40-s-Stück kam als das einzelne Wort „language“ zurück. Stille geht an keines von ihnen, und jedes Stück muss nach seinem eigenen Pegel Sprache enthalten (`src/core/speech.ts`). Cohere Transcribe erfindet auch Text für Geräusche: 12 s gleichmäßiges Rauschen, lauter als die -45 dBFS, die als Sprache zählen, kamen als ganze deutsche Sätze zurück, wiederholt. Seine Stücke dürfen deshalb auch nicht ein gleichmäßiger Pegel sein (`isSteady`: Die lauteren Frames von Sprache sind 18- bis 1500-mal so laut wie die leiseren, die eines Lüfters 1,1-mal; die anderen schrieben für dasselbe Rauschen nichts). Unter Windows auf ARM gibt es keinen sherpa-onnx-Build, deshalb werden dort seine zehn Modelle nicht angeboten.

Jede Engine läuft in einem eigenen Hilfsprozess (`local-worker.js`, `sherpa-worker.js`): ONNX Runtime blockiert den Thread, auf dem es läuft, und sherpa-onnx bringt sein eigenes ONNX Runtime mit (1.28.2, neben dem 1.30.0 von onnxruntime-node). Unter Windows heißen beide `onnxruntime.dll`, und Windows gibt eine DLL, die schon geladen ist, an den Nächsten weiter, der nach diesem Namen fragt, sodass in einem Prozess eine Engine auf der Runtime der anderen laufen würde. Ein Hilfsprozess endet, wenn das Modell von Lokal zur anderen Engine wechselt oder ein anderer Anbieter gewählt wird, was seinen ganzen Speicher zurückgibt. Die Windows-Pakete bringen die C++-Runtime-DLLs von Microsoft neben onnxruntime-node mit (`build/vcruntime.py` holt sie aus dem Redistributable von Microsoft); ein frisches Windows hat keine. Der Windows-Build von sherpa-onnx braucht keine.

Lizenzen der Modelle, die satz lädt (keines wird mitgeliefert): Parakeet TDT 0.6B [v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) und [v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) und [Canary 180M Flash](https://huggingface.co/nvidia/canary-180m-flash) von NVIDIA, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); Moonshine [Base](https://huggingface.co/UsefulSensors/moonshine-base) und [Tiny](https://huggingface.co/UsefulSensors/moonshine-tiny) von Useful Sensors, MIT; [SenseVoiceSmall](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) von FunAudioLLM (Alibaba), [Modelllizenz von FunASR](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE), in seinem [sherpa-onnx-Export](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17); Whisper von OpenAI, MIT; [Cohere Transcribe](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) von Cohere, Apache-2.0, im [int8-Export](https://huggingface.co/csukuangfj2/sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01) von sherpa-onnx; [Qwen3-ASR 0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) vom Qwen-Team von Alibaba, Apache-2.0, im [int8-Export](https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25) von sherpa-onnx; [Canary 1B v2](https://huggingface.co/nvidia/canary-1b-v2) von NVIDIA, CC BY 4.0, im [Community-int8-Export von Sarphix](https://huggingface.co/Sarphix/canary-1b-v2-sherpa-onnx-int8) (CC BY 4.0, keine offizielle Veröffentlichung); [Parakeet primeLine](https://huggingface.co/primeline/parakeet-primeline) von primeLine, CC BY 4.0, im [Community-int8-Export von x-ian](https://huggingface.co/x-ian/sherpa-onnx-parakeet-primeline-de-int8) (das Lizenzfeld des Repos selbst ist leer).

## Einfügen und die Zwischenablage

Der Text kommt auf die Zwischenablage, Strg+V wird an das Fenster geschickt, in dem das Diktat begann (vorher nach vorn geholt, falls du inzwischen woanders warst), und eine Sekunde später wird die Zwischenablage in jeder Form zurückgegeben, in der sie vorlag, aber nur, solange sie noch nichts als das Transkript enthält: Was du inzwischen kopiert hast, bleibt. Eine Sekunde, nicht weniger: Eine beschäftigte App (Word, ein Remote-Desktop, eine VM) nahm Strg+V, nachdem die alte Zwischenablage schon zurück war, und fügte diese ein. Aufeinanderfolgende Einfügungen geben die Zwischenablage von vor allen zurück, es sei denn, du hast dazwischen etwas kopiert: Dann kommt diese zurück (`src/main/clipboardHandback.ts`). Wo keine Taste gesendet werden kann oder das Fenster weg ist, bleibt der Text auf der Zwischenablage.

## Linux und Wayland

Wayland (der Standard von Ubuntu) lässt keine App die Tastatur beobachten oder in andere Apps tippen. satz geht so damit um:

- **Kurzbefehl:** Die rechte Strg-Taste zweimal geht, wenn der Benutzer die Tastaturgeräte lesen darf: `sudo usermod -aG input $USER`, dann ab- und wieder anmelden. Ohne das legst du in den Systemeinstellungen ein Tastenkürzel an, das `satz --toggle` ausführt.
- **Einfügen:** Läuft [ydotool](https://github.com/ReimuNotMoe/ydotool) (`ydotoold`), fügt satz von selbst ein. Ohne es geht der Text auf die Zwischenablage, und die Karte sagt „Auf der Zwischenablage. Mit Strg+V einfügen.“
- **Terminals:** Wayland zeigt satz gar kein Fenster, deshalb kann es ein Terminal nicht von jeder anderen App unterscheiden und sendet Strg+V, das GNOME Terminal, Console und Ähnliche nicht als Einfügen annehmen. Nichts geht verloren: Jedes Diktat steht im Verlauf, und mit eingeschaltetem *Text in der Zwischenablage behalten* bleibt der Text für Strg+Umschalt+V von Hand auf der Zwischenablage. Unter X11 kennt satz das Terminal und sendet Strg+Umschalt+V selbst.
- Die Karte läuft über XWayland, den einzigen Weg, wie ein Fenster oben bleiben und seinen Platz wählen kann. Das Startskript `satz` kümmert sich darum und um die Sandbox von Chromium (siehe `build/after-pack.cjs`).

### Programme, die satz unter Linux aufruft

Neben den Bibliotheken, von denen das `.deb` abhängt, startet satz ein paar kleine Programme. Jedes ist optional; ohne eines fehlt eine Sache, nie das Diktat.

| Programm | Paket (Debian, Ubuntu) | Wofür |
|---|---|---|
| `xprop` | `x11-utils` | Nur X11. Das Fenster, in dem ein Diktat begann, und ob es ein Terminal ist (Strg+Umschalt+V). Ohne es bekommt jedes Fenster Strg+V, und Terminals nehmen nichts. |
| `xdotool` oder `wmctrl` | `xdotool`, `wmctrl` | Nur X11. Holt dieses Fenster zurück, wenn du beim Sprechen in ein anderes geklickt hast. Ohne eines von beiden geht der Text auf die Zwischenablage („das Fenster ist nicht mehr da“), statt eingefügt zu werden. |
| `gdbus` | `libglib2.0-bin` | Pausiert Musik und Videos, während du diktierst (MPRIS über D-Bus). Ohne es tut die Einstellung nichts. |
| `ydotool` und `ydotoold` | `ydotool` | Nur Wayland. Sendet Strg+V. Siehe oben. |

Das `.deb` empfiehlt `x11-utils` und `xdotool`, `apt install` holt sie also, solange Empfehlungen nicht ausgeschaltet sind; `xprop` und `gdbus` sind auf einem Desktop meist schon da. Das tar.gz bringt nichts mit: Installier sie selbst.

### Wenn der Kurzbefehl fehlt

Unter ARM Linux mit X11 ist die vorkompilierte Binärdatei der Tastatur-Bibliothek x86-64, deshalb startet satz ohne den Hook (ein blockiertes natives Modul unter Windows tut dasselbe). Die Einstellungen sagen das dann unter *Kurzbefehl*, in der Sprache der App, und nennen den Ausweg: ein Tastenkürzel, das `satz --toggle` ausführt (Systemeinstellungen unter Linux, eine Verknüpfung mit Tastenkombination unter Windows).

## Bauen

```bash
npm install
npm test               # der gemeinsame Kern, von der Mac-App portiert, die lokalen Engines und die Teile der App selbst
npm run dist:win       # release/*.zip
npm run dist:linux     # release/*.deb, *.tar.gz
```

Alles baut auf einem Mac. Die Hilfsprozesse und der Hauptprozess sind esbuild-Bundles (transformers.js steckt in `local-worker.js`), ein Paket trägt also nur, was neben ihnen geladen wird: `onnxruntime-node`, `uiohook-napi` und sherpa-onnx. Das `files` in `package.json` lässt den Rest der Abhängigkeiten von transformers.js weg (`onnxruntime-web`, `sharp` mit seinen macOS-Bibliotheken und Ähnliches, zig MB in einem Paket), und `build/after-pack.cjs` behält pro Paket ein ONNX Runtime und eine Tastatur-Hook-Bibliothek. `test/appFix.test.ts` prüft, dass das Whisper-Bundle nichts anderes anfordert. Unter Windows überspringt `signExecutable: false` nur das Signieren: electron-builder schreibt trotzdem Namen, Version, Firma und Icon von satz in `satz.exe`. `npm start` startet es lokal. npm installiert den nativen Code von sherpa-onnx nur für den Mac, der baut (`sherpa-onnx-darwin-arm64`, aus den Paketen herausgehalten); `build/after-pack.cjs` legt den jedes Pakets eigenen, `sherpa-onnx-linux-x64`, `-linux-arm64` oder `-win-x64`, in der Version und mit der Prüfsumme, die `package-lock.json` nennt (zwischengespeichert in `build/sherpa/`), neben `app.asar` in `resources/app.asar.unpacked/node_modules/`, wo `src/main/sherpaEngine.ts` ihn lädt. Das fügt einem Download 8 bis 13 MB hinzu (23 bis 40 MB entpackt); das Windows-ARM-Zip bekommt nichts.

## Testmodus

`satz --dev-control 48700 --test-audio a.wav:b.wav` spielt WAV-Dateien statt des Mikrofons ab und nimmt Befehle auf `http://127.0.0.1:48700/<command>` entgegen: `press`, `release`, `mic`, `discard`, `undo`, `restore`, `eye`, `caret?at=N`, `state`, `picture`, `js?code=…`, `local`, `local-download`, `local-cancel` und `local-measure` (der Zustand eines lokalen Modells, sein Download, sein Abbrechen und sein Tempotest; `?id=…` nennt das Modell, z. B. `sherpa/moonshine-tiny`, sonst das benutzte; setz `"provider": "local"` in preferences.json, um damit zu diktieren). `--models-dir <folder>` hält die Modelle eines Tests woanders, nie im Ordner des Benutzers; es braucht `--dev-control` (allein beendet sich satz sofort, statt als normales satz auf einem eigenen Ordner zu laufen). Ohne es nutzt eine Testkopie die Modelle des Benutzers, lädt aber nie in diesen Ordner und löscht nie daraus; die Dev-Control-Befehle `local-download` und die Buttons der Einstellungen loggen das und tun nichts. Texte werden aufgezeichnet statt eingefügt, außer `--test-paste` ist gegeben, und ein Test pausiert nie die Musik, außer `--test-media` ist gegeben. Ein Test schreibt seinen Verlauf in das Profil, in dem er läuft, starte ihn also dort, wo das wichtig ist, mit Electrons `--user-data-dir <folder>`. Windows nimmt `;` zwischen den Dateien.

## Was geprüft wurde (10.10.2026): Microsoft, Google und vier weitere lokale Modelle

- **Microsoft und Google, nur gegen einen Ersatz-Server.** `test/providers.test.ts` lässt den echten Anfrage-Code gegen einen Server auf 127.0.0.1 laufen, der genaue Adresse, Header und Body prüft (die Multipart-Teile `audio` und `definition` von Microsoft, aus dem Datenstrom zurückgelesen, Googles JSON und Base64-Audio), mit den dokumentierten Formen antwortet und mit 401, 403, 413, 429, 400 „too long“ und 500 antwortet, um zu sehen, wie jedes benannt wird. **Die echten Dienste wurden nicht aufgerufen: Es gab keinen Schlüssel von Microsoft oder Google.** Ungeprüft ist, ob sie diese Anfragen annehmen und was sie wirklich antworten.
- **Die vier lokalen Modelle, durch den eigenen Code der Engine in reinem Node** (`dist/sherpa-worker.js`, ein Wegwerf-Modellordner, nie der von satz selbst): jedes Modell Datei für Datei bei seinem festen Commit geladen, jede SHA-256 geprüft, in sherpa-onnx-node 1.13.8 geladen, auf `assets/speedtest.wav` gemessen (Sekunden pro 10 s Sprache auf einem M5 Pro, vier Threads) und auf deutschen Clips laufen gelassen, die mit `say -v Anna` gemacht wurden (9,8 s, 6,3 s mit Wortschatz, 40 s in Stücken, 0,8 s), auf Stille und auf 12 s gleichmäßigem Rauschen bei -45 und -32 dBFS.

| Modell | Tempotest | Deutsche Clips | Rauschen |
|---|---|---|---|
| Parakeet V3 German | 0,21 s | Wort für Wort, Zahlen als Ziffern; schreibt „ss“ für „ß“ („Lindenstrasse“) | nichts |
| Qwen3-ASR 0.6B | 1,51 s | richtig, Zahlen als Wörter; ein paar falsche Wörter im 40-s-Clip („beantragt“ für „beantwortet“); „Immofanten“ kam im Clip mit Wortschatz richtig heraus (ohne ihn nicht verglichen) | nichts |
| Canary 1B v2 | 1,01 s | alle bis auf ein Wort („schickt“ für „schick“), „4.500 Euro“ | nichts |
| Cohere Transcribe | 0,58 s | Wort für Wort, das beste der vier; „Emophanten“ für einen erfundenen Namen (kein Wortschatz) | ganze erfundene Sätze, bis `isSteady` (unten) |

- **Cohere Transcribe erfindet Text für gleichmäßiges Rauschen**, das lauter ist als die -45 dBFS, die `hasSpeech` als Sprache nimmt („Ich bin jetzt nicht mehr so gut.“ siebenmal für einen 12 s langen Lüfter). Die drei anderen schrieben für dasselbe Rauschen nichts. Die Stücke von Cohere dürfen jetzt auch nicht ein gleichmäßiger Pegel sein (`isSteady`): Sprache war 18- bis 1500-mal so laut, das Rauschen 1,1-mal, mit der Schwelle bei 2. Danach schickte es für dieselben Clips nichts (1 ms), und die deutschen Clips blieben unverändert. Rauschen, das nicht gleichmäßig ist (eine Tür, ein Husten), kann bei ihm trotzdem einen erfundenen Satz auslösen.
- **Der Decoder von Qwen3-ASR fasst 512 Tokens** für den Prompt, 13 pro Sekunde Audio und den Text. Ein 40-s-Stück kam als das einzelne Wort „language“ zurück (sherpa-onnx loggte das Abschneiden und machte weiter); bei 30 s bleiben etwa 100 Tokens für den Text, zu wenig für Deutsch in normalem Tempo; deshalb sind seine Stücke 15 s.
- **Die Encoder-Gewichte von Cohere** (`encoder.int8.onnx.data`, 2,7 GB) sind eine zweite Datei, die im Encoder genannt wird: Sie werden wie der Rest geladen und geprüft, und das Modell lief mit ihnen neben dem Encoder.
- Nicht geprüft: die Pakete für Windows x64 und Linux x64 mit diesen Modellen (keine VM; der Code ist dieselbe Engine, die dort Handys Modelle laufen ließ), die gepackte App mit dem neuen IPC-Kanal `settings:open-key-page` (`main.ts` liegt außerhalb der Unit-Tests: Die gepackte App einmal in der Ubuntu-VM starten), der Speicher auf einem kleinen Computer (die vier brauchten im Testaufbau 2,5 bis 5,4 GB residenten Speicher, Cohere am meisten) und das Tempo der Modelle auf langsameren Prozessoren.

## Was geprüft wurde (09.10.2026): Handys Modelle

- **Auf dem Mac, durch den eigenen Code der Engine in reinem Node** (`dist/sherpa-worker.js`, Wegwerf-Ordner): jedes der sechs Modelle Datei für Datei geladen und geprüft, dann auf `assets/speedtest.wav` gemessen (Sekunden pro 10 s Sprache auf einem M5 Pro, vier Threads): Moonshine Tiny 0,08, SenseVoice 0,10 (der ursprüngliche Export; der vom 09.09.2025, ein Kantonesisch-Fine-Tuning, schrieb Englisch in verstümmelten Großbuchstaben), Moonshine Base 0,14, Parakeet V2 0,22, Parakeet V3 0,25, Canary 0,38. Parakeet V3 schrieb einen 41 s langen deutschen Clip (`say -v Anna`) fast Wort für Wort; Canary beinahe, nachdem die Leerzeichen vor seiner Zeichensetzung entfernt sind. Stille ergab nichts. Abbrechen hinterließ keine Datei.
- **In der Ubuntu-VM, das gepackte arm64-tar.gz:** Moonshine Tiny wurde über `local-download` geladen, sein Tempotest lief (0,24 s pro 10 s auf 4 VM-Kernen), und ein 28 s langes englisches Diktat aus `--test-audio` kam in 1,3 s zurück. Abbrechen über `local-cancel` entfernte den halb geladenen Ordner.
- Nicht geprüft: Windows x64 und Linux x64 mit sherpa-onnx (keine VM; die Pakete wurden darauf geprüft, dass sie die richtigen nativen Dateien tragen).

## Was geprüft wurde (04.10.2026)

In einer Windows-11-ARM-VM und einer Ubuntu-26.04-ARM-VM (GNOME unter Wayland), mit echten Tastendrücken und Klicks, die in die VMs geschickt wurden, und echten MAI-Transcribe-Aufrufen:

- **Kurzbefehl:** Echte Tipper auf die rechte Strg-Taste starten und beenden ein Diktat. Escape verwirft während der Aufnahme. Strg+C mit der rechten Strg-Taste löst nichts aus.
- **Karte:** Der Mikrofon-Knopf pausiert und setzt fort, das Auge blendet den Text aus und ein, × verwirft und Rückgängig bringt ihn zurück. Die Karte hält am Bildschirmrand an und merkt sich, wo sie hingelegt wurde.
- **Einfügen:** Der Text geht in Notepad (Windows) und per ydotool in den GNOME-Texteditor. Ohne ydotool fällt es auf die Zwischenablage zurück. Die Zwischenablage wird danach zurückgegeben, oder behält den Text, wenn „Text in der Zwischenablage behalten“ an ist (beides in der Ubuntu-VM geprüft, 05.10.).
- **Beim Anmelden starten:** satz startet nach dem Anmelden von selbst, auf beiden. Die Einstellungen werden gesichert. „Kein Mikrofon“ wird klar gesagt.

Nicht geprüft: ein echtes Mikrofon (die VMs haben keines; der Testmodus speist Dateien in denselben Weg ein) und die x64-Builds, für die es keine VM gibt. Unter ARM Linux mit X11 ist die vorkompilierte Binärdatei der Tastatur-Bibliothek in Wirklichkeit x86-64 (ein Verpackungsfehler im Upstream); satz startet dann ohne den Hook und nutzt `satz --toggle`.
