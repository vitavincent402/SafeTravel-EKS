/* 화면이 api를 부르는 단 하나의 창구.
 * 로그인 설정(ST_AUTH)이 있으면 진짜 api(stApi, Cognito 토큰을 Bearer로 붙임), 비어 있으면 체험 모드(keeperMock)로 보낸다.
 * 화면 코드는 이 파일만 쓰므로, 진짜 api로 바꿀 때 화면 코드는 고치지 않는다.
 * 모든 호출은 { status, ok, data } 모양으로 돌려준다. 오류 본문은 { "error": "..." } (db 파트와 맞춘 형식).
 * 불러오는 순서: auth-config.js → cognito.js → api-client.js → mock-api.js → 이 파일 → 화면 스크립트 */
(function () {
    "use strict";

    function isMock() { return !(window.stAuth && window.stAuth.enabled()); }

    function toResult(r) {
        if (r.status === 204) { return { status: 204, ok: true, data: null }; }
        return r.json().catch(function () { return null; }).then(function (d) { return { status: r.status, ok: r.ok, data: d }; });
    }

    /* JSON 요청. headers는 추가 머리말(예: 보호자 열람 토큰 X-View-Token). */
    function call(method, url, body, headers) {
        if (isMock()) { return window.keeperMock.call(method, url, body, headers || {}); }
        var h = { "Accept": "application/json" }, k;
        for (k in (headers || {})) { if (Object.prototype.hasOwnProperty.call(headers, k)) { h[k] = headers[k]; } }
        if (method !== "GET") { h["X-Requested-With"] = "fetch"; }
        var init = { method: method, headers: h };
        if (body !== undefined && body !== null) { h["Content-Type"] = "application/json"; init.body = JSON.stringify(body); }
        return window.stApi.fetch(url, init).then(toResult);
    }

    /* 서류 파일 받기 → Blob. <img src>로는 Authorization 머리말을 못 붙이므로 받아서 blob: 주소로 보여 준다. */
    function blob(url, headers) {
        if (isMock()) { return window.keeperMock.blob(url, headers || {}); }
        return window.stApi.fetch(url, { headers: headers || {} }).then(function (r) {
            return r.ok ? r.blob() : Promise.reject({ status: r.status });
        });
    }

    /* 서류 올리기(multipart). */
    function upload(url, form) {
        if (isMock()) { return window.keeperMock.upload(url, form); }
        return window.stApi.fetch(url, { method: "POST", body: form, headers: { "X-Requested-With": "fetch" } }).then(toResult);
    }

    function isLoggedIn() { return isMock() ? !!window.keeperMock.role() : window.stAuth.isLoggedIn(); }

    /* role: 체험 모드에서만 쓴다("user" 또는 "guardian"). 진짜 로그인은 Cognito 화면에서 계정으로 정해진다. */
    function login(role) {
        if (isMock()) { window.keeperMock.login(role); location.assign("/"); return; }
        window.stAuth.login("/");
    }
    function logout() {
        if (isMock()) { window.keeperMock.logout(); location.assign("/"); return; }
        window.stApi.logout();
    }

    window.keeperApi = { isMock: isMock, call: call, blob: blob, upload: upload, isLoggedIn: isLoggedIn, login: login, logout: logout };
})();
