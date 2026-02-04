# Badak Chadan Flutter Mobile User

Flutter 3.32.0 템플릿 기준으로 만든 BLE 제어 앱입니다.

## 핵심 동작

1. 앱 시작/연결 시 로컬 저장소(`shared_preferences`)에서 `device_id + assigned_period`를 확인합니다.
2. 로컬 정보가 있고 **현재 날짜가 assigned_period 범위 안**이면 해당 `device_id`로 BLE 연결을 시도합니다.
3. 로컬 정보가 없거나 기간 만료면 `.env`의 `API_BASE_URL`로 `POST /mobile/device-by-phone`를 호출합니다.
4. 이때 전화번호는 직접 입력하지 않고, 앱이 전화 권한을 요청한 뒤 단말/USIM 번호를 읽어 인증합니다.
5. 조회된 장치가 여러 개면 장치 박스를 탭하는 즉시 해당 장치로 연결을 시작합니다.
6. API 응답이 아래처럼 오고, 기간이 유효하면 로컬에 저장한 뒤 **즉시 BLE 연결**합니다.

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
- UI: 상단 BLE 연결 상태 박스 표시
- UI: 장치가 여러 개면 박스 탭 즉시 연결 (다른 박스 선택 시 기존 연결 종료 후 전환)
- UI: `위/아래` 원형 버튼은 세로(상하) 배치
- 인증: 전화번호 수동 입력 없이 전화 권한 기반 자동 인증
- 인증 UI는 저장된 할당 정보가 없을 때만 표시
- `갱신하기` 버튼으로 저장 정보가 있어도 재인증/재조회 가능
- BLE 비밀번호 입력 UI 제거, 연결 시 기본값 `123456` 자동 사용
- 할당 기간이 지나면 저장된 장치 정보/연결을 자동 정리
- `갱신하기` 결과에 장치가 없으면 기존 저장/연결 정보를 제거

## 권한

- 블루투스: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`
- 전화: `READ_PHONE_STATE`, `READ_PHONE_NUMBERS` (Android 권한 요청)

## 실행

```bash
cd mobile_app_user
cp .env.example .env
# API_BASE_URL 값을 FastAPI 주소로 변경
flutter pub get
flutter run
```

## 앱 아이콘 적용

아이콘 원본:
- `../parkee_icon_512.png`
- `../parkee_icon.ico`

아래 명령으로 Android/iOS/Web/Windows/macOS 런처 아이콘을 생성합니다.

```bash
cd mobile_app_user
flutter pub get
dart run flutter_launcher_icons
```

## 앱 이름 변경 방법

예시 이름: `Parkee User`

1) Android
- 파일: `android/app/src/main/AndroidManifest.xml`
- 수정: `<application android:label="mobile_app" ...>` 값을 원하는 앱 이름으로 변경
- 예: `android:label="Parkee User"`

2) iOS
- 파일: `ios/Runner/Info.plist`
- 수정 키:
  - `CFBundleDisplayName` (홈 화면에 보이는 이름)
  - `CFBundleName` (내부 번들 이름)
- 예:
  - `CFBundleDisplayName` -> `Parkee User`
  - `CFBundleName` -> `parkee_user`

3) Web(선택)
- 파일: `web/index.html`
- 수정:
  - `<title>mobile_app</title>`
  - `<meta name="apple-mobile-web-app-title" content="mobile_app">`

4) Flutter 타이틀(선택)
- 파일: `lib/main.dart`
- 수정: `MaterialApp(title: 'Badak Chadan Mobile User')`

변경 후 반영:

```bash
cd mobile_app_user
flutter clean
flutter pub get
flutter run
```

## 빌드

Android APK:

```bash
cd mobile_app_user
flutter build apk --release
```

Android App Bundle (Play Store):

```bash
cd mobile_app_user
flutter build appbundle --release
```

출력 경로:
- APK: `build/app/outputs/flutter-apk/app-release.apk`
- AAB: `build/app/outputs/bundle/release/app-release.aab`

## 환경변수

`.env`

```dotenv
API_BASE_URL=http://127.0.0.1:8000
```
