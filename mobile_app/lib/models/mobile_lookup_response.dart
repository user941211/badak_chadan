import 'package:mobile_app/models/device_assignment.dart';

class MobileLookupResponse {
  MobileLookupResponse({
    required this.exists,
    required this.message,
    this.deviceId,
    this.assignedPeriod,
    this.assignments = const <DeviceAssignment>[],
  });

  final bool exists;
  final String message;
  final String? deviceId;
  final String? assignedPeriod;
  final List<DeviceAssignment> assignments;

  factory MobileLookupResponse.fromJson(Map<String, dynamic> json) {
    final parsedAssignments = <DeviceAssignment>[];

    void addFromPair(String? id, String? period) {
      final assignment = DeviceAssignment.fromApi(
        deviceId: id,
        assignedPeriod: period,
      );
      if (assignment != null) {
        parsedAssignments.add(assignment);
      }
    }

    void addFromObject(Map<String, dynamic> map) {
      addFromPair(
        (map['device_id'] as String?)?.trim(),
        (map['assigned_period'] as String?)?.trim(),
      );
    }

    void addFromListField(String field) {
      final value = json[field];
      if (value is! List) {
        return;
      }
      for (final item in value) {
        if (item is Map<String, dynamic>) {
          addFromObject(item);
        }
      }
    }

    addFromListField('devices');
    addFromListField('device_list');
    addFromListField('assignments');
    addFromListField('results');

    final rawDeviceId = json['device_id'];
    final rawAssignedPeriod = json['assigned_period'];

    if (rawDeviceId is String) {
      addFromPair(rawDeviceId.trim(), (rawAssignedPeriod as String?)?.trim());
    } else if (rawDeviceId is List) {
      final ids = rawDeviceId.whereType<String>().map((e) => e.trim()).toList();
      final periods = rawAssignedPeriod is List
          ? rawAssignedPeriod.whereType<String>().map((e) => e.trim()).toList()
          : <String>[];
      for (var i = 0; i < ids.length; i++) {
        final period = i < periods.length ? periods[i] : null;
        addFromPair(ids[i], period);
      }
    }

    final deduped = <DeviceAssignment>[];
    final seen = <String>{};
    for (final item in parsedAssignments) {
      final key = '${item.deviceId}|${item.assignedPeriod}';
      if (seen.add(key)) {
        deduped.add(item);
      }
    }

    return MobileLookupResponse(
      exists: json['exists'] == true,
      message: (json['message'] as String?)?.trim() ?? '',
      deviceId: (json['device_id'] as String?)?.trim(),
      assignedPeriod: (json['assigned_period'] as String?)?.trim(),
      assignments: deduped,
    );
  }
}
