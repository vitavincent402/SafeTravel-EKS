/* 화면 공용 도구: 요소 만들기, 남은 시간 표시, 상단 표시줄, 로그인 확인.
 * 서버에서 온 글자는 모두 textContent로만 넣는다(HTML로 해석하지 않음 → XSS 방지). */
(function () {
    "use strict";

    function $(id) { return document.getElementById(id); }

    function el(tag, cls, text) {
        var e = document.createElement(tag);
        if (cls) { e.className = cls; }
        if (text !== undefined && text !== null) { e.textContent = text; }
        return e;
    }

    /* 남은 시간 "m:ss". 음수면 0:00 */
    function remain(ms) {
        var s = Math.max(0, Math.ceil(ms / 1000));
        var m = Math.floor(s / 60), r = s % 60;
        return m + ":" + (r < 10 ? "0" : "") + r;
    }

    /* 서버가 준 만료 시각(expires_at, ISO UTC)까지 1초마다 onTick(남은 글자, 남은 ms)를 부르고, 끝나면 onEnd().
     * 화면에 15분·1분을 고정으로 쓰지 않는다(값이 바뀌어도 화면은 그대로). 돌려준 함수를 부르면 멈춘다. */
    function countdown(expiresAt, onTick, onEnd) {
        var end = Date.parse(expiresAt), done = false;
        function step() {
            var left = end - Date.now();
            if (left <= 0) { stop(); if (!done) { done = true; onEnd(); } return; }
            onTick(remain(left), left);
        }
        var timer = setInterval(step, 1000);
        function stop() { clearInterval(timer); }
        step();
        return function () { done = true; stop(); };
    }

    function when(isoText) {
        var d = new Date(isoText);
        if (isNaN(d)) { return ""; }
        function p(n) { return (n < 10 ? "0" : "") + n; }
        return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) + " " + p(d.getHours()) + ":" + p(d.getMinutes());
    }

    /* 상단 표시줄: 이름(캐릭터 얼굴), 역할, 로그아웃. 체험 모드면 안내 띠도 */
    function topbar(name, roleText) {
        var bar = $("topbar");
        if (!bar) { return; }
        bar.textContent = "";
        var who = el("span", "who");
        var face = el("img");
        face.src = "/img/mohum.svg";
        face.alt = "";
        who.appendChild(face);
        who.appendChild(el("span", null, name + " 님"));
        who.appendChild(el("small", null, roleText));
        var out = el("button", "btn small", "로그아웃");
        out.type = "button";
        out.addEventListener("click", function () { window.keeperApi.logout(); });
        bar.appendChild(who);
        bar.appendChild(out);
        if (window.keeperApi.isMock()) { mockBanner(); }
    }

    function mockBanner() {
        var b = $("mockbar");
        if (!b) { return; }
        b.hidden = false;
        b.textContent = "";
        b.appendChild(el("span", null, "🧪 체험 모드: 가짜 데이터로 동작해요. 다른 탭에서 상대 역할로 들어가면 서로 반응해요."));
        var reset = el("button", "link", "체험 데이터 처음으로");
        reset.type = "button";
        reset.addEventListener("click", function () { window.keeperMock.reset(); location.reload(); });
        b.appendChild(reset);
    }

    /* 로그인과 역할을 확인하고 /api/me 결과를 돌려준다. 로그인 전이면 첫 화면으로, 역할이 다르면 맞는 화면으로 보낸다. */
    function requireRole(role) {
        return window.keeperApi.call("GET", "/api/me").then(function (r) {
            if (r.status === 401 || !r.ok || !r.data) { location.replace("/"); return Promise.reject(new Error("login")); }
            if (r.data.role !== role) { location.replace(r.data.role === "guardian" ? "/guardian.html" : "/traveler.html"); return Promise.reject(new Error("role")); }
            return r.data;
        });
    }

    /* 화면 아래 짧은 알림 */
    function toast(text) {
        var t = $("toast");
        if (!t) { return; }
        t.textContent = text;
        t.hidden = false;
        clearTimeout(toast.timer);
        toast.timer = setTimeout(function () { t.hidden = true; }, 3500);
    }

    /* 서버 오류를 사람이 읽을 문장으로 */
    var ERR = {
        not_guardian: "이 사람의 보호자로 등록돼 있지 않아요.",
        not_emergency: "비상 상태가 아니라 열람할 수 없어요.",
        no_view_token: "열람을 먼저 시작해 주세요.",
        invalid_view_token: "열람 시간이 끝났거나 권한이 없어요.",
        not_owner: "내 서류가 아니에요.",
        already_emergency: "이미 비상 상태예요.",
        already_pending: "이미 응답을 기다리는 요청이 있어요.",
        not_pending: "이미 끝난 요청이에요.",
        guardian_not_found: "그 이메일로 가입한 사람이 없어요. 보호자가 먼저 가입해야 해요.",
        mock_too_large: "체험 모드에서는 1MB까지만 올릴 수 있어요. (실제 서비스는 5MB)"
    };
    function errText(r) {
        if (!r) { return "요청에 실패했어요."; }
        var code = r.data && r.data.error;
        if (code && ERR[code]) { return ERR[code]; }
        if (r.status === 401) { return "로그인이 필요해요."; }
        if (r.status === 403) { return "권한이 없어요."; }
        if (r.status === 404) { return "찾을 수 없어요."; }
        if (r.status === 409) { return "지금은 할 수 없는 상태예요."; }
        if (r.status === 413) { return "파일이 너무 커요. 5MB까지 올릴 수 있어요."; }
        if (r.status === 415) { return "PNG·JPEG·WEBP·PDF 파일만 올릴 수 있어요."; }
        if (r.status === 429) { return "요청이 너무 많아요. 잠시 후 다시 시도해 주세요."; }
        /* 모르는 오류는 서버가 보낸 이유 글자도 같이 보여 준다 (11/25 업로드 400 때 원인을 바로 못 본 일 반영).
         * 글자는 textContent로만 쓰이지만, 영문·숫자·공백·_·- 만 남기고 60자로 자른다 */
        var why = (typeof code === "string") ? code.replace(/[^A-Za-z0-9 _-]/g, "").slice(0, 60) : "";
        return "요청에 실패했어요." + (r.status ? " (" + r.status + (why ? " " + why : "") + ")" : "");
    }


    /* 원형 타이머. 처음 본 남은 시간을 100%로 잡고 줄어든다. 돌려준 객체의 set(글자, 남은 ms)로 갱신 */
    function ring(cls) {
        var NS = "http://www.w3.org/2000/svg", R = 32, C = 2 * Math.PI * R, total = 0;
        var box = el("div", "ring" + (cls ? " " + cls : ""));
        var svg = document.createElementNS(NS, "svg");
        svg.setAttribute("viewBox", "0 0 76 76");
        [["bg"], ["fg"]].forEach(function (k) {
            var c = document.createElementNS(NS, "circle");
            c.setAttribute("cx", "38"); c.setAttribute("cy", "38"); c.setAttribute("r", String(R));
            c.setAttribute("class", k[0]);
            if (k[0] === "fg") { c.setAttribute("stroke-dasharray", String(C)); c.setAttribute("stroke-dashoffset", "0"); }
            svg.appendChild(c);
        });
        var label = el("b", null, "-");
        box.appendChild(svg);
        box.appendChild(label);
        var fg = svg.lastChild;
        return {
            el: box,
            set: function (text, leftMs) {
                label.textContent = text;
                if (!total || leftMs > total) { total = leftMs; }
                fg.setAttribute("stroke-dashoffset", String(C * (1 - Math.max(0, leftMs) / total)));
            }
        };
    }

    /* 서류 크게 보기 창(모달). blob 그림 주소와 제목을 받아 띄우고, 닫으면 주소를 해제한다. */
    var modalUrl = null;
    function openModal(title, blob, footText) {
        closeModal();
        var m = $("modal");
        if (!m) { return; }
        modalUrl = URL.createObjectURL(blob);
        $("modalTitle").textContent = title;
        /* PDF는 그림 칸에 못 그리므로 새 탭에서 연다(브라우저 PDF 보기). 열람 시간이 끝나면 주소를 지워 다시 못 연다 */
        var pdf = blob.type === "application/pdf";
        $("modalImg").hidden = pdf;
        $("modalPdf").hidden = !pdf;
        if (pdf) { $("modalPdfLink").href = modalUrl; }
        else { $("modalImg").src = modalUrl; $("modalImg").alt = title; }
        $("modalFoot").textContent = footText || "";
        m.hidden = false;
        $("modalClose").focus();
    }
    function closeModal() {
        var m = $("modal");
        if (m) { m.hidden = true; }
        if ($("modalImg")) { $("modalImg").removeAttribute("src"); }
        if ($("modalPdfLink")) { $("modalPdfLink").removeAttribute("href"); }
        if (modalUrl) { URL.revokeObjectURL(modalUrl); modalUrl = null; }
    }
    document.addEventListener("DOMContentLoaded", function () {
        var m = $("modal");
        if (!m) { return; }
        $("modalClose").addEventListener("click", closeModal);
        m.addEventListener("click", function (e) { if (e.target === m) { closeModal(); } });
        document.addEventListener("keydown", function (e) { if (e.key === "Escape") { closeModal(); } });
    });

    /* api의 비상 이유 코드(trigger_source) → 화면 문장 */
    function reason(code) {
        if (!code) { return ""; }
        if (code === "sos") { return "SOS"; }
        if (code === "auto") { return "보호자 요청에 응답 없음"; }
        return code;
    }

    window.kp = { reason: reason, $: $, el: el, remain: remain, countdown: countdown, when: when, topbar: topbar, requireRole: requireRole, toast: toast, errText: errText, ring: ring, openModal: openModal, closeModal: closeModal };
})();
