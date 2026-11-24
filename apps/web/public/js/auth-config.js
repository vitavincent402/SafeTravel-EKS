/* Cognito 로그인 설정. 비밀값이 아니다(로그인 도메인과 앱 클라이언트 ID는 브라우저에 공개되는 값).
 * 값이 비어 있으면 로그인을 쓰지 않고 체험 모드(mock-api.js, 가짜 데이터)로 동작한다.
 * 새 Cognito 풀이 만들어지면 배포 때 이 파일을 실제 값으로 바꿔 넣는다(차트 값 또는 ConfigMap, soc와 상의).
 * 2.5차와 같은 모양: domain / clientId / scope / redirectPath / logoutPath */
window.ST_AUTH = {
    domain: "",
    clientId: "",
    scope: "openid email profile",
    redirectPath: "/auth/callback.html",
    logoutPath: "/"
};
