/* 첫 화면: 로그인돼 있으면 역할에 맞는 화면으로 보내고, 아니면 로그인 버튼을 보여 준다.
 * 체험 모드에서는 Cognito 대신 "여행자로 / 보호자로 체험" 버튼을 보여 준다. */
(function () {
    "use strict";
    var api = window.keeperApi, el = window.kp.el, area = window.kp.$("loginArea");

    function button(text, cls, onClick) {
        var b = el("button", cls, text);
        b.type = "button";
        b.addEventListener("click", onClick);
        area.appendChild(b);
    }

    function showLogin() {
        area.textContent = "";
        if (api.isMock()) {
            button("여행자로 체험하기", "btn white lg", function () { api.login("user"); });
            button("보호자로 체험하기", "btn ghost lg", function () { api.login("guardian"); });
            window.kp.$("loginMsg").textContent = "로그인 설정이 아직 없어 체험 모드로 열려요.";
        } else {
            button("로그인하고 시작하기", "btn white lg", function () { api.login(); });
        }
    }

    if (!api.isLoggedIn()) { showLogin(); return; }

    api.call("GET", "/api/me").then(function (r) {
        if (r.ok && r.data && r.data.role === "guardian") { location.replace("/guardian.html"); }
        else if (r.ok && r.data) { location.replace("/traveler.html"); }
        else { showLogin(); }
    }, showLogin);
})();
