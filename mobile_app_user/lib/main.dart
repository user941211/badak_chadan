import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

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

  static const int _demoTapThreshold = 10;
  static const String _demoPassword = '123456789';
  static const String _demoPhoneNumber = '01057213321';

  List<DeviceAssignment> _availableAssignments = <DeviceAssignment>[];
  int? _selectedAssignmentIndex;

  bool _busy = false;
  bool _connecting = false;
  String _statusText = '미연결';
  _ActionType? _activeAction;
  int _bluetoothTapCount = 0;
  int _upSpinTrigger = 0;
  int _downSpinTrigger = 0;

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
      await _fetchAssignmentsForPhone(phoneNumber);
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

  Future<void> _lookupAssignmentsWithPhone(String phoneNumber) async {
    if (_busy) {
      return;
    }

    setState(() {
      _busy = true;
      _statusText = '테스트 인증 중';
    });

    try {
      await _fetchAssignmentsForPhone(phoneNumber);
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

  Future<void> _fetchAssignmentsForPhone(String phoneNumber) async {
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

    final saved = await _store.readValidAssignment();
    int? restoredIndex;
    if (saved != null) {
      final idx = candidates.indexWhere(
        (item) =>
            item.deviceId == saved.deviceId &&
            item.originId == saved.originId &&
            item.assignedPeriod == saved.assignedPeriod,
      );
      if (idx >= 0) {
        restoredIndex = idx;
      }
    }

    final selectedIndex = candidates.length == 1 ? 0 : restoredIndex;

    setState(() {
      _availableAssignments = candidates;
      _selectedAssignmentIndex = selectedIndex;
      _statusText = candidates.length == 1
          ? '장치 1개 확인됨'
          : (selectedIndex == null ? '장치 선택 필요' : '이전 선택 장치 복원됨');
    });

    if (candidates.length == 1) {
      await _selectDeviceAndConnect(
        0,
        forceReconnect: true,
        allowWhenBusy: true,
      );
      return;
    }

    if (selectedIndex != null) {
      await _selectDeviceAndConnect(selectedIndex, allowWhenBusy: true);
    }
  }

  void _handleBluetoothDemoTap() {
    if (_busy) {
      return;
    }

    _bluetoothTapCount += 1;
    if (_bluetoothTapCount < _demoTapThreshold) {
      return;
    }
    _bluetoothTapCount = 0;
    unawaited(_showDemoPasswordDialog());
  }

  Future<void> _showDemoPasswordDialog() async {
    final controller = TextEditingController();
    bool invalid = false;

    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('테스트 인증'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '비밀번호'),
                  ),
                  if (invalid)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        '비밀번호가 올바르지 않습니다.',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () {
                    if (controller.text.trim() == _demoPassword) {
                      Navigator.of(context).pop(true);
                      return;
                    }
                    setState(() {
                      invalid = true;
                    });
                  },
                  child: const Text('확인'),
                ),
              ],
            );
          },
        );
      },
    );

    if (accepted == true) {
      unawaited(_lookupAssignmentsWithPhone(_demoPhoneNumber));
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
    bool allowWhenBusy = false,
  }) async {
    if (_busy && !allowWhenBusy) {
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
        previous.originId != next.originId ||
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
              item.originId == current.originId &&
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
        deviceId: valid.originId,
        password: '123456',
      );
      _reconnectTimer?.cancel();

      String connectedStatus = '연결됨';
      try {
        final autoDownResult = await _bleService.armDown();
        connectedStatus = autoDownResult.isSuccess
            ? '연결됨 (자동 내림 완료)'
            : '연결됨 (자동 내림 응답 수신)';
      } catch (_) {
        connectedStatus = '연결됨 (자동 내림 실패)';
      }

      if (mounted) {
        setState(() {
          _statusText = connectedStatus;
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
      _upSpinTrigger += 1;
    });
    try {
      await Future.wait([
        _bleService.armUp(),
        Future<void>.delayed(const Duration(seconds: 1)),
      ]);
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
      _downSpinTrigger += 1;
    });
    try {
      await Future.wait([
        _bleService.armDown(),
        Future<void>.delayed(const Duration(seconds: 1)),
      ]);
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
    final screenWidth = MediaQuery.sizeOf(context).width;
    final iconTextGap = screenWidth * 0.02;

    return SafeArea(
      top: false,
      child: Card(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _handleBluetoothDemoTap,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      connected
                          ? Icons.bluetooth_connected
                          : Icons.bluetooth_disabled,
                      color: statusColor,
                    ),
                    SizedBox(width: iconTextGap),
                    const Text(
                      '블루투스',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    SizedBox(width: iconTextGap),
                  ],
                ),
              ),
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
    final screenHeight = MediaQuery.sizeOf(context).height;
    final contentGap = screenHeight * 0.014;

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
            SizedBox(height: contentGap),
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

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selectedIndex =
        _selectedAssignmentIndex != null &&
            _selectedAssignmentIndex! >= 0 &&
            _selectedAssignmentIndex! < _availableAssignments.length
        ? _selectedAssignmentIndex
        : null;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final panelWidth = constraints.maxWidth;
          final headerIconSize = panelWidth * 0.09;
          final headerGap = panelWidth * 0.026;
          final sectionGap = panelWidth * 0.03;
          final itemGap = panelWidth * 0.02;

          return Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: headerIconSize,
                      height: headerIconSize,
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.developer_board_rounded,
                        color: colorScheme.onPrimaryContainer,
                        size: headerIconSize * 0.58,
                      ),
                    ),
                    SizedBox(width: headerGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '연결 장치 선택',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '장치를 선택하면 자동으로 연결됩니다',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: panelWidth * 0.026,
                        vertical: panelWidth * 0.015,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${_availableAssignments.length}대',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSecondaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: sectionGap),
                InputDecorator(
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: panelWidth * 0.03,
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      isExpanded: true,
                      value: selectedIndex,
                      borderRadius: BorderRadius.circular(12),
                      hint: const Text('연결할 장치를 선택해 주세요'),
                      items: List<DropdownMenuItem<int>>.generate(
                        _availableAssignments.length,
                        (index) {
                          final item = _availableAssignments[index];
                          return DropdownMenuItem<int>(
                            value: index,
                            child: Row(
                              children: [
                                Icon(
                                  Icons.memory_rounded,
                                  size: panelWidth * 0.045,
                                  color: colorScheme.primary,
                                ),
                                SizedBox(width: itemGap),
                                Expanded(
                                  child: Text(
                                    '${item.deviceId} (${item.assignedPeriod})',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      onChanged: _busy
                          ? null
                          : (value) {
                              if (value == null) {
                                return;
                              }
                              unawaited(_selectDeviceAndConnect(value));
                            },
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildVerticalControls() {
    return Expanded(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 요청사항: 현재 대비 약 2배 크기로 키우되, 화면 높이를 넘지 않게 제한.
          const gapRatio = 0.04;
          const buttonRatio = 0.38;
          const sizeScale = 2.0;

          final gap = constraints.maxHeight * gapRatio;
          final preferred = constraints.maxHeight * buttonRatio * sizeScale;
          final maxByHeight = (constraints.maxHeight - gap) / 2;
          final diameter = math.min(preferred, maxByHeight);

          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CircleActionButton(
                  icon: Icons.keyboard_arrow_up_rounded,
                  color: const Color(0xFF00897B),
                  enabled: !_busy && _bleService.isConnected,
                  loading: _activeAction == _ActionType.up,
                  spinTrigger: _upSpinTrigger,
                  diameter: diameter,
                  onPressed: _armUp,
                ),
                SizedBox(height: gap),
                _CircleActionButton(
                  icon: Icons.keyboard_arrow_down_rounded,
                  color: const Color(0xFF00695C),
                  enabled: !_busy && _bleService.isConnected,
                  loading: _activeAction == _ActionType.down,
                  spinTrigger: _downSpinTrigger,
                  diameter: diameter,
                  onPressed: _armDown,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasStoredInfo = _availableAssignments.isNotEmpty;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final topGap = screenHeight * 0.017;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(height: topGap),
            if (!hasStoredInfo) _buildAuthCard(),
            _buildDeviceSelection(),
            _buildVerticalControls(),
            _buildFooterStatusCard(),
          ],
        ),
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
    required this.spinTrigger,
    required this.diameter,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final bool enabled;
  final bool loading;
  final int spinTrigger;
  final double diameter;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    final progressDiameter = diameter * 1.05;
    final iconSize = diameter * 0.39;
    final shadowColor = enabled
        ? Colors.black.withValues(alpha: 0.16)
        : Colors.black.withValues(alpha: 0.08);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: diameter,
          height: diameter,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (loading)
                SizedBox(
                  width: progressDiameter,
                  height: progressDiameter,
                  child: const CircularProgressIndicator(strokeWidth: 4),
                ),
              _OneTurnSpin(
                trigger: spinTrigger,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: shadowColor,
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                      elevation: 0,
                      backgroundColor: enabled
                          ? color
                          : const Color(0xFFB0BEC5),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: enabled ? () => unawaited(onPressed()) : null,
                    child: Icon(icon, size: iconSize),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OneTurnSpin extends StatefulWidget {
  const _OneTurnSpin({required this.trigger, required this.child});

  final int trigger;
  final Widget child;

  @override
  State<_OneTurnSpin> createState() => _OneTurnSpinState();
}

class _OneTurnSpinState extends State<_OneTurnSpin>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
  }

  @override
  void didUpdateWidget(covariant _OneTurnSpin oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger != widget.trigger) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(turns: _controller, child: widget.child);
  }
}
