/* Cognito 로그인(Authorization Code + PKCE). 2.5차 SafeTravel의 cognito.js를 그대로 가져왔다.
 * 흐름: login() → Cognito 로그인 화면 → /auth/callback.html 로 돌아옴 → handleCallback() 이 코드를 토큰으로 교환
 * 토큰은 sessionStorage 에 둔다. (탭을 닫으면 사라진다) 설정(ST_AUTH)이 비어 있으면 아무것도 하지 않는다. */
(function () {
    "use strict";
    var C = window.ST_AUTH || {};
    var TOK = "stAuth.tokens", VER = "stAuth.verifier", STATE = "stAuth.state", BACK = "stAuth.back";

    function enabled() { return !!(C.domain && C.clientId); }
    function redirectUri() { return location.origin + (C.redirectPath || "/auth/callback.html"); }
    function ss(k, v) { try { if (v === undefined) { return sessionStorage.getItem(k); } if (v === null) { sessionStorage.removeItem(k); } else { sessionStorage.setItem(k, v); } } catch (e) { /* 저장 불가 */ } return null; }

    function b64url(buf) {
        var s = "", a = new Uint8Array(buf);
        for (var i = 0; i < a.length; i++) { s += String.fromCharCode(a[i]); }
        return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    }
    function rand(n) { var a = new Uint8Array(n); crypto.getRandomValues(a); return b64url(a); }
    function sha256(str) { return crypto.subtle.digest("SHA-256", new TextEncoder().encode(str)); }

    /* 사이트에서 고른 언어(localStorage "language")를 Cognito 로그인 화면 언어(lang)로 바꾼다.
     * Managed login 이 지원하는 언어로 바꾸고, 베트남어(vi)는 지원하지 않아 WAS 안내대로 en 으로 보낸다. 모르는 값은 "" 를 돌려줘서 lang 을 붙이지 않는다. */
    var LANG = { ko: "ko", en: "en", ja: "ja", zh: "zh-CN", vi: "en" };
    function uiLang() {
        var l = "";
        try { l = localStorage.getItem("language") || "ko"; } catch (e) { l = "ko"; }
        return Object.prototype.hasOwnProperty.call(LANG, l) ? LANG[l] : "";
    }

    /* 로그인 시작: 돌아올 화면을 기억해 두고 Cognito 로 이동
     * screen: "signup" → 가입 화면, "forgotPassword" → 비밀번호 찾기(재설정) 화면, 그 외 → 로그인.
     * opts: true 이거나 { replace: true } 이면 현재 화면을 방문 기록에서 빼고 이동한다(login.html 처럼 이동만 하는 화면용).
     *       그래야 Cognito 화면에서 "뒤로 가기"를 눌렀을 때 이동 화면으로 다시 튕기지 않고 그 앞 화면(첫 화면)으로 돌아간다.
     * opts.reauth = true 면 prompt=login 을 붙여 이미 로그인돼 있어도 비밀번호를 다시 입력하게 한다(탈퇴 전 본인 확인). */
    function login(backPath, screen, opts) {
        var replace = opts === true || !!(opts && opts.replace);
        if (!enabled()) { return Promise.reject(new Error("auth-disabled")); }
        var verifier = rand(48), state = rand(16);
        return sha256(verifier).then(function (h) {
            ss(VER, verifier); ss(STATE, state);
            ss(BACK, typeof backPath === "string" && backPath.charAt(0) === "/" && backPath.indexOf("//") !== 0 ? backPath : "/");
            var q = "response_type=code&client_id=" + encodeURIComponent(C.clientId) +
                "&redirect_uri=" + encodeURIComponent(redirectUri()) +
                "&scope=" + encodeURIComponent(C.scope || "openid email") +
                "&state=" + encodeURIComponent(state) +
                "&code_challenge_method=S256&code_challenge=" + encodeURIComponent(b64url(h));
            var lang = uiLang();
            if (lang) { q += "&lang=" + encodeURIComponent(lang); }
            if (opts && opts.reauth) { q += "&prompt=login"; }
            /* signup·forgotPassword 화면도 같은 값을 넘기므로 끝나면 같은 방식(code + PKCE)으로 돌아온다. */
            var path = screen === "signup" ? "/signup?" : screen === "forgotPassword" ? "/forgotPassword?" : "/oauth2/authorize?";
            var to = C.domain + path + q;
            if (replace) { location.replace(to); } else { location.assign(to); }
        });
    }

    /* 콜백 페이지에서 호출: code → 토큰 교환. 성공하면 처음 있던 화면 경로를 돌려준다. */
    function handleCallback() {
        if (!enabled()) { return Promise.reject(new Error("auth-disabled")); }
        var p = new URLSearchParams(location.search);
        var code = p.get("code"), state = p.get("state"), err = p.get("error");
        if (err) { return Promise.reject(new Error("auth-error:" + err)); }
        if (!code || !state || state !== ss(STATE)) { return Promise.reject(new Error("auth-state")); }
        var verifier = ss(VER);
        if (!verifier) { return Promise.reject(new Error("auth-verifier")); }
        var body = new URLSearchParams({
            grant_type: "authorization_code", client_id: C.clientId, code: code,
            redirect_uri: redirectUri(), code_verifier: verifier
        });
        return fetch(C.domain + "/oauth2/token", {
            method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: body.toString()
        }).then(function (r) {
            if (!r.ok) { throw new Error("auth-token:" + r.status); }
            return r.json();
        }).then(function (t) {
            var back = ss(BACK) || "/";
            ss(TOK, JSON.stringify({
                access: t.access_token, id: t.id_token, refresh: t.refresh_token,
                exp: Date.now() + (Number(t.expires_in) || 3600) * 1000
            }));
            ss(VER, null); ss(STATE, null); ss(BACK, null);
            return back;
        });
    }

    function tokens() {
        try { var o = JSON.parse(ss(TOK) || "null"); return o && o.access ? o : null; } catch (e) { return null; }
    }
    /* 로그인 상태: 액세스 토큰이 살아 있거나, 갱신 토큰이 있어 곧 새로 받을 수 있으면 로그인 중으로 본다 */
    function isLoggedIn() { var t = tokens(); return !!t && (t.exp > Date.now() || !!t.refresh); }
    function accessToken() { var t = tokens(); return t && t.exp > Date.now() ? t.access : null; }

    /* 토큰 갱신(WAS 안내): POST /oauth2/token, grant_type=refresh_token
     * 성공하면 새 access/id 토큰과 만료 시각을 저장하고, 새 갱신 토큰이 오면 교체한다(회전 켜진 경우).
     * 실패(갱신 토큰 만료 등)하면 저장된 토큰을 지우고 거부한다. 동시에 여러 번 부르면 한 번만 보낸다. */
    var refreshing = null;
    function refresh() {
        if (refreshing) { return refreshing; }
        var t = tokens();
        if (!enabled() || !t || !t.refresh) { return Promise.reject(new Error("auth-no-refresh")); }
        var body = new URLSearchParams({ grant_type: "refresh_token", client_id: C.clientId, refresh_token: t.refresh });
        refreshing = fetch(C.domain + "/oauth2/token", {
            method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: body.toString()
        }).then(function (r) {
            if (!r.ok) { throw new Error("auth-refresh:" + r.status); }
            return r.json();
        }).then(function (n) {
            ss(TOK, JSON.stringify({
                access: n.access_token, id: n.id_token || t.id, refresh: n.refresh_token || t.refresh,
                exp: Date.now() + (Number(n.expires_in) || 600) * 1000
            }));
            refreshing = null;
            return n.access_token;
        }, function (e) {
            refreshing = null;
            ss(TOK, null);
            throw e;
        });
        return refreshing;
    }

    /* 쓸 수 있는 액세스 토큰을 돌려준다. 만료 1분 전부터는 미리 갱신한다. 로그인 전이거나 갱신 실패면 null. */
    function ensureToken() {
        var t = tokens();
        if (!t) { return Promise.resolve(null); }
        if (t.exp - Date.now() > 60 * 1000) { return Promise.resolve(t.access); }
        return refresh().then(function (a) { return a; }, function () { return null; });
    }

    /* API 호출용: Authorization: Bearer 헤더를 붙여 부른다.
     * 토큰이 없거나 갱신에 실패하면 Cognito 로그인으로 보낸다. 401 이면 한 번 갱신해서 다시 시도한다. */
    function apiFetch(url, init) {
        function send(token) {
            var o = {};
            for (var k in (init || {})) { if (Object.prototype.hasOwnProperty.call(init, k)) { o[k] = init[k]; } }
            var h = new Headers(o.headers || {});
            h.set("Authorization", "Bearer " + token);
            o.headers = h;
            return fetch(url, o);
        }
        function needLogin() {
            login(location.pathname + location.search);
            return Promise.reject(new Error("auth-required"));
        }
        return ensureToken().then(function (token) {
            if (!token) { return needLogin(); }
            return send(token).then(function (r) {
                if (r.status !== 401) { return r; }
                return refresh().then(function (a) { return send(a); }, needLogin);
            });
        });
    }

    function logout() {
        ss(TOK, null);
        if (!enabled()) { location.assign("/"); return; }
        location.assign(C.domain + "/logout?client_id=" + encodeURIComponent(C.clientId) +
            "&logout_uri=" + encodeURIComponent(location.origin + (C.logoutPath || "/")));
    }

    window.stAuth = { enabled: enabled, login: login, handleCallback: handleCallback, isLoggedIn: isLoggedIn, accessToken: accessToken, apiFetch: apiFetch, ensureToken: ensureToken, refresh: refresh, logout: logout };
})();
