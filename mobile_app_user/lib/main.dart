import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mobile_number/mobile_number.dart';
import 'package:mobile_app/models/device_assignment.dart';
import 'package:mobile_app/services/ble_lock_service.dart';
import 'package:mobile_app/services/local_assignment_store.dart';
import 'package:mobile_app/services/mobile_api_service.dart';
import 'package:permission_handler/permission_handler.dart';

enum _ActionType { up, down }

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // .env 로드 실패 시에도 앱은 실행하고 API 호출 시점에 오류를 보여준다.
  }
  runApp(const ParkingLockApp());
}

class ParkingLockApp extends StatelessWidget {
  const ParkingLockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Badak Chadan Mobile User',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00695C)),
        useMaterial3: true,
      ),
      home: const ParkingLockHomePage(),
    );
  }
}

class ParkingLockHomePage extends StatefulWidget {
  const ParkingLockHomePage({super.key});

  @override
  State<ParkingLockHomePage> createState() => _ParkingLockHomePageState();
}

class _ParkingLockHomePageState extends State<ParkingLockHomePage> {
  final LocalAssignmentStore _store = LocalAssignmentStore();
  final MobileApiService _apiService = MobileApiService();
  final BleLockService _bleService = BleLockService();

  List<DeviceAssignment> _availableAssignments = <DeviceAssignment>[];
  int? _selectedAssignmentIndex;

  bool _busy = false;
  bool _connecting = false;
  String _statusText = '미연결';
  _ActionType? _activeAction;

  Timer? _reconnectTimer;
  Timer? _expiryCheckTimer;

  @override
  void initState() {
    super.initState();
    _startExpiryWatcher();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _expiryCheckTimer?.cancel();
    _apiService.dispose();
    unawaited(_bleService.dispose());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final saved = await _store.readValidAssignment();
    if (!mounted || saved == null) {
      return;
    }

    setState(() {
      _availableAssignments = <DeviceAssignment>[saved];
      _selectedAssignmentIndex = 0;
    });
    _startReconnectLoop();
  }

  Future<void> _lookupAssignments() async {
    if (_busy) {
      return;
    }

    setState(() {
      _busy = true;
      _statusText = '권한 확인/전화번호 조회 중';
    });

    try {
      final phoneNumber = await _resolvePhoneNumberFromDevice();
      final response = await _apiService.lookupByPhone(phoneNumber);
      if (!response.exists) {
        await _clearAssignmentsAndConnection('등록된 장치가 없습니다.');
        return;
      }

      // Server's is_started filtering is already applied in parser.
      // Avoid extra client-date filtering here to reduce device clock variance issues.
      final candidates = response.assignments.toList();

      if (candidates.isEmpty) {
        await _clearAssignmentsAndConnection('유효한 장치 할당 정보가 없습니다.');
        return;
      }

      setState(() {
        _availableAssignments = candidates;
        _selectedAssignmentIndex = candidates.length == 1 ? 0 : null;
        _statusText = candidates.length == 1 ? '장치 1개 확인됨' : '장치 선택 필요';
      });

      if (candidates.length == 1) {
        await _selectDeviceAndConnect(0, forceReconnect: true);
      }
    } catch (error) {
      setState(() {
        _statusText = '인증 실패: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<String> _resolvePhoneNumberFromDevice() async {
    if (!Platform.isAndroid) {
      throw const MobileApiException('현재는 Android에서만 자동 전화번호 인증을 지원합니다.');
    }

    final permission = await Permission.phone.request();
    if (!permission.isGranted && !permission.isLimited) {
      throw const MobileApiException('전화번호 권한이 필요합니다.');
    }

    String? number = await MobileNumber.mobileNumber;

    number ??= await _readPhoneFromSimCards();
    final normalized = _normalizePhoneNumber(number ?? '');

    if (normalized.isEmpty) {
      throw const MobileApiException(
        '단말에서 전화번호를 읽지 못했습니다. (통신사/USIM 설정 확인 필요)',
      );
    }

    return normalized;
  }

  Future<String?> _readPhoneFromSimCards() async {
    try {
      final sims = await MobileNumber.getSimCards;
      if (sims == null || sims.isEmpty) {
        return null;
      }

      for (final sim in sims) {
        final normalized = _normalizePhoneNumber(sim.number ?? '');
        if (normalized.isNotEmpty) {
          return normalized;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  String _normalizePhoneNumber(String value) {
    var digits = value.replaceAll(RegExp(r'[^0-9]'), '');

    // Korean international prefix normalization:
    // +82 10xxxx -> 010xxxx
    if (digits.startsWith('0082')) {
      digits = digits.substring(4);
      if (!digits.startsWith('0')) {
        digits = '0$digits';
      }
    } else if (digits.startsWith('82')) {
      digits = digits.substring(2);
      if (!digits.startsWith('0')) {
        digits = '0$digits';
      }
    }

    return digits;
  }

  Future<void> _selectDeviceAndConnect(
    int index, {
    bool forceReconnect = false,
  }) async {
    if (_busy) {
      return;
    }
    if (index < 0 || index >= _availableAssignments.length) {
      return;
    }

    final next = _availableAssignments[index];
    final prevIndex = _selectedAssignmentIndex;
    final previous =
        prevIndex != null &&
            prevIndex >= 0 &&
            prevIndex < _availableAssignments.length
        ? _availableAssignments[prevIndex]
        : null;

    final changed =
        previous == null ||
        previous.deviceId != next.deviceId ||
        previous.assignedPeriod != next.assignedPeriod;
    if (!forceReconnect && !changed && _bleService.isConnected) {
      return;
    }

    setState(() {
      _busy = true;
      _selectedAssignmentIndex = index;
      _statusText = changed ? '선택 장치 전환 중' : '연결 재시도 준비 중';
    });

    try {
      await _store.save(next);
      _reconnectTimer?.cancel();

      if (_bleService.isConnected || _connecting) {
        await _bleService.disconnect();
      }

      if (mounted) {
        setState(() {
          _statusText = '연결 시도 중';
        });
      }

      _startReconnectLoop();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  void _startReconnectLoop() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_tryConnectOnce());
    });
    unawaited(_tryConnectOnce());
  }

  void _startExpiryWatcher() {
    _expiryCheckTimer?.cancel();
    _expiryCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_pruneExpiredAssignments());
    });
  }

  Future<void> _pruneExpiredAssignments() async {
    final active = _availableAssignments
        .where((item) => item.isCurrentlyActive)
        .toList();

    final listChanged = active.length != _availableAssignments.length;
    if (listChanged) {
      int? nextSelected;
      if (_selectedAssignmentIndex != null &&
          _selectedAssignmentIndex! >= 0 &&
          _selectedAssignmentIndex! < _availableAssignments.length) {
        final current = _availableAssignments[_selectedAssignmentIndex!];
        nextSelected = active.indexWhere(
          (item) =>
              item.deviceId == current.deviceId &&
              item.assignedPeriod == current.assignedPeriod,
        );
        if (nextSelected < 0) {
          nextSelected = active.isEmpty ? null : 0;
        }
      } else {
        nextSelected = active.isEmpty ? null : 0;
      }

      if (mounted) {
        setState(() {
          _availableAssignments = active;
          _selectedAssignmentIndex = nextSelected;
        });
      } else {
        _availableAssignments = active;
        _selectedAssignmentIndex = nextSelected;
      }
    }

    final stored = await _store.readValidAssignment();
    if (stored == null && (_bleService.isConnected || _connecting)) {
      await _bleService.disconnect();
      _reconnectTimer?.cancel();
      if (mounted) {
        setState(() {
          _statusText = '할당 기간 만료';
          if (_availableAssignments.isEmpty) {
            _selectedAssignmentIndex = null;
          }
        });
      } else {
        _statusText = '할당 기간 만료';
      }
    }
  }

  Future<void> _clearAssignmentsAndConnection(String status) async {
    await _store.clear();
    _reconnectTimer?.cancel();

    if (_bleService.isConnected || _connecting) {
      await _bleService.disconnect();
    }

    if (mounted) {
      setState(() {
        _availableAssignments = <DeviceAssignment>[];
        _selectedAssignmentIndex = null;
        _statusText = status;
      });
    } else {
      _availableAssignments = <DeviceAssignment>[];
      _selectedAssignmentIndex = null;
      _statusText = status;
    }
  }

  Future<void> _tryConnectOnce() async {
    if (_bleService.isConnected || _connecting) {
      if (_bleService.isConnected) {
        _reconnectTimer?.cancel();
        if (mounted) {
          setState(() {
            _statusText = '연결됨';
          });
        }
      }
      return;
    }

    final valid = await _store.readValidAssignment();
    if (valid == null) {
      _reconnectTimer?.cancel();
      if (!mounted) {
        return;
      }
      setState(() {
        _availableAssignments = <DeviceAssignment>[];
        _selectedAssignmentIndex = null;
        _statusText = '할당 기간 만료';
      });
      return;
    }

    _connecting = true;
    if (mounted) {
      setState(() {
        _statusText = '연결 시도 중';
      });
    }

    try {
      await _bleService.connectAndLogin(
        deviceId: valid.deviceId,
        password: '123456',
      );
      _reconnectTimer?.cancel();
      if (mounted) {
        setState(() {
          _statusText = '연결됨';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _statusText = '미연결 (재시도 대기)';
        });
      }
    } finally {
      _connecting = false;
    }
  }

  Future<void> _armUp() async {
    if (_busy || !_bleService.isConnected) {
      return;
    }
    setState(() {
      _busy = true;
      _activeAction = _ActionType.up;
    });
    try {
      await _bleService.armUp();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activeAction = null;
        });
      }
    }
  }

  Future<void> _armDown() async {
    if (_busy || !_bleService.isConnected) {
      return;
    }
    setState(() {
      _busy = true;
      _activeAction = _ActionType.down;
    });
    try {
      await _bleService.armDown();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activeAction = null;
        });
      }
    }
  }

  Widget _buildFooterStatusCard() {
    final connected = _bleService.isConnected;
    final statusColor = connected
        ? const Color(0xFF2E7D32)
        : const Color(0xFFC62828);

    return SafeArea(
      top: false,
      child: Card(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                connected
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
                color: statusColor,
              ),
              const SizedBox(width: 8),
              const Text('블루투스', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusText,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: statusColor),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => unawaited(_lookupAssignments()),
                icon: const Icon(Icons.refresh),
                label: const Text('갱신하기'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAuthCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            const Text(
              '휴대폰 번호를 직접 입력하지 않고 권한 허용 후 자동 인증합니다.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : () => unawaited(_lookupAssignments()),
                child: const Text('전화번호 인증'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceSelection() {
    if (_availableAssignments.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('연결 장치 선택', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ...List.generate(_availableAssignments.length, (index) {
              final item = _availableAssignments[index];
              final selected = _selectedAssignmentIndex == index;

              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                color: selected
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : null,
                child: ListTile(
                  onTap: _busy
                      ? null
                      : () {
                          unawaited(_selectDeviceAndConnect(index));
                        },
                  title: Text(item.deviceId),
                  subtitle: Text(item.assignedPeriod),
                  trailing: selected
                      ? Icon(
                          Icons.check_circle,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : const Icon(Icons.radio_button_unchecked),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildVerticalControls() {
    return Expanded(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _CircleActionButton(
              icon: Icons.keyboard_arrow_up_rounded,
              color: const Color(0xFF00897B),
              enabled: !_busy && _bleService.isConnected,
              loading: _activeAction == _ActionType.up,
              onPressed: _armUp,
            ),
            const SizedBox(height: 28),
            _CircleActionButton(
              icon: Icons.keyboard_arrow_down_rounded,
              color: const Color(0xFF00695C),
              enabled: !_busy && _bleService.isConnected,
              loading: _activeAction == _ActionType.down,
              onPressed: _armDown,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasStoredInfo = _availableAssignments.isNotEmpty;

    return Scaffold(
      body: Column(
        children: [
          const SizedBox(height: 14),
          if (!hasStoredInfo) _buildAuthCard(),
          _buildDeviceSelection(),
          _buildVerticalControls(),
          _buildFooterStatusCard(),
        ],
      ),
    );
  }
}

class _CircleActionButton extends StatelessWidget {
  const _CircleActionButton({
    required this.icon,
    required this.color,
    required this.enabled,
    required this.loading,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final bool enabled;
  final bool loading;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 160,
          height: 160,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (loading)
                const SizedBox(
                  width: 168,
                  height: 168,
                  child: CircularProgressIndicator(strokeWidth: 4),
                ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: EdgeInsets.zero,
                  elevation: enabled ? 8 : 0,
                  backgroundColor: enabled ? color : const Color(0xFFB0BEC5),
                  foregroundColor: Colors.white,
                ),
                onPressed: enabled ? () => unawaited(onPressed()) : null,
                child: Icon(icon, size: 62),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
