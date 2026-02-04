# FastAPI + SQLite Device API

## 실행

개발(핫 리로드):
```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

운영(서비스 실행):
```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

`python -m app.main`은 내부에서 `reload=True`로 실행되므로 개발용으로만 사용하세요.

## 다른 서버로 그대로 복사해서 운영하기 (체크리스트)

1. 프로젝트 폴더 전체를 새 서버로 복사합니다.
2. 기존 데이터를 유지하려면, 구 서버의 앱을 먼저 중지한 뒤 아래 파일을 함께 복사합니다.
   - `devices.db`
   - `devices.db-wal`
   - `devices.db-shm`
3. 새 서버에서 아래를 실행합니다.
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   python -m pip install -r requirements.txt
   python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```
4. 동작 확인:
   ```bash
   curl http://127.0.0.1:8000/
   ```
   응답이 `{"status":"ok"}`면 정상입니다.

## 서비스로 등록해서 자동 재시작하기

### Linux (systemd) 예시

`/etc/systemd/system/badak-chadan.service`:
```ini
[Unit]
Description=Badak Chadan FastAPI Server
After=network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/badak_chadan_server
ExecStart=/opt/badak_chadan_server/.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

적용:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now badak-chadan
sudo systemctl status badak-chadan
sudo journalctl -u badak-chadan -f
```

### macOS (launchd) 예시

`~/Library/LaunchAgents/com.badak.chadan.server.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>com.badak.chadan.server</string>
    <key>ProgramArguments</key>
    <array>
      <string>/Users/USERNAME/path/to/badak_chadan_server/.venv/bin/python</string>
      <string>-m</string>
      <string>uvicorn</string>
      <string>app.main:app</string>
      <string>--host</string><string>0.0.0.0</string>
      <string>--port</string><string>8000</string>
    </array>
    <key>WorkingDirectory</key><string>/Users/USERNAME/path/to/badak_chadan_server</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/badak_chadan.out.log</string>
    <key>StandardErrorPath</key><string>/tmp/badak_chadan.err.log</string>
  </dict>
</plist>
```

적용:
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.badak.chadan.server.plist
launchctl kickstart -k gui/$(id -u)/com.badak.chadan.server
launchctl print gui/$(id -u)/com.badak.chadan.server
```

서버 실행 후 접속 주소:
- 로컬(같은 PC): `http://127.0.0.1:8000/swagger`
- 내부망(같은 Wi-Fi/LAN): `http://<서버 내부망 IP>:8000/swagger`
- 외부망(인터넷): `http://<공인 IP>:8000/swagger`

웹 대시보드의 `API BASE URL`도 반드시 같은 포트(`:8000`)를 써야 합니다.
- 예: `http://192.168.0.55:8000`
- `:80`로 넣으면 다른 서비스로 접속되어 API가 동작하지 않습니다.

외부망 접속을 위해서는 아래가 필요합니다.
- 공유기/라우터 포트포워딩: `8000 -> 서버 내부망 IP:8000`
- 서버/OS 방화벽에서 `8000` 포트 허용
- (클라우드 사용 시) 보안 그룹/네트워크 ACL에서 `8000` 허용

DB 파일은 프로젝트 루트에 `devices.db`로 생성됩니다.

`database is locked`가 보이면:
- DB Browser 같은 외부 SQLite 툴의 편집 트랜잭션을 종료/닫기
- 중복 실행 중인 서버 프로세스를 정리 후 재시작
- 서버는 잠금 충돌 시 `503 (Database is busy. Please retry.)`를 반환하도록 되어 있음

## DB 스키마

- table: `device`
  - `device_id` (TEXT, PK)
  - `phone_number` (TEXT, nullable)
  - `assigned_period` (TEXT, nullable)
  - `parking_lot_name` (TEXT, nullable)
- table: `user`
  - `num_id` (INTEGER, PK, autoincrement)
  - `parking_lot_name` (TEXT, not null)
  - `id` (TEXT, unique, not null)
  - `pw` (TEXT, not null, password hash)

서버 시작 시 기본 사용자 1개를 자동 생성합니다(없을 때만):
- `id`: `master`
- `pw`: `silla01177!`
- `parking_lot_name`: `all`

운영 환경에서는 위 기본 계정 비밀번호를 즉시 변경(또는 계정 삭제 후 재생성)하세요.

## API

### 1) 휴대폰 번호로 장치 조회 (모바일)

`POST /mobile/device-by-phone`

Request:
```json
{
  "phone_number": "01012345678"
}
```

Response (단일 장치 매칭):
```json
{
  "exists": true,
  "message": "Phone number found",
  "devices": [
    {
      "device_id": "device-001",
      "assigned_period": "2026-02-01~2026-12-31",
      "is_started": true
    }
  ],
  "is_started": true,
  "device_id": "device-001",
  "assigned_period": "2026-02-01~2026-12-31"
}
```

Response (동일 전화번호가 여러 장치에 매칭):
```json
{
  "exists": true,
  "message": "Phone number found (2 devices, 1 not started)",
  "devices": [
    {
      "device_id": "device-001",
      "assigned_period": "2026-03-01~2026-12-31",
      "is_started": false
    },
    {
      "device_id": "device-002",
      "assigned_period": "2026-02-01~2026-12-31",
      "is_started": true
    }
  ],
  "is_started": true,
  "device_id": "device-001,device-002",
  "assigned_period": "2026-03-01~2026-12-31,2026-02-01~2026-12-31"
}
```

Not Found Response (status 200):
```json
{
  "exists": false,
  "message": "Phone number not found",
  "devices": [],
  "is_started": null,
  "device_id": null,
  "assigned_period": null
}
```

`devices` 배열에 매칭된 장치를 모두 반환합니다.
`is_started`는 매칭된 장치 중 하나라도 시작 상태면 `true`를 반환합니다.
`device_id`/`assigned_period`는 매칭된 장치 순서대로 `,`로 연결해 함께 반환합니다.
`assigned_period`의 시작일 포맷은 `YYYY-MM-DD`, `YYYY.MM.DD`, `YYYY/MM/DD`를 지원합니다.

### 2) 장치 전화번호 upsert (웹)

`PUT /web/device-phone`

Request:
```json
{
  "device_id": "device-001",
  "phone_number": "01012345678"
}
```

### 3) 장치 부여기간 upsert (웹)

`PUT /web/device-period`

Request:
```json
{
  "device_id": "device-001",
  "assigned_period": "2026-02-01~2026-12-31"
}
```

### 4) device_id 행 추가 API (웹)

`POST /web/device`

Request:
```json
{
  "device_id": "device-003"
}
```

이미 존재하는 `device_id`면 `409` 에러를 반환합니다.

### 5) 컬럼 delete API (웹)

- 전화번호 삭제: `DELETE /web/device-phone/{device_id}`
- 부여기간 삭제: `DELETE /web/device-period/{device_id}`

삭제는 row 자체를 지우지 않고 해당 column 값을 `null`로 만듭니다.

### 6) 행 전체 삭제 API (웹)

`DELETE /web/device/{device_id}`

`device_id`가 일치하는 row 전체를 삭제합니다.

### 7) 웹 테이블용 전체 조회 API

`GET /web/devices`

Basic Auth(`id`/`pw`)가 필요합니다.
- 로그인한 사용자의 `parking_lot_name`이 `all`이면 전체 row 반환
- `all`이 아니면 `device.parking_lot_name == 사용자 parking_lot_name`인 row만 반환
- 응답 필드는 `parking_lot_name`을 제외한 컬럼만 반환

예시:
```bash
curl -u master:'silla01177!' http://127.0.0.1:8000/web/devices
```

Response:
```json
[
  {
    "device_id": "device-001",
    "phone_number": "01012345678",
    "assigned_period": "2026-02-01~2026-12-31"
  },
  {
    "device_id": "device-002",
    "phone_number": null,
    "assigned_period": null
  }
]
```

### 8) 로그인 API

`POST /auth/login`

Request:
```json
{
  "id": "admin",
  "pw": "plain-password"
}
```

Success Response:
```json
{
  "success": true,
  "message": "Login successful",
  "num_id": 1,
  "id": "admin",
  "parking_lot_name": "A Lot"
}
```

### 9) 사용자 추가 API

`POST /auth/user`

Request:
```json
{
  "id": "admin2",
  "pw": "admin2-password",
  "parking_lot_name": "A Lot"
}
```

Success Response:
```json
{
  "num_id": 2,
  "id": "admin2",
  "parking_lot_name": "A Lot"
}
```

`id`가 이미 있으면 `409`를 반환합니다.

로그인/사용자추가에서 `pw`는 문자열 직접 비교/저장이 아니라 PBKDF2 해시 기반으로 검증/저장합니다.

초기 사용자 저장 시 해시는 아래처럼 만들 수 있습니다.
```bash
python3 -c "from app.security import hash_password; print(hash_password('your-password'))"
```
