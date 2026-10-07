#!/usr/bin/env python3
"""Microsoft's C++ runtime for the Windows packages.

ONNX Runtime, which runs Whisper on the computer, needs these DLLs, and a
fresh Windows does not have them: loading it failed with "The specified
module could not be found" in a clean Windows 11 VM. They come from
Microsoft's own redistributable, which may be shipped next to an app, and
land in build/vcruntime/<arch>/ for electron-builder to put beside
onnxruntime_binding.node: Windows looks for a native module's DLLs in the
module's own folder, not in satz.exe's.

The installer is a WiX bundle: a cabinet holding more cabinets, where the
DLLs are named like msvcp140.dll_amd64. bsdtar reads cabinets.
"""
import pathlib
import re
import struct
import subprocess
import tempfile

# What onnxruntime.dll and onnxruntime_binding.node import (api-ms-win-crt-* is part of Windows).
NEEDED = ['msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_atomic_wait.dll', 'vcruntime140.dll', 'vcruntime140_1.dll']
SUFFIX = {'x64': 'amd64', 'arm64': 'arm64'}
here = pathlib.Path(__file__).parent

for arch, suffix in SUFFIX.items():
    target = here / 'vcruntime' / arch
    names = [name for name in NEEDED if not (arch == 'arm64' and name == 'vcruntime140_1.dll')]
    if all((target / name).exists() for name in names):
        continue
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        # curl, for its retries: the download broke off halfway now and then.
        # Resuming needs the file's own address, not aka.ms's redirect to it.
        url = subprocess.run(['curl', '-sSIL', '-o', '/dev/null', '-w', '%{url_effective}', f'https://aka.ms/vs/17/release/vc_redist.{arch}.exe'],
                             check=True, capture_output=True, text=True).stdout
        subprocess.run(['curl', '-sSf', '--retry', '20', '--retry-all-errors', '-C', '-', '-o', work / 'redist.exe', url], check=True)
        exe = (work / 'redist.exe').read_bytes()
        # The second cabinet is the payload; the first holds the installer's own interface.
        start = [m.start() for m in re.finditer(b'MSCF\x00\x00\x00\x00', exe)][1]
        size = struct.unpack_from('<I', exe, start + 8)[0]
        (work / 'payload.cab').write_bytes(exe[start:start + size])
        (work / 'outer').mkdir()
        subprocess.run(['bsdtar', '-xf', work / 'payload.cab', '-C', work / 'outer'], check=False)
        found = {}
        for inner in (work / 'outer').iterdir():
            if inner.read_bytes()[:4] != b'MSCF':
                continue
            unpacked = work / 'inner' / inner.name
            unpacked.mkdir(parents=True)
            subprocess.run(['bsdtar', '-xf', inner, '-C', unpacked], check=False)
            for file in unpacked.iterdir():
                found[file.name.lower()] = file
        target.mkdir(parents=True, exist_ok=True)
        for name in names:
            dll = found[f'{name}_{suffix}'].read_bytes()
            # The PE header names the chip: 0x8664 x64, 0xAA64 arm64.
            machine = struct.unpack_from('<H', dll, struct.unpack_from('<I', dll, 0x3C)[0] + 4)[0]
            assert machine == {'x64': 0x8664, 'arm64': 0xAA64}[arch], f'{name} is not {arch}'
            (target / name).write_bytes(dll)
    print(f'vcruntime: {arch} ready')
