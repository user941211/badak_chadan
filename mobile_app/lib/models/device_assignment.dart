class DeviceAssignment {
  DeviceAssignment({
    required this.deviceId,
    required this.startDate,
    required this.endDate,
  });

  final String deviceId;
  final DateTime startDate;
  final DateTime endDate;

  String get assignedPeriod =>
      '${_formatDate(startDate)}~${_formatDate(endDate)}';

  bool get isCurrentlyActive {
    final today = _dateOnly(DateTime.now());
    return !today.isBefore(startDate) && !today.isAfter(endDate);
  }

  Map<String, dynamic> toJson() {
    return {'device_id': deviceId, 'assigned_period': assignedPeriod};
  }

  static DeviceAssignment? fromJson(Map<String, dynamic> json) {
    final deviceId = (json['device_id'] as String?)?.trim();
    final period = (json['assigned_period'] as String?)?.trim();
    return fromApi(deviceId: deviceId, assignedPeriod: period);
  }

  static DeviceAssignment? fromApi({
    required String? deviceId,
    required String? assignedPeriod,
  }) {
    final normalizedDeviceId = deviceId?.trim();
    final normalizedPeriod = assignedPeriod?.trim();

    if (normalizedDeviceId == null || normalizedDeviceId.isEmpty) {
      return null;
    }
    if (normalizedPeriod == null || normalizedPeriod.isEmpty) {
      return null;
    }

    final parsed = parseAssignedPeriod(normalizedPeriod);
    if (parsed == null) {
      return null;
    }

    return DeviceAssignment(
      deviceId: normalizedDeviceId,
      startDate: parsed.start,
      endDate: parsed.end,
    );
  }

  static ({DateTime start, DateTime end})? parseAssignedPeriod(String value) {
    final parts = value.split('~');
    if (parts.length != 2) {
      return null;
    }

    try {
      final start = _dateOnly(DateTime.parse(parts[0].trim()));
      final end = _dateOnly(DateTime.parse(parts[1].trim()));
      if (end.isBefore(start)) {
        return null;
      }
      return (start: start, end: end);
    } catch (_) {
      return null;
    }
  }

  static DateTime _dateOnly(DateTime dateTime) {
    return DateTime(dateTime.year, dateTime.month, dateTime.day);
  }

  static String _formatDate(DateTime dateTime) {
    final y = dateTime.year.toString().padLeft(4, '0');
    final m = dateTime.month.toString().padLeft(2, '0');
    final d = dateTime.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
