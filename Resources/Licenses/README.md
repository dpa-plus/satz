# Hinweise zur mitgelieferten Software

Die MIT-Lizenz von satz selbst wird aus der `LICENSE` des Repositorys neben
diesem Verzeichnis in die Ressourcen der App kopiert. Diese Dateien bewahren
die Lizenzen und Namensnennungen der Software von Dritten, die in den
verpackten Apps steckt. Sie ändern die Lizenzen dieser Komponenten nicht zu
MIT.

Beide App-Builds tragen dieses gemeinsame Verzeichnis. Einige Komponenten
gelten nur für eine Plattform:

| Komponente | Version | Verwendet von |
|---|---|---|
| FluidAudio, mit den Hinweisen zu seinen Komponenten | 0.17.3 | Mac |
| WhisperKit, einschließlich der Hinweise zu swift-transformers | 1.1.0 | Mac |
| Swift Argument Parser, einschließlich der Runtime Library Exception | 1.8.2 | Abhängigkeitsgraph des Mac |
| sherpa-onnx | 1.13.8 | Mac, Windows x64, Linux |
| ONNX Runtime | 1.28.2 | native Engine von sherpa-onnx |
| kaldi-native-fbank, kaldi-decoder, kaldifst, Eigen, simple-sentencepiece, OpenFST, hclust-cpp, KissFFT, nlohmann/json | Siehe `SOURCES.json` | sherpa-onnx und seine gelinkten Abhängigkeiten |
| Transformers.js, Hugging Face Jinja und tokenizers | 4.3.1, 0.5.10, 0.2.0 | JavaScript-Bundle für Windows und Linux |
| ONNX Runtime node/common | 1.30.0 | Whisper-Engine für Windows und Linux |
| ONNX Runtime Web | 1.31.0-dev.20260914-8d85527a0 | JavaScript, das Transformers.js einbindet |
| uiohook-napi, libuiohook, node-gyp-build | Siehe `SOURCES.json` | Tastatur-Hook für Windows und Linux |
| Piper phonemize, eSpeak NG und die Unicode/uni-algo-Hinweise | Siehe `SOURCES.json` | Native sherpa-Pakete für den Desktop, einschließlich ihres ungenutzten TTS-Codes |
| Microsoft Visual C++ runtime | 14.44.35211.0 | Windows |

`SOURCES.json` hält für jeden Hinweis die Upstream-Version, die URL und die
SHA-256 fest. Lizenzdateien werden unverändert kopiert. Auszüge mit
Namensnennungen behalten ihren Originalwortlaut; hinzugefügte Überschriften
nennen ihre Quelldateien. Die Hinweisdateien von ONNX Runtime und Eigen
enthalten die vollständigen Lizenzverzeichnisse des Upstreams, einschließlich
optionaler Komponenten, die möglicherweise nicht in jedem Plattform-Build
verwendet werden.

Das Build-Manifest von sherpa-onnx 1.13.8 für macOS wählt ONNX Runtime 1.28.2
in [`cmake/onnxruntime-osx-universal.cmake`](https://github.com/k2-fsa/sherpa-onnx/blob/11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf/cmake/onnxruntime-osx-universal.cmake).
Die Versionen der gelinkten Abhängigkeiten stammen aus den CMake-Dateien dieses
Releases. Der Referenzhinweis zu cpp-base64 ist enthalten, weil `base64-decode.cc`
von sherpa auf dieses Projekt verweist; sherpa nennt die ursprünglich kopierte
Revision nicht.

Der MIT-Wrapper des Tastatur-Hooks und seine Komponente libuiohook unter
LGPL-3.0-or-later haben getrennte Hinweise. Die Quellrevision
`f259ff37e81125f6f91ebac5439e7cde1e78b296` von libuiohook wird von
uiohook-napi 1.5.5 gepatcht
([Wrapper-Quellcode und Patch](https://github.com/SnosMe/uiohook-napi/tree/44e0d868ac6fedd2a68c7f8ad8163c73a3f36fc3)).
Das Paket behält sein Quellverzeichnis `libuiohook`, den Wrapper-Quellcode und
die Build-Dateien neben dem vorkompilierten nativen Modul. Die Übereinstimmung
mit dem Quellcode wurde geprüft; ob sich die vorkompilierten Binärdateien des
Upstreams reproduzieren lassen, wurde nicht festgestellt.

Die Lizenz der Microsoft-Runtime ist die unveränderte englische Ressource
`license.rtf` aus Microsofts Redistributable 14.44.35211.0. Die Runtime-DLLs
beider verpackter Architekturen wurden Byte für Byte mit dem in
`SOURCES.json` festgehaltenen Installer abgeglichen. Diese Runtime steht unter
Microsofts Lizenz, getrennt von der MIT-Lizenz von satz.

## Quellcode der nativen Desktop-Bibliothek

Die nativen sherpa-Bibliotheken in den Paketen für Windows x64 und Linux
enthalten Piper phonemize und eSpeak NG, obwohl satz nur die Spracherkennung
nutzt. Die zusammengefassten nativen Bibliotheken werden unter der GNU GPL
Version 3 oder, nach deiner Wahl, jeder späteren Version verteilt, weil sie
eSpeak NG enthalten. Siehe `espeak-ng/COPYING` und seine Quellangaben. Es gibt
keine Gewährleistung; die Lizenz erlaubt Kopieren, Ändern und Weiterverteilen
zu ihren Bedingungen. Der Mac nutzt den getrennten nativen Build ohne TTS, und
das Windows-ARM-Paket enthält keine native sherpa-Bibliothek. Der Quellcode, der
satz selbst gehört, bleibt unter MIT verfügbar; die ursprünglichen Lizenzen
aller Komponenten von Dritten bleiben hier erhalten.

Der zugehörige Quellcode und die Bauanleitung für die nativen
Desktop-Bibliotheken, einschließlich des Node-Addons und der gelinkten
Abhängigkeiten, werden kostenlos bereitgestellt in
[`satz-0.4.5-source.tar.gz`](https://github.com/dpa-plus/satz/releases/download/v0.4.5/satz-0.4.5-source.tar.gz),
zusammen mit den Downloads der Anwendung. Dieses Archiv enthält die
Quellcode-Stände für satz 0.4.5, 0.4.4, 0.4.3 und 0.4.2, die dieselben Versionen der nativen
Pakete nutzen, dazu Upstream-Quellarchive und Build-Skripte. Seine
`BUILDING.md` erklärt den Aufbau des Quellcodes und wie sich die Komponenten
neu bauen oder ändern lassen. Dieser Quellcode-Download muss zusammen mit den
Binär-Downloads verfügbar bleiben.

Weitere Hinweise reisen schon mit ihren Komponenten:

- Das Verzeichnis `Fonts` des Mac trägt die drei Texte der SIL Open Font License.
- `speedtest.txt` neben dem Beispiel-Audio hält die Namensnennung an LibriVox fest.
- Die Plattform-Pakete von Electron tragen `LICENSE.electron.txt` und
  `LICENSES.chromium.html`; behalte die plattformspezifischen Dateien, die
  Electron mitliefert.
- Verpackte npm-Module behalten ihre eigenen Lizenzdateien, auch die
  Abhängigkeiten für native ONNX-Helfer. Die zusätzlichen Kopien hier decken
  auch Code ab, der in JavaScript-Bundles oder native Bibliotheken eingefaltet ist.
- Herunterladbare Gewichte der Sprachmodelle sind nicht in der Anwendung
  enthalten; ihre Upstream-Lizenzen sind in der Haupt-README verlinkt.

Wenn du Abhängigkeits-Pins oder den Download der Microsoft-Runtime änderst,
aktualisiere die betroffenen Hinweise und `SOURCES.json` und prüfe dann jedes
entstandene App-Paket. Besonders kann sich der Inhalt des Microsoft-Downloads
ändern, obwohl die URL gleich bleibt. Dieses Verzeichnis hält die für 0.4.4
geprüften Versionen fest; es begründet weder eine rechtliche Zertifizierung
noch die Reproduzierbarkeit der Binärdateien.
