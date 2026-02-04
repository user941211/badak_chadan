import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_app/models/mobile_lookup_response.dart';

class MobileApiService {
  MobileApiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<MobileLookupResponse> lookupByPhone(String phoneNumber) async {
    final normalizedPhone = phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
    if (normalizedPhone.isEmpty) {
      throw const MobileApiException('전화번호를 입력해 주세요.');
    }

    final baseUrl = _apiBaseUrl;
    final uri = Uri.parse('$baseUrl/mobile/device-by-phone');

    final response = await _client.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'phone_number': normalizedPhone}),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MobileApiException(
        'API 호출 실패: ${response.statusCode} ${response.reasonPhrase ?? ''}'
            .trim(),
      );
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const MobileApiException('API 응답 형식이 올바르지 않습니다.');
    }

    return MobileLookupResponse.fromJson(decoded);
  }

  String get _apiBaseUrl {
    final raw = dotenv.env['API_BASE_URL']?.trim() ?? '';
    if (raw.isEmpty) {
      throw const MobileApiException('.env의 API_BASE_URL 값이 비어 있습니다.');
    }
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  void dispose() {
    _client.close();
  }
}

class MobileApiException implements Exception {
  const MobileApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
