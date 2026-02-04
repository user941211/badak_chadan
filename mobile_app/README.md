# Badak Chadan Flutter Mobile

Flutter 3.32.0 템플릿 기준으로 만든 BLE 제어 앱입니다.

## 핵심 동작

1. 앱 시작/연결 시 로컬 저장소(`shared_preferences`)에서 `device_id + assigned_period`를 확인합니다.
2. 로컬 정보가 있고 **현재 날짜가 assigned_period 범위 안**이면 해당 `device_id`로 BLE 연결을 시도합니다.
3. 로컬 정보가 없거나 기간 만료면 `.env`의 `API_BASE_URL`로 `POST /mobile/device-by-phone`를 호출합니다.
4. API 응답의 `device_id`가 1개면 자동 저장 후 **즉시 BLE 연결**합니다.
5. `device_id`가 2개 이상이면 앱에서 장치 박스를 선택한 뒤 `선택 장치 연결`로 진행합니다.
6. `갱신하기` 버튼으로 기간이 남아 있어도 전화번호 재인증 후 최신 할당 정보를 다시 받아올 수 있습니다.

```json
{
  "exists": true,
  "message": "Phone number found",
  "device_id": "device-001",
  "assigned_period": "2026-02-01~2026-12-31"
}
```

> `assigned_period` 밖의 날짜면 저장하지 않고 연결도 진행하지 않습니다.

## BLE 구현 내용 (Python 포팅)

- 프레임 인코딩/파싱 (length/cmd/data/xor)
- 로그인 변형 탐색: `(big/little endian) x (FF/00 pad)`
- 명령 지원: 올림(잠금), 내림(해제), 상태조회, 버전조회, 리미트조회, 재부팅
- 상태보고(0x41) Notify 수신 + 자동 ACK 전송
- 상태 스냅샷 안정화 판정(연속 2회 동일 bit0)
- BLE 비밀번호 입력 UI 제거, 기본 비밀번호 `123456` 사용

## 권한

- 블루투스: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`
- 전화: `READ_PHONE_STATE`, `READ_PHONE_NUMBERS` (Android 권한 요청)

## 실행

```bash
cd mobile_app
cp .env.example .env
# API_BASE_URL 값을 FastAPI 주소로 변경
flutter pub get
flutter run
```

## 환경변수

`.env`

```dotenv
API_BASE_URL=http://127.0.0.1:8000
```
