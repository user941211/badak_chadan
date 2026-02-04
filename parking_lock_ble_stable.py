#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Parking Lock BLE CLI (Raspberry Pi / BlueZ hardened)

What this fixes vs previous:
1) BlueZ auto-reconnect (HID/HOGP) keeps device "Connected: yes" and stops advertising.
   - We can block the device when we are NOT using it (Device1.Blocked=true).
   - On start we unblock, on exit we disconnect + (optionally) block.
   - No /etc edits; uses busctl DBus runtime toggles only.

2) Login fails with ACK 0x0A.
   - Docs show login frame but lock-id endianness is ambiguous for values > 0xFF.
   - We add "login variant search": tries (big/little endian) x (FF/00 padding) for password.
   - If one works, we keep that encoding for this session.

3) Bleak API drift:
   - Prefer client.services property, only call get_services() if missing.

Install:
  sudo apt install -y python3-bleak

Run (recommended):
  sudo python3 parking_lock_ble_cli_pi_final.py
"""

from __future__ import annotations

import asyncio
import re
import sys
import time
import shutil
import subprocess
from dataclasses import dataclass
from typing import Optional, Dict, List, Tuple

from bleak import BleakClient, BleakScanner
from bleak.exc import BleakError


# ---- UUID candidates ----
UUID_BASE_STD = "-0000-1000-8000-00805f9b34fb"
UUID_BASE_DOC = "-0000-1000-8000-0805f9b34fb"  # doc typo variant

SERVICE_UUID_CANDIDATES = [
    f"00007195{UUID_BASE_STD}",
    f"00007195{UUID_BASE_DOC}",
    f"00007198{UUID_BASE_STD}",
    f"00007198{UUID_BASE_DOC}",
]
CHAR_UUID_CANDIDATES = [
    f"00007198{UUID_BASE_STD}",
    f"00007198{UUID_BASE_DOC}",
]

# ---- command codes ----
CMD_LOGIN = 0x00
CMD_UP = 0x02
CMD_DOWN = 0x03
CMD_GET_STATUS = 0x05
CMD_GET_VERSION = 0x07
CMD_GET_LIMIT = 0x0D
CMD_REBOOT = 0x0F
CMD_REMOTE_CFG = 0x10
CMD_STATE_REPORT = 0x41

EXPECT_RSP: Dict[int, Optional[int]] = {
    CMD_LOGIN: 0x80,
    CMD_UP: 0x82,
    CMD_DOWN: 0x83,
    CMD_GET_STATUS: 0x85,
    CMD_GET_VERSION: 0x87,
    CMD_GET_LIMIT: 0x8D,
    CMD_REMOTE_CFG: 0x90,
    CMD_REBOOT: None,
}

ACK_CODES: Dict[int, str] = {
    0: "성공",
    1: "실패",
    2: "데이터 길이 오류",
    3: "장치 주소 오류",
    4: "명령 코드 오류",
    5: "체크섬(XOR) 오류",
    6: "모터 동작 중",
    7: "파라미터 설정 실패",
    8: "요청 방향 한계(리미트) 도달",
    9: "리미트(한계) 이상",
    10: "모터 타임아웃",
    13: "배터리 부족",
    14: "락 위에 차량 존재",
    15: "미로그인/권한 없음",
    255: "통신 타임아웃",
}

CMD_NAMES: Dict[int, str] = {
    CMD_LOGIN: "로그인",
    CMD_UP: "상승(올림)",
    CMD_DOWN: "하강(내림)",
    CMD_GET_STATUS: "상태 조회",
    CMD_GET_VERSION: "버전 조회",
    CMD_GET_LIMIT: "자석 한계 상태 조회",
    CMD_REBOOT: "재부팅",
    CMD_REMOTE_CFG: "리모컨 설정",
    CMD_STATE_REPORT: "상태 보고(Notify)",
}


def hx(b: bytes) -> str:
    return " ".join(f"{x:02X}" for x in b)


def xor_bytes(buf: bytes) -> int:
    x = 0
    for v in buf:
        x ^= v
    return x


def build_frame(cmd: int, data: bytes = b"") -> bytes:
    """
    Doc: XOR from length to XOR must make total XOR == 0
    Frame: [len][cmd][data...][xor]
    """
    length = 1 + 1 + len(data) + 1
    prefix = bytes([length, cmd]) + data
    xorsum = xor_bytes(prefix)
    return prefix + bytes([xorsum])


@dataclass
class Frame:
    length: int
    cmd: int
    data: bytes
    xorsum: int
    xor_ok: bool
    length_ok: bool


def parse_frame(raw: bytes) -> Optional[Frame]:
    if not raw or len(raw) < 3:
        return None
    length = raw[0]
    cmd = raw[1]
    xorsum = raw[-1]
    data = raw[2:-1]
    length_ok = (length == len(raw))
    xor_ok = (xor_bytes(raw) == 0)
    return Frame(length=length, cmd=cmd, data=data, xorsum=xorsum, xor_ok=xor_ok, length_ok=length_ok)


def try_parse_lock_id(text: str) -> Optional[int]:
    m = re.search(r"\bPL(\d{1,12})\b", text or "")
    return int(m.group(1)) if m else None


def encode_lock_id(lock_id: int, endian: str) -> bytes:
    if endian not in ("big", "little"):
        raise ValueError("endian must be big/little")
    return int(lock_id).to_bytes(4, byteorder=endian, signed=False)


def encode_password(pw: str, pad: int) -> bytes:
    b = pw.encode("ascii", errors="strict")
    b = b[:8]
    if len(b) < 8:
        b = b + bytes([pad] * (8 - len(b)))
    return b


def decode_ack(payload: bytes) -> str:
    if not payload:
        return "(payload 없음)"
    ack = payload[0]
    return f"ack=0x{ack:02X}({ACK_CODES.get(ack,'?')}) raw={hx(payload)}"


def decode_status_payload(payload: bytes) -> str:
    # some devices may return ack-only when unauthorized -> handle outside
    if len(payload) < 5:
        return f"(상태 payload 길이 부족: {len(payload)}B) raw={hx(payload)}"
    status_word = payload[0] | (payload[1] << 8)
    lock_state = payload[2]
    battery = payload[3]
    sig4g = payload[4]

    def bit(n: int) -> int:
        return (status_word >> n) & 1

    lines = []
    lines.append(f"status_word=0x{status_word:04X}")
    lines.append(f"  bit0(요금/점유): {'요금' if bit(0) else '점유'}")
    lines.append(f"  bit1(BLE): {'ON' if bit(1) else 'OFF'}")
    lines.append(f"  bit2(푸시-오픈): {'ON' if bit(2) else 'OFF'}")
    lines.append(f"  bit3(제어모드): {'능동' if bit(3) else '수동'}")
    lines.append(f"  bit4(LED): {'ON' if bit(4) else 'OFF'}")
    lines.append(f"  bit5(음성): {'ON' if bit(5) else 'OFF'}")
    lines.append(f"  bit6(라이다): {'ON' if bit(6) else 'OFF'}")
    lines.append(f"  bit7(지자기): {'ON' if bit(7) else 'OFF'}")
    lines.append(f"  bit8(4G): {'ON' if bit(8) else 'OFF'}")
    lines.append(f"  bit9(방충): {'ON' if bit(9) else 'OFF'}")
    arm = "ARM_DOWN(해제)" if (lock_state & 1) else "ARM_UP(잠금)"
    lines.append(f"lock_state=0x{lock_state:02X}  bit0={(lock_state & 1)} -> {arm}")

    lines.append(f"battery={battery}%")
    lines.append(f"4G_signal={sig4g} (0=OFF, 1~6=강함)")
    return "\n".join(lines)


def decode_version_payload(payload: bytes) -> str:
    if len(payload) < 9:
        return f"(버전 payload 길이 부족: {len(payload)}B) raw={hx(payload)}"
    ack = payload[0]
    hw = int.from_bytes(payload[1:5], "little", signed=False)
    fw = int.from_bytes(payload[5:9], "little", signed=False)

    def split(v: int) -> Tuple[int, int, int]:
        major = v // 1_000_000
        minor = (v % 1_000_000) // 100_000
        build = v % 100_000
        return major, minor, build

    hw_m, hw_n, hw_b = split(hw)
    fw_m, fw_n, fw_b = split(fw)

    return (
        f"ack=0x{ack:02X}({ACK_CODES.get(ack,'?')})\n"
        f"HW={hw} -> {hw_m}.{hw_n}.{hw_b}\n"
        f"FW={fw} -> {fw_m}.{fw_n}.{fw_b}\n"
        f"raw={hx(payload)}"
    )


def decode_limit_payload(payload: bytes) -> str:
    if len(payload) < 2:
        return f"(limit payload 길이 부족: {len(payload)}B) raw={hx(payload)}"
    ack = payload[0]
    st = payload[1]
    meaning = {0x20: "정상"}.get(st, "알 수 없음")
    return f"ack=0x{ack:02X}({ACK_CODES.get(ack,'?')}), limit_state=0x{st:02X}({meaning}) raw={hx(payload)}"


# ---------------- BlueZ(busctl) helpers ----------------
def have_busctl() -> bool:
    return shutil.which("busctl") is not None


def addr_to_obj(addr: str, adapter: str = "hci0") -> str:
    return f"/org/bluez/{adapter}/dev_{addr.replace(':', '_')}"


def run_cmd(cmd: List[str], timeout: float = 3.0) -> Tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except Exception as e:
        return 125, "", str(e)


def busctl_get_bool(obj: str, prop: str) -> Optional[bool]:
    cmd = ["busctl", "get-property", "org.bluez", obj, "org.bluez.Device1", prop]
    rc, out, _ = run_cmd(cmd, timeout=2.0)
    if rc != 0:
        return None
    parts = out.split()
    if len(parts) >= 2 and parts[0] == "b":
        return parts[1].lower() == "true"
    return None


def busctl_set_bool(obj: str, prop: str, value: bool) -> bool:
    cmd = ["busctl", "set-property", "org.bluez", obj, "org.bluez.Device1", prop, "b", "true" if value else "false"]
    rc, _, err = run_cmd(cmd, timeout=3.0)
    if rc == 0:
        return True
    # try sudo non-interactive; user likely runs script with sudo anyway
    cmd2 = ["sudo", "-n"] + cmd
    rc2, _, _ = run_cmd(cmd2, timeout=3.0)
    return rc2 == 0


def busctl_call(obj: str, iface: str, method: str, sig: str = "", *args: str) -> bool:
    cmd = ["busctl", "call", "org.bluez", obj, iface, method]
    if sig:
        cmd += [sig] + list(args)
    rc, _, _ = run_cmd(cmd, timeout=3.0)
    if rc == 0:
        return True
    cmd2 = ["sudo", "-n"] + cmd
    rc2, _, _ = run_cmd(cmd2, timeout=3.0)
    return rc2 == 0


async def bluez_disconnect_loop(addr: str, seconds: float = 2.5, adapter: str = "hci0") -> None:
    if not have_busctl():
        return
    obj = addr_to_obj(addr, adapter=adapter)
    end = time.time() + seconds
    while time.time() < end:
        connected = busctl_get_bool(obj, "Connected")
        if connected is False:
            return
        busctl_call(obj, "org.bluez.Device1", "Disconnect")
        await asyncio.sleep(0.25)


async def bluez_unblock_for_app(addr: str, adapter: str = "hci0") -> None:
    """
    Make it usable for Bleak:
      - Blocked=false
      - Trusted=false (reduce auto reconnect)
      - disconnect any existing (HID) connection
    """
    if not have_busctl():
        return
    obj = addr_to_obj(addr, adapter=adapter)
    busctl_set_bool(obj, "Blocked", False)
    busctl_set_bool(obj, "Trusted", False)
    await bluez_disconnect_loop(addr, seconds=2.5, adapter=adapter)


async def bluez_lockdown_after_use(addr: str, adapter: str = "hci0", block: bool = True, remove: bool = False) -> None:
    """
    After finishing:
      - disconnect
      - Trusted=false
      - optionally Blocked=true to prevent BlueZ auto reconnect
      - optionally RemoveDevice (forget bonding)
    """
    if not have_busctl():
        return
    obj = addr_to_obj(addr, adapter=adapter)
    busctl_set_bool(obj, "Trusted", False)
    await bluez_disconnect_loop(addr, seconds=2.5, adapter=adapter)
    if block:
        busctl_set_bool(obj, "Blocked", True)
    if remove:
        # Adapter1.RemoveDevice(o)
        adapter_obj = f"/org/bluez/{adapter}"
        busctl_call(adapter_obj, "org.bluez.Adapter1", "RemoveDevice", "o", obj)


# ---------------- BLE helpers ----------------
@dataclass
class BleCtx:
    client: BleakClient
    write_uuid: str
    notify_uuid: str
    rx_queue: "asyncio.Queue[bytes]"
    lock_endian: str = "big"   # will be updated by variant search if needed
    pw_pad: int = 0xFF         # FF recommended by doc for 123456


async def safe_gap(min_ms: int = 120) -> None:
    await asyncio.sleep(min_ms / 1000.0)


async def write_cmd(ctx: BleCtx, cmd: int, data: bytes = b"") -> None:
    await safe_gap(110)
    frame = build_frame(cmd, data)
    await ctx.client.write_gatt_char(ctx.write_uuid, frame, response=False)
    print(f"[TX] {CMD_NAMES.get(cmd, f'CMD 0x{cmd:02X}')} -> {hx(frame)}")


async def wait_rsp(ctx: BleCtx, expect_cmd: int, timeout: float = 3.0) -> Optional[Frame]:
    end = time.time() + timeout
    while time.time() < end:
        remain = end - time.time()
        try:
            raw = await asyncio.wait_for(ctx.rx_queue.get(), timeout=remain)
        except asyncio.TimeoutError:
            return None
        fr = parse_frame(raw)
        if fr and fr.cmd == expect_cmd:
            return fr
    return None


def pretty(fr: Frame) -> str:
    base = fr.cmd & 0x7F
    is_rsp = (fr.cmd & 0x80) != 0
    name = CMD_NAMES.get(base, f"0x{base:02X}")
    flags = []
    if not fr.length_ok:
        flags.append("LEN_MISMATCH")
    if not fr.xor_ok:
        flags.append("XOR_BAD")
    flag_s = f" [{' '.join(flags)}]" if flags else ""
    return f"{'RSP' if is_rsp else 'NOTIFY'}({name}) cmd=0x{fr.cmd:02X} data={hx(fr.data)}{flag_s}"


async def do_login_once(ctx: BleCtx, lock_id: int, password: str) -> Tuple[bool, Optional[int]]:
    data = encode_lock_id(lock_id, ctx.lock_endian) + encode_password(password, ctx.pw_pad)
    await write_cmd(ctx, CMD_LOGIN, data=data)
    fr = await wait_rsp(ctx, EXPECT_RSP[CMD_LOGIN], timeout=4.0)  # type: ignore[arg-type]
    if not fr:
        print("[RX] 로그인 응답 없음")
        return False, None
    print("[RX] " + pretty(fr))
    if fr.data:
        ack = fr.data[0]
        print(decode_ack(fr.data))
        return ack == 0, ack
    return False, None


async def login_variant_search(ctx: BleCtx, lock_id: int, password: str) -> bool:
    """
    Try variants:
      endian: big/little
      pw_pad: 0xFF / 0x00
    Stop at first success (ack==0).
    """
    variants = [
        ("big", 0xFF),
        ("little", 0xFF),
        ("big", 0x00),
        ("little", 0x00),
    ]
    seen = set()
    for endian, pad in variants:
        if (endian, pad) in seen:
            continue
        seen.add((endian, pad))
        ctx.lock_endian = endian
        ctx.pw_pad = pad
        print(f"[TRY] 로그인 시도: lock_endian={endian}, pw_pad=0x{pad:02X}")
        ok, ack = await do_login_once(ctx, lock_id, password)
        if ok:
            print(f"[OK] 로그인 성공! (lock_endian={endian}, pw_pad=0x{pad:02X})")
            return True
        if ack == 5:
            print("  - 체크섬 오류(0x05) -> 프레임 형식 자체가 틀렸을 때 주로 나옵니다.")
        elif ack == 15:
            print("  - 미로그인(0x0F) -> 로그인 자체 실패 또는 권한 거부")
        elif ack == 10:
            print("  - 모터 타임아웃(0x0A) -> 장치가 fault 상태일 가능성이 큽니다.")
        await asyncio.sleep(0.25)
    print("[FAIL] 로그인 변형 4종 모두 실패")
    return False



async def drain_queue(q: "asyncio.Queue[Frame]") -> None:
    """Drain an asyncio.Queue without blocking."""
    try:
        while True:
            _ = q.get_nowait()
    except Exception:
        return

async def collect_status_stable(
    status_queue: "asyncio.Queue[Frame]",
    window: float = 10.0,
    settle_consecutive: int = 2,
) -> tuple[Optional[int], Optional[Frame], int]:
    """
    Collect 0x41 status reports for up to `window` seconds and return:
      (stable_bit0, last_frame, samples_count)

    - stable_bit0 is determined by `settle_consecutive` identical consecutive bit0 values.
    - If not settled, it falls back to the last observed bit0 (if any).
    """
    loop = asyncio.get_running_loop()
    deadline = loop.time() + window

    last_frame: Optional[Frame] = None
    last_b0: Optional[int] = None
    stable: Optional[int] = None
    consec = 0
    samples = 0

    while True:
        remain = deadline - loop.time()
        if remain <= 0:
            break
        try:
            fr = await asyncio.wait_for(status_queue.get(), timeout=remain)
        except asyncio.TimeoutError:
            break

        samples += 1
        last_frame = fr
        b0 = arm_state_from_frame(fr)
        if b0 is None:
            continue

        if b0 == last_b0:
            consec += 1
        else:
            last_b0 = b0
            consec = 1

        if consec >= settle_consecutive:
            stable = b0
            break

    if stable is None:
        stable = last_b0
    return stable, last_frame, samples

async def request_status_snapshot(
    ctx: "BleCtx",
    status_queue: "asyncio.Queue[Frame]",
    window: float = 2.0,
    settle_consecutive: int = 2,
) -> tuple[Optional[int], Optional[Frame], int]:
    """
    Send CMD_GET_STATUS(0x05) to provoke a 0x41 status report and return a stabilized value.
    """
    await drain_queue(status_queue)
    await write_cmd(ctx, CMD_GET_STATUS)
    return await collect_status_stable(status_queue, window=window, settle_consecutive=settle_consecutive)

def arm_state_from_frame(fr: Frame) -> Optional[int]:
    """
    Return bit0 of lock_state if payload seems valid: status_report payload is 5 bytes.
    lock_state byte index=2.
    """
    if not fr or len(fr.data) < 3:
        return None
    lock_state = fr.data[2]
    return 1 if (lock_state & 1) else 0  # 0=ARM_UP(lock), 1=ARM_DOWN(unlock)

def describe_arm(bit0: int) -> str:
    return "ARM_DOWN(해제)" if bit0 == 1 else "ARM_UP(잠금)"

def print_help() -> None:
    print(
        "\n[메뉴]\n"
        "  1) 로그인(변형 자동탐색)\n"
        "  2) 상승(올림)\n"
        "  3) 하강(내림)\n"
        "  4) 상태 조회\n"
        "  5) 버전 조회\n"
        "  6) 자석 한계 상태 조회\n"
        "  7) 재부팅(응답 없음)\n"
        "  8) 리모컨 설정(mode=1/0/3)\n"
        "  9) 종료(블루즈 자동재연결 차단 옵션 적용)\n"
        "  p) (선택) OS 페어링(pair) 시도\n"
    )


async def run_menu(ctx: BleCtx, lock_id: int, password: str, status_queue: "asyncio.Queue[Frame]") -> None:
    print_help()
    while True:
        s = input("선택> ").strip().lower()
        if s in ("9", "0", "q", "quit", "exit"):
            return

        if s == "p":
            try:
                paired = await ctx.client.pair()
                print(f"[BLE] pair() 결과: {paired}")
            except Exception as e:
                print(f"[BLE] pair() 실패/불필요: {e}")
            continue

        if s == "1":
            ok = await login_variant_search(ctx, lock_id, password)
            print(f"로그인 결과: {'성공' if ok else '실패'}")
            continue

        if s == "2":
            await write_cmd(ctx, CMD_UP)
            fr = await wait_rsp(ctx, EXPECT_RSP[CMD_UP], timeout=3.0)  # type: ignore[arg-type]
            if fr:
                print("[RX] " + pretty(fr))
                if fr.data:
                    print(decode_ack(fr.data))
                ack = fr.data[0] if fr.data else None
                if ack == 0:
                    # 자동 상태 확인(안정화): ACK 후 상태 요청(0x05)로 0x41 유도 → 10초 내 안정화(2회 연속) 판정
                    stable, last_fr, samples = await request_status_snapshot(ctx, status_queue, window=10.0, settle_consecutive=2)
                    if last_fr:
                        print("[AUTO] (상태 관측) " + pretty(last_fr))
                        print(decode_status_payload(last_fr.data))
                    if stable is None:
                        print("[AUTO] 상태 판정 실패: 0x41 수신 없음/불충분")
                    else:
                        exp = 0  # 기대: ARM_UP(잠금)
                        print(f"[AUTO] 판정: 기대={describe_arm(exp)} / 현재={describe_arm(stable)} / samples={samples} -> " +
                              ("OK" if stable == exp else "MISMATCH"))
            else:
                print("[RX] 응답 없음")
            continue

        if s == "3":
            await write_cmd(ctx, CMD_DOWN)
            fr = await wait_rsp(ctx, EXPECT_RSP[CMD_DOWN], timeout=3.0)  # type: ignore[arg-type]
            if fr:
                print("[RX] " + pretty(fr))
                if fr.data:
                    print(decode_ack(fr.data))
                ack = fr.data[0] if fr.data else None
                if ack == 0:
                    # 자동 상태 확인(안정화): ACK 후 상태 요청(0x05)로 0x41 유도 → 10초 내 안정화(2회 연속) 판정
                    stable, last_fr, samples = await request_status_snapshot(ctx, status_queue, window=10.0, settle_consecutive=2)
                    if last_fr:
                        print("[AUTO] (상태 관측) " + pretty(last_fr))
                        print(decode_status_payload(last_fr.data))
                    if stable is None:
                        print("[AUTO] 상태 판정 실패: 0x41 수신 없음/불충분")
                    else:
                        exp = 1  # 기대: ARM_DOWN(해제)
                        print(f"[AUTO] 판정: 기대={describe_arm(exp)} / 현재={describe_arm(stable)} / samples={samples} -> " +
                              ("OK" if stable == exp else "MISMATCH"))
            else:
                print("[RX] 응답 없음")
            continue

        if s == "4":
            # 안정화된 상태 조회:
            # - 요청(0x05)로 0x41을 유도한 뒤, 2초 동안 관측
            # - bit0가 2회 연속 동일하면 그 값을 사용, 아니면 마지막 값을 사용
            stable, last_fr, samples = await request_status_snapshot(ctx, status_queue, window=2.5, settle_consecutive=2)
            if last_fr:
                print("[RX] (상태 스냅샷) " + pretty(last_fr))
                print(decode_status_payload(last_fr.data))
            else:
                print("[RX] 상태 스냅샷(0x41) 수신 실패: timeout (장치가 푸시를 안 하거나 BLE 링크가 불안정할 수 있음)")
            if stable is not None:
                print(f"[RX] (안정화 판정) arm={describe_arm(stable)} / samples={samples}")
            continue

        if s == "5":
            await write_cmd(ctx, CMD_GET_VERSION)
            fr = await wait_rsp(ctx, EXPECT_RSP[CMD_GET_VERSION], timeout=3.5)  # type: ignore[arg-type]
            if fr:
                print("[RX] " + pretty(fr))
                if len(fr.data) == 1:
                    print(decode_ack(fr.data))
                else:
                    print(decode_version_payload(fr.data))
            else:
                print("[RX] 응답 없음")
            continue

        if s == "6":
            await write_cmd(ctx, CMD_GET_LIMIT)
            fr = await wait_rsp(ctx, EXPECT_RSP[CMD_GET_LIMIT], timeout=3.0)  # type: ignore[arg-type]
            if fr:
                print("[RX] " + pretty(fr))
                if len(fr.data) == 1:
                    print(decode_ack(fr.data))
                else:
                    print(decode_limit_payload(fr.data))
            else:
                print("[RX] 응답 없음")
            continue

        if s == "7":
            await write_cmd(ctx, CMD_REBOOT)
            print("재부팅 명령 전송 완료(문서상 응답 없음).")
            continue

        if s == "8":
            mode = input("리모컨 모드 입력 (1=추가/삭제, 0=종료, 3=전체삭제): ").strip()
            if mode not in ("0", "1", "3"):
                print("잘못된 모드입니다.")
                continue

        if s == "t":
            print("[TEST] 자동 테스트 시작: 상태→올림→상태→내림→상태")

            # S0: 현재 상태(안정화)
            stable0, fr0, n0 = await request_status_snapshot(ctx, status_queue, window=3.0, settle_consecutive=2)
            if fr0:
                print("[TEST] S0 " + decode_status_payload(fr0.data))
            else:
                print("[TEST] S0 timeout")
            if stable0 is not None:
                print(f"[TEST] S0 arm={describe_arm(stable0)} / samples={n0}")

            # UP
            await write_cmd(ctx, CMD_UP)
            r1 = await wait_rsp(ctx, EXPECT_RSP[CMD_UP], timeout=3.0)  # type: ignore[arg-type]
            if r1 and r1.data:
                print("[TEST] UP " + decode_ack(r1.data))
            else:
                print("[TEST] UP timeout")

            stable1, fr1, n1 = await request_status_snapshot(ctx, status_queue, window=10.0, settle_consecutive=2)
            if fr1:
                print("[TEST] S1 " + decode_status_payload(fr1.data))
            else:
                print("[TEST] S1 timeout")
            if stable1 is not None:
                exp = 0
                print(f"[TEST] S1 기대={describe_arm(exp)} / 현재={describe_arm(stable1)} / samples={n1} -> " +
                      ("OK" if stable1 == exp else "MISMATCH"))

            # DOWN
            await write_cmd(ctx, CMD_DOWN)
            r2 = await wait_rsp(ctx, EXPECT_RSP[CMD_DOWN], timeout=3.0)  # type: ignore[arg-type]
            if r2 and r2.data:
                print("[TEST] DOWN " + decode_ack(r2.data))
            else:
                print("[TEST] DOWN timeout")

            stable2, fr2, n2 = await request_status_snapshot(ctx, status_queue, window=10.0, settle_consecutive=2)
            if fr2:
                print("[TEST] S2 " + decode_status_payload(fr2.data))
            else:
                print("[TEST] S2 timeout")
            if stable2 is not None:
                exp = 1
                print(f"[TEST] S2 기대={describe_arm(exp)} / 현재={describe_arm(stable2)} / samples={n2} -> " +
                      ("OK" if stable2 == exp else "MISMATCH"))

            print("[TEST] 자동 테스트 종료")
            continue
            data = bytes([int(mode)])
            await write_cmd(ctx, CMD_REMOTE_CFG, data=data)
            exp = EXPECT_RSP[CMD_REMOTE_CFG]
            if exp is not None:
                fr = await wait_rsp(ctx, exp, timeout=3.0)
                if fr:
                    print("[RX] " + pretty(fr))
                    print(decode_ack(fr.data))
                else:
                    print("[RX] 응답 없음")
            continue

        print_help()


async def resolve_chars(client: BleakClient) -> Tuple[str, str]:
    services = getattr(client, "services", None)
    if services is None:
        # fallback for older bleak - may warn in some versions, but only used if needed
        services = await client.get_services()

    service = None
    try:
        for su in SERVICE_UUID_CANDIDATES:
            service = services.get_service(su)
            if service:
                break
    except Exception:
        service = None

    chars = []
    if service:
        chars = list(service.characteristics)
    else:
        # fallback: scan all services
        try:
            for s in services:
                chars.extend(list(s.characteristics))
        except Exception:
            pass

    notify_uuid = None
    for cu in CHAR_UUID_CANDIDATES:
        for ch in chars:
            if ch.uuid.lower() == cu.lower() and ("notify" in ch.properties):
                notify_uuid = ch.uuid
                break
        if notify_uuid:
            break
    if not notify_uuid:
        for ch in chars:
            if "notify" in ch.properties:
                notify_uuid = ch.uuid
                break

    write_uuid = None
    for ch in chars:
        if ("write" in ch.properties) or ("write-without-response" in ch.properties):
            if any(ch.uuid.lower() == cu.lower() for cu in CHAR_UUID_CANDIDATES):
                write_uuid = ch.uuid
                break
            if write_uuid is None:
                write_uuid = ch.uuid

    if not notify_uuid:
        raise RuntimeError("Notify 특성을 찾지 못했습니다. (UUID 확인 필요)")
    if not write_uuid:
        write_uuid = notify_uuid

    print("\n[GATT] 선택된 특성")
    print(f"  notify_uuid = {notify_uuid}")
    print(f"  write_uuid  = {write_uuid}")
    return write_uuid, notify_uuid


async def pick_device(timeout: float = 6.0) -> Optional[Tuple[str, str]]:
    print(f"\n[SCAN] 주변 BLE 스캔 중... ({timeout:.1f}s)")
    try:
        found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    except TypeError:
        found = await BleakScanner.discover(timeout=timeout)

    def norm_items(obj):
        if obj is None:
            return []
        if isinstance(obj, dict):
            return list(obj.values())
        if isinstance(obj, (list, tuple, set)):
            return list(obj)
        return [obj]

    items = norm_items(found)

    rows: List[Tuple[int, str, str, int]] = []
    idx = 1
    for it in items:
        dev = None
        adv = None
        if isinstance(it, (tuple, list)) and len(it) >= 1:
            dev = it[0]
            adv = it[1] if len(it) >= 2 else None
        else:
            dev = it

        if isinstance(dev, str):
            addr = dev
            name = ""
            rssi = 0
        else:
            addr = getattr(dev, "address", "") or ""
            name = getattr(dev, "name", "") or ""
            rssi = 0
            if adv is not None:
                rv = getattr(adv, "rssi", None)
                if isinstance(rv, int):
                    rssi = rv
            if rssi == 0:
                rv2 = getattr(dev, "rssi", None)
                if isinstance(rv2, int):
                    rssi = rv2

        if addr:
            rows.append((idx, addr, name, int(rssi)))
            idx += 1

    if rows:
        print("\n번호 | RSSI | Address | Name")
        print("-" * 72)
        for i, addr, name, rssi in rows:
            print(f"{i:>4} | {rssi:>4} | {addr:<18} | {name}")
    else:
        print("  스캔 결과가 없습니다. (연결 중인 기기는 광고를 안 할 수 있어요)")

    while True:
        s = input("\n연결할 기기 번호 입력, 또는 m=수동입력, q=종료: ").strip().lower()
        if s in ("q", "quit", "exit"):
            return None
        if s == "m":
            addr = input("MAC 주소 입력(예: E0:4E:7A:4A:D5:03): ").strip()
            name = input("이름(예: PL0000000033) (모르면 엔터): ").strip()
            return addr, name
        if s.isdigit():
            sel = int(s)
            if 1 <= sel <= len(rows):
                _, addr, name, _ = rows[sel - 1]
                return addr, name
        print("  잘못된 입력입니다.")


async def main() -> None:
    if sys.platform.startswith("win"):
        try:
            asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())  # type: ignore[attr-defined]
        except Exception:
            pass

    picked = await pick_device(timeout=6.0)
    if not picked:
        return
    address, name = picked

    lock_id = try_parse_lock_id(name or "")
    if lock_id is None:
        s = input("기기 이름에서 락번호(PL...)를 찾지 못했습니다. 락 번호(숫자만) 입력: ").strip()
        if not s.isdigit():
            print("락 번호 입력이 올바르지 않습니다. 종료합니다.")
            return
        lock_id = int(s)

    password = input("로그인 비밀번호(기본 123456): ").strip() or "123456"

    # auto-reconnect mitigation switches
    block_on_exit = True
    remove_on_exit = False

    print(f"\n[INFO] 선택된 기기: addr={address}, name={name}")
    print(f"[INFO] 락 번호: {lock_id} (PL{lock_id:010d} 형태)")
    print(f"[INFO] 로그인 비밀번호: {password}")
    print(f"[INFO] 종료 시 Blocked=true 적용: {block_on_exit} (BlueZ 자동재연결 차단)")
    print(f"[INFO] 종료 시 RemoveDevice 적용: {remove_on_exit}")

    print("\n[FLOW] BlueZ 상태 정리(언블록/언트러스트/강제disconnect)...")
    await bluez_unblock_for_app(address)

    rx_queue: asyncio.Queue[bytes] = asyncio.Queue()
    status_queue: asyncio.Queue[Frame] = asyncio.Queue()
    notify_uuid: Optional[str] = None

    def on_disconnect(_client: BleakClient):
        print("\n[BLE] 연결이 끊어졌습니다(콜백).")

    client = BleakClient(address, disconnected_callback=on_disconnect)

    try:
        print("\n[BLE] 연결 중...")
        await client.connect(timeout=12.0)
        print("[BLE] 연결 완료.")
        print("  - OS에서 PIN/패스키 팝업이 뜨면 '123456' 입력 (필요할 때만)")

        write_uuid, notify_uuid = await resolve_chars(client)
        ctx = BleCtx(client=client, write_uuid=write_uuid, notify_uuid=notify_uuid, rx_queue=rx_queue)

        async def handle_state_report(fr: Frame) -> None:
            # ACK to state report (best-effort)
            ack_cmd = (CMD_STATE_REPORT | 0x80)
            ack = build_frame(ack_cmd, b"\x00")
            try:
                await safe_gap(110)
                await client.write_gatt_char(write_uuid, ack, response=False)
                print(f"[TX][AUTO-ACK] 상태보고 ACK -> {hx(ack)}")
            except Exception as e:
                print(f"[WARN] 상태보고 ACK 실패: {e}")

        def notify_cb(_uuid: str, data: bytearray):
            raw = bytes(data)
            fr = parse_frame(raw)
            if fr:
                base = fr.cmd & 0x7F
                # 0x41 상태보고(Notify)는 "요청-응답" 큐로 넣지 않고 별도 큐로 관리합니다.
                # (CMD 0x05 상태조회는 문서상 0x41과 동일 데이터로 올 수 있어서 0x85가 없을 수 있음)
                if base == CMD_STATE_REPORT and (fr.cmd & 0x80) == 0:
                    print("\n[RX][NOTIFY] " + pretty(fr))
                    # (printed above)
                    print(decode_status_payload(fr.data))
                    try:
                        status_queue.put_nowait(fr)
                    except Exception:
                        pass
                    asyncio.create_task(handle_state_report(fr))
                    return  # <-- rx_queue로는 넣지 않음

                # 그 외 프레임만 wait_rsp용 큐로 전달
                rx_queue.put_nowait(raw)
            else:
                print(f"\n[RX] (파싱 실패) raw={hx(raw)}")
                # (printed above)


        print("\n[BLE] Notify 구독 시작...")
        # (printed above)
        await client.start_notify(notify_uuid, notify_cb)
        print("[BLE] Notify OK.")

        # auto login variant search
        print("\n[FLOW] 연결 직후 로그인(변형 자동탐색) 시도...")
        ok = await login_variant_search(ctx, lock_id, password)
        print(f"[FLOW] 자동 로그인 결과: {'성공' if ok else '실패'}")

        if not ok:
            print("\n[HINT] 로그인 실패 후 버전/상태가 0x0F(미로그인)로만 나오면 정상입니다.")
            print("       만약 ack=0x0A(모터 타임아웃)만 계속 나오면, 장치가 fault 상태일 가능성이 큽니다.")
            print("       현장 확인(암 걸림/장애물/배터리) 또는 '7) 재부팅' 후 재시도 권장.")

        await run_menu(ctx, lock_id, password, status_queue)

    except BleakError as e:
        print(f"[BLE] 실패: {e}")
        print("  - RPi에서는 sudo 실행이 더 안정적입니다: sudo python3 parking_lock_ble_cli_pi_final.py")
    except Exception as e:
        print(f"[ERR] 예외: {e}")
    finally:
        print("\n[FLOW] 종료 처리: Notify 해제 및 disconnect...")
        try:
            if notify_uuid:
                await client.stop_notify(notify_uuid)
        except Exception:
            pass
        try:
            if client.is_connected:
                await client.disconnect()
        except Exception:
            pass

        print("[FLOW] BlueZ 자동재연결 차단(옵션) 적용 중...")
        await bluez_lockdown_after_use(address, block=block_on_exit, remove=remove_on_exit)

        # show connected state via DBus if possible
        if have_busctl():
            obj = addr_to_obj(address)
            c = busctl_get_bool(obj, "Connected")
            b = busctl_get_bool(obj, "Blocked")
            t = busctl_get_bool(obj, "Trusted")
            print(f"[BLUEZ] Connected={c}  Blocked={b}  Trusted={t}")

        print("[DONE] 종료.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
