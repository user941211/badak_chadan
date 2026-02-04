# React Web (Frontend)

React 19 + Vite 7 based web UI has been added in this same directory.

## Frontend 실행

```bash
npm install
cp .env.example .env
npm run dev
```

- Default web URL: `http://127.0.0.1:5173`
- `.env` value `VITE_API_BASE_URL` can be changed to internal network IP (for example: `http://192.168.0.10:8000`)

## Frontend 핵심 기능

- Header + separate container/table layout
- `GET /web/devices` data table rendering
- Row add: `POST /web/device`
- Column add/update:
  - `PUT /web/device-phone`
  - `PUT /web/device-period`
- Column delete (set null):
  - `DELETE /web/device-phone/{device_id}`
  - `DELETE /web/device-period/{device_id}`
- Row delete: `DELETE /web/device/{device_id}`
- Every add/delete/update action immediately refreshes table with `GET /web/devices`

## Ubuntu 배포 (Nginx 정적 배포)

아래는 프론트를 `dist/`로 빌드해서 Ubuntu 서버에서 Nginx로 서비스하는 방법입니다.

### 1) 서버 준비

```bash
sudo apt update
sudo apt install -y nginx rsync
```

> Node.js는 20+ 권장입니다. (apt 기본 버전이 낮으면 nvm 사용 권장)

### 2) 빌드

```bash
cp .env.example .env
```

`.env` 파일에서 API 주소를 실제 FastAPI 주소로 변경:

```dotenv
VITE_API_BASE_URL=http://<FASTAPI_IP>:8000
```

빌드 실행:

```bash
npm install
npm run build
```

### 3) Nginx 배포 경로로 복사

```bash
sudo mkdir -p /var/www/badak_chadan_web
sudo rsync -av --delete dist/ /var/www/badak_chadan_web/
```

### 4) Nginx 설정

`/etc/nginx/sites-available/badak_chadan_web` 파일 생성:

```nginx
server {
    listen 80;
    server_name _;

    root /var/www/badak_chadan_web;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

활성화:

```bash
sudo ln -s /etc/nginx/sites-available/badak_chadan_web /etc/nginx/sites-enabled/badak_chadan_web
sudo nginx -t
sudo systemctl reload nginx
```

## Raspberry Pi 배포

Raspberry Pi OS에서도 동일하게 배포할 수 있습니다.

### 방법 A) 라즈베리파이에서 직접 빌드

```bash
sudo apt update
sudo apt install -y nginx rsync nodejs npm
```

이후 Ubuntu 절차와 동일하게:

1. `.env` 설정 (`VITE_API_BASE_URL`)
2. `npm install && npm run build`
3. `/var/www/badak_chadan_web`로 `dist/` 복사
4. Nginx 설정/재시작

### 방법 B) 개발 PC에서 빌드 후 라즈베리파이에 업로드

개발 PC에서:

```bash
npm install
npm run build
scp -r dist/* pi@<PI_IP>:/tmp/badak_chadan_web_dist/
```

라즈베리파이에서:

```bash
sudo mkdir -p /var/www/badak_chadan_web
sudo rsync -av --delete /tmp/badak_chadan_web_dist/ /var/www/badak_chadan_web/
sudo nginx -t
sudo systemctl reload nginx
```

## 운영 시 체크 사항

- FastAPI 서버의 CORS에 웹 주소(예: `http://<WEB_IP>`)를 허용해야 합니다.
- 방화벽 사용 시 HTTP(80) 또는 HTTPS(443) 포트를 열어야 합니다.
- 외부 배포면 HTTPS(예: Let's Encrypt + certbot) 적용을 권장합니다.
