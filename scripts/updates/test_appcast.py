import tempfile
import unittest
from pathlib import Path
import xml.etree.ElementTree as ET
from appcast import appcast, NAMESPACE


class FeedTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = Path(self.directory.name) / 'satz-mac.zip'
        self.archive.write_bytes(b'signed archive fixture')
        self.info = {'CFBundleVersion': '12', 'CFBundleShortVersionString': '0.4.6'}
        self.signature = 'A' * 86 + '=='

    def feed(self, base='https://cdn.example/satz/v0.4.6'):
        return appcast(self.info, self.archive, self.signature, base)

    def test_uses_build_for_comparison_human_version_for_display_and_exact_archive(self):
        item = ET.fromstring(self.feed()).find('channel/item')
        self.assertEqual(item.find(f'{{{NAMESPACE}}}version').text, '12')
        self.assertEqual(item.find(f'{{{NAMESPACE}}}shortVersionString').text, '0.4.6')
        enclosure = item.find('enclosure')
        self.assertEqual(enclosure.get('url'), 'https://cdn.example/satz/v0.4.6/satz-mac.zip')
        self.assertEqual(enclosure.get('length'), str(self.archive.stat().st_size))
        self.assertEqual(enclosure.get(f'{{{NAMESPACE}}}edSignature'), self.signature)

    def test_refuses_insecure_or_ambiguous_download_bases(self):
        for base in ['http://cdn.example/satz', 'https://cdn.example/a?q=x', 'https://cdn.example/a#x']:
            with self.subTest(base=base), self.assertRaises(ValueError): self.feed(base)

    def test_refuses_nonrelease_version_or_build(self):
        for key, value in [('CFBundleVersion', 'main'), ('CFBundleShortVersionString', '0.4.6-beta')]:
            with self.subTest(key=key):
                info = dict(self.info, **{key: value})
                with self.assertRaises(ValueError): appcast(info, self.archive, self.signature, 'https://cdn.example/v0.4.6')

    def test_refuses_missing_or_truncated_signature(self):
        for signature in ['', 'A' * 30]:
            with self.subTest(signature=signature), self.assertRaises(ValueError):
                appcast(self.info, self.archive, signature, 'https://cdn.example/v0.4.6')


if __name__ == '__main__': unittest.main()
