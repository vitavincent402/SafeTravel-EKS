/* 여행자 화면: 상태(평소/비상), SOS·비상 해제, 보호자 요청 알림(시간 안에 거부), 내 보호자(등록·삭제),
 * 서류함(미리보기·크게 보기·올리기·삭제).
 * 10초마다 /api/requests/pending 과 /api/me 를 확인한다(폴링). */
(function () {
    "use strict";
    var api = window.keeperApi, kp = window.kp, $ = kp.$, el = kp.el;
    /* 10초마다 묻는다. 5초였을 때 창 2개(같은 IP)만으로 WAF 요청 제한(IP당 5분 300건)을 넘었다 (11/25 10:08~10:10, 103건 차단).
     * 탭이 안 보이는 동안은 묻지 않고, 다시 보이면 바로 한 번 묻는다. 요청 대기는 60초라 10초 간격이면 충분히 거부할 수 있다. */
    var POLL_MS = 10000;
    var pendingId = null, stopReq = null, thumbs = [];

    /* ---------- 상태와 SOS ---------- */
    function renderState(me) {
        var emergency = !!me.emergency;
        $("statusCard").className = "card status" + (emergency ? " is-red" : "");
        $("stateIco").textContent = emergency ? "🚨" : "🛡️";
        $("stateTitle").textContent = emergency ? "비상 모드" : "안전 모드";
        $("stateBadge").textContent = emergency ? "비상" : "평소";
        $("stateBadge").className = "pill " + (emergency ? "red" : "green");
        $("stateText").textContent = emergency
            ? "보호자가 서류를 열람할 수 있어요." + (me.emergency_since ? " " + kp.when(me.emergency_since) + "부터" + (me.emergency_reason ? " · " + kp.reason(me.emergency_reason) : "") : "")
            : "서류는 나만 볼 수 있어요. 위급할 때 SOS를 눌러 주세요.";
        $("sosArea").hidden = emergency;
        $("calmArea").hidden = !emergency;
        if (!emergency) { $("calmConfirm").hidden = true; $("calmBtn").hidden = false; }
    }

    $("sosBtn").addEventListener("click", function () { $("sosConfirm").hidden = false; $("sosWrap").hidden = true; $("sosHint").hidden = true; });
    $("sosNo").addEventListener("click", function () { $("sosConfirm").hidden = true; $("sosWrap").hidden = false; $("sosHint").hidden = false; });
    $("sosYes").addEventListener("click", function () {
        api.call("POST", "/api/sos").then(function (r) {
            if (!r.ok) { kp.toast(kp.errText(r)); return; }
            kp.toast("SOS를 보냈어요. 보호자에게 알림이 가요.");
            if (pendingId) { closeRequest("↩️", "SOS를 보내서 기다리던 보호자 요청은 취소됐어요. 지금은 비상 상태예요.", "done"); }
            $("sosConfirm").hidden = true; $("sosWrap").hidden = false; $("sosHint").hidden = false;
            refreshMe();
        });
    });

    /* 비상 해제: 평소 상태로 돌아가고 보호자 열람도 끝난다 */
    $("calmBtn").addEventListener("click", function () { $("calmConfirm").hidden = false; $("calmBtn").hidden = true; });
    $("calmNo").addEventListener("click", function () { $("calmConfirm").hidden = true; $("calmBtn").hidden = false; });
    $("calmYes").addEventListener("click", function () {
        api.call("POST", "/api/sos/cancel").then(function (r) {
            if (!r.ok) { kp.toast(kp.errText(r)); return; }
            kp.toast("비상을 해제했어요. 보호자의 열람도 끝났어요.");
            if (pendingId) { closeRequest("↩️", "비상을 해제해서 기다리던 보호자 요청은 취소됐어요.", "done"); }
            refreshMe();
        });
    });

    function refreshMe() {
        return api.call("GET", "/api/me").then(function (r) { if (r.ok && r.data) { renderState(r.data); } });
    }

    /* ---------- 보호자 요청 알림 ---------- */
    /* 이미 거부한 요청: 거부 직전에 보낸 폴링 응답이 늦게 와도 알림을 다시 띄우지 않는다 (11/25 실제 시험에서 발견) */
    var deniedIds = {};

    function showRequest(req) {
        if (pendingId === req.request_id || deniedIds[req.request_id]) { return; }
        pendingId = req.request_id;
        $("reqIco").textContent = "🔔";
        $("reqText").textContent = req.guardian_name + " 님(보호자)이 서류 열람을 요청했어요";
        $("denyBtn").hidden = false;
        $("reqRow").hidden = false;
        $("reqHint").hidden = false;
        $("reqbar").className = "reqbar";
        $("reqbar").hidden = false;
        if (stopReq) { stopReq(); }
        stopReq = kp.countdown(req.expires_at, function (txt) { $("reqLeft").textContent = txt; }, function () {
            $("reqLeft").textContent = "0:00";
            $("denyBtn").hidden = true;
            checkRequest();
        });
    }

    function closeRequest(icon, text, cls) {
        if (stopReq) { stopReq(); stopReq = null; }
        pendingId = null;
        $("reqIco").textContent = icon;
        $("reqText").textContent = text;
        $("denyBtn").hidden = true;
        $("reqRow").hidden = true;
        $("reqHint").hidden = true;
        $("reqbar").className = "reqbar " + cls;
        $("reqbar").hidden = false;
        setTimeout(function () { if (!pendingId) { $("reqbar").hidden = true; } }, 8000);
    }

    $("denyBtn").addEventListener("click", function () {
        if (!pendingId) { return; }
        var id = pendingId;
        deniedIds[id] = true;
        api.call("POST", "/api/requests/" + encodeURIComponent(id) + "/deny").then(function (r) {
            if (!r.ok) { delete deniedIds[id]; }
            if (r.ok) { closeRequest("✋", "요청을 거부했어요. 보호자에게 거부했다고 알려져요.", "done"); }
            else { kp.toast(kp.errText(r)); checkRequest(); }
        });
    });

    function checkRequest() {
        return api.call("GET", "/api/requests/pending").then(function (r) {
            if (r.status === 200 && r.data) { showRequest(r.data); return; }
            if (pendingId) {
                /* 대기 중이던 요청이 사라짐: 시간이 지나 비상으로 바뀌었는지 확인 */
                return api.call("GET", "/api/me").then(function (m) {
                    if (m.ok && m.data) { renderState(m.data); }
                    if (m.ok && m.data && m.data.emergency) { closeRequest("🚨", "응답이 없어 비상 상태로 전환됐어요. 보호자가 서류를 열람할 수 있어요.", "alarm"); }
                    else { closeRequest("ℹ️", "보호자 요청이 끝났어요. (내가 SOS·해제를 누르면 대기 중인 요청은 취소돼요)", "done"); }
                });
            }
        });
    }

    /* ---------- 서류함 ---------- */
    function clearThumbs() { thumbs.forEach(function (u) { URL.revokeObjectURL(u); }); thumbs = []; }

    function loadDocs() {
        api.call("GET", "/api/docs").then(function (r) {
            var ul = $("docList");
            ul.textContent = "";
            clearThumbs();
            if (!r.ok) { ul.appendChild(el("li", "empty", kp.errText(r))); return; }
            var list = r.data || [];
            $("docCount").textContent = String(list.length);
            if (!list.length) { ul.appendChild(el("li", "empty", "아직 올린 서류가 없어요. 아래에서 샘플을 올려 보세요.")); return; }
            list.forEach(function (d) {
                var li = el("li", "doc");
                var th = el("div", "thumb");
                th.appendChild(el("span", "lock", "🔒"));
                li.appendChild(th);
                var meta = el("div", "meta");
                meta.appendChild(el("span", "title", d.title));
                meta.appendChild(el("span", "date", kp.when(d.uploaded_at) + " 올림"));
                var acts = el("div", "acts");
                var v = el("button", "btn small", "크게 보기");
                v.type = "button";
                v.addEventListener("click", function () { openDoc(d); });
                acts.appendChild(v);
                var del = el("button", "btn small ghost-red", "삭제");
                del.type = "button";
                del.addEventListener("click", function () { removeDoc(d, del); });
                acts.appendChild(del);
                meta.appendChild(acts);
                li.appendChild(meta);
                ul.appendChild(li);
                /* 미리보기: 본인 서류라 바로 받아서 작게 보여 준다 */
                api.blob("/api/docs/" + encodeURIComponent(d.id)).then(function (b) {
                    if (b.type === "application/pdf") { th.textContent = ""; th.appendChild(el("span", "pdf", "📄")); return; }
                    var u = URL.createObjectURL(b);
                    thumbs.push(u);
                    var img = el("img");
                    img.src = u;
                    img.alt = "";
                    th.textContent = "";
                    th.appendChild(img);
                }, function () { /* 미리보기 실패는 자물쇠 그대로 */ });
            });
        });
    }

    function openDoc(d) {
        api.blob("/api/docs/" + encodeURIComponent(d.id)).then(function (b) {
            kp.openModal(d.title, b, "내 서류 · " + kp.when(d.uploaded_at) + " 올림");
        }, function (e) { kp.toast(kp.errText(e)); });
    }

    /* 삭제는 두 번 눌러 확인한다(브라우저 확인 창은 쓰지 않음) */
    function removeDoc(d, btn) {
        if (btn.dataset.armed !== "1") {
            btn.dataset.armed = "1";
            btn.textContent = "정말 삭제";
            setTimeout(function () { btn.dataset.armed = ""; btn.textContent = "삭제"; }, 4000);
            return;
        }
        api.call("DELETE", "/api/docs/" + encodeURIComponent(d.id)).then(function (r) {
            if (!r.ok) { kp.toast(kp.errText(r)); return; }
            kp.toast("서류를 금고에서 지웠어요.");
            loadDocs();
        });
    }

    /* 올리기 전에 화면에서 먼저 거른다. 최종 검사는 api가 한다 */
    var OK_TYPES = ["image/png", "image/jpeg", "image/webp", "application/pdf"], MAX_BYTES = 5 * 1024 * 1024;
    function fileProblem(f) {
        if (OK_TYPES.indexOf(f.type) < 0) { return "PNG·JPEG·WEBP·PDF 파일만 올릴 수 있어요."; }
        if (f.size > MAX_BYTES) { return "파일이 너무 커요. 5MB까지 올릴 수 있어요."; }
        return null;
    }

    $("upFile").addEventListener("change", function () {
        var f = $("upFile").files[0];
        $("upName").textContent = f ? f.name : "파일 고르기";
        if (f && !$("upTitle").value) { $("upTitle").value = f.name.replace(/\.[^.]+$/, ""); }
    });

    /* 업로드 중에는 올리기 버튼을 잠근다: 큰 파일은 몇 초 걸려 두 번 눌러 같은 서류가 2개 저장되던 문제(11/26 db 보고) */
    var uploading = false;
    var upBtn = $("upForm").querySelector('button[type="submit"]');
    function setUploading(on) {
        uploading = on;
        upBtn.disabled = on;
        upBtn.textContent = on ? "올리는 중…" : "올리기";
    }

    $("upForm").addEventListener("submit", function (ev) {
        ev.preventDefault();
        if (uploading) { return; }
        var f = $("upFile").files[0];
        if (!f) { kp.toast("파일을 골라 주세요."); return; }
        var bad = fileProblem(f);
        if (bad) { kp.toast(bad); return; }
        var form = new FormData();
        /* api는 제목 1~50자가 필수: 비어 있으면 파일 이름으로 */
        form.append("title", ($("upTitle").value.trim() || f.name.replace(/\.[^.]+$/, "") || "서류").slice(0, 50));
        form.append("file", f);
        setUploading(true);
        api.upload("/api/docs", form).then(function (r) {
            setUploading(false);
            if (!r.ok) { kp.toast(kp.errText(r)); return; }
            kp.toast("서류를 금고에 넣었어요.");
            $("upForm").reset();
            $("upName").textContent = "파일 고르기";
            loadDocs();
        }, function () {
            setUploading(false);
            kp.toast("요청에 실패했어요. 잠시 뒤 다시 올려 주세요.");
        });
    });

    /* ---------- 내 보호자 ---------- */
    /* 자동 비상까지의 대기 시간(서버 값 request_wait_seconds)을 사람이 읽는 글자로. 60 → "60초", 3600 → "1시간" */
    function duration(sec) {
        sec = Math.round(Number(sec) || 0);
        if (sec >= 3600 && sec % 3600 === 0) { return (sec / 3600) + "시간"; }
        if (sec > 60 && sec % 60 === 0) { return (sec / 60) + "분"; }
        return sec + "초";
    }
    function showRule(me) {
        if (!me || !me.request_wait_seconds) { return; }
        $("gdRule").textContent = "보호자가 열람을 요청한 뒤 " + duration(me.request_wait_seconds) + " 안에 거부하지 않으면 비상 상태로 바뀌고, 보호자가 내 서류를 볼 수 있다는 규칙에 동의해요.";
    }
    if (api.isMock()) {
        $("gdEmail").placeholder = "friend@keeper.test";
        $("gdForm").appendChild(el("p", "hint", "체험 모드: guardian@keeper.test(김보호)로 초대하면 보호자 탭에서 수락할 수 있고, friend@keeper.test(박친구)는 수락 대기로 남아요."));
    }

    /* 보호자 목록은 10초마다 다시 불러온다. 바뀐 게 없으면 그리지 않고(누르던 '정말 해제' 유지),
     * 수락 대기였던 사람이 수락하면 바로 알린다(11/27 시험: 보호자는 이미 열람 중인데 여행자 화면은 '수락 대기'로 남았음) */
    var gdSig = null, gdStatus = {};
    function loadGuardians() {
        return api.call("GET", "/api/guardians").then(function (r) {
            var ul = $("gdList");
            var list = (r.ok && r.data && r.data.my_guardians) || [];
            var sig = r.ok ? JSON.stringify(list) : "error";
            if (sig === gdSig) { return; }
            gdSig = sig;
            list.forEach(function (g) {
                if (gdStatus[g.id] === "pending" && g.status !== "pending") { kp.toast((g.name || g.email || "보호자") + " 님이 보호자 요청을 수락했어요. 이제 비상일 때 내 서류를 볼 수 있어요."); }
            });
            gdStatus = {};
            list.forEach(function (g) { gdStatus[g.id] = g.status; });
            ul.textContent = "";
            if (!r.ok) { ul.appendChild(el("li", "empty", kp.errText(r))); return; }
            /* 응답: { my_guardians: [{id, email, name, status: pending|accepted}], guarding: [...] } */
            $("gdCount").textContent = String(list.filter(function (g) { return g.status !== "pending"; }).length);
            if (!list.length) { ul.appendChild(el("li", "empty", "등록된 보호자가 없어요. 비상일 때 서류를 볼 사람을 초대해 주세요.")); return; }
            list.forEach(function (g) {
                var li = el("li");
                li.appendChild(el("span", null, "🧑‍🤝‍🧑"));
                var who = el("div", "who2");
                who.appendChild(el("b", null, g.name || g.email || "보호자"));
                /* 수락 전에는 서버가 이름을 주지 않는다(이메일만) */
                if (g.email && g.name) { who.appendChild(el("span", null, g.email)); }
                li.appendChild(who);
                var pending = g.status === "pending";
                li.appendChild(el("span", "pill " + (pending ? "amber" : "green"), pending ? "수락 대기" : "보호자"));
                var del = el("button", "btn small ghost-red", pending ? "취소" : "해제");
                del.type = "button";
                del.dataset.label = del.textContent;
                del.addEventListener("click", function () { removeGuardian(g, del); });
                li.appendChild(del);
                ul.appendChild(li);
            });
        });
    }

    function removeGuardian(g, btn) {
        if (btn.dataset.armed !== "1") {
            btn.dataset.armed = "1";
            btn.textContent = "정말 " + btn.dataset.label;
            kp.toast("한 번 더 누르면 " + btn.dataset.label + "돼요. 진행 중인 요청과 열람도 함께 끝나요.");
            setTimeout(function () { btn.dataset.armed = ""; btn.textContent = btn.dataset.label; }, 4000);
            return;
        }
        api.call("DELETE", "/api/guardians/" + encodeURIComponent(g.id)).then(function (r) {
            if (!r.ok) { kp.toast(kp.errText(r)); return; }
            kp.toast(g.status === "pending" ? "보호자 초대를 취소했어요." : "보호자 등록을 해제했어요. 이제 내 서류를 볼 수 없어요.");
            loadGuardians();
        });
    }

    $("gdForm").addEventListener("submit", function (ev) {
        ev.preventDefault();
        var email = $("gdEmail").value.trim();
        if (!email) { return; }
        if (!$("gdAgree").checked) { kp.toast("자동 비상 규칙에 동의해야 초대할 수 있어요."); return; }
        api.call("POST", "/api/guardians", { email: email, agree_rule: true }).then(function (r) {
            if (r.status === 400 && r.data && r.data.error === "cannot add yourself") { kp.toast("나 자신은 보호자로 등록할 수 없어요."); return; }
            if (!r.ok) { kp.toast(kp.errText(r)); return; }
            /* 가입하지 않은 이메일이어도 같은 응답이 온다(가입 여부를 드러내지 않음) */
            kp.toast("초대했어요. 상대가 Keeper에 가입한 이메일이면 로그인할 때 요청이 보이고, 수락하면 보호자가 돼요.");
            $("gdForm").reset();
            loadGuardians();
        });
    });

    /* ---------- 시작 ---------- */
    kp.requireRole("user").then(function (me) {
        showRule(me);
        kp.topbar(me.name, "여행자");
        renderState(me);
        loadDocs();
        loadGuardians();
        window.keeperInvites.load();
        checkRequest();
        var tick = function () { checkRequest(); if (!pendingId) { refreshMe(); } loadGuardians(); window.keeperInvites.load(); };
        setInterval(function () { if (!document.hidden) { tick(); } }, POLL_MS);
        document.addEventListener("visibilitychange", function () { if (!document.hidden) { tick(); } });
    }, function () { /* 다른 화면으로 이동함 */ });
})();
