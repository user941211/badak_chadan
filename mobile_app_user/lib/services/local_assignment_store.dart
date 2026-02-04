import 'dart:convert';

import 'package:mobile_app/models/device_assignment.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalAssignmentStore {
  static const _assignmentKey = 'device_assignment';

  Future<DeviceAssignment?> readValidAssignment() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_assignmentKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final assignment = DeviceAssignment.fromJson(json);
      if (assignment == null || !assignment.isCurrentlyActive) {
        await prefs.remove(_assignmentKey);
        return null;
      }
      return assignment;
    } catch (_) {
      await prefs.remove(_assignmentKey);
      return null;
    }
  }

  Future<void> save(DeviceAssignment assignment) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_assignmentKey, jsonEncode(assignment.toJson()));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_assignmentKey);
  }
}
