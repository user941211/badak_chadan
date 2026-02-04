import 'dart:typed_data';

class BleFrame {
  BleFrame({
    required this.length,
    required this.cmd,
    required this.data,
    required this.xorSum,
    required this.lengthOk,
    required this.xorOk,
  });

  final int length;
  final int cmd;
  final Uint8List data;
  final int xorSum;
  final bool lengthOk;
  final bool xorOk;

  int get baseCmd => cmd & 0x7F;
  bool get isResponse => (cmd & 0x80) != 0;

  static BleFrame? parse(List<int> raw) {
    if (raw.length < 3) {
      return null;
    }

    final bytes = Uint8List.fromList(raw);
    final length = bytes[0];
    final cmd = bytes[1];
    final xorSum = bytes[bytes.length - 1];
    final payload = bytes.sublist(2, bytes.length - 1);

    return BleFrame(
      length: length,
      cmd: cmd,
      data: payload,
      xorSum: xorSum,
      lengthOk: length == bytes.length,
      xorOk: xorBytes(bytes) == 0,
    );
  }

  static Uint8List build(int cmd, [List<int> data = const []]) {
    final length = 1 + 1 + data.length + 1;
    final prefix = <int>[length, cmd, ...data];
    final x = xorBytes(prefix);
    return Uint8List.fromList([...prefix, x]);
  }

  static int xorBytes(List<int> values) {
    var x = 0;
    for (final value in values) {
      x ^= value;
    }
    return x & 0xFF;
  }
}

String toHex(List<int> values) {
  return values
      .map((v) => v.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}
