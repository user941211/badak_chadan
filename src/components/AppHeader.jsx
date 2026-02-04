function AppHeader({ totalRows, userId, parkingLotName, onLogout, isBusy }) {
  const userLabel = parkingLotName
    ? `${parkingLotName} / ${userId}`
    : userId || "로그인 사용자";

  return (
    <header className="app-header">
      <div>
        <h1>장치 테이블 관리</h1>
        <p className="count-chip">총 {totalRows}개 행</p>
      </div>
      <div className="header-actions">
        <p className="header-user">{userLabel}</p>
        <button
          className="btn btn-secondary"
          type="button"
          onClick={onLogout}
          disabled={isBusy}
        >
          로그아웃
        </button>
      </div>
    </header>
  );
}

export default AppHeader;
