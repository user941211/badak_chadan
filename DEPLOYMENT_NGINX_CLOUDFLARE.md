# Nginx + Cloudflare 배포 정리 (park-keeper.kr 기준)

이 문서는 아래 구조를 기준으로 정리한 운영 가이드입니다.

- FastAPI: `/home/silla/badak_chadan_server` (systemd: `badak-chadan-server`)
- Web 소스: `/home/silla/badak_chadan_web`
- Web 빌드 결과: `/var/www/badak_chadan_web`
- 도메인: `web.park-keeper.kr`
- Nginx가 정적 파일 + API 프록시를 담당

---

## 1) 서비스 구조

- 브라우저 -> Cloudflare -> Nginx(80/443) -> FastAPI(127.0.0.1:8000)
- `/` : React 정적 파일
- `/auth/*`, `/web/*`, `/mobile/*`, `/docs` : FastAPI 프록시

---

## 2) FastAPI 서비스 확인

```bash
sudo systemctl status badak-chadan-server
curl -i http://127.0.0.1:8000/web/devices/<id>
```

`/web/devices/<id>`는 Basic Auth가 없으면 `401 Not authenticated`가 정상입니다.

---

## 3) Web 빌드/배포

`.env` (중요):

```dotenv
VITE_API_BASE_URL=https://web.park-keeper.kr
```

빌드/배포:

```bash
cd /home/silla/badak_chadan_web
npm run build
sudo mkdir -p /var/www/badak_chadan_web
sudo rsync -av --delete dist/ /var/www/badak_chadan_web/
```

> `dist/`는 상대경로라서 반드시 `/home/silla/badak_chadan_web`에서 실행하거나, 절대경로를 사용하세요.

---

## 4) Nginx 설정 파일

파일: `/etc/nginx/sites-available/badak_chadan_web`

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name web.park-keeper.kr;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name web.park-keeper.kr;

    ssl_certificate     /etc/nginx/cf-origin/web.park-keeper.kr.pem;
    ssl_certificate_key /etc/nginx/cf-origin/web.park-keeper.kr.key;

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
        proxy_set_header Host $host;
    }

    location /swagger {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
    }

    location /openapi.json {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

적용:

```bash
sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
sudo rm -f /etc/nginx/sites-enabled/default || true
sudo ln -sf /etc/nginx/sites-available/badak_chadan_web /etc/nginx/sites-enabled/badak_chadan_web
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

---

## 5) Cloudflare 설정

### DNS
- 레코드: `web` (CNAME -> DDNS 주소 또는 A -> 공인IP)
- Proxy status: **Proxied(주황 구름)**
- `AAAA` 레코드는 IPv6 미사용 시 제거

### SSL/TLS
- 권장: **Full (strict)**
- Origin Server에서 발급한 인증서/키를 Nginx에 설치

---

## 6) Origin Certificate 설치

Cloudflare -> SSL/TLS -> Origin Server -> Create Certificate

서버 저장:

```bash
sudo mkdir -p /etc/nginx/cf-origin
sudo nano /etc/nginx/cf-origin/web.park-keeper.kr.pem
sudo nano /etc/nginx/cf-origin/web.park-keeper.kr.key
sudo chmod 644 /etc/nginx/cf-origin/web.park-keeper.kr.pem
sudo chmod 600 /etc/nginx/cf-origin/web.park-keeper.kr.key
sudo chown root:root /etc/nginx/cf-origin/web.park-keeper.kr.pem /etc/nginx/cf-origin/web.park-keeper.kr.key
sudo nginx -t && sudo systemctl reload nginx
```

---

## 7) 포트포워딩 / 네트워크

공유기:
- 외부 80 -> 내부 서버 80
- 외부 443 -> 내부 서버 443

UFW 사용 시:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

---

## 8) 동작 검증

원본 서버 내부:

```bash
curl -I http://127.0.0.1/
curl -i http://127.0.0.1/web/devices/<id>
curl -i -u test:test http://127.0.0.1/web/devices/<id>
```

정상 기준:
- 무인증 `/web/devices/<id>` -> `401` + JSON
- 인증 포함 `/web/devices/<id>` -> `200` + JSON

외부:

```bash
curl -I https://web.park-keeper.kr/
curl -i https://web.park-keeper.kr/web/devices/<id>
curl -i -u test:test https://web.park-keeper.kr/web/devices/<id>
```

---

## 9) 자주 발생한 이슈와 해결

### A. `/web/devices/<id>`가 HTML(index.html)로 나옴
- 원인: Nginx에 `/web/` 프록시 location 누락
- 해결: `location /web/ { proxy_pass http://127.0.0.1:8000; }` 추가

### B. Cloudflare 523 Origin is unreachable
- 원인: Cloudflare -> 원본 80/443 연결 불가
- 점검: 포트포워딩, 공인IP/DDNS, `AAAA` 레코드, ISP/CGNAT

### C. Mixed Content (`https` 페이지에서 `http` API 호출)
- 원인: 빌드 시 `VITE_API_BASE_URL`이 `http://...`
- 해결: `.env`를 `https://web.park-keeper.kr`로 변경 후 재빌드/재배포

### D. 인증서 파일 없음 (`cannot load certificate`)
- 원인: `.pem`/`.key` 파일 경로 또는 파일 누락
- 해결: Origin cert+key 재발급/재저장 후 `nginx -t`

### E. 캐시 때문에 구버전 JS 계속 로드
- 브라우저 강력 새로고침 / 시크릿창 테스트
- Cloudflare Cache Purge 수행

---

## 10) 운영 팁

- FastAPI를 Nginx 뒤에서만 쓰려면 FastAPI `--host 127.0.0.1`로 좁히는 것이 안전합니다.
- Nginx 설정 변경 후 항상:
  - `sudo nginx -t`
  - `sudo systemctl reload nginx`
- 장애 확인:
  - `sudo journalctl -u nginx -f`
  - `sudo journalctl -u badak-chadan-server -f`
