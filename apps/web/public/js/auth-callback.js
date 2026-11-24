/* 로그인 후 돌아오는 페이지(/auth/callback.html)의 처리. 인라인 스크립트로 두지 않는 이유:
 * 나중에 CSP 에 script-src 를 걸 때 인라인 스크립트가 막히기 때문이다. */
(function () {
    "use strict";
    var msg = document.getElementById("msg");
    function fail(text) {
        msg.textContent = text;
        document.getElementById("back").hidden = false;
    }
    if (!window.stAuth || !window.stAuth.enabled()) { return fail("로그인 기능이 아직 준비되지 않았습니다."); }
    window.stAuth.handleCallback().then(function (back) {
        location.replace(back);
    }).catch(function () {
        fail("로그인에 실패했습니다. 다시 시도해 주세요.");
    });
})();
