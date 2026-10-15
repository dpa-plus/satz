# Bundled software notices

satz's own MIT license is copied from the repository's `LICENSE` into the app's
resources beside this directory. These files preserve the licenses and
attributions of the third-party software used by the packaged apps. They do not
change those components' licenses to MIT.

Both app builds carry this shared inventory. Some components apply to only one
platform:

| Component | Version | Used by |
|---|---|---|
| WhisperKit, including its swift-transformers notices | 1.1.0 | Mac |
| Swift Argument Parser, including the Runtime Library Exception | 1.8.2 | Mac dependency graph |
| sherpa-onnx | 1.13.8 | Mac, Windows x64, Linux |
| ONNX Runtime | 1.28.2 | sherpa-onnx native engine |
| kaldi-native-fbank, kaldi-decoder, kaldifst, Eigen, simple-sentencepiece, OpenFST, hclust-cpp, KissFFT, nlohmann/json | See `SOURCES.json` | sherpa-onnx and its linked dependencies |
| Transformers.js, Hugging Face Jinja and tokenizers | 4.3.1, 0.5.10, 0.2.0 | Windows and Linux JavaScript bundle |
| ONNX Runtime node/common | 1.30.0 | Windows and Linux Whisper engine |
| ONNX Runtime Web | 1.31.0-dev.20260914-8d85527a0 | JavaScript included by Transformers.js |
| uiohook-napi, libuiohook, node-gyp-build | See `SOURCES.json` | Windows and Linux keyboard hook |
| Piper phonemize, eSpeak NG and Unicode/uni-algo notices | See `SOURCES.json` | Desktop sherpa native packages, including their unused TTS code |
| Microsoft Visual C++ runtime | 14.44.35211.0 | Windows |

`SOURCES.json` records each notice's upstream version, URL and SHA-256. License
files are copied without editing. Attribution excerpts retain their original
wording; added headings identify their source files. The ONNX Runtime and Eigen notice
files preserve the complete upstream license inventories, including optional
components that may not be used by every platform build.

The sherpa-onnx 1.13.8 macOS build manifest selects ONNX Runtime 1.28.2 in
[`cmake/onnxruntime-osx-universal.cmake`](https://github.com/k2-fsa/sherpa-onnx/blob/11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf/cmake/onnxruntime-osx-universal.cmake).
Its linked dependency versions come from that release's CMake files. The
cpp-base64 reference notice is included because sherpa's `base64-decode.cc`
references that project; sherpa does not identify the original copied revision.

The keyboard hook's MIT wrapper and its LGPL-3.0-or-later libuiohook component
have separate notices. libuiohook source revision
`f259ff37e81125f6f91ebac5439e7cde1e78b296` is patched by uiohook-napi 1.5.5
([wrapper source and patch](https://github.com/SnosMe/uiohook-napi/tree/44e0d868ac6fedd2a68c7f8ad8163c73a3f36fc3)).
The package retains its `libuiohook` source directory, wrapper source and build
files alongside the prebuilt native module. Source correspondence was checked;
reproducibility of the upstream prebuilt binaries was not established.

The Microsoft runtime license is the unmodified English `license.rtf` resource
from Microsoft's 14.44.35211.0 redistributable. Both packaged architectures'
runtime DLLs were matched byte for byte to the installer recorded in
`SOURCES.json`. This runtime has Microsoft's license, separately from satz's MIT
license.

## Desktop native library source

The sherpa native libraries in the Windows x64 and Linux packages include
Piper phonemize and eSpeak NG even though satz only uses speech recognition.
The combined native libraries are distributed under the GNU GPL version 3 or,
at your option, any later version, because they include eSpeak NG. See
`espeak-ng/COPYING` and its source attributions. There is no warranty; the
license permits copying, modification and redistribution on its terms.
The Mac uses the separate no-TTS native build, and the Windows ARM package
contains no sherpa native library. Satz-owned source remains available under
MIT; the original licenses of all third-party components are retained here.

The corresponding source and build instructions for the desktop native
libraries, including the Node addon and linked dependencies, are provided at
no charge in
[`satz-0.4.3-source.tar.gz`](https://github.com/dpa-plus/satz/releases/download/v0.4.3/satz-0.4.3-source.tar.gz)
alongside the application downloads. That archive contains the source snapshots
for satz 0.4.3 and 0.4.2, which use these same native package versions, plus
upstream source archives and build scripts. Its `BUILDING.md` explains the
source layout and how to rebuild or modify the components. Keep this source
download available with the binary downloads.

Other notices already travel with their components:

- The Mac's `Fonts` directory carries the three SIL Open Font License texts.
- `speedtest.txt` beside the sample audio records its LibriVox attribution.
- Electron's platform packages carry `LICENSE.electron.txt` and
  `LICENSES.chromium.html`; retain the platform-specific files supplied by
  Electron.
- Packaged npm modules retain their own license files, including native ONNX
  helper dependencies. The additional copies here also cover code folded into
  JavaScript bundles or native libraries.
- Downloadable speech model weights are not included in the application; their
  upstream licenses are linked in the main README.

When changing dependency pins or the Microsoft runtime download, refresh the
affected notices and `SOURCES.json`, then inspect each resulting app package.
In particular, the Microsoft download URL can change its contents even while
the URL stays the same. This inventory records the versions checked for 0.4.3;
it does not establish legal certification or binary reproducibility.
