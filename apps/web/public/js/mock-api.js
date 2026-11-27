/* 체험 모드용 가짜 api. db 파트의 api 목록이 나오기 전에 화면을 끝까지 만들어 보기 위한 것이다.
 * - 로그인 설정(ST_AUTH)이 비어 있을 때만 쓴다(keeper-api.js가 고른다). 진짜 api가 생기면 자동으로 안 쓰인다.
 * - 상태는 localStorage("keeper.mock.v2")에 두어 같은 브라우저의 탭끼리 공유한다.
 *   탭 하나는 여행자, 다른 탭은 보호자로 들어가면 요청·거부·비상 전환이 서로 보인다.
 * - 역할(여행자/보호자)은 탭마다 sessionStorage("keeper.mock.role")에 둔다.
 * - 주소와 응답 모양은 db 파트가 만든 api 기준(11/24 회신 반영): 비상 해제, 서류 삭제, 보호자 관리, 요청 상태 cancelled,
 *   403 오류 값 not_guardian · not_emergency · no_view_token · invalid_view_token · not_owner.
 * - 보호자는 초대 후 수락해야 된다. 체험 모드에서 guardian@keeper.test(김보호)는 바로 수락, friend@keeper.test(박친구)는 수락 대기로 남는다.
 *   가입하지 않은 이메일이어도 같은 응답(202)을 준다(실제 서버와 같음).
 * - 기본 샘플 서류: img/sample-passport.png, img/sample-insurance.png (캐릭터 "모험이"의 가상 서류, SAMPLE 표시)
 * - 시간: 보호자 요청 대기 60초, 열람 토큰 15분(임시값). localStorage "keeper.mock.fast"=1 이면 10초 / 90초로 줄인다(시연 연습용). */
(function () {
    "use strict";

    var KEY = "keeper.mock.v3", ROLE = "keeper.mock.role";
    var ACCOUNTS = [
        { id: "g1", name: "김보호", email: "guardian@keeper.test" },
        { id: "g2", name: "박친구", email: "friend@keeper.test" }
    ];
    var OK_TYPES = ["image/png", "image/jpeg", "image/webp", "application/pdf"];
    function fast() { try { return localStorage.getItem("keeper.mock.fast") === "1"; } catch (e) { return false; } }
    function waitMs() { return fast() ? 10 * 1000 : 60 * 1000; }
    function viewMs() { return fast() ? 90 * 1000 : 15 * 60 * 1000; }
    function iso(ms) { return new Date(ms).toISOString(); }

    function fresh() {
        var now = Date.now();
        return {
            traveler: { id: "u1", name: "김여행", emergency: false, emergency_since: null, emergency_reason: null },
            guardian: { id: "g1", name: "김보호" },          /* 보호자 탭으로 들어온 사람 */
            guardians: [ACCOUNTS[0]],                        /* 여행자가 등록한 보호자 목록 */
            docs: [
                { id: 1, title: "여권 사본 (SAMPLE)", uploaded_at: iso(now - 86400000 * 3), data: "/img/sample-passport.png" },
                { id: 2, title: "여행자 보험증 (SAMPLE)", uploaded_at: iso(now - 86400000), data: "/img/sample-insurance.png" }
            ],
            nextDocId: 3,
            request: null,      /* { id, status: pending|denied|timeout|cancelled, created_at, expires_at } */
            viewToken: null     /* { token, expires_at } */
        };
    }
    function load() {
        try { var s = JSON.parse(localStorage.getItem(KEY) || "null"); if (s && s.traveler) { return s; } } catch (e) { /* 없음 */ }
        var f = fresh(); save(f); return f;
    }
    function save(s) { try { localStorage.setItem(KEY, JSON.stringify(s)); } catch (e) { /* 저장 불가 */ } }

    /* 시간이 지나 바뀌어야 할 상태를 반영한다(서버라면 서버가 하는 일). */
    function tick(s) {
        var now = Date.now();
        if (s.request && s.request.status === "pending" && Date.parse(s.request.expires_at) <= now) {
            s.request.status = "timeout";
            if (!s.traveler.emergency) {
                s.traveler.emergency = true;
                s.traveler.emergency_since = iso(now);
                s.traveler.emergency_reason = "auto";
            }
        }
        if (s.viewToken && Date.parse(s.viewToken.expires_at) <= now) { s.viewToken = null; }
        return s;
    }

    function role() { try { return sessionStorage.getItem(ROLE); } catch (e) { return null; } }
    function res(status, data) { return Promise.resolve({ status: status, ok: status >= 200 && status < 300, data: data === undefined ? null : data }); }
    function err(status, msg) { return res(status, { error: msg }); }
    /* status가 없는 예전 저장값은 수락된 것으로 본다 */
    function isGuardian(s) { return s.guardians.some(function (g) { return g.id === s.guardian.id && g.status !== "pending"; }); }
    /* SOS나 비상 해제를 누르면 대기 중인 요청은 취소된다 */
    function cancelPending(s) { if (s.request && s.request.status === "pending") { s.request.status = "cancelled"; } }
    function list(docs) { return docs.map(function (d) { return { id: d.id, title: d.title, uploaded_at: d.uploaded_at }; }); }

    /* 부분 장애 체험: setVaultDown(true)면 서류 기능만 503, 상태 확인 본문에 vault 오류 (E2E 시험용) */
    var VAULT_DOWN = "keeper.mock.vaultDown";
    function vaultDown() { try { return sessionStorage.getItem(VAULT_DOWN) === "1"; } catch (e) { return false; } }
    function usesVault(url) { return url.indexOf("/api/docs") === 0 || url.indexOf("/docs") > 0 || url === "/api/guardian/view-token"; }

    function call(method, url, body, headers) {
        var s = tick(load()), r = role(), m;
        var token = headers && headers["X-View-Token"];
        if (!r) { return err(401, "login required"); }
        if (vaultDown() && usesVault(url)) { return err(503, "vault unavailable"); }

        if (method === "GET" && url === "/api/me") {
            if (r === "user") { save(s); return res(200, { name: s.traveler.name, role: "user", emergency: s.traveler.emergency, emergency_since: s.traveler.emergency_since, emergency_reason: s.traveler.emergency_reason }); }
            return res(200, { name: s.guardian.name, role: "guardian" });
        }

        /* ---------- 여행자 ---------- */
        if (url.indexOf("/api/guardian/") !== 0) {
            if (r !== "user") { return err(403, "forbidden"); }
            if (method === "GET" && url === "/api/docs") { return res(200, list(s.docs)); }
            if (method === "POST" && url === "/api/sos") {
                if (s.traveler.emergency) { return err(409, "already_emergency"); }
                cancelPending(s);
                if (!s.traveler.emergency) { s.traveler.emergency = true; s.traveler.emergency_since = iso(Date.now()); s.traveler.emergency_reason = "sos"; }
                save(s); return res(200, { emergency: true });
            }
            if (method === "POST" && url === "/api/sos/cancel") {
                if (!s.traveler.emergency) { return err(409, "not_emergency"); }
                cancelPending(s);
                s.traveler.emergency = false; s.traveler.emergency_since = null; s.traveler.emergency_reason = null;
                s.viewToken = null;   /* 열람도 바로 끝 */
                save(s); return res(200, { emergency: false });
            }
            m = url.match(/^\/api\/docs\/(\d+)$/);
            if (method === "DELETE" && m) {
                var before = s.docs.length;
                s.docs = s.docs.filter(function (d) { return String(d.id) !== m[1]; });
                if (s.docs.length === before) { return err(404, "not found"); }
                save(s); return res(204);
            }
            if (method === "GET" && url === "/api/guardians") { return res(200, { my_guardians: s.guardians, guarding: [] }); }
            if (method === "GET" && url === "/api/guardians/invites") { return res(200, []); }
            if (method === "POST" && url === "/api/guardians") {
                var email = String((body && body.email) || "").trim().toLowerCase();
                var acc = ACCOUNTS.filter(function (a) { return a.email === email; })[0];
                if (!email) { return err(400, "email required"); }
                if (acc && !s.guardians.some(function (g) { return g.id === acc.id; })) {
                    /* 체험 모드: 김보호(보호자 탭의 사람)는 바로 수락, 그 밖은 수락 대기 */
                    s.guardians.push({ id: acc.id, name: acc.name, email: acc.email, status: acc.id === s.guardian.id ? "accepted" : "pending" });
                    save(s);
                }
                return res(202, { invited: email });
            }
            m = url.match(/^\/api\/guardians\/([^/]+)$/);
            if (method === "DELETE" && m) {
                var n = s.guardians.length;
                s.guardians = s.guardians.filter(function (g) { return g.id !== decodeURIComponent(m[1]); });
                if (s.guardians.length === n) { return err(404, "not found"); }
                if (!isGuardian(s)) { s.viewToken = null; }
                save(s); return res(204);
            }
            if (method === "GET" && url === "/api/requests/pending") {
                save(s);
                if (s.request && s.request.status === "pending") { return res(200, { request_id: s.request.id, guardian_name: s.guardian.name, expires_at: s.request.expires_at }); }
                return res(204);
            }
            m = url.match(/^\/api\/requests\/(\d+)\/deny$/);
            if (method === "POST" && m) {
                if (!s.request || String(s.request.id) !== m[1] || s.request.status !== "pending") { save(s); return err(409, "not_pending"); }
                s.request.status = "denied"; save(s); return res(200, { denied: true });
            }
            return err(404, "not found");
        }

        /* ---------- 보호자 ---------- */
        if (r !== "guardian") { return err(403, "forbidden"); }
        if (method === "GET" && url === "/api/guardian/travelers") {
            save(s);
            if (!isGuardian(s)) { return res(200, []); }
            return res(200, [{
                user_id: s.traveler.id, name: s.traveler.name, emergency: s.traveler.emergency,
                emergency_since: s.traveler.emergency_since, emergency_reason: s.traveler.emergency_reason,
                request: s.request ? { request_id: s.request.id, status: s.request.status, wait_until: s.request.expires_at } : null
            }]);
        }
        if (url !== "/api/guardian/travelers" && !isGuardian(s)) { return err(403, "not_guardian"); }
        if (method === "POST" && url === "/api/guardian/requests") {
            if (s.traveler.emergency) { return err(409, "already_emergency"); }
            if (s.request && s.request.status === "pending") { return err(409, "already_pending"); }
            var now = Date.now();
            s.request = { id: now % 100000, status: "pending", created_at: iso(now), expires_at: iso(now + waitMs()) };
            save(s); return res(201, { request_id: s.request.id, wait_until: s.request.expires_at });
        }
        if (method === "POST" && url === "/api/guardian/view-token") {
            if (!s.traveler.emergency) { return err(403, "not_emergency"); }
            s.viewToken = { token: "mock-" + Math.random().toString(36).slice(2), expires_at: iso(Date.now() + viewMs()) };
            save(s); return res(201, { view_token: s.viewToken.token, expires_at: s.viewToken.expires_at });
        }
        m = url.match(/^\/api\/guardian\/travelers\/([^/]+)\/docs$/);
        if (method === "GET" && m) {
            if (m[1] !== s.traveler.id) { return err(403, "not_guardian"); }
            if (!s.traveler.emergency) { return err(403, "not_emergency"); }
            if (!token) { return err(403, "no_view_token"); }
            if (!s.viewToken || token !== s.viewToken.token) { return err(403, "invalid_view_token"); }
            return res(200, list(s.docs));
        }
        return err(404, "not found");
    }

    /* 서류 파일(그림)을 Blob으로 돌려준다. 여행자 본인 또는 유효한 열람 토큰을 가진 보호자만. */
    function blob(url, headers) {
        var s = tick(load()), r = role(), m, token = headers && headers["X-View-Token"];
        if (vaultDown()) { return Promise.reject({ status: 503 }); }
        m = url.match(/^\/api\/(guardian\/)?docs\/(\d+)$/);
        if (!m) { return Promise.reject({ status: 404 }); }
        if (m[1]) {
            if (r !== "guardian" || !isGuardian(s) || !s.traveler.emergency || !s.viewToken || token !== s.viewToken.token) { return Promise.reject({ status: 403 }); }
        } else if (r !== "user") { return Promise.reject({ status: 403 }); }
        var d = s.docs.filter(function (x) { return String(x.id) === m[2]; })[0];
        if (!d) { return Promise.reject({ status: 404 }); }
        /* 기본 샘플은 우리 서버의 그림 파일, 올린 서류는 data: 주소 */
        if (d.data.indexOf("data:") === 0) { return Promise.resolve(dataUrlToBlob(d.data)); }
        return fetch(d.data).then(function (x) { if (!x.ok) { throw { status: x.status }; } return x.blob(); });
    }

    /* data: 주소 → Blob. fetch(data:)는 CSP connect-src에 막히므로 직접 바꾼다. */
    function dataUrlToBlob(url) {
        var comma = url.indexOf(","), head = url.slice(5, comma), body = url.slice(comma + 1);
        var type = head.split(";")[0] || "application/octet-stream";
        if (/;base64/.test(head)) {
            var bin = atob(body), arr = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) { arr[i] = bin.charCodeAt(i); }
            return new Blob([arr], { type: type });
        }
        return new Blob([decodeURIComponent(body)], { type: type });
    }

    /* 서류 올리기: PNG·JPEG·WEBP·PDF. 진짜 api는 5MB까지 받고 S3에 암호문으로 저장한다.
     * 체험 모드는 브라우저 저장 공간(localStorage)이 작아서 1MB까지만 받는다. */
    function upload(url, form) {
        if (role() !== "user") { return err(403, "forbidden"); }
        if (url !== "/api/docs") { return err(404, "not found"); }
        if (vaultDown()) { return err(503, "vault unavailable"); }
        var file = form.get("file"), title = (form.get("title") || "").toString().trim();
        if (!file || !file.size) { return err(400, "file required"); }
        if (OK_TYPES.indexOf(file.type) < 0) { return err(415, "unsupported type"); }
        if (file.size > 1024 * 1024) { return res(413, { error: "mock_too_large" }); }
        return new Promise(function (resolve) {
            var fr = new FileReader();
            fr.onload = function () {
                var s = load(), id = s.nextDocId++;
                s.docs.push({ id: id, title: title || file.name, uploaded_at: iso(Date.now()), data: fr.result });
                save(s); resolve({ status: 201, ok: true, data: { id: id } });
            };
            fr.onerror = function () { resolve({ status: 400, ok: false, data: { error: "read failed" } }); };
            fr.readAsDataURL(file);
        });
    }

    window.keeperMock = {
        call: call, blob: blob, upload: upload,
        login: function (r) { try { sessionStorage.setItem(ROLE, r); } catch (e) { /* 저장 불가 */ } },
        logout: function () { try { sessionStorage.removeItem(ROLE); } catch (e) { /* 저장 불가 */ } },
        reset: function () { save(fresh()); },
        health: function () { return res(200, { api: "ok", vault: vaultDown() ? { error: "mock vault down" } : { status: "ok" } }); },
        setVaultDown: function (on) { try { if (on) { sessionStorage.setItem(VAULT_DOWN, "1"); } else { sessionStorage.removeItem(VAULT_DOWN); } } catch (e) { /* 저장 불가 */ } },
        role: role
    };
})();
