from sqlalchemy import Column, Integer, String

from .database import Base


class Device(Base):
    __tablename__ = "device"

    device_id = Column(String, primary_key=True, index=True)
    origin_id = Column(String, nullable=True, index=True)
    phone_number = Column(String, nullable=True, index=True)
    assigned_period = Column(String, nullable=True)
    parking_lot_name = Column(String, nullable=True, index=True)


class User(Base):
    __tablename__ = "user"

    num_id = Column(Integer, primary_key=True, autoincrement=True, index=True)
    parking_lot_name = Column(String, nullable=False, index=True)
    id = Column(String, nullable=False, unique=True, index=True)
    pw = Column(String, nullable=False)
