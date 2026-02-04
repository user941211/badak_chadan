import { useCallback, useEffect, useMemo, useState } from "react";
import AppHeader from "./components/AppHeader";
import {
  addDevice,
  deleteDevicePeriod,
  deleteDeviceParkingLotName,
  deleteDevicePhone,
  deleteDeviceRow,
  deleteDeviceOriginId,
  getDefaultApiBaseUrl,
  getDevicesWithAuth,
  login,
  updateDevicePeriod,
  updateDeviceParkingLotName,
  updateDeviceOriginId,
  updateDevicePhone
} from "./api/devices";

const PERIOD_PATTERN = /^(\d{4}-\d{2}-\d{2})~(\d{4}-\d{2}-\d{2})$/;
const AUTH_STORAGE_KEY = "badak_chadan_auth_state";

const createInputMap = (rows, key) =>
  Object.fromEntries(rows.map((row) => [row.device_id, row[key] ?? ""]));

const normalizeRows = (rows) =>
  rows
    .map((row) => {
      if (!row || typeof row !== "object") {
        return null;
      }

      const rawDeviceId = row.device_id ?? row.id ?? "";
      const deviceId =
        typeof rawDeviceId === "string" || typeof rawDeviceId === "number"
          ? String(rawDeviceId)
          : "";

      if (!deviceId) {
        return null;
      }

      return {
        ...row,
        device_id: deviceId
      };
    })
    .filter((row) => row && row.device_id);

const getCellText = (value) => {
  if (value === null || value === undefined || value === "") {
    return "없음";
  }

  if (typeof value === "object") {
    try {
      return JSON.stringify(value);
    } catch {
      return String(value);
    }
  }

  return String(value);
};

const parsePeriodRange = (value) => {
  if (typeof value !== "string") {
    return { startDate: "", endDate: "" };
  }

  const match = value.trim().match(PERIOD_PATTERN);
  if (!match) {
    return { startDate: "", endDate: "" };
  }

  return { startDate: match[1], endDate: match[2] };
};

const formatPeriodRange = (startDate, endDate) => `${startDate}~${endDate}`;
const getTodayDateString = () => {
  const now = new Date();
  const localNow = new Date(now.getTime() - now.getTimezoneOffset() * 60000);
  return localNow.toISOString().slice(0, 10);
};

const encodeBasicToken = (id, pw) => {
  const source = `${id}:${pw}`;
  const bytes = new TextEncoder().encode(source);
  let binary = "";
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return window.btoa(binary);
};

const getStoredAuthState = () => {
  if (typeof window === "undefined") {
    return null;
  }

  const stored = window.localStorage.getItem(AUTH_STORAGE_KEY);
  if (!stored) {
    return null;
  }

  try {
    const parsed = JSON.parse(stored);
    if (
      parsed &&
      parsed.user &&
      typeof parsed.user.id === "string" &&
      typeof parsed.basicToken === "string"
    ) {
      return parsed;
    }
  } catch {
    return null;
  }

  return null;
};

const storeAuthState = (state) => {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(AUTH_STORAGE_KEY, JSON.stringify(state));
};

const clearStoredAuthState = () => {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(AUTH_STORAGE_KEY);
};

function App() {
  const apiBaseUrl = useMemo(() => getDefaultApiBaseUrl(), []);
  const today = useMemo(() => getTodayDateString(), []);

  const [authState, setAuthState] = useState(() => getStoredAuthState());
  const [loginForm, setLoginForm] = useState({ id: "", pw: "" });
  const [loginBusy, setLoginBusy] = useState(false);
  const [loginError, setLoginError] = useState("");

  const [devices, setDevices] = useState([]);
  const [phoneInputs, setPhoneInputs] = useState({});
  const [parkingLotInputs, setParkingLotInputs] = useState({});
  const [originIdInputs, setOriginIdInputs] = useState({});
  const [periodEditor, setPeriodEditor] = useState({
    open: false,
    deviceId: "",
    startDate: "",
    endDate: ""
  });

  const [newDeviceId, setNewDeviceId] = useState("");
  const [loading, setLoading] = useState(false);
  const [mutating, setMutating] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const authUser = authState?.user || null;
  const basicAuth = useMemo(
    () =>
      authState?.basicToken ? { basicToken: authState.basicToken } : null,
    [authState?.basicToken]
  );
  const canDeleteRow = authUser?.id === "master";
  const isBusy = loading || mutating;
  const deviceIdCollator = useMemo(
    () => new Intl.Collator("ko", { numeric: true, sensitivity: "base" }),
    []
  );

  const loadDevices = useCallback(async () => {
    if (!authUser?.id) {
      return;
    }

    setLoading(true);
    setError("");

    try {
      const result = await getDevicesWithAuth(apiBaseUrl, authUser.id, basicAuth);
      const rows = normalizeRows(Array.isArray(result) ? result : []);
      setDevices(rows);
      setPhoneInputs(createInputMap(rows, "phone_number"));
      setParkingLotInputs(createInputMap(rows, "parking_lot_name"));
      setOriginIdInputs(createInputMap(rows, "origin_id"));
    } catch (requestError) {
      if (requestError?.status === 401) {
        clearStoredAuthState();
        setAuthState(null);
        setLoginError("인증이 만료되었거나 유효하지 않습니다. 다시 로그인해주세요.");
        return;
      }
      setError(`장치 목록을 불러오지 못했습니다: ${requestError.message}`);
    } finally {
      setLoading(false);
    }
  }, [apiBaseUrl, authUser?.id, basicAuth]);

  useEffect(() => {
    if (!authUser) {
      setDevices([]);
      setPhoneInputs({});
      setParkingLotInputs({});
      setOriginIdInputs({});
      return;
    }

    void loadDevices();
  }, [authUser, loadDevices]);

  const runMutation = useCallback(
    async (action, successMessage) => {
      setMutating(true);
      setError("");
      setNotice("");

      try {
        await action();
        await loadDevices();
        setNotice(successMessage);
        return true;
      } catch (requestError) {
        if (requestError?.status === 401) {
          clearStoredAuthState();
          setAuthState(null);
          setLoginError("인증이 만료되었거나 유효하지 않습니다. 다시 로그인해주세요.");
          return false;
        }
        setError(requestError.message);
        return false;
      } finally {
        setMutating(false);
      }
    },
    [loadDevices]
  );

  const handleLogin = async (event) => {
    event.preventDefault();
    const trimmedId = loginForm.id.trim();

    if (!trimmedId || !loginForm.pw) {
      setLoginError("아이디와 비밀번호를 모두 입력해주세요.");
      return;
    }

    setLoginBusy(true);
    setLoginError("");

    try {
      const result = await login(apiBaseUrl, trimmedId, loginForm.pw);
      const user = {
        num_id: result.num_id ?? null,
        id: result.id || trimmedId,
        parking_lot_name: result.parking_lot_name || ""
      };

      const storedState = {
        user,
        basicToken: encodeBasicToken(trimmedId, loginForm.pw)
      };
      storeAuthState(storedState);
      setAuthState(storedState);
      setLoginForm({ id: "", pw: "" });
      setNotice("");
      setError("");
    } catch (requestError) {
      setLoginError(requestError.message || "로그인에 실패했습니다.");
    } finally {
      setLoginBusy(false);
    }
  };

  const handleLogout = () => {
    clearStoredAuthState();
    setAuthState(null);
    setLoginForm({ id: "", pw: "" });
    setLoginError("");
    setDevices([]);
    setPhoneInputs({});
    setParkingLotInputs({});
    setOriginIdInputs({});
    setNewDeviceId("");
    setError("");
    setNotice("");
    setMutating(false);
    setLoading(false);
    setPeriodEditor({
      open: false,
      deviceId: "",
      startDate: "",
      endDate: ""
    });
  };

  const updateLoginField = (field, value) => {
    setLoginForm((prev) => ({
      ...prev,
      [field]: value
    }));
  };

  const handleAddRow = async () => {
    if (!canDeleteRow) {
      setError("행 추가는 master 계정만 가능합니다.");
      return;
    }

    const trimmedDeviceId = newDeviceId.trim();
    if (!trimmedDeviceId) {
      setError("device_id를 입력해주세요.");
      return;
    }

    const succeeded = await runMutation(
      () => addDevice(apiBaseUrl, trimmedDeviceId, basicAuth),
      `${trimmedDeviceId} 행을 추가했습니다.`
    );
    if (succeeded) {
      setNewDeviceId("");
    }
  };

  const updatePhoneInput = (deviceId, value) => {
    setPhoneInputs((prev) => ({ ...prev, [deviceId]: value }));
  };

  const updateParkingLotInput = (deviceId, value) => {
    setParkingLotInputs((prev) => ({ ...prev, [deviceId]: value }));
  };

  const updateOriginIdInput = (deviceId, value) => {
    setOriginIdInputs((prev) => ({ ...prev, [deviceId]: value }));
  };

  const openPeriodEditor = (deviceId, assignedPeriod) => {
    const { startDate, endDate } = parsePeriodRange(assignedPeriod);
    setPeriodEditor({
      open: true,
      deviceId,
      startDate,
      endDate
    });
  };

  const closePeriodEditor = () => {
    setPeriodEditor({
      open: false,
      deviceId: "",
      startDate: "",
      endDate: ""
    });
  };

  const updatePeriodEditorField = (field, value) => {
    setPeriodEditor((prev) => ({
      ...prev,
      [field]: value
    }));
  };

  const handleSavePhone = async (deviceId) => {
    const value = (phoneInputs[deviceId] ?? "").trim();
    if (!value) {
      setError("phone_number는 비워둘 수 없습니다. null로 만들려면 삭제를 눌러주세요.");
      return;
    }

    await runMutation(
      () => updateDevicePhone(apiBaseUrl, deviceId, value, basicAuth),
      `${deviceId}의 phone_number를 저장했습니다.`
    );
  };

  const handleDeletePhone = async (deviceId) => {
    await runMutation(
      () => deleteDevicePhone(apiBaseUrl, deviceId, basicAuth),
      `${deviceId}의 phone_number를 삭제했습니다.`
    );
  };

  const handleSavePeriod = async () => {
    const { deviceId, startDate, endDate } = periodEditor;

    if (!startDate || !endDate) {
      setError("시작일과 종료일을 모두 선택해주세요.");
      return;
    }

    if (startDate < today) {
      setError(`시작일은 오늘(${today})보다 빠를 수 없습니다.`);
      return;
    }

    if (startDate > endDate) {
      setError("종료일은 시작일보다 빠를 수 없습니다.");
      return;
    }

    const value = formatPeriodRange(startDate, endDate);
    const succeeded = await runMutation(
      () => updateDevicePeriod(apiBaseUrl, deviceId, value, basicAuth),
      `${deviceId}의 부여기간을 저장했습니다.`
    );
    if (succeeded) {
      closePeriodEditor();
    }
  };

  const handleDeletePeriod = async (deviceId) => {
    const succeeded = await runMutation(
      () => deleteDevicePeriod(apiBaseUrl, deviceId, basicAuth),
      `${deviceId}의 부여기간을 삭제했습니다.`
    );
    if (succeeded && periodEditor.open && periodEditor.deviceId === deviceId) {
      closePeriodEditor();
    }
  };

  const handleSaveParkingLotName = async (deviceId) => {
    if (!canDeleteRow) {
      setError("parking_lot_name 수정은 master 계정만 가능합니다.");
      return;
    }

    const value = (parkingLotInputs[deviceId] ?? "").trim();
    if (!value) {
      setError("parking_lot_name은 비워둘 수 없습니다. null로 만들려면 삭제를 눌러주세요.");
      return;
    }

    await runMutation(
      () => updateDeviceParkingLotName(apiBaseUrl, deviceId, value, basicAuth),
      `${deviceId}의 parking_lot_name을 저장했습니다.`
    );
  };

  const handleDeleteParkingLotName = async (deviceId) => {
    if (!canDeleteRow) {
      setError("parking_lot_name 삭제는 master 계정만 가능합니다.");
      return;
    }

    await runMutation(
      () => deleteDeviceParkingLotName(apiBaseUrl, deviceId, basicAuth),
      `${deviceId}의 parking_lot_name을 삭제했습니다.`
    );
  };

  const handleSaveOriginId = async (deviceId) => {
    if (!canDeleteRow) {
      setError("origin_id 수정은 master 계정만 가능합니다.");
      return;
    }

    const value = (originIdInputs[deviceId] ?? "").trim();
    if (!value) {
      setError("origin_id는 비워둘 수 없습니다. null로 만들려면 삭제를 눌러주세요.");
      return;
    }

    await runMutation(
      () => updateDeviceOriginId(apiBaseUrl, deviceId, value, basicAuth),
      `${deviceId}의 origin_id를 저장했습니다.`
    );
  };

  const handleDeleteOriginId = async (deviceId) => {
    if (!canDeleteRow) {
      setError("origin_id 삭제는 master 계정만 가능합니다.");
      return;
    }

    await runMutation(
      () => deleteDeviceOriginId(apiBaseUrl, deviceId, basicAuth),
      `${deviceId}의 origin_id를 삭제했습니다.`
    );
  };

  const handleDeleteRow = async (deviceId) => {
    if (!canDeleteRow) {
      setError("행 삭제는 master 계정만 가능합니다.");
      return;
    }

    const confirmed = window.confirm(`${deviceId} 행을 삭제할까요?`);
    if (!confirmed) return;

    await runMutation(
      () => deleteDeviceRow(apiBaseUrl, deviceId, basicAuth),
      `${deviceId} 행을 삭제했습니다.`
    );
  };

  const statusClassName = useMemo(() => {
    if (error) return "status-banner status-error";
    if (notice) return "status-banner status-ok";
    return "status-banner";
  }, [error, notice]);

  const endDateMin = useMemo(() => {
    if (!periodEditor.startDate) return today;
    return periodEditor.startDate > today ? periodEditor.startDate : today;
  }, [periodEditor.startDate, today]);

  const sortedDevices = useMemo(
    () =>
      [...devices].sort((left, right) =>
        deviceIdCollator.compare(left.device_id, right.device_id)
      ),
    [devices, deviceIdCollator]
  );

  const tableColumns = useMemo(() => {
    const columnSet = new Set();
    sortedDevices.forEach((row) => {
      Object.keys(row).forEach((key) => columnSet.add(key));
    });

    const prioritized = ["device_id", "phone_number", "assigned_period"];
    const ordered = prioritized.filter((key) => columnSet.has(key));
    const remains = Array.from(columnSet).filter(
      (key) => !prioritized.includes(key)
    );

    return [...ordered, ...remains];
  }, [sortedDevices]);

  const getColumnLabel = (column) => {
    if (column === "device_id") return "장치 ID";
    if (column === "phone_number") return "전화번호";
    if (column === "assigned_period") return "부여기간";
    if (column === "parking_lot_name") return "PARKING_LOT_NAME";
    if (column === "origin_id") return "ORIGIN_ID";
    return column;
  };

  if (!authUser) {
    return (
      <main className="app-shell app-shell-login">
        <section className="login-panel">
          <h1>장치 관리 로그인</h1>
          <p className="login-subtext">
            아이디와 비밀번호를 입력한 뒤 로그인해주세요.
          </p>

          {loginError && <p className="status-banner status-error">{loginError}</p>}

          <form className="login-form" onSubmit={handleLogin}>
            <label>
              아이디
              <input
                className="text-input"
                type="text"
                value={loginForm.id}
                onChange={(event) => updateLoginField("id", event.target.value)}
                autoComplete="username"
                placeholder="admin"
              />
            </label>
            <label>
              비밀번호
              <input
                className="text-input"
                type="password"
                value={loginForm.pw}
                onChange={(event) => updateLoginField("pw", event.target.value)}
                autoComplete="current-password"
                placeholder="비밀번호 입력"
              />
            </label>
            <button className="btn btn-primary login-submit-btn" type="submit" disabled={loginBusy}>
              {loginBusy ? "로그인 중..." : "로그인"}
            </button>
          </form>
        </section>
      </main>
    );
  }

  return (
    <main className="app-shell">
      <AppHeader
        totalRows={devices.length}
        userId={authUser.id}
        parkingLotName={authUser.parking_lot_name}
        onLogout={handleLogout}
        isBusy={isBusy}
      />

      <section className="table-panel">
        <div className="panel-top">
          <div>
            <h2>장치 목록</h2>
            <p>
              {canDeleteRow
                ? "행을 추가/삭제하고, 각 칼럼 값을 저장하거나 삭제할 수 있습니다."
                : "각 칼럼 값을 저장하거나 삭제할 수 있습니다."}
            </p>
          </div>
          {canDeleteRow && (
            <div className="inline-form add-form">
              <input
                className="text-input"
                type="text"
                value={newDeviceId}
                onChange={(event) => setNewDeviceId(event.target.value)}
                placeholder="새 device_id"
              />
              <button
                className="btn btn-primary"
                type="button"
                onClick={handleAddRow}
                disabled={isBusy}
              >
                행 추가
              </button>
            </div>
          )}
        </div>

        {(error || notice) && (
          <p className={statusClassName}>{error || notice}</p>
        )}

        <div className="table-scroll">
          <table className="device-table">
            <thead>
              <tr>
                {tableColumns.map((column) => (
                  <th key={column}>{getColumnLabel(column)}</th>
                ))}
                {canDeleteRow && <th>행 작업</th>}
              </tr>
            </thead>
            <tbody>
              {sortedDevices.length === 0 && (
                <tr>
                  <td
                    colSpan={tableColumns.length + (canDeleteRow ? 1 : 0)}
                    className="empty-cell"
                  >
                    {loading ? "불러오는 중..." : "장치 데이터가 없습니다."}
                  </td>
                </tr>
              )}
              {sortedDevices.map((device) => (
                <tr key={device.device_id}>
                  {tableColumns.map((column) => {
                    if (column === "device_id") {
                      return (
                        <td key={column} className="device-id-cell">
                          {device.device_id}
                        </td>
                      );
                    }

                    if (column === "phone_number") {
                      return (
                        <td key={column}>
                          <div className="cell-block">
                            <p className="value-chip">
                              {getCellText(device.phone_number)}
                            </p>
                            <div className="inline-form cell-form">
                              <input
                                className="text-input"
                                type="text"
                                value={phoneInputs[device.device_id] ?? ""}
                                onChange={(event) =>
                                  updatePhoneInput(
                                    device.device_id,
                                    event.target.value
                                  )
                                }
                                placeholder="01012345678"
                              />
                              <button
                                className="btn btn-secondary"
                                type="button"
                                onClick={() => handleSavePhone(device.device_id)}
                                disabled={isBusy}
                              >
                                저장
                              </button>
                              <button
                                className="btn btn-danger"
                                type="button"
                                onClick={() =>
                                  handleDeletePhone(device.device_id)
                                }
                                disabled={isBusy}
                              >
                                삭제
                              </button>
                            </div>
                          </div>
                        </td>
                      );
                    }

                    if (column === "assigned_period") {
                      return (
                        <td key={column}>
                          <div className="cell-block">
                            <p className="value-chip">
                              {getCellText(device.assigned_period)}
                            </p>
                            <div className="inline-form cell-form">
                              <button
                                className="btn btn-secondary"
                                type="button"
                                onClick={() =>
                                  openPeriodEditor(
                                    device.device_id,
                                    device.assigned_period
                                  )
                                }
                                disabled={isBusy}
                              >
                                달력 선택
                              </button>
                              <button
                                className="btn btn-danger"
                                type="button"
                                onClick={() =>
                                  handleDeletePeriod(device.device_id)
                                }
                                disabled={isBusy}
                              >
                                삭제
                              </button>
                            </div>
                          </div>
                        </td>
                      );
                    }

                    if (column === "parking_lot_name") {
                      return (
                        <td key={column}>
                          <div className="cell-block">
                            <p className="value-chip">
                              {getCellText(device.parking_lot_name)}
                            </p>
                            {canDeleteRow && (
                              <div className="inline-form cell-form">
                                <input
                                  className="text-input"
                                  type="text"
                                  value={parkingLotInputs[device.device_id] ?? ""}
                                  onChange={(event) =>
                                    updateParkingLotInput(
                                      device.device_id,
                                      event.target.value
                                    )
                                  }
                                  placeholder="parking_lot_name"
                                />
                                <button
                                  className="btn btn-secondary"
                                  type="button"
                                  onClick={() =>
                                    handleSaveParkingLotName(device.device_id)
                                  }
                                  disabled={isBusy}
                                >
                                  저장
                                </button>
                                <button
                                  className="btn btn-danger"
                                  type="button"
                                  onClick={() =>
                                    handleDeleteParkingLotName(device.device_id)
                                  }
                                  disabled={isBusy}
                                >
                                  삭제
                                </button>
                              </div>
                            )}
                          </div>
                        </td>
                      );
                    }

                    if (column === "origin_id") {
                      return (
                        <td key={column}>
                          <div className="cell-block">
                            <p className="value-chip">{getCellText(device.origin_id)}</p>
                            {canDeleteRow && (
                              <div className="inline-form cell-form">
                                <input
                                  className="text-input"
                                  type="text"
                                  value={originIdInputs[device.device_id] ?? ""}
                                  onChange={(event) =>
                                    updateOriginIdInput(
                                      device.device_id,
                                      event.target.value
                                    )
                                  }
                                  placeholder="origin_id"
                                />
                                <button
                                  className="btn btn-secondary"
                                  type="button"
                                  onClick={() =>
                                    handleSaveOriginId(device.device_id)
                                  }
                                  disabled={isBusy}
                                >
                                  저장
                                </button>
                                <button
                                  className="btn btn-danger"
                                  type="button"
                                  onClick={() =>
                                    handleDeleteOriginId(device.device_id)
                                  }
                                  disabled={isBusy}
                                >
                                  삭제
                                </button>
                              </div>
                            )}
                          </div>
                        </td>
                      );
                    }

                    return (
                      <td key={column}>
                        <p className="value-chip">{getCellText(device[column])}</p>
                      </td>
                    );
                  })}
                  {canDeleteRow && (
                    <td>
                      <button
                        className="btn btn-danger"
                        type="button"
                        onClick={() => handleDeleteRow(device.device_id)}
                        disabled={isBusy}
                      >
                        행 삭제
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {periodEditor.open && (
        <div
          className="modal-overlay"
          role="presentation"
          onClick={closePeriodEditor}
        >
          <div
            className="modal-card"
            role="dialog"
            aria-modal="true"
            aria-labelledby="period-modal-title"
            onClick={(event) => event.stopPropagation()}
          >
            <h3 id="period-modal-title">부여기간 선택</h3>
            <p className="modal-subtitle">
              장치 ID: <strong>{periodEditor.deviceId}</strong>
            </p>
            <div className="modal-date-grid">
              <label>
                시작일
                <input
                  className="text-input"
                  type="date"
                  value={periodEditor.startDate}
                  onChange={(event) =>
                    updatePeriodEditorField("startDate", event.target.value)
                  }
                  min={today}
                  max={periodEditor.endDate || undefined}
                />
              </label>
              <label>
                종료일
                <input
                  className="text-input"
                  type="date"
                  value={periodEditor.endDate}
                  onChange={(event) =>
                    updatePeriodEditorField("endDate", event.target.value)
                  }
                  min={endDateMin}
                />
              </label>
            </div>
            <div className="modal-actions">
              <button
                className="btn btn-primary"
                type="button"
                onClick={handleSavePeriod}
                disabled={isBusy}
              >
                저장
              </button>
              <button
                className="btn btn-secondary"
                type="button"
                onClick={closePeriodEditor}
                disabled={isBusy}
              >
                취소
              </button>
            </div>
          </div>
        </div>
      )}
    </main>
  );
}

export default App;
