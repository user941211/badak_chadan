import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:mobile_app/models/ble_frame.dart';
import 'package:permission_handler/permission_handler.dart';

class BleLockService {
  BleLockService({FlutterReactiveBle? ble})
    : _ble = ble ?? FlutterReactiveBle();

  static const String _uuidBaseStd = '-0000-1000-8000-00805f9b34fb';
  static const String _uuidBaseDoc = '-0000-1000-8000-0805f9b34fb';

  static final Set<String> _serviceUuidCandidates = {
    '00007195$_uuidBaseStd',
    '00007195$_uuidBaseDoc',
    '00007198$_uuidBaseStd',
    '00007198$_uuidBaseDoc',
  }.map((e) => e.toLowerCase()).toSet();

  static final Set<String> _characteristicUuidCandidates = {
    '00007198$_uuidBaseStd',
    '00007198$_uuidBaseDoc',
  }.map((e) => e.toLowerCase()).toSet();

  static const int _cmdLogin = 0x00;
  static const int _cmdUp = 0x02;
  static const int _cmdDown = 0x03;
  static const int _cmdGetStatus = 0x05;
  static const int _cmdGetVersion = 0x07;
  static const int _cmdGetLimit = 0x0D;
  static const int _cmdReboot = 0x0F;
  static const int _cmdStateReport = 0x41;

  static const Map<int, int?> _expectResponse = {
    _cmdLogin: 0x80,
    _cmdUp: 0x82,
    _cmdDown: 0x83,
    _cmdGetStatus: 0x85,
    _cmdGetVersion: 0x87,
    _cmdGetLimit: 0x8D,
    _cmdReboot: null,
  };

  static const Map<int, String> _ackCodes = {
    0: '성공',
    1: '실패',
    2: '데이터 길이 오류',
    3: '장치 주소 오류',
    4: '명령 코드 오류',
    5: '체크섬(XOR) 오류',
    6: '모터 동작 중',
    7: '파라미터 설정 실패',
    8: '요청 방향 한계(리미트) 도달',
    9: '리미트(한계) 이상',
    10: '모터 타임아웃',
    13: '배터리 부족',
    14: '락 위에 차량 존재',
    15: '미로그인/권한 없음',
    255: '통신 타임아웃',
  };

  final FlutterReactiveBle _ble;
  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  final Map<int, Completer<BleFrame>> _pendingResponses =
      <int, Completer<BleFrame>>{};
  final Queue<BleFrame> _statusQueue = Queue<BleFrame>();

  StreamSubscription<ConnectionStateUpdate>? _connectionSub;
  StreamSubscription<List<int>>? _notifySub;

  QualifiedCharacteristic? _writeCharacteristic;
  QualifiedCharacteristic? _notifyCharacteristic;
  bool _writeWithoutResponse = true;

  String? _deviceId;
  String? _deviceName;
  int? _lockId;
  String _lockEndian = 'big';
  int _pwPad = 0xFF;
  bool _isConnected = false;

  Stream<String> get logs => _logController.stream;
  bool get isConnected => _isConnected;
  String? get connectedDeviceName => _deviceName;
  int? get lockId => _lockId;

  Future<void> connectAndLogin({
    required String deviceId,
    String password = '123456',
  }) async {
    await _ensureRuntimePermissions();
    await disconnect();

    final target = await _scanAndPickDevice(deviceId);
    _deviceId = target.id;
    _deviceName = target.name;

    await _connect(target);
    await _resolveCharacteristics();
    await _startNotify();

    final parsedLockId = _parseLockId(target.name) ?? _parseLockId(deviceId);
    if (parsedLockId == null) {
      throw const BleOperationException(
        'lock_id를 추출하지 못했습니다. device_id에 숫자를 포함해 주세요. (예: device-001)',
      );
    }
    _lockId = parsedLockId;

    final normalizedPassword = password.trim().isEmpty
        ? '123456'
        : password.trim();
    final loginOk = await _loginVariantSearch(normalizedPassword);
    if (!loginOk) {
      throw const BleOperationException(
        '로그인 변형 탐색(big/little + FF/00) 모두 실패했습니다.',
      );
    }

    _emitLog(
      '로그인 성공: lock_id=$_lockId, endian=$_lockEndian, pw_pad=0x${_pwPad.toRadixString(16).padLeft(2, '0').toUpperCase()}',
    );
  }

  Future<AckResult> armUp() =>
      _sendAckCommand(_cmdUp, timeout: const Duration(seconds: 3));

  Future<AckResult> armDown() =>
      _sendAckCommand(_cmdDown, timeout: const Duration(seconds: 3));

  Future<String> readVersion() async {
    final frame = await _writeAndWaitResponse(
      _cmdGetVersion,
      timeout: const Duration(seconds: 4),
    );
    if (frame == null) {
      throw const BleOperationException('버전 조회 응답이 없습니다.');
    }

    if (frame.data.length == 1) {
      return decodeAckPayload(frame.data);
    }
    return decodeVersionPayload(frame.data);
  }

  Future<String> readLimit() async {
    final frame = await _writeAndWaitResponse(
      _cmdGetLimit,
      timeout: const Duration(seconds: 3),
    );
    if (frame == null) {
      throw const BleOperationException('리미트 조회 응답이 없습니다.');
    }

    if (frame.data.length == 1) {
      return decodeAckPayload(frame.data);
    }
    return decodeLimitPayload(frame.data);
  }

  Future<void> reboot() async {
    await _writeAndWaitResponse(_cmdReboot);
    _emitLog('재부팅 명령 전송 완료 (문서상 응답 없음)');
  }

  Future<StatusSnapshot> requestStatusSnapshot({
    Duration window = const Duration(seconds: 3),
    int settleConsecutive = 2,
  }) async {
    _statusQueue.clear();
    await _writeCommand(_cmdGetStatus);

    final deadline = DateTime.now().add(window);
    BleFrame? lastFrame;
    int? lastBit0;
    int? stable;
    var consecutive = 0;
    var samples = 0;

    while (DateTime.now().isBefore(deadline)) {
      if (_statusQueue.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        continue;
      }

      final frame = _statusQueue.removeFirst();
      lastFrame = frame;
      samples++;

      final bit0 = armStateFromFrame(frame);
      if (bit0 == null) {
        continue;
      }

      if (bit0 == lastBit0) {
        consecutive += 1;
      } else {
        lastBit0 = bit0;
        consecutive = 1;
      }

      if (consecutive >= settleConsecutive) {
        stable = bit0;
        break;
      }
    }

    stable ??= lastBit0;
    return StatusSnapshot(
      stableBit0: stable,
      lastFrame: lastFrame,
      samples: samples,
    );
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;

    await _connectionSub?.cancel();
    _connectionSub = null;

    _failPending('BLE 연결이 종료되었습니다.');
    _statusQueue.clear();

    _writeCharacteristic = null;
    _notifyCharacteristic = null;
    _writeWithoutResponse = true;
    _isConnected = false;
    _deviceId = null;
    _deviceName = null;
    _lockId = null;
    _lockEndian = 'big';
    _pwPad = 0xFF;
  }

  Future<void> dispose() async {
    await disconnect();
    await _logController.close();
  }

  Future<void> _ensureRuntimePermissions() async {
    if (!Platform.isAndroid) {
      return;
    }

    final requested = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.phone,
    ].request();

    final denied = requested.entries
        .where((entry) => !entry.value.isGranted && !entry.value.isLimited)
        .map((entry) => entry.key.toString())
        .toList();

    if (denied.isNotEmpty) {
      throw BleOperationException('BLE 권한이 필요합니다: ${denied.join(', ')}');
    }
  }

  Future<DiscoveredDevice> _scanAndPickDevice(
    String deviceId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final completer = Completer<DiscoveredDevice>();
    final candidates = _buildNameCandidates(deviceId);

    _emitLog('스캔 시작: device_id=$deviceId');

    final scanSubscription = _ble
        .scanForDevices(
          withServices: const <Uuid>[],
          scanMode: ScanMode.lowLatency,
        )
        .listen(
          (device) {
            if (_isTargetDevice(device, deviceId, candidates)) {
              if (!completer.isCompleted) {
                _emitLog(
                  '대상 발견: ${device.name} (${device.id}) RSSI=${device.rssi}',
                );
                completer.complete(device);
              }
            }
          },
          onError: (Object error) {
            if (!completer.isCompleted) {
              completer.completeError(BleOperationException('스캔 실패: $error'));
            }
          },
        );

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw BleOperationException(
          '스캔 시간 초과: device_id=$deviceId 에 해당하는 BLE 기기를 찾지 못했습니다.',
        ),
      );
    } finally {
      await scanSubscription.cancel();
    }
  }

  bool _isTargetDevice(
    DiscoveredDevice device,
    String deviceId,
    Set<String> candidates,
  ) {
    final name = device.name.trim();
    if (name.isEmpty) {
      return false;
    }

    final lowerName = name.toLowerCase();
    for (final candidate in candidates) {
      if (lowerName.contains(candidate)) {
        return true;
      }
    }

    final lockFromName = _parseLockId(name);
    final lockFromDeviceId = _parseLockId(deviceId);
    return lockFromName != null &&
        lockFromDeviceId != null &&
        lockFromName == lockFromDeviceId;
  }

  Set<String> _buildNameCandidates(String deviceId) {
    final clean = deviceId.trim();
    final candidates = <String>{clean.toLowerCase()};

    final lock = _parseLockId(clean);
    if (lock != null) {
      candidates.add('pl${lock.toString().padLeft(10, '0')}');
      candidates.add('pl$lock');
    }

    return candidates;
  }

  int? _parseLockId(String text) {
    final fromPl = RegExp(
      r'PL(\d{1,12})',
      caseSensitive: false,
    ).firstMatch(text);
    if (fromPl != null) {
      return int.tryParse(fromPl.group(1)!);
    }

    final fromAnyNumber = RegExp(r'(\d{1,12})').firstMatch(text);
    if (fromAnyNumber != null) {
      return int.tryParse(fromAnyNumber.group(1)!);
    }

    return null;
  }

  Future<void> _connect(DiscoveredDevice target) async {
    final connectReady = Completer<void>();

    _connectionSub = _ble
        .connectToDevice(
          id: target.id,
          connectionTimeout: const Duration(seconds: 12),
        )
        .listen(
          (update) {
            switch (update.connectionState) {
              case DeviceConnectionState.connected:
                _isConnected = true;
                if (!connectReady.isCompleted) {
                  connectReady.complete();
                }
                _emitLog('BLE 연결 완료: ${target.name} (${target.id})');
                break;
              case DeviceConnectionState.disconnected:
                final wasConnected = _isConnected;
                _isConnected = false;
                _failPending('BLE 연결이 끊어졌습니다.');
                if (wasConnected) {
                  _emitLog('BLE 연결 해제됨');
                }
                if (!connectReady.isCompleted) {
                  connectReady.completeError(
                    const BleOperationException('BLE 연결 실패: disconnected'),
                  );
                }
                break;
              default:
                _emitLog('BLE 상태: ${update.connectionState.name}');
                break;
            }
          },
          onError: (Object error) {
            _isConnected = false;
            _failPending('BLE 연결 오류: $error');
            if (!connectReady.isCompleted) {
              connectReady.completeError(
                BleOperationException('BLE 연결 오류: $error'),
              );
            }
          },
        );

    await connectReady.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw const BleOperationException('BLE 연결 타임아웃'),
    );
  }

  Future<void> _resolveCharacteristics() async {
    final deviceId = _deviceId;
    if (deviceId == null) {
      throw const BleOperationException('연결된 deviceId가 없습니다.');
    }

    await _ble.discoverAllServices(deviceId);
    final services = await _ble.getDiscoveredServices(deviceId);

    QualifiedCharacteristic? preferredNotify;
    QualifiedCharacteristic? fallbackNotify;

    QualifiedCharacteristic? preferredWrite;
    Characteristic? preferredWriteRaw;
    QualifiedCharacteristic? fallbackWrite;
    Characteristic? fallbackWriteRaw;

    for (final service in services) {
      final serviceUuid = service.id.toString().toLowerCase();
      final preferredService = _serviceUuidCandidates.contains(serviceUuid);

      for (final characteristic in service.characteristics) {
        final charUuid = characteristic.id.toString().toLowerCase();
        final preferredChar = _characteristicUuidCandidates.contains(charUuid);

        final qualified = QualifiedCharacteristic(
          characteristicId: characteristic.id,
          serviceId: service.id,
          deviceId: deviceId,
        );

        if (characteristic.isNotifiable) {
          if (preferredNotify == null && preferredService && preferredChar) {
            preferredNotify = qualified;
          }
          fallbackNotify ??= qualified;
        }

        final writable =
            characteristic.isWritableWithoutResponse ||
            characteristic.isWritableWithResponse;
        if (writable) {
          if (preferredWrite == null && preferredService && preferredChar) {
            preferredWrite = qualified;
            preferredWriteRaw = characteristic;
          }
          fallbackWrite ??= qualified;
          fallbackWriteRaw ??= characteristic;
        }
      }
    }

    _notifyCharacteristic = preferredNotify ?? fallbackNotify;
    _writeCharacteristic = preferredWrite ?? fallbackWrite;

    final selectedWriteRaw = preferredWriteRaw ?? fallbackWriteRaw;
    _writeWithoutResponse = selectedWriteRaw?.isWritableWithoutResponse ?? true;

    if (_notifyCharacteristic == null) {
      throw const BleOperationException('Notify 특성을 찾지 못했습니다.');
    }
    if (_writeCharacteristic == null) {
      throw const BleOperationException('Write 특성을 찾지 못했습니다.');
    }

    _emitLog('notify_uuid=${_notifyCharacteristic!.characteristicId}');
    _emitLog('write_uuid=${_writeCharacteristic!.characteristicId}');
  }

  Future<void> _startNotify() async {
    final notifyCharacteristic = _notifyCharacteristic;
    if (notifyCharacteristic == null) {
      throw const BleOperationException('Notify 특성이 초기화되지 않았습니다.');
    }

    _notifySub = _ble
        .subscribeToCharacteristic(notifyCharacteristic)
        .listen(
          _handleNotify,
          onError: (Object error) {
            _emitLog('Notify 오류: $error');
          },
        );
  }

  void _handleNotify(List<int> raw) {
    final frame = BleFrame.parse(raw);
    if (frame == null) {
      _emitLog('[RX] parse 실패: ${toHex(raw)}');
      return;
    }

    _emitLog(
      '[RX] cmd=0x${frame.cmd.toRadixString(16).padLeft(2, '0').toUpperCase()} data=${toHex(frame.data)}',
    );

    if (frame.baseCmd == _cmdStateReport && !frame.isResponse) {
      _statusQueue.add(frame);
      _emitLog(decodeStatusPayload(frame.data));
      unawaited(_sendStateReportAck());
      return;
    }

    final completer = _pendingResponses.remove(frame.cmd);
    if (completer != null && !completer.isCompleted) {
      completer.complete(frame);
    }
  }

  Future<void> _sendStateReportAck() async {
    try {
      final ackCmd = _cmdStateReport | 0x80;
      await _writeRaw(BleFrame.build(ackCmd, const <int>[0x00]));
    } catch (error) {
      _emitLog('상태보고 ACK 실패: $error');
    }
  }

  Future<AckResult> _sendAckCommand(
    int cmd, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final frame = await _writeAndWaitResponse(cmd, timeout: timeout);
    if (frame == null || frame.data.isEmpty) {
      throw BleOperationException(
        '명령 응답이 비어 있습니다. cmd=0x${cmd.toRadixString(16)}',
      );
    }

    final ack = frame.data.first;
    return AckResult(
      ack: ack,
      description: decodeAckPayload(frame.data),
      frame: frame,
    );
  }

  Future<bool> _loginVariantSearch(String password) async {
    final lockId = _lockId;
    if (lockId == null) {
      throw const BleOperationException('lock_id가 없습니다.');
    }

    final variants = <({String endian, int pad})>[
      (endian: 'big', pad: 0xFF),
      (endian: 'little', pad: 0xFF),
      (endian: 'big', pad: 0x00),
      (endian: 'little', pad: 0x00),
    ];

    for (final variant in variants) {
      _lockEndian = variant.endian;
      _pwPad = variant.pad;

      _emitLog(
        '로그인 시도: lock_endian=${variant.endian}, pw_pad=0x${variant.pad.toRadixString(16).padLeft(2, '0').toUpperCase()}',
      );

      final ack = await _loginOnce(lockId, password);
      if (ack == 0) {
        return true;
      }

      _emitLog(
        '로그인 실패: ack=0x${(ack ?? -1).toRadixString(16).toUpperCase()} ${_ackCodes[ack] ?? ''}'
            .trim(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    return false;
  }

  Future<int?> _loginOnce(int lockId, String password) async {
    final payload = <int>[
      ..._encodeLockId(lockId, _lockEndian),
      ..._encodePassword(password, _pwPad),
    ];

    final frame = await _writeAndWaitResponse(
      _cmdLogin,
      data: payload,
      timeout: const Duration(seconds: 4),
    );

    if (frame == null || frame.data.isEmpty) {
      return null;
    }

    return frame.data.first;
  }

  Future<BleFrame?> _writeAndWaitResponse(
    int cmd, {
    List<int> data = const <int>[],
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final expected = _expectResponse[cmd];
    Completer<BleFrame>? completer;

    if (expected != null) {
      if (_pendingResponses.containsKey(expected)) {
        throw const BleOperationException('이전 응답이 아직 대기 중입니다.');
      }
      completer = Completer<BleFrame>();
      _pendingResponses[expected] = completer;
    }

    try {
      await _writeCommand(cmd, data);
      if (completer == null) {
        return null;
      }

      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw BleOperationException(
          '응답 타임아웃: cmd=0x${cmd.toRadixString(16).toUpperCase()}',
        ),
      );
    } finally {
      if (expected != null) {
        _pendingResponses.remove(expected);
      }
    }
  }

  Future<void> _writeCommand(int cmd, [List<int> data = const <int>[]]) async {
    final frame = BleFrame.build(cmd, data);
    await _writeRaw(frame);
    _emitLog(
      '[TX] cmd=0x${cmd.toRadixString(16).padLeft(2, '0').toUpperCase()} frame=${toHex(frame)}',
    );
  }

  Future<void> _writeRaw(Uint8List frame) async {
    final characteristic = _writeCharacteristic;
    if (!_isConnected || characteristic == null) {
      throw const BleOperationException('BLE가 연결되지 않았습니다.');
    }

    if (_writeWithoutResponse) {
      await _ble.writeCharacteristicWithoutResponse(
        characteristic,
        value: frame,
      );
    } else {
      await _ble.writeCharacteristicWithResponse(characteristic, value: frame);
    }
  }

  Uint8List _encodeLockId(int lockId, String endian) {
    final data = ByteData(4);
    data.setUint32(0, lockId, endian == 'little' ? Endian.little : Endian.big);
    return data.buffer.asUint8List();
  }

  Uint8List _encodePassword(String password, int pad) {
    final asciiBytes = ascii.encode(password);
    final trimmed = asciiBytes.length > 8
        ? asciiBytes.sublist(0, 8)
        : asciiBytes;

    if (trimmed.length == 8) {
      return Uint8List.fromList(trimmed);
    }

    return Uint8List.fromList(<int>[
      ...trimmed,
      ...List<int>.filled(8 - trimmed.length, pad),
    ]);
  }

  int? armStateFromFrame(BleFrame frame) {
    if (frame.data.length < 3) {
      return null;
    }

    final lockState = frame.data[2];
    return (lockState & 1) == 1 ? 1 : 0;
  }

  String decodeAckPayload(Uint8List payload) {
    if (payload.isEmpty) {
      return '(payload 없음)';
    }

    final ack = payload[0];
    return 'ack=0x${ack.toRadixString(16).padLeft(2, '0').toUpperCase()}(${_ackCodes[ack] ?? '?'}) raw=${toHex(payload)}';
  }

  String decodeStatusPayload(Uint8List payload) {
    if (payload.length < 5) {
      return '(상태 payload 길이 부족: ${payload.length}B) raw=${toHex(payload)}';
    }

    final statusWord = payload[0] | (payload[1] << 8);
    final lockState = payload[2];
    final battery = payload[3];
    final signal4g = payload[4];

    final arm = (lockState & 1) == 1 ? 'ARM_DOWN(해제)' : 'ARM_UP(잠금)';

    return 'status_word=0x${statusWord.toRadixString(16).padLeft(4, '0').toUpperCase()}, '
        'lock_state=0x${lockState.toRadixString(16).padLeft(2, '0').toUpperCase()} -> $arm, '
        'battery=$battery%, 4G=$signal4g';
  }

  String decodeVersionPayload(Uint8List payload) {
    if (payload.length < 9) {
      return '(버전 payload 길이 부족: ${payload.length}B) raw=${toHex(payload)}';
    }

    final ack = payload[0];
    final hw = _toUint32LE(payload, 1);
    final fw = _toUint32LE(payload, 5);

    return 'ack=0x${ack.toRadixString(16).padLeft(2, '0').toUpperCase()}(${_ackCodes[ack] ?? '?'}) '
        'HW=${_splitVersion(hw)} FW=${_splitVersion(fw)} raw=${toHex(payload)}';
  }

  String decodeLimitPayload(Uint8List payload) {
    if (payload.length < 2) {
      return '(limit payload 길이 부족: ${payload.length}B) raw=${toHex(payload)}';
    }

    final ack = payload[0];
    final state = payload[1];
    final meaning = state == 0x20 ? '정상' : '알 수 없음';
    return 'ack=0x${ack.toRadixString(16).padLeft(2, '0').toUpperCase()}(${_ackCodes[ack] ?? '?'}) '
        'limit_state=0x${state.toRadixString(16).padLeft(2, '0').toUpperCase()}($meaning) raw=${toHex(payload)}';
  }

  int _toUint32LE(Uint8List bytes, int offset) {
    final data = ByteData.sublistView(bytes, offset, offset + 4);
    return data.getUint32(0, Endian.little);
  }

  String _splitVersion(int value) {
    final major = value ~/ 1000000;
    final minor = (value % 1000000) ~/ 100000;
    final build = value % 100000;
    return '$major.$minor.$build';
  }

  void _emitLog(String message) {
    if (!_logController.isClosed) {
      _logController.add(message);
    }
  }

  void _failPending(String reason) {
    for (final entry in _pendingResponses.entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(BleOperationException(reason));
      }
    }
    _pendingResponses.clear();
  }
}

class AckResult {
  const AckResult({required this.ack, required this.description, this.frame});

  final int ack;
  final String description;
  final BleFrame? frame;

  bool get isSuccess => ack == 0;
}

class StatusSnapshot {
  const StatusSnapshot({
    required this.stableBit0,
    required this.lastFrame,
    required this.samples,
  });

  final int? stableBit0;
  final BleFrame? lastFrame;
  final int samples;

  String get armDescription {
    if (stableBit0 == null) {
      return 'UNKNOWN';
    }
    return stableBit0 == 1 ? 'ARM_DOWN(해제)' : 'ARM_UP(잠금)';
  }
}

class BleOperationException implements Exception {
  const BleOperationException(this.message);

  final String message;

  @override
  String toString() => message;
}
