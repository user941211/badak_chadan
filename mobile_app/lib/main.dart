import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mobile_app/models/device_assignment.dart';
import 'package:mobile_app/services/ble_lock_service.dart';
import 'package:mobile_app/services/local_assignment_store.dart';
import 'package:mobile_app/services/mobile_api_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // .env가 없어도 앱은 실행하고, API 호출 시점에 명확한 오류를 보여준다.
  }

  runApp(const ParkingLockApp());
}

class ParkingLockApp extends StatelessWidget {
  const ParkingLockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Badak Chadan Mobile',
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
  final TextEditingController _phoneController = TextEditingController();

  final LocalAssignmentStore _store = LocalAssignmentStore();
  final MobileApiService _apiService = MobileApiService();
  final BleLockService _bleService = BleLockService();

  final List<String> _logs = <String>[];

  StreamSubscription<String>? _bleLogSubscription;
  DeviceAssignment? _assignment;
  List<DeviceAssignment> _selectableAssignments = <DeviceAssignment>[];
  int? _selectedAssignmentIndex;
  bool _busy = false;
  String _status = '대기 중';
  bool? _experimentalVoiceEnabled;

  @override
  void initState() {
    super.initState();

    _bleLogSubscription = _bleService.logs.listen((message) {
      _appendLog('[BLE] $message');
    });

    unawaited(_loadSavedAssignment());
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _bleLogSubscription?.cancel();
    _apiService.dispose();
    unawaited(_bleService.dispose());
    super.dispose();
  }

  Future<void> _loadSavedAssignment() async {
    final saved = await _store.readValidAssignment();
    if (!mounted) {
      return;
    }

    setState(() {
      _assignment = saved;
    });

    if (saved != null) {
      _appendLog(
        '저장된 device_id 사용 가능: ${saved.deviceId} (${saved.assignedPeriod})',
      );
    } else {
      _appendLog('저장된 device_id 없음 또는 기간 만료 -> 전화번호 조회 필요');
    }
  }

  Future<void> _runTask(Future<void> Function() task) async {
    if (_busy) {
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      await task();
    } catch (error) {
      _setStatus('오류 발생');
      _appendLog('[ERR] $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _connectFlow() async {
    await _runTask(() async {
      _setStatus('연결 준비 중...');

      DeviceAssignment? assignment = await _store.readValidAssignment();

      if (assignment != null) {
        _appendLog('로컬 저장된 device_id로 BLE 연결 시도: ${assignment.deviceId}');
      } else {
        assignment = await _lookupAssignmentAndMaybeSelect();
      }

      if (assignment == null) {
        return;
      }

      final resolvedAssignment = assignment;

      if (!mounted) {
        return;
      }

      setState(() {
        _assignment = resolvedAssignment;
      });

      _setStatus('BLE 연결 + 로그인 중...');
      await _bleService.connectAndLogin(deviceId: resolvedAssignment.deviceId);

      _setStatus('연결 완료');
      _appendLog(
        '연결 성공: device_id=${resolvedAssignment.deviceId}, lock_id=${_bleService.lockId}',
      );
    });
  }

  Future<DeviceAssignment?> _lookupAssignmentAndMaybeSelect() async {
    final phoneNumber = _phoneController.text.trim();
    if (phoneNumber.isEmpty) {
      throw const MobileApiException('전화번호를 먼저 입력해 주세요.');
    }

    _setStatus('전화번호로 device_id 조회 중...');
    final response = await _apiService.lookupByPhone(phoneNumber);
    _appendLog('API 응답: ${response.message}');

    if (!response.exists) {
      throw const MobileApiException('등록된 전화번호가 없습니다.');
    }

    final candidates = response.assignments
        .where((item) => item.isCurrentlyActive)
        .toList();

    if (candidates.isEmpty) {
      await _store.clear();
      throw const MobileApiException(
        '유효한 할당 정보가 없습니다. assigned_period를 확인해 주세요.',
      );
    }

    if (candidates.length == 1) {
      final only = candidates.first;
      await _store.save(only);
      setState(() {
        _assignment = only;
        _selectableAssignments = <DeviceAssignment>[];
        _selectedAssignmentIndex = null;
      });
      _appendLog('단일 장치 자동 선택: ${only.deviceId} (${only.assignedPeriod})');
      return only;
    }

    setState(() {
      _selectableAssignments = candidates;
      _selectedAssignmentIndex = null;
    });
    _setStatus('장치 선택 필요');
    _appendLog('조회 결과 ${candidates.length}개 장치 발견: 박스 선택 후 연결해 주세요.');
    return null;
  }

  Future<void> _connectSelectedAssignment() async {
    await _runTask(() async {
      final idx = _selectedAssignmentIndex;
      if (idx == null || idx < 0 || idx >= _selectableAssignments.length) {
        throw const MobileApiException('연결할 장치를 먼저 선택해 주세요.');
      }
      final selected = _selectableAssignments[idx];

      await _store.save(selected);
      setState(() {
        _assignment = selected;
      });

      _setStatus('BLE 연결 + 로그인 중...');
      await _bleService.connectAndLogin(deviceId: selected.deviceId);
      _setStatus('연결 완료');
      _appendLog('선택 연결 성공: device_id=${selected.deviceId}');
    });
  }

  Future<void> _refreshAssignment() async {
    await _runTask(() async {
      _setStatus('할당 정보 갱신 중...');
      final found = await _lookupAssignmentAndMaybeSelect();
      if (found != null) {
        _appendLog('갱신 완료: ${found.deviceId} (${found.assignedPeriod})');
      }
    });
  }

  Future<void> _clearSavedAssignment() async {
    await _runTask(() async {
      await _store.clear();
      if (!mounted) {
        return;
      }

      setState(() {
        _assignment = null;
        _selectableAssignments = <DeviceAssignment>[];
        _selectedAssignmentIndex = null;
      });

      _appendLog('로컬 저장 device_id 삭제 완료');
    });
  }

  Future<void> _disconnect() async {
    await _runTask(() async {
      await _bleService.disconnect();
      _setStatus('연결 해제');
      _appendLog('BLE 연결 해제 완료');
    });
  }

  Future<void> _armUp() async {
    await _runTask(() async {
      final result = await _bleService.armUp();
      _appendLog('올림 명령: ${result.description}');

      if (result.isSuccess) {
        final snapshot = await _bleService.requestStatusSnapshot(
          window: const Duration(seconds: 10),
          settleConsecutive: 2,
        );
        _appendSnapshot('올림 후 확인', snapshot);
      }
    });
  }

  Future<void> _armDown() async {
    await _runTask(() async {
      final result = await _bleService.armDown();
      _appendLog('내림 명령: ${result.description}');

      if (result.isSuccess) {
        final snapshot = await _bleService.requestStatusSnapshot(
          window: const Duration(seconds: 10),
          settleConsecutive: 2,
        );
        _appendSnapshot('내림 후 확인', snapshot);
      }
    });
  }

  Future<void> _statusSnapshot() async {
    await _runTask(() async {
      final snapshot = await _bleService.requestStatusSnapshot(
        window: const Duration(seconds: 3),
        settleConsecutive: 2,
      );
      _appendSnapshot('상태 조회', snapshot);
    });
  }

  Future<void> _readVersion() async {
    await _runTask(() async {
      final text = await _bleService.readVersion();
      _appendLog('버전 조회: $text');
    });
  }

  Future<void> _readLimit() async {
    await _runTask(() async {
      final text = await _bleService.readLimit();
      _appendLog('리미트 조회: $text');
    });
  }

  Future<void> _reboot() async {
    await _runTask(() async {
      await _bleService.reboot();
      _appendLog('재부팅 명령 전송 완료');
    });
  }

  Future<void> _voiceOnExperimental() async {
    await _runTask(() async {
      final result = await _bleService.setVoiceEnabledExperimental(true);
      _appendLog('음성 ON(실험): ${result.description}');
      if (!result.isSuccess || !mounted) {
        return;
      }
      setState(() {
        _experimentalVoiceEnabled = true;
      });
    });
  }

  Future<void> _voiceOffExperimental() async {
    await _runTask(() async {
      final result = await _bleService.setVoiceEnabledExperimental(false);
      _appendLog('음성 OFF(실험): ${result.description}');
      if (!result.isSuccess || !mounted) {
        return;
      }
      setState(() {
        _experimentalVoiceEnabled = false;
      });
    });
  }

  void _appendSnapshot(String title, StatusSnapshot snapshot) {
    final lastFrame = snapshot.lastFrame;
    final decoded = lastFrame == null
        ? '상태 프레임 없음'
        : _bleService.decodeStatusPayload(lastFrame.data);

    _appendLog(
      '$title -> arm=${snapshot.armDescription}, samples=${snapshot.samples}, $decoded',
    );
  }

  void _setStatus(String value) {
    if (!mounted) {
      return;
    }

    setState(() {
      _status = value;
    });
  }

  void _appendLog(String message) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');

    if (!mounted) {
      return;
    }

    setState(() {
      _logs.add('[$hh:$mm:$ss] $message');
      if (_logs.length > 300) {
        _logs.removeRange(0, _logs.length - 300);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final assignment = _assignment;

    return Scaffold(
      appBar: AppBar(title: const Text('Badak Chadan BLE Mobile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('상태: $_status'),
                  const SizedBox(height: 6),
                  Text('BLE 연결: ${_bleService.isConnected ? '연결됨' : '미연결'}'),
                  const SizedBox(height: 6),
                  Text(
                    assignment == null
                        ? '저장된 할당 정보 없음'
                        : '저장된 할당: ${assignment.deviceId} (${assignment.assignedPeriod})',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            enabled: !_busy,
            onSubmitted: (_) {
              if (!_busy) {
                unawaited(_connectFlow());
              }
            },
            decoration: const InputDecoration(
              labelText: '휴대폰 번호',
              hintText: '01012345678',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _connectFlow,
                  child: const Text('연결 시작'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _refreshAssignment,
                  child: const Text('갱신하기'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _clearSavedAssignment,
                  child: const Text('저장 정보 삭제'),
                ),
              ),
            ],
          ),
          if (_selectableAssignments.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '연결할 장치 선택 (${_selectableAssignments.length}개)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            InputDecorator(
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '장치 선택',
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _selectedAssignmentIndex,
                  hint: const Text('연결할 장치를 선택해 주세요'),
                  items: List<DropdownMenuItem<int>>.generate(
                    _selectableAssignments.length,
                    (index) {
                      final item = _selectableAssignments[index];
                      return DropdownMenuItem<int>(
                        value: index,
                        child: Text(
                          '${item.deviceId} (${item.assignedPeriod})',
                        ),
                      );
                    },
                  ),
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() {
                            _selectedAssignmentIndex = value;
                          });
                        },
                ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _connectSelectedAssignment,
              child: const Text('선택 장치 연결'),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: (!_busy && _bleService.isConnected) ? _armUp : null,
                child: const Text('올림(잠금)'),
              ),
              FilledButton.tonal(
                onPressed: (!_busy && _bleService.isConnected)
                    ? _armDown
                    : null,
                child: const Text('내림(해제)'),
              ),
              OutlinedButton(
                onPressed: (!_busy && _bleService.isConnected)
                    ? _statusSnapshot
                    : null,
                child: const Text('상태 조회'),
              ),
              OutlinedButton(
                onPressed: (!_busy && _bleService.isConnected)
                    ? _readVersion
                    : null,
                child: const Text('버전 조회'),
              ),
              OutlinedButton(
                onPressed: (!_busy && _bleService.isConnected)
                    ? _readLimit
                    : null,
                child: const Text('리미트 조회'),
              ),
              OutlinedButton(
                onPressed: (!_busy && _bleService.isConnected) ? _reboot : null,
                child: const Text('재부팅'),
              ),
              FilledButton.tonal(
                onPressed: (!_busy && _bleService.isConnected)
                    ? _voiceOnExperimental
                    : null,
                child: const Text('음성 ON(실험)'),
              ),
              FilledButton.tonal(
                onPressed: (!_busy && _bleService.isConnected)
                    ? _voiceOffExperimental
                    : null,
                child: const Text('음성 OFF(실험)'),
              ),
              OutlinedButton(
                onPressed: (!_busy && _bleService.isConnected)
                    ? _disconnect
                    : null,
                child: const Text('연결 해제'),
              ),
            ],
          ),
          if (_experimentalVoiceEnabled != null) ...[
            const SizedBox(height: 8),
            Text(
              '실험 음성 상태: ${_experimentalVoiceEnabled! ? 'ON' : 'OFF'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 12),
          Container(
            height: 300,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: _logs.isEmpty
                ? const Text('로그 없음')
                : ListView.builder(
                    itemCount: _logs.length,
                    itemBuilder: (context, index) => Text(_logs[index]),
                  ),
          ),
        ],
      ),
    );
  }
}
