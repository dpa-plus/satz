#!/usr/bin/python3
"""Sign nested code inside-out, then the app. Never use --deep for signing."""

import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

SCRIPT_DIR = Path(__file__).resolve().parent
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def run(arguments, **kwargs):
    return subprocess.run([str(value) for value in arguments], check=True, **kwargs)


def check_identity(identity):
    # A full certificate name makes the distribution intent unambiguous; an
    # Apple Development or ad-hoc identity must never pass the release gate.
    if not identity.startswith("Developer ID Application:"):
        raise ValueError("Set SIGN_IDENTITY to the full name of an existing Developer ID Application certificate.")
    identities = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                     capture_output=True, text=True).stdout
    if '"' + identity + '"' not in identities:
        raise ValueError("The configured Developer ID Application identity is not valid in the current Keychain.")


def is_macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as source:
        return source.read(4) in MACHO_MAGICS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path)
    parser.add_argument("--identity", default=os.environ.get("SIGN_IDENTITY", "-"))
    parser.add_argument("--check-identity", action="store_true")
    arguments = parser.parse_args()
    production = arguments.identity != "-"
    if production or arguments.check_identity:
        check_identity(arguments.identity)
    if arguments.check_identity:
        return
    if arguments.app is None:
        parser.error("app is required")
    app = arguments.app.resolve()
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != "plus.dpa.satz":
        raise ValueError("Expected a staged plus.dpa.satz app bundle.")
    main_executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    if not is_macho(main_executable):
        raise ValueError("The staged app has no Mach-O main executable.")

    paths = [path for path in app.rglob("*") if not path.is_symlink()]
    bundles = [path for path in paths if path.is_dir() and path.suffix in {".framework", ".xpc", ".appex", ".app"}]
    binaries = [path for path in paths if path != main_executable and is_macho(path)]
    # Framework symlinks are deliberately skipped, so each real binary is
    # signed once and its containing code bundle is sealed afterwards.
    nested = sorted(bundles + binaries, key=lambda path: (-len(path.parts), str(path)))
    options = ["--force", "--sign", arguments.identity]
    if production:
        options += ["--options", "runtime", "--timestamp"]

    with tempfile.TemporaryDirectory(prefix="satz-sign-") as temporary:
        downloader_entitlements = {}
        for bundle in bundles:
            # Sparkle 2.6+ may ship a sandboxed Downloader. Preserve only this
            # helper's upstream entitlements, never copy them onto the host.
            if bundle.name == "Downloader.xpc" and "Sparkle.framework" in bundle.parts:
                result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)],
                                        capture_output=True, check=False)
                if result.stdout.strip():
                    entitlements = plistlib.loads(result.stdout)
                    entitlements.pop("com.apple.security.get-task-allow", None)
                    if entitlements:
                        destination = Path(temporary) / (str(len(downloader_entitlements)) + ".plist")
                        destination.write_bytes(plistlib.dumps(entitlements))
                        downloader_entitlements[bundle] = destination
        for path in nested:
            command = ["/usr/bin/codesign"] + options
            if path in downloader_entitlements:
                command += ["--entitlements", downloader_entitlements[path]]
            run(command + [path])
        command = ["/usr/bin/codesign"] + options + ["--identifier", "plus.dpa.satz"]
        if production:
            command += ["--entitlements", SCRIPT_DIR.parent.parent / "Resources/Release.entitlements"]
        else:
            # Stable local TCC grants across ad-hoc rebuilds. A public release
            # uses Apple's certificate-derived requirement instead.
            command += ["--requirements", '=designated => identifier "plus.dpa.satz"']
        run(command + [app])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    print("Signed staged app (" + ("Developer ID / Hardened Runtime" if production else "ad-hoc local build") + ").")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("sign-app: " + str(error), file=sys.stderr)
        sys.exit(1)
