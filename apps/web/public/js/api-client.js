/* api 호출 공통 (ALB /api/* → keeper api 파드). 2.5차 api-client.js를 그대로 가져왔다.
 * - 모든 요청에 Authorization: Bearer <Cognito 액세스 토큰> 을 붙인다. (cognito.js 의 stAuth 사용)
 * - 로그인 전(토큰 없음)이면 서버에 보내지 않고 401 응답을 돌려준다. 로그인 화면으로 강제로 보내지 않는다.
 *   (공개 페이지에서 로그인 상태를 확인할 때 방문자를 Cognito 로 튕기지 않기 위해서)
 * - 401 을 받으면 토큰을 한 번 갱신해서 다시 보낸다. 갱신도 실패하면 401 을 그대로 돌려준다.
 * - 쿠키(세션)는 더 이상 쓰지 않으므로 credentials 는 보내지 않는다.
 * 불러오는 순서: /js/auth-config.js → /js/cognito.js → 이 파일 → 화면 스크립트 */
(function () {
    "use strict";

    function A() { return window.stAuth || null; }
    function unauthorized() {
        return new Response(JSON.stringify({ error: "UNAUTHORIZED" }), {
            status: 401, headers: { "Content-Type": "application/json" }
        });
    }
    function copyInit(init, token) {
        var o = {};
        init = init || {};
        for (var k in init) { if (Object.prototype.hasOwnProperty.call(init, k)) { o[k] = init[k]; } }
        var h = new Headers(o.headers || {});
        if (!h.has("Accept")) { h.set("Accept", "application/json"); }
        h.set("Authorization", "Bearer " + token);
        o.headers = h;
        o.credentials = "omit";
        return o;
    }

    /* fetch 와 같은 모양으로 쓴다: stApi.fetch("/api/me", { method: "GET" }) → Response */
    function apiFetch(url, init) {
        var a = A();
        if (!a || !a.enabled || !a.enabled()) { return Promise.resolve(unauthorized()); }
        return a.ensureToken().then(function (token) {
            if (!token) { return unauthorized(); }
            return fetch(url, copyInit(init, token)).then(function (r) {
                if (r.status !== 401) { return r; }
                return a.refresh().then(function (t2) { return fetch(url, copyInit(init, t2)); }, function () { return r; });
            });
        });
    }

    /* JSON 호출: stApi.call("PATCH", "/api/me", { name: "..." }) → { status, ok, data } */
    function call(method, url, body, extra) {
        var o = { method: method, headers: { "Accept": "application/json" } };
        if (method !== "GET" && method !== "HEAD") { o.headers["X-Requested-With"] = "fetch"; }
        if (body !== undefined && body !== null) { o.headers["Content-Type"] = "application/json"; o.body = JSON.stringify(body); }
        if (extra) { for (var k in extra) { if (Object.prototype.hasOwnProperty.call(extra, k)) { o[k] = extra[k]; } } }
        return apiFetch(url, o).then(function (r) {
            if (r.status === 204) { return { status: 204, ok: true, data: null }; }
            return r.json().catch(function () { return null; }).then(function (d) { return { status: r.status, ok: r.ok, data: d }; });
        });
    }

    /* 로그아웃: 서버 API 는 없다. 토큰을 지우고 Cognito 로그아웃 주소로 이동한다. */
    function logout() {
        var a = A();
        if (a && a.logout) { a.logout(); } else { location.assign("/"); }
    }

    window.stApi = { fetch: apiFetch, call: call, logout: logout };
})();
