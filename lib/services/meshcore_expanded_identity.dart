import 'dart:typed_data';

// MeshCore stores the SHA-512-expanded Ed25519 secret, not its 32-byte seed.
// The first 32 bytes are the clamped scalar. Derive the public point directly
// so a backup can be bound to the selected contact without altering the key.
Uint8List deriveMeshCoreExpandedPublicKey(Uint8List privateKey) {
  if (privateKey.length != 64 ||
      privateKey[0] & 7 != 0 ||
      privateKey[31] & 0xc0 != 0x40) {
    throw const FormatException('Invalid MeshCore expanded private key.');
  }

  var scalar = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    scalar = (scalar << 8) | BigInt.from(privateKey[i]);
  }
  var point = _EdPoint.identity();
  var multiple = _EdPoint.base();
  for (var i = 0; i < 255; i++) {
    if ((scalar & BigInt.one) == BigInt.one) point = point.add(multiple);
    multiple = multiple.doublePoint();
    scalar >>= 1;
  }

  final inverseZ = point.z.modPow(_fieldPrime - BigInt.two, _fieldPrime);
  final x = _mod(point.x * inverseZ);
  var y = _mod(point.y * inverseZ);
  final encoded = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    encoded[i] = (y & BigInt.from(0xff)).toInt();
    y >>= 8;
  }
  if (x.isOdd) encoded[31] |= 0x80;
  return encoded;
}

final BigInt _fieldPrime = (BigInt.one << 255) - BigInt.from(19);
final BigInt _d = _mod(
  -BigInt.from(121665) * BigInt.from(121666).modInverse(_fieldPrime),
);

BigInt _mod(BigInt value) => value % _fieldPrime;

class _EdPoint {
  _EdPoint(this.x, this.y, this.z, this.t);

  factory _EdPoint.identity() =>
      _EdPoint(BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);

  factory _EdPoint.base() {
    final x = BigInt.parse(
      '15112221349535400772501151409588531511454012693041857206046113283949847762202',
    );
    final y = BigInt.parse(
      '46316835694926478169428394003475163141307993866256225615783033603165251855960',
    );
    return _EdPoint(x, y, BigInt.one, _mod(x * y));
  }

  final BigInt x;
  final BigInt y;
  final BigInt z;
  final BigInt t;

  _EdPoint add(_EdPoint other) {
    final a = _mod((y - x) * (other.y - other.x));
    final b = _mod((y + x) * (other.y + other.x));
    final c = _mod(BigInt.two * _d * t * other.t);
    final d = _mod(BigInt.two * z * other.z);
    final e = _mod(b - a);
    final f = _mod(d - c);
    final g = _mod(d + c);
    final h = _mod(b + a);
    return _EdPoint(_mod(e * f), _mod(g * h), _mod(f * g), _mod(e * h));
  }

  _EdPoint doublePoint() {
    final a = _mod(x * x);
    final b = _mod(y * y);
    final c = _mod(BigInt.two * z * z);
    final d = _mod(-a);
    final e = _mod((x + y) * (x + y) - a - b);
    final g = _mod(d + b);
    final f = _mod(g - c);
    final h = _mod(d - b);
    return _EdPoint(_mod(e * f), _mod(g * h), _mod(f * g), _mod(e * h));
  }
}
