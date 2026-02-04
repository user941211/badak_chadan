from datetime import date, datetime
from time import sleep

from fastapi import Depends, FastAPI, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.docs import get_swagger_ui_html
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from sqlalchemy import text
from sqlalchemy.dialects.sqlite import insert
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session, load_only

from .database import Base, SessionLocal, engine, get_db
from .models import Device, User
from .security import hash_password, verify_password
from .schemas import (
    CreateUserRequest,
    CreateDeviceRequest,
    DeleteResponse,
    DeviceResponse,
    LoginRequest,
    LoginResponse,
    PhoneLookupDevice,
    PhoneLookupRequest,
    PhoneLookupResponse,
    UpsertPeriodRequest,
    UpsertPhoneRequest,
    UserResponse,
)

app = FastAPI(
    title="Device API",
    version="1.0.0",
    description="Device(phone/assigned period) management API",
    openapi_tags=[
        {"name": "common", "description": "Common APIs"},
        {"name": "mobile", "description": "Mobile client APIs"},
        {"name": "web", "description": "Web admin APIs"},
        {"name": "auth", "description": "Authentication APIs"},
    ],
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)
security = HTTPBasic()


def parse_start_date(assigned_period: str | None) -> date | None:
    if not assigned_period:
        return None

    start_text = assigned_period.split("~", 1)[0].strip()
    if not start_text:
        return None

    for fmt in ("%Y-%m-%d", "%Y.%m.%d", "%Y/%m/%d"):
        try:
            return datetime.strptime(start_text, fmt).date()
        except ValueError:
            continue

    return None


def authenticate_user_or_401(user_id: str, password: str, db: Session) -> User:
    user = db.query(User).filter(User.id == user_id).first()
    if not user or not verify_password(password, user.pw):
        raise HTTPException(
            status_code=401,
            detail="Invalid id or password",
            headers={"WWW-Authenticate": "Basic"},
        )
    return user


def _is_locked_error(exc: OperationalError) -> bool:
    return "database is locked" in str(getattr(exc, "orig", exc)).lower()


def execute_with_retry(db: Session, stmt, retries: int = 2, delay_seconds: float = 0.2) -> None:
    for attempt in range(retries + 1):
        try:
            db.execute(stmt)
            return
        except OperationalError as exc:
            db.rollback()
            if (not _is_locked_error(exc)) or attempt == retries:
                raise
            sleep(delay_seconds * (attempt + 1))


def commit_with_retry(db: Session, retries: int = 2, delay_seconds: float = 0.2) -> None:
    for attempt in range(retries + 1):
        try:
            db.commit()
            return
        except OperationalError as exc:
            db.rollback()
            if (not _is_locked_error(exc)) or attempt == retries:
                raise
            sleep(delay_seconds * (attempt + 1))


def commit_or_503(db: Session) -> None:
    try:
        commit_with_retry(db)
    except OperationalError as exc:
        raise HTTPException(
            status_code=503,
            detail="Database is busy. Please retry.",
        ) from exc


def ensure_device_parking_lot_name_column() -> None:
    with engine.begin() as connection:
        columns = {
            row[1]
            for row in connection.execute(text("PRAGMA table_info(device)")).fetchall()
        }
        if columns and "parking_lot_name" not in columns:
            connection.execute(text("ALTER TABLE device ADD COLUMN parking_lot_name VARCHAR"))


def ensure_default_master_user() -> None:
    db = SessionLocal()
    try:
        existing = db.query(User).filter(User.id == "master").first()
        if existing:
            return

        db.add(
            User(
                id="master",
                pw=hash_password("silla01177!"),
                parking_lot_name="all",
            )
        )
        commit_with_retry(db)
    finally:
        db.close()


@app.on_event("startup")
def on_startup() -> None:
    Base.metadata.create_all(bind=engine)
    ensure_device_parking_lot_name_column()
    ensure_default_master_user()


@app.get("/", tags=["common"])
def health_check() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/swagger", include_in_schema=False)
def custom_swagger_ui():
    return get_swagger_ui_html(
        openapi_url=app.openapi_url,
        title=f"{app.title} - Swagger UI",
    )


@app.post("/mobile/device-by-phone", response_model=PhoneLookupResponse, tags=["mobile"])
def get_device_by_phone(
    payload: PhoneLookupRequest,
    response: Response,
    db: Session = Depends(get_db),
) -> PhoneLookupResponse:
    phone_number = payload.phone_number
    if phone_number.startswith("082"):
        phone_number = "0" + phone_number[3:]

    print(
        f"[/mobile/device-by-phone] phone_number_raw={payload.phone_number}, phone_number={phone_number}",
        flush=True,
    )
    devices = (
        db.query(Device)
        .filter(Device.phone_number == phone_number)
        .order_by(Device.device_id.asc())
        .all()
    )
    if not devices:
        response.status_code = 207
        return PhoneLookupResponse(
            exists=False,
            message="Phone number not found",
        )

    lookup_devices: list[PhoneLookupDevice] = []
    for device in devices:
        start_date = parse_start_date(device.assigned_period)
        is_started = not (start_date and date.today() < start_date)
        lookup_devices.append(
            PhoneLookupDevice(
                device_id=device.device_id,
                assigned_period=device.assigned_period,
                is_started=is_started,
            )
        )

    first_device = lookup_devices[0]
    any_started = any(device.is_started for device in lookup_devices)
    combined_device_ids = ",".join(device.device_id for device in lookup_devices)
    combined_assigned_period = ",".join(
        (device.assigned_period or "") for device in lookup_devices
    )

    if len(lookup_devices) == 1 and not any_started:
        first_start_date = parse_start_date(first_device.assigned_period)
        return PhoneLookupResponse(
            exists=True,
            message=f"Not started yet (start_date: {first_start_date.isoformat()})",
            devices=lookup_devices,
            is_started=any_started,
            device_id=combined_device_ids,
            assigned_period=combined_assigned_period,
        )

    not_started_count = sum(1 for device in lookup_devices if not device.is_started)
    message = "Phone number found"
    if len(lookup_devices) > 1:
        if not_started_count == 0:
            message = f"Phone number found ({len(lookup_devices)} devices)"
        else:
            message = (
                f"Phone number found ({len(lookup_devices)} devices, "
                f"{not_started_count} not started)"
            )

    return PhoneLookupResponse(
        exists=True,
        message=message,
        devices=lookup_devices,
        is_started=any_started,
        device_id=combined_device_ids,
        assigned_period=combined_assigned_period,
    )


@app.post("/auth/login", response_model=LoginResponse, tags=["auth"])
def login(
    payload: LoginRequest,
    db: Session = Depends(get_db),
) -> LoginResponse:
    user = authenticate_user_or_401(payload.id, payload.pw, db)

    return LoginResponse(
        success=True,
        message="Login successful",
        num_id=user.num_id,
        id=user.id,
        parking_lot_name=user.parking_lot_name,
    )


@app.post("/auth/user", response_model=UserResponse, status_code=201, tags=["auth"])
def create_user(
    payload: CreateUserRequest,
    db: Session = Depends(get_db),
) -> UserResponse:
    user_id = payload.id.strip()
    password = payload.pw
    parking_lot_name = payload.parking_lot_name.strip()

    if not user_id or not password.strip() or not parking_lot_name:
        raise HTTPException(status_code=400, detail="id, pw, parking_lot_name are required")

    existing = db.query(User).filter(User.id == user_id).first()
    if existing:
        raise HTTPException(status_code=409, detail="User id already exists")

    user = User(
        id=user_id,
        pw=hash_password(password),
        parking_lot_name=parking_lot_name,
    )
    db.add(user)
    commit_or_503(db)
    db.refresh(user)
    return user


@app.get("/web/devices", response_model=list[DeviceResponse], tags=["web"])
def get_all_devices(
    credentials: HTTPBasicCredentials = Depends(security),
    db: Session = Depends(get_db),
) -> list[DeviceResponse]:
    user = authenticate_user_or_401(
        credentials.username,
        credentials.password,
        db,
    )

    query = (
        db.query(Device)
        .options(
            load_only(
                Device.device_id,
                Device.phone_number,
                Device.assigned_period,
            )
        )
    )

    if user.parking_lot_name.lower() != "all":
        query = query.filter(Device.parking_lot_name == user.parking_lot_name)

    devices = query.order_by(Device.device_id.asc()).all()
    return devices


@app.post("/web/device", response_model=DeviceResponse, status_code=201, tags=["web"])
def create_device(
    payload: CreateDeviceRequest,
    db: Session = Depends(get_db),
) -> DeviceResponse:
    existing = db.get(Device, payload.device_id)
    if existing:
        raise HTTPException(status_code=409, detail="Device already exists")

    device = Device(device_id=payload.device_id)
    db.add(device)
    commit_or_503(db)
    db.refresh(device)
    return device


@app.put("/web/device-phone", response_model=DeviceResponse, tags=["web"])
def upsert_device_phone(
    payload: UpsertPhoneRequest,
    db: Session = Depends(get_db),
) -> DeviceResponse:
    stmt = insert(Device).values(
        device_id=payload.device_id,
        phone_number=payload.phone_number,
    )
    stmt = stmt.on_conflict_do_update(
        index_elements=[Device.device_id],
        set_={"phone_number": payload.phone_number},
    )
    execute_with_retry(db, stmt)
    commit_or_503(db)

    device = db.get(Device, payload.device_id)
    if device is None:
        raise HTTPException(status_code=500, detail="Failed to upsert phone number")
    return device


@app.put("/web/device-period", response_model=DeviceResponse, tags=["web"])
def upsert_device_period(
    payload: UpsertPeriodRequest,
    db: Session = Depends(get_db),
) -> DeviceResponse:
    stmt = insert(Device).values(
        device_id=payload.device_id,
        assigned_period=payload.assigned_period,
    )
    stmt = stmt.on_conflict_do_update(
        index_elements=[Device.device_id],
        set_={"assigned_period": payload.assigned_period},
    )
    execute_with_retry(db, stmt)
    commit_or_503(db)

    device = db.get(Device, payload.device_id)
    if device is None:
        raise HTTPException(status_code=500, detail="Failed to upsert assigned period")
    return device


@app.delete("/web/device-phone/{device_id}", response_model=DeleteResponse, tags=["web"])
def delete_device_phone(
    device_id: str,
    db: Session = Depends(get_db),
) -> DeleteResponse:
    device = db.get(Device, device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    device.phone_number = None
    commit_or_503(db)
    db.refresh(device)

    return DeleteResponse(
        message="Phone number deleted",
        device=device,
    )


@app.delete("/web/device-period/{device_id}", response_model=DeleteResponse, tags=["web"])
def delete_device_period(
    device_id: str,
    db: Session = Depends(get_db),
) -> DeleteResponse:
    device = db.get(Device, device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    device.assigned_period = None
    commit_or_503(db)
    db.refresh(device)

    return DeleteResponse(
        message="Assigned period deleted",
        device=device,
    )


@app.delete("/web/device/{device_id}", response_model=DeleteResponse, tags=["web"])
def delete_device_row(
    device_id: str,
    db: Session = Depends(get_db),
) -> DeleteResponse:
    device = db.get(Device, device_id)
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    deleted_device = DeviceResponse(
        device_id=device.device_id,
        phone_number=device.phone_number,
        assigned_period=device.assigned_period,
    )

    db.delete(device)
    commit_or_503(db)

    return DeleteResponse(
        message="Device row deleted",
        device=deleted_device,
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)
