/* 보호자 화면: 지키는 사람 카드(상태·진행 단계), 열람 요청(사용자 응답 대기), 비상일 때 열람 토큰으로 서류 보기.
 * - 열람 토큰은 서버가 준 만료 시각(expires_at)까지만 쓰고, 끝나면 화면과 열린 서류 창을 닫는다.
 * - 토큰은 메모리에만 둔다(새로 고침하면 다시 받아야 함). 요청마다 X-View-Token 머리말로 보낸다.
 * - 10초마다 목록을 확인하고, 상태가 바뀐 카드만 다시 그린다(진행 중인 타이머가 끊기지 않게). */
(function () {
    "use strict";
    var api = window.keeperApi, kp = window.kp, $ = kp.$, el = kp.el;
    /* 10초마다 묻는다. 5초였을 때 창 2개(같은 IP)만으로 WAF 요청 제한(IP당 5분 300건)을 넘었다 (11/25 10:08~10:10, 103건 차단).
     * 탭이 안 보이는 동안은 묻지 않고, 다시 보이면 바로 한 번 묻는다. 요청 대기는 60초라 10초 간격이면 충분히 거부할 수 있다. */
    var POLL_MS = 10000;
    var cards = {};   /* user_id → { sig, box, stops: [], view: { token, expires_at } | null, urls: [] } */

    function stopAll(c) { c.stops.forEach(function (f) { f(); }); c.stops = []; }
    function revoke(c) { c.urls.forEach(function (u) { URL.revokeObjectURL(u); }); c.urls = []; }
    function sig(t, c) {
        var r = t.request;
        return [t.emergency, r ? r.request_id + ":" + r.status : "-", c && c.view ? "view" : "-"].join("|");
    }
    function button(text, cls, onClick) {
        var b = el("button", cls, text);
        b.type = "button";
        b.addEventListener("click", onClick);
        return b;
    }

    /* 진행 단계: 평소 → 요청 대기 → 비상 → 열람 중 */
    function track(step) {
        var names = ["평소", "요청 대기", "비상", "열람 중"], ol = el("ol", "track");
        names.forEach(function (n, i) {
            var cls = i > step ? "" : (i >= 2 ? "red" : "on");
            ol.appendChild(el("li", cls, n));
        });
        return ol;
    }

    function panel(cls, title, sub) {
        var p = el("div", "panel" + (cls ? " " + cls : ""));
        var t = el("div", "txt");
        t.appendChild(el("p", "t", title));
        if (sub) { t.appendChild(el("p", "s", sub)); }
        p.appendChild(t);
        return p;
    }

    function render(t) {
        var c = cards[t.user_id];
        if (!c) {
            c = cards[t.user_id] = { sig: null, box: null, stops: [], view: null, urls: [] };
            c.box = el("article", "card person");
            $("travelers").appendChild(c.box);
        }
        var s = sig(t, c);
        if (s === c.sig) { return; }
        c.sig = s;
        stopAll(c);
        revoke(c);
        var box = c.box;
        box.textContent = "";

        var av = el("img", "avatar");
        av.src = "/img/mohum.svg";
        av.alt = "";
        box.appendChild(av);
        var body = el("div");
        box.appendChild(body);

        var head = el("div", "person-head");
        head.appendChild(el("b", null, t.name));
        head.appendChild(el("span", "pill " + (t.emergency ? "red" : "green"), t.emergency ? "비상" : "평소"));
        var lv = button("연결 끊기", "btn small ghost-red", function () { leave(t, lv); });
        lv.classList.add("leave");
        head.appendChild(lv);
        body.appendChild(head);
        body.appendChild(el("p", "sub", t.emergency
            ? "비상 상태" + (t.emergency_reason ? " · " + kp.reason(t.emergency_reason) : "") + (t.emergency_since ? " · " + kp.when(t.emergency_since) + "부터" : "")
            : "여행 중 · 서류는 본인만 볼 수 있는 상태예요"));

        var r = t.request;
        if (!t.emergency && c.view) {
            /* 열람 중에 여행자가 비상을 해제함: 서버도 토큰을 끊으므로 화면도 바로 닫는다 */
            c.view = null;
            kp.closeModal();
            kp.toast(t.name + " 님이 비상을 해제해 열람을 끝냈어요.");
        }
        if (!t.emergency) {
            if (r && r.status === "pending") {
                body.appendChild(track(1));
                var p = panel(null, "열람을 요청했어요. 사용자 응답을 기다리는 중", "남은 시간 안에 거부하지 않으면 비상 상태로 바뀌어요.");
                var rg = kp.ring();
                p.insertBefore(rg.el, p.firstChild);
                body.appendChild(p);
                c.stops.push(kp.countdown(r.wait_until, rg.set, function () { rg.set("0:00", 0); poll(); }));
                return;
            }
            body.appendChild(track(0));
            if (r && r.status === "denied") { body.appendChild(el("p", "note", "✋ 최근 요청을 사용자가 거부했어요. 사용자가 응답할 수 있는 상태라는 뜻이에요.")); }
            if (r && r.status === "cancelled") { body.appendChild(el("p", "note", "↩️ 최근 요청이 취소됐어요. 사용자가 직접 SOS나 비상 해제를 눌렀어요.")); }
            var p0 = panel(null, "연락이 닿지 않나요?", "열람을 요청하면 사용자 화면에 알림이 가요. 거부하지 않으면 비상 상태로 바뀌어요.");
            p0.appendChild(button("열람 요청", "btn primary", function () { ask(t); }));
            body.appendChild(p0);
            return;
        }

        if (!c.view) {
            body.appendChild(track(2));
            var p2 = panel("red", "지금 서류를 열람할 수 있어요", "열람을 시작하면 정해진 시간 동안만 볼 수 있고, 사용자와 관제에 기록이 남아요.");
            p2.appendChild(button("서류 열람 시작", "btn danger", function () { startView(t); }));
            body.appendChild(p2);
            return;
        }
        body.appendChild(track(3));
        drawView(t, c, body);
    }

    function ask(t) {
        api.call("POST", "/api/guardian/requests", { user_id: t.user_id }).then(function (r) {
            if (!r.ok) { kp.toast(kp.errText(r)); } else { kp.toast("열람을 요청했어요."); }
            poll();
        });
    }

    function startView(t) {
        api.call("POST", "/api/guardian/view-token", { user_id: t.user_id }).then(function (r) {
            if (!r.ok || !r.data) { kp.toast(kp.errText(r)); return; }
            var c = cards[t.user_id];
            c.view = { token: r.data.view_token, expires_at: r.data.expires_at };
            c.sig = null;
            render(t);
        });
    }

    function endView(t, text) {
        var c = cards[t.user_id];
        c.view = null;
        c.sig = null;
        kp.closeModal();
        kp.toast(text);
        poll();
    }

    function drawView(t, c, body) {
        var h = { "X-View-Token": c.view.token };
        var p = panel("red", "열람 중이에요", "시간이 끝나면 서류가 자동으로 닫혀요. 열람 기록이 남아요.");
        var rg = kp.ring("red");
        p.insertBefore(rg.el, p.firstChild);
        body.appendChild(p);
        c.stops.push(kp.countdown(c.view.expires_at, rg.set, function () { endView(t, "열람 시간이 끝나 서류를 닫았어요."); }));

        var ul = el("ul", "docgrid viewing-docs");
        body.appendChild(ul);
        api.call("GET", "/api/guardian/travelers/" + encodeURIComponent(t.user_id) + "/docs", null, h).then(function (r) {
            if (!r.ok) {
                ul.appendChild(el("li", "empty", kp.errText(r)));
                if (r.status === 403) { endView(t, "열람 권한이 끝났어요."); }
                return;
            }
            (r.data || []).forEach(function (d) {
                var li = el("li", "doc");
                var th = el("div", "thumb");
                th.appendChild(el("span", "lock", "🔒"));
                li.appendChild(th);
                var meta = el("div", "meta");
                meta.appendChild(el("span", "title", d.title));
                meta.appendChild(button("크게 보기", "btn small", function () {
                    api.blob("/api/guardian/docs/" + encodeURIComponent(d.id), h).then(function (b) {
                        kp.openModal(d.title, b, t.name + " 님의 서류 · 비상 열람 중 · 열람 기록이 남아요");
                    }, function (e) {
                        kp.toast(kp.errText(e));
                        if (e && e.status === 403) { endView(t, "열람 권한이 끝났어요."); }
                    });
                }));
                li.appendChild(meta);
                ul.appendChild(li);
            });
        });
    }

    /* 목록에서 빠진 사람(여행자가 보호자를 해제했거나 내가 끊음)의 카드와 열린 서류를 정리한다 */
    function drop(id, text) {
        var c = cards[id];
        if (!c) { return; }
        if (c.view) { c.view = null; kp.closeModal(); }
        stopAll(c);
        revoke(c);
        c.box.remove();
        delete cards[id];
        if (text) { kp.toast(text); }
    }

    function leave(t, btn) {
        if (btn.dataset.armed !== "1") {
            btn.dataset.armed = "1";
            btn.textContent = "정말 끊기";
            kp.toast("한 번 더 누르면 연결이 끊기고, 이 사람의 서류를 더 볼 수 없어요.");
            setTimeout(function () { btn.dataset.armed = ""; btn.textContent = "연결 끊기"; }, 4000);
            return;
        }
        btn.disabled = true;
        api.call("DELETE", "/api/guardian/travelers/" + encodeURIComponent(t.user_id)).then(function (r) {
            if (!r.ok) { kp.toast(kp.errText(r)); btn.disabled = false; return; }
            drop(t.user_id, t.name + " 님과 연결을 끊었어요.");
            /* 지키는 사람이 더 없으면 보호자가 아니므로 여행자 화면으로 간다 */
            api.call("GET", "/api/me").then(function (m) {
                if (m.ok && m.data && m.data.role !== "guardian") { location.replace("/traveler.html"); } else { poll(); }
            });
        });
    }

    function poll() {
        return api.call("GET", "/api/guardian/travelers").then(function (r) {
            if (!r.ok) { kp.toast(kp.errText(r)); return; }
            var list = r.data || [];
            var root = $("travelers"), ids = {};
            list.forEach(function (t) { ids[t.user_id] = true; });
            Object.keys(cards).forEach(function (id) { if (!ids[id]) { drop(id, "연결이 해제되어 더 이상 서류를 볼 수 없어요."); } });
            if (!Object.keys(cards).length) { root.textContent = ""; }
            if (!list.length) { root.appendChild(el("p", "muted", "연결된 사람이 없어요.")); return; }
            list.forEach(render);
        });
    }

    kp.requireRole("guardian").then(function (me) {
        kp.topbar(me.name, "보호자");
        window.keeperInvites.load();
        poll();
        setInterval(function () { if (!document.hidden) { poll(); window.keeperInvites.load(); } }, POLL_MS);
        document.addEventListener("visibilitychange", function () { if (!document.hidden) { poll(); } });
    }, function () { /* 다른 화면으로 이동함 */ });
})();
