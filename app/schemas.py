from typing import Optional

from pydantic import BaseModel, Field


class PhoneLookupRequest(BaseModel):
    phone_number: str


class PhoneLookupDevice(BaseModel):
    device_id: str
    assigned_period: Optional[str] = None
    origin_id: Optional[str] = None
    is_started: bool


class PhoneLookupResponse(BaseModel):
    exists: bool
    message: str
    devices: list[PhoneLookupDevice] = Field(default_factory=list)
    # Backward-compatible fields:
    # - is_started: true if any matched device is started
    # - device_id/assigned_period/origin_id: all matched values joined by comma (in order)
    is_started: Optional[bool] = None
    device_id: Optional[str] = None
    assigned_period: Optional[str] = None
    origin_id: Optional[str] = None


class UpsertPhoneRequest(BaseModel):
    device_id: str
    phone_number: str


class UpsertPeriodRequest(BaseModel):
    device_id: str
    assigned_period: str


class UpsertParkingLotNameRequest(BaseModel):
    device_id: str
    parking_lot_name: str


class UpsertOriginIdRequest(BaseModel):
    device_id: str
    origin_id: str


class CreateDeviceRequest(BaseModel):
    device_id: str


class LoginRequest(BaseModel):
    id: str
    pw: str


class LoginResponse(BaseModel):
    success: bool
    message: str
    num_id: Optional[int] = None
    id: Optional[str] = None
    parking_lot_name: Optional[str] = None


class CreateUserRequest(BaseModel):
    id: str
    pw: str
    parking_lot_name: str


class UserResponse(BaseModel):
    num_id: int
    id: str
    parking_lot_name: str

    class Config:
        from_attributes = True


class DeviceResponse(BaseModel):
    device_id: str
    phone_number: Optional[str] = None
    assigned_period: Optional[str] = None

    class Config:
        from_attributes = True




class DeviceMasterResponse(BaseModel):
    device_id: str
    phone_number: Optional[str] = None
    assigned_period: Optional[str] = None
    parking_lot_name: Optional[str] = None
    origin_id: Optional[str] = None

    class Config:
        from_attributes = True


class DeleteResponse(BaseModel):
    message: str
    device: DeviceResponse


class DeleteMasterResponse(BaseModel):
    message: str
    device: DeviceMasterResponse
