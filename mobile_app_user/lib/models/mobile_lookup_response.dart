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
    final topLevelStarted = json['is_started'] != false;

    void addFromPair(String? id, String? originId, String? period) {
      final assignment = DeviceAssignment.fromApi(
        deviceId: id,
        originId: originId,
        assignedPeriod: period,
      );
      if (assignment != null) {
        parsedAssignments.add(assignment);
      }
    }

    String? toStringOrNull(dynamic value) {
      if (value == null) {
        return null;
      }
      if (value is String) {
        final t = value.trim();
        return t.isEmpty ? null : t;
      }
      final t = value.toString().trim();
      return t.isEmpty ? null : t;
    }

    void addFromObject(Map<String, dynamic> map) {
      if (map['is_started'] == false) {
        return;
      }
      addFromPair(
        toStringOrNull(map['device_id']),
        toStringOrNull(map['origin_id']),
        toStringOrNull(map['assigned_period']),
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
    final rawOriginId = json['origin_id'];
    final rawAssignedPeriod = json['assigned_period'];

    if (rawDeviceId is String) {
      final splitIds = rawDeviceId
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      final splitOriginIds = (rawOriginId as String? ?? '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      final splitPeriods = (rawAssignedPeriod as String? ?? '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      if (splitIds.length > 1) {
        if (topLevelStarted) {
          for (var i = 0; i < splitIds.length; i++) {
            final originId = i < splitOriginIds.length
                ? splitOriginIds[i]
                : null;
            final period = i < splitPeriods.length ? splitPeriods[i] : null;
            addFromPair(splitIds[i], originId, period);
          }
        }
      } else {
        final originId = rawOriginId is String ? rawOriginId.trim() : null;
        final period = rawAssignedPeriod is String
            ? rawAssignedPeriod.trim()
            : null;
        addFromPair(rawDeviceId.trim(), originId, period);
      }
    } else if (rawDeviceId is List) {
      final ids = rawDeviceId.whereType<String>().map((e) => e.trim()).toList();
      final originIds = rawOriginId is List
          ? rawOriginId.whereType<String>().map((e) => e.trim()).toList()
          : <String>[];
      final periods = rawAssignedPeriod is List
          ? rawAssignedPeriod.whereType<String>().map((e) => e.trim()).toList()
          : <String>[];
      for (var i = 0; i < ids.length; i++) {
        final originId = i < originIds.length ? originIds[i] : null;
        final period = i < periods.length ? periods[i] : null;
        addFromPair(ids[i], originId, period);
      }
    }

    final deduped = <DeviceAssignment>[];
    final seen = <String>{};
    for (final item in parsedAssignments) {
      final key = '${item.deviceId}|${item.originId}|${item.assignedPeriod}';
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
