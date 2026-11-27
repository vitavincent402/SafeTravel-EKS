/* 받은 보호자 요청: 누군가 나를 보호자로 초대하면 여기서 수락하거나 거절한다.
 * 수락할 때 "비상일 때 그 사람의 서류를 볼 수 있다"는 열람 조건에 동의해야 한다(agree: true).
 * 여행자 화면과 보호자 화면 둘 다에서 쓴다. 받은 요청이 없으면 카드를 숨긴다. */
(function () {
    "use strict";
    var api = window.keeperApi, kp = window.kp, $ = kp.$, el = kp.el;

    /* 10초마다 다시 불러와도, 바뀐 게 없으면 그리지 않는다(체크해 둔 동의가 풀리지 않게) */
    var sig = null;
    function render(list) {
        var s = JSON.stringify(list);
        if (s === sig) { return; }
        sig = s;
        var card = $("invitesCard"), ul = $("invList");
        ul.textContent = "";
        card.hidden = !list.length;
        list.forEach(function (inv) {
            var li = el("li", "invite");
            var who = el("div", "who2");
            who.appendChild(el("b", null, (inv.name || inv.email) + " 님이 나를 보호자로 지정하려고 해요"));
            if (inv.email) { who.appendChild(el("span", null, inv.email)); }
            li.appendChild(who);

            var label = el("label", "agree");
            var box = el("input");
            box.type = "checkbox";
            label.appendChild(box);
            label.appendChild(el("span", null, "이 사람이 비상 상태일 때 정해진 시간 동안 서류를 열람할 수 있고, 열람 기록이 남는 것에 동의해요."));
            li.appendChild(label);

            var row = el("div", "invite-actions");
            var ok = el("button", "btn small primary", "수락");
            ok.type = "button";
            ok.disabled = true;
            box.addEventListener("change", function () { ok.disabled = !box.checked; });
            ok.addEventListener("click", function () { accept(inv, ok); });
            var no = el("button", "btn small ghost-red", "거절");
            no.type = "button";
            no.addEventListener("click", function () { decline(inv, no); });
            row.appendChild(ok);
            row.appendChild(no);
            li.appendChild(row);
            ul.appendChild(li);
        });
    }

    function load() {
        return api.call("GET", "/api/guardians/invites").then(function (r) {
            render(r.ok && Array.isArray(r.data) ? r.data : []);
        });
    }

    function accept(inv, btn) {
        btn.disabled = true;
        api.call("POST", "/api/guardians/invites/" + encodeURIComponent(inv.id) + "/accept", { agree: true }).then(function (r) {
            if (!r.ok) { kp.toast(kp.errText(r)); btn.disabled = false; return; }
            kp.toast("보호자 요청을 수락했어요. 보호자 화면으로 이동해요.");
            /* 수락하면 역할이 보호자로 바뀐다. 화면을 새로 열면 맞는 화면으로 간다 */
            setTimeout(function () { location.replace("/guardian.html"); }, 1200);
        });
    }

    function decline(inv, btn) {
        btn.disabled = true;
        api.call("POST", "/api/guardians/invites/" + encodeURIComponent(inv.id) + "/decline").then(function (r) {
            if (!r.ok) { kp.toast(kp.errText(r)); btn.disabled = false; return; }
            kp.toast("보호자 요청을 거절했어요.");
            sig = null;
            load();
        });
    }

    window.keeperInvites = { load: load };
})();
