#!/usr/bin/env python3
"""Create and sign a Sparkle feed for an already-built, signed Mac archive."""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

NAMESPACE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NAMESPACE)


def appcast(info, archive, signature, base_url):
    version = info['CFBundleShortVersionString']
    build = info['CFBundleVersion']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'\d+', build):
        raise ValueError('A numeric build and stable x.y.z version are required')
    if not re.fullmatch(r'[A-Za-z0-9+/]{86}==', signature):
        raise ValueError('Invalid Ed25519 signature')
    if not base_url.startswith('https://') or '?' in base_url or '#' in base_url:
        raise ValueError('Use an HTTPS version-folder URL')
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'satz Updates'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'satz {version}'
    ET.SubElement(item, 'link').text = 'https://github.com/dpa-plus/satz/releases'
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f'{{{NAMESPACE}}}version').text = build
    ET.SubElement(item, f'{{{NAMESPACE}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{NAMESPACE}}}minimumSystemVersion').text = '14.0.0'
    ET.SubElement(item, 'enclosure', url=f'{base_url.rstrip("/")}/{archive.name}',
                  length=str(archive.stat().st_size), type='application/octet-stream',
                  attrib={f'{{{NAMESPACE}}}edSignature': signature})
    ET.indent(rss)
    return ET.tostring(rss, encoding='utf-8', xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--sparkle-bin', required=True, type=Path)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--account', default='plus.dpa.satz')
    args = parser.parse_args()
    info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    public = subprocess.check_output([str(args.sparkle_bin / 'generate_keys'), '--account', args.account, '-p'], text=True).strip()
    if public != info.get('SUPublicEDKey'):
        raise SystemExit('Signing key does not match the public key embedded in this app')
    signer = [str(args.sparkle_bin / 'sign_update'), '--account', args.account]
    signature = subprocess.check_output(signer + ['-p', str(args.archive)], text=True).strip()
    args.output.write_bytes(appcast(info, args.archive, signature, args.base_url))
    subprocess.run(signer + [str(args.output)], check=True)
    subprocess.run(signer + ['--verify', str(args.output)], check=True)
    print(f'Created signed feed: {args.output}')


if __name__ == '__main__':
    main()
