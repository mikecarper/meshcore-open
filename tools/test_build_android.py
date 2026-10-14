"""Run with python3 -m unittest discover -s tools -p test_build_android.py."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('build_android', Path(__file__).with_name('build_android.py'))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class BuildProfileTests(unittest.TestCase):
    def test_legacy_manifest_is_isolated_and_local_secrets_are_excluded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'source'
            output = Path(temporary) / 'build'
            root.mkdir()
            output.mkdir()
            modern = 'environment:\n  sdk: ^3.9.2\ndependencies:\n  mobile_scanner: ^7.1.4\ndev_dependencies:\n  integration_test:\n    sdk: flutter\n'
            files = {
                'pubspec.yaml': modern,
                'pubspec.lock': 'modern lock',
                'lib/main.dart': 'void main() {}',
                'android/key.properties': 'private signing properties',
                'keys/release.keystore': 'private key',
                '.env.local': 'private environment',
                'android/local.properties': 'host paths',
                'pubspec_overrides.yaml': 'developer-only overrides',
                'build_profiles/legacy/pubspec.lock': 'legacy lock',
                'build_profiles/legacy/pubspec_overrides.yaml': 'dependency_overrides: {}',
                'build_profiles/legacy/pubspec-pins.json': json.dumps({
                    'sdk': '>=3.8.0 <4.0.0', 'dependencies': {'mobile_scanner': '6.0.10'}}),
            }
            for relative, text in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            with patch.object(builder, 'source_files', return_value=list(files)):
                builder.prepare(root, output, 'legacy')
            self.assertEqual((root / 'pubspec.yaml').read_text(), modern)
            self.assertEqual((root / 'pubspec.lock').read_text(), 'modern lock')
            legacy = (output / 'pubspec.yaml').read_text()
            self.assertIn('sdk: ">=3.8.0 <4.0.0"', legacy)
            self.assertIn('mobile_scanner: 6.0.10', legacy)
            self.assertNotIn('integration_test:', legacy)
            self.assertEqual((output / 'pubspec.lock').read_text(), 'legacy lock')
            for relative in ['android/key.properties', 'keys/release.keystore',
                             '.env.local', 'android/local.properties']:
                self.assertFalse((output / relative).exists(), relative)

    def test_source_inventory_rejects_outside_links_and_generated_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'source'
            root.mkdir()
            external = Path(temporary) / 'outside.txt'
            external.write_text('outside data')
            (root / 'outside-link').symlink_to(external)
            paths = ['lib/main.dart', '.build/cache.bin', '.android-build/cache.bin', '.dart_tool/cache.bin',
                     'tools/__pycache__/helper.pyc', 'outside-link']
            for relative in paths[:-1]:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('source or generated cache')
            with patch.object(builder, 'run', return_value='\0'.join(paths) + '\0'):
                self.assertEqual(builder.source_files(root), ['lib/main.dart'])

    def test_packaging_requires_correct_abi_and_native_ft2(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / 'fixture.apk'
            def write(*libraries):
                with zipfile.ZipFile(apk, 'w') as archive:
                    for library in libraries:
                        archive.writestr(library, b'layout fixture, not executable')
            write('lib/armeabi-v7a/libflutter.so', 'lib/armeabi-v7a/libaeic_codec_exec.so')
            self.assertEqual(builder.verify_apk(apk, 'legacy')['abis'], ['armeabi-v7a'])
            write('lib/arm64-v8a/libaeic_codec_exec.so')
            with self.assertRaises(RuntimeError):
                builder.verify_apk(apk, 'legacy')
            write('lib/armeabi-v7a/libflutter.so')
            with self.assertRaises(RuntimeError):
                builder.verify_apk(apk, 'legacy')
            write('lib/armeabi-v7a/libaeic_codec_exec.so', 'lib/armeabi-v7a/libonnxruntime.so')
            with self.assertRaises(RuntimeError):
                builder.verify_apk(apk, 'legacy')


if __name__ == '__main__':
    unittest.main()
