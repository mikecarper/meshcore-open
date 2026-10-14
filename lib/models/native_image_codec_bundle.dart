import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'image_codec_support.dart';

const nativeFt2BundleFormat = 'aeic-native-ft2-bundle-v1';
const nativeFt2CheckpointSha256 =
    '519a0f935dc19fa7f8c5d4dd24df32c3d1c017f29834dd6a7bf68587b47a16a1';
const nativeFt2SharedWeightsSha256 =
    '0031dcec7c37313c041df7dacb1f60071e049d869ef9b6a6d991ab4266f66c48';
const nativeFt2EntropyHashes = <String, String>{
  'y_cdf.bin':
      '5c1e2487f5ba2c683c35cc07368278ffb4fe486cce28e2f3582e9c9957e7abaf',
  'z_cdf.bin':
      '8a4fa5ca7b0190131b369ffcd264e752d8d2751538333028c2813c83ba95b075',
  'z_medians.f32':
      '076a27c79e5ace2a3d47f9dd2e83e4ff6ea8872b3c2218f66c92b89b55f36560',
};

/// An import-only native model specification. There is no download URL.
class NativeFt2ModelSpec {
  const NativeFt2ModelSpec();
  String get id => kNativeFt2ModelId;
  String get name => 'AEIC FT2 phone model';
  List<int> get resolutions => kNativeFt2Resolutions;
}

const nativeFt2ModelSpec = NativeFt2ModelSpec();

class NativeBundleAsset {
  final String path;
  final int size;
  final String sha256;
  const NativeBundleAsset(this.path, this.size, this.sha256);
}

/// Regular files are hashed while streaming. Links are created by the installer.
class NativeImageCodecManifest {
  final Map<String, NativeBundleAsset> files;
  final Map<String, String> links;
  final String sourceJson;
  NativeImageCodecManifest._(this.files, this.links, this.sourceJson);

  int get totalFileBytes =>
      files.values.fold(0, (sum, file) => sum + file.size);

  factory NativeImageCodecManifest.parse(String text) {
    final raw = jsonDecode(text);
    if (raw is! Map<String, dynamic> ||
        raw['format'] != nativeFt2BundleFormat ||
        raw['codec_identity'] != kNativeFt2ModelId ||
        raw['checkpoint_sha256'] != nativeFt2CheckpointSha256) {
      throw const FormatException('This is not the verified native FT2 model.');
    }
    final resolutions = raw['resolutions'];
    if (resolutions is! List ||
        resolutions.length != kNativeFt2Resolutions.length ||
        !Iterable<int>.generate(kNativeFt2Resolutions.length).every(
          (index) => resolutions[index] == kNativeFt2Resolutions[index],
        )) {
      throw const FormatException(
        'The model must include all eight image sizes.',
      );
    }
    final files = <String, NativeBundleAsset>{};
    final rawFiles = raw['files'];
    final rawLinks = raw['links'];
    if (rawFiles is! List ||
        rawLinks is! List ||
        rawFiles.length > 10000 ||
        rawLinks.length > 10000) {
      throw const FormatException('Invalid model file list.');
    }
    final hashPattern = RegExp(r'^[0-9a-f]{64}$');
    for (final item in rawFiles) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid model file.');
      }
      final path = item['path'];
      final size = item['size'];
      final hash = item['sha256'];
      if (path is! String ||
          !_assetPath(path) ||
          size is! int ||
          size < 0 ||
          size > (path.endsWith('.ncnn.bin') ? 256 : 2) * 1024 * 1024 ||
          hash is! String ||
          !hashPattern.hasMatch(hash) ||
          files.containsKey(path)) {
        throw const FormatException('Invalid model file.');
      }
      files[path] = NativeBundleAsset(path, size, hash);
    }
    final weights =
        files.values.where((file) => file.path.endsWith('.ncnn.bin')).toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    final weightList = weights
        .map((file) => '${file.path}\t${file.size}\t${file.sha256}\n')
        .join();
    if (raw['shared_weights_sha256'] != nativeFt2SharedWeightsSha256 ||
        sha256.convert(ascii.encode(weightList)).toString() !=
            nativeFt2SharedWeightsSha256) {
      throw const FormatException(
        'The model weights do not match the FT2 checkpoint.',
      );
    }
    final links = <String, String>{};
    for (final item in rawLinks) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid model link.');
      }
      final path = item['path'];
      final target = item['target'];
      if (path is! String ||
          !_assetPath(path) ||
          !path.startsWith('codec') ||
          target is! String ||
          !RegExp(r'^\.\./shared/[A-Za-z0-9_.-]+$').hasMatch(target) ||
          files.containsKey(path) ||
          links.containsKey(path) ||
          !files.containsKey(target.substring(3))) {
        throw const FormatException('Invalid shared model link.');
      }
      links[path] = target;
    }
    for (final size in kNativeFt2Resolutions) {
      for (final name in [
        'codec.tsv',
        'encoder.tsv',
        'renderer.tsv',
        'metadata.tsv',
      ]) {
        if (!files.containsKey('codec$size/$name')) {
          throw FormatException('Missing configuration for image size $size.');
        }
      }
      for (final entropy in nativeFt2EntropyHashes.entries) {
        final sharedPath = 'shared/${entropy.key}';
        if (files[sharedPath]?.sha256 != entropy.value ||
            links['codec$size/${entropy.key}'] != '../$sharedPath') {
          throw const FormatException('The FT2 entropy assets do not match.');
        }
      }
    }
    final manifest = NativeImageCodecManifest._(
      Map.unmodifiable(files),
      Map.unmodifiable(links),
      text,
    );
    if (manifest.totalFileBytes > 3 * 1024 * 1024 * 1024) {
      throw const FormatException('The model bundle is too large.');
    }
    return manifest;
  }

  static bool _assetPath(String path) {
    final parts = path.split('/');
    return parts.length == 2 &&
        (parts[0] == 'shared' ||
            kNativeFt2Resolutions.any((s) => parts[0] == 'codec$s')) &&
        RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*$').hasMatch(parts[1]);
  }
}
