# React Web (Frontend)

React 19 + Vite 7 based web UI has been added in this same directory.

운영 배포 요약 문서:
- `DEPLOYMENT_NGINX_CLOUDFLARE.md` (Nginx + Cloudflare + HTTPS + 트러블슈팅)

## Frontend 실행

```bash
npm install
cp .env.example .env
npm run dev
```

- Default web URL: `http://127.0.0.1:5173`
- `.env` value `VITE_API_BASE_URL` can be changed to internal network IP (for example: `http://192.168.0.10:8000`)

## Frontend 핵심 기능

- 로그인 페이지 (`POST /auth/login`) 후 장치 관리 페이지 진입
- `/web/*` 요청 시 Basic Auth 헤더 자동 포함 (401 발생 시 로그인 화면 복귀)
- 헤더 우측 `로그아웃` 버튼으로 로그인 페이지 복귀
- Header + separate container/table layout
- `GET /web/devices/{id}` data table rendering (로그인한 id 기준)
- Row add: `POST /web/device`
- Column add/update:
  - `PUT /web/device-phone`
  - `PUT /web/device-period`
- Column delete (set null):
  - `DELETE /web/device-phone/{device_id}`
  - `DELETE /web/device-period/{device_id}`
- Row delete: `DELETE /web/device/{device_id}`
- Every add/delete/update action immediately refreshes table with `GET /web/devices/{id}`

## 배포 방식 비교 (포트 직접 공개 vs Nginx)

| 항목 | 포트 직접 공개 (임시) | Nginx 리버스 프록시 (권장) |
|---|---|---|
| 외부 오픈 포트 | `5173`, `8000` 둘 다 오픈 | `80`(또는 `443`)만 오픈 |
| 프론트 주소 | `http://IP:5173` | `http://도메인` 또는 `http://IP` |
| CORS 설정 | 필요 (프론트 Origin 허용) | 거의 불필요(동일 Origin 구성 가능) |
| 보안/운영성 | 낮음 (임시 운영용) | 높음 (운영 표준) |
| HTTPS 확장 | 별도 구성 필요 | Nginx에서 TLS 적용 쉬움 |

정리:
- **임시 운영**: 포트 직접 공개
- **실운영**: Nginx 프록시 + systemd

## Ubuntu 배포 (Nginx 정적 파일만)

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
cd /home/silla/badak_chadan_web
sudo mkdir -p /var/www/badak_chadan_web
sudo rsync -av --delete dist/ /var/www/badak_chadan_web/
```

`dist/`는 **현재 디렉터리 기준 상대경로**입니다.  
어느 경로에서 실행하든 안전하게 하려면 아래처럼 절대경로를 사용하세요.

```bash
sudo rsync -av --delete /home/silla/badak_chadan_web/dist/ /var/www/badak_chadan_web/
```

### 4) Nginx 설정

먼저 경로 확인:

```bash
ls -ld /etc/nginx /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d
```

Ubuntu 기본 패키지면 `sites-available`가 있습니다.  
없으면 아래처럼 디렉터리를 만들거나(`sites-available` 방식), `conf.d` 방식으로 진행하세요.

```bash
sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
```

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
sudo rm -f /etc/nginx/sites-enabled/default || true
sudo ln -sf /etc/nginx/sites-available/badak_chadan_web /etc/nginx/sites-enabled/badak_chadan_web
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

> 이 방식은 **웹 정적 파일만 Nginx로 서비스**합니다.  
> API는 별도로 `:8000`을 직접 열어 호출해야 하므로 CORS 설정이 필요합니다.
>
> `sites-available`를 쓰지 않는 환경이면 아래처럼 대체 가능:
> ```bash
> sudo cp /etc/nginx/sites-available/badak_chadan_web /etc/nginx/conf.d/badak_chadan_web.conf
> sudo nginx -t && sudo systemctl reload nginx
> ```

## Ubuntu 서비스 운영 (`/home/silla` 기준, 현재 서버 방식 맞춤)

아래는 질문에서 공유한 운영 방식에 맞춰,  
`/home/silla/badak_chadan_server`(FastAPI) + `/home/silla/badak_chadan_web`(Web)로 올리는 절차입니다.

### 1) 디렉터리 구성

```bash
/home/silla/badak_chadan_server
/home/silla/badak_chadan_web
```

### 2) FastAPI 서비스(이미 운영 중) 확인

현재 서비스 파일:

```ini
# /etc/systemd/system/badak-chadan-server.service
[Unit]
Description=Badak Chadan FastAPI Server
After=network.target

[Service]
Type=simple
User=silla
Group=silla
WorkingDirectory=/home/silla/badak_chadan_server
ExecStart=/home/silla/badak_chadan_server/.venv/bin/python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

확인:

```bash
sudo systemctl status badak-chadan-server
sudo journalctl -u badak-chadan-server -f
```

### 3) 웹 빌드 (`/home/silla/badak_chadan_web`)

Node.js가 Ubuntu에 있으면 서버에서 직접:

```bash
cd /home/silla/badak_chadan_web
cp .env.example .env
# 예시: 포트 직접 운영 기준
# VITE_API_BASE_URL=http://<SERVER_IP>:8000
npm install
npm run build
```

Node.js가 Ubuntu에 없으면 Mac에서 빌드 후 업로드:

```bash
# Mac
cd /path/to/badak_chadan_web
cp .env.example .env
npm install
npm run build
rsync -av --delete dist/ silla@<SERVER_IP>:/home/silla/badak_chadan_web/dist/
```

### 4) 웹 서비스 등록 (FastAPI와 동일한 systemd 패턴)

`/etc/systemd/system/badak-chadan-web.service` 생성:

```ini
[Unit]
Description=Badak Chadan Web Static Server
After=network.target

[Service]
Type=simple
User=silla
Group=silla
WorkingDirectory=/home/silla/badak_chadan_web
ExecStart=/usr/bin/python3 -m http.server 5173 --bind 0.0.0.0 --directory /home/silla/badak_chadan_web/dist
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

적용:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now badak-chadan-web
sudo systemctl status badak-chadan-web
sudo journalctl -u badak-chadan-web -f
```

### 5) 업데이트(재배포)

```bash
# web 프로젝트 업데이트 후
cd /home/silla/badak_chadan_web
# (서버에서 빌드 시) npm run build
# (Mac에서 빌드 시) dist rsync 업로드
sudo systemctl restart badak-chadan-web

# FastAPI 코드 변경 시
sudo systemctl restart badak-chadan-server
```

### 6) 포트 직접 운영 시 체크

- 웹: `5173`
- API: `8000`
- 공유기 포트포워딩/방화벽(UFW)에서 두 포트 허용 필요

```bash
sudo ufw allow 5173/tcp
sudo ufw allow 8000/tcp
```

> 이후 Nginx를 붙일 때는 `badak-chadan-web` 서비스 없이 Nginx가 `dist`를 직접 서빙하도록 전환하는 것이 일반적입니다.

### 7) Nginx 프록시로 전환할 때 (권장 운영 형태)

`badak-chadan-web` 서비스 대신 Nginx가 정적 파일 + API 프록시를 담당합니다.

1) 정적 파일 배포:

```bash
sudo mkdir -p /var/www/badak_chadan_web
sudo rsync -av --delete /home/silla/badak_chadan_web/dist/ /var/www/badak_chadan_web/
```

2) Nginx 설정 (`/etc/nginx/sites-available/badak_chadan_web`):

경로 없으면 먼저 생성:

```bash
sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
```

아래 `server { ... }` 내용을 **파일로 저장**해야 합니다.

```bash
sudo nano /etc/nginx/sites-available/badak_chadan_web
```

또는 한 번에 저장:

```bash
sudo tee /etc/nginx/sites-available/badak_chadan_web > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;

    root /var/www/badak_chadan_web;
    index index.html;

    location /auth/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /web/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /mobile/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /docs {
        proxy_pass http://127.0.0.1:8000;
    }

    location /swagger {
        proxy_pass http://127.0.0.1:8000;
    }

    location /openapi.json {
        proxy_pass http://127.0.0.1:8000;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF
```

```nginx
server {
    listen 80;
    server_name _;

    root /var/www/badak_chadan_web;
    index index.html;

    location /auth/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /web/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /mobile/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /docs {
        proxy_pass http://127.0.0.1:8000;
    }

    location /swagger {
        proxy_pass http://127.0.0.1:8000;
    }

    location /openapi.json {
        proxy_pass http://127.0.0.1:8000;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

3) 적용:

```bash
sudo rm -f /etc/nginx/sites-enabled/default || true
sudo ln -sf /etc/nginx/sites-available/badak_chadan_web /etc/nginx/sites-enabled/badak_chadan_web
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
sudo systemctl disable --now badak-chadan-web
```

`sites-available` 방식이 없는 배포판이면:

```bash
sudo cp /etc/nginx/sites-available/badak_chadan_web /etc/nginx/conf.d/badak_chadan_web.conf
sudo nginx -t
sudo systemctl reload nginx
```

4) 확인:

```bash
curl -I http://127.0.0.1/
curl -I http://127.0.0.1/web/devices/<id>
curl -I http://127.0.0.1/docs
```

주의:
- `proxy_pass http://127.0.0.1:8000;`처럼 **끝 슬래시(`/`) 없이** 쓰면 `/web/*`, `/auth/*` 경로가 원본 그대로 FastAPI로 전달됩니다.
- Nginx만 통해서 API를 열 계획이면 FastAPI 서비스 `ExecStart`를 `--host 127.0.0.1`로 바꾸고 외부 `8000` 포트는 닫는 것이 안전합니다.

## 운영 시 체크 사항

- FastAPI 서버의 CORS에 웹 주소(예: `http://<WEB_IP>`)를 허용해야 합니다.
- 위 Nginx처럼 같은 도메인으로 `/auth`, `/web`, `/mobile` 프록시하면 CORS 이슈를 크게 줄일 수 있습니다.
- 방화벽 사용 시 HTTP(80) 또는 HTTPS(443) 포트를 열어야 합니다.
- 외부 배포면 HTTPS(예: Let's Encrypt + certbot) 적용을 권장합니다.
