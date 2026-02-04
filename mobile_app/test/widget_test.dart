import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/models/device_assignment.dart';

void main() {
  test('assigned_period 파싱', () {
    final assignment = DeviceAssignment.fromApi(
      deviceId: 'device-001',
      assignedPeriod: '2026-02-01~2026-12-31',
    );

    expect(assignment, isNotNull);
    expect(assignment!.deviceId, 'device-001');
    expect(assignment.assignedPeriod, '2026-02-01~2026-12-31');
  });
}
