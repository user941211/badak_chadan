const DEFAULT_BASE_URL = (
  import.meta.env.VITE_API_BASE_URL || "http://127.0.0.1:8000"
).replace(/\/+$/, "");

const normalizeBaseUrl = (baseUrl) =>
  (baseUrl || DEFAULT_BASE_URL).trim().replace(/\/+$/, "");

const getBasicAuthorization = (auth) => {
  if (!auth) return null;
  if (typeof auth.basicToken === "string" && auth.basicToken) {
    return `Basic ${auth.basicToken}`;
  }

  if (typeof auth.id === "string" && typeof auth.pw === "string") {
    const source = `${auth.id}:${auth.pw}`;
    const bytes = new TextEncoder().encode(source);
    let binary = "";
    bytes.forEach((byte) => {
      binary += String.fromCharCode(byte);
    });
    return `Basic ${window.btoa(binary)}`;
  }

  return null;
};

const parseError = async (response) => {
  try {
    const body = await response.json();
    if (typeof body.detail === "string") return body.detail;
    if (Array.isArray(body.detail)) {
      return body.detail.map((item) => item.msg || "Request failed").join(", ");
    }
    if (typeof body.message === "string") return body.message;
  } catch {
    return `${response.status} ${response.statusText}`;
  }

  return `${response.status} ${response.statusText}`;
};

async function request(baseUrl, path, options = {}, auth) {
  const authorization = getBasicAuthorization(auth);
  const headers = {
    ...(options.headers || {}),
    ...(authorization ? { Authorization: authorization } : {})
  };

  const response = await fetch(`${normalizeBaseUrl(baseUrl)}${path}`, {
    ...options,
    headers
  });

  if (!response.ok) {
    const error = new Error(await parseError(response));
    error.status = response.status;
    throw error;
  }

  if (response.status === 204) {
    return null;
  }

  const text = await response.text();
  if (!text) {
    return null;
  }

  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

export const getDefaultApiBaseUrl = () => DEFAULT_BASE_URL;

export const login = async (baseUrl, id, pw) => {
  const result = await request(baseUrl, "/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id, pw })
  });

  if (!result || result.success !== true) {
    throw new Error(result?.message || "로그인에 실패했습니다.");
  }

  return result;
};

export const getDevicesWithAuth = (baseUrl, userId, auth) =>
  request(baseUrl, `/web/devices/${encodeURIComponent(userId)}`, { method: "GET" }, auth);

export const addDevice = (baseUrl, deviceId, auth) =>
  request(baseUrl, "/web/device", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ device_id: deviceId })
  }, auth);

export const updateDevicePhone = (baseUrl, deviceId, phoneNumber, auth) =>
  request(baseUrl, "/web/device-phone", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ device_id: deviceId, phone_number: phoneNumber })
  }, auth);

export const updateDevicePeriod = (baseUrl, deviceId, assignedPeriod, auth) =>
  request(baseUrl, "/web/device-period", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ device_id: deviceId, assigned_period: assignedPeriod })
  }, auth);

export const updateDeviceParkingLotName = (baseUrl, deviceId, parkingLotName, auth) =>
  request(baseUrl, "/web/device-parking-lot-name", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ device_id: deviceId, parking_lot_name: parkingLotName })
  }, auth);

export const updateDeviceOriginId = (baseUrl, deviceId, originId, auth) =>
  request(baseUrl, "/web/device-origin-id", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ device_id: deviceId, origin_id: originId })
  }, auth);

export const deleteDevicePhone = (baseUrl, deviceId, auth) =>
  request(baseUrl, `/web/device-phone/${encodeURIComponent(deviceId)}`, {
    method: "DELETE"
  }, auth);

export const deleteDevicePeriod = (baseUrl, deviceId, auth) =>
  request(baseUrl, `/web/device-period/${encodeURIComponent(deviceId)}`, {
    method: "DELETE"
  }, auth);

export const deleteDeviceParkingLotName = (baseUrl, deviceId, auth) =>
  request(baseUrl, `/web/device-parking-lot-name/${encodeURIComponent(deviceId)}`, {
    method: "DELETE"
  }, auth);

export const deleteDeviceOriginId = (baseUrl, deviceId, auth) =>
  request(baseUrl, `/web/device-origin-id/${encodeURIComponent(deviceId)}`, {
    method: "DELETE"
  }, auth);

export const deleteDeviceRow = (baseUrl, deviceId, auth) =>
  request(baseUrl, `/web/device/${encodeURIComponent(deviceId)}`, {
    method: "DELETE"
  }, auth);
