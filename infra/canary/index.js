// SafeTravel Keeper 가용성 감시 (CloudWatch Synthetics, WEB 담당)
// 5분마다 사용자가 쓰는 경로를 바깥에서 확인한다. 하나라도 실패하면 예외를 던져 "실패"로 기록되고 알람이 울린다.
// 브라우저를 띄우지 않고 HTTP 요청만 보내서 가볍다. (런타임의 Node.js 기본 fetch 사용)
//
// 환경 변수 (monitoring.tf 가 넣음)
//   TARGET_URL      감시할 주소. 예: https://travelsafe.click  (도메인이 없으면 http://<ALB 주소>)
//   LOGIN_DOMAIN    Cognito 관리형 로그인 주소. 비어 있으면 로그인 확인은 건너뜀
//   LOGIN_CLIENT_ID Cognito 앱 클라이언트 ID (공개값. 비밀 아님)

const BASE = (process.env.TARGET_URL || "").replace(/\/$/, "");
const LOGIN_DOMAIN = (process.env.LOGIN_DOMAIN || "").replace(/\/$/, "");
const LOGIN_CLIENT_ID = process.env.LOGIN_CLIENT_ID || "";

async function get(url, opts = {}) {
  const res = await fetch(url, { signal: AbortSignal.timeout(15000), ...opts });
  const text = await res.text();
  return { res, text };
}

const checks = [
  {
    name: "1. 첫 화면",
    run: async () => {
      const { res, text } = await get(BASE + "/");
      if (res.status !== 200) throw new Error(`status ${res.status}`);
      if (!text.includes("<title>SafeTravel Keeper")) throw new Error("제목 SafeTravel Keeper 없음");
    },
  },
  {
    name: "2. web 상태 확인(/healthz)",
    run: async () => {
      const { res } = await get(BASE + "/healthz");
      if (res.status !== 200) throw new Error(`status ${res.status}`);
    },
  },
  {
    name: "3. 보안 헤더",
    run: async () => {
      const { res } = await get(BASE + "/");
      if (res.status !== 200) throw new Error(`status ${res.status} (정상 화면에서만 헤더를 본다)`);
      const h = (k) => res.headers.get(k) || "";
      const missing = [];
      const csp = h("content-security-policy");
      if (!csp.includes("default-src 'self'")) missing.push("CSP default-src");
      if (!csp.includes("frame-ancestors 'none'")) missing.push("CSP frame-ancestors");
      if (csp.includes("'unsafe-inline'") || csp.includes("'unsafe-eval'")) missing.push("CSP에 unsafe 허용이 섞임");
      if (h("x-frame-options").toUpperCase() !== "DENY") missing.push("X-Frame-Options");
      if (h("x-content-type-options").toLowerCase() !== "nosniff") missing.push("X-Content-Type-Options");
      if (h("referrer-policy") !== "no-referrer") missing.push("Referrer-Policy");
      if (/nginx\/\d/i.test(h("server"))) missing.push("Server 헤더에 버전 노출");
      if (BASE.startsWith("https://") && !h("strict-transport-security")) console.log("참고: HSTS 헤더 없음 (실패로 치지는 않음)");
      if (missing.length) throw new Error("빠짐: " + missing.join(", "));
    },
  },
  {
    name: "4. api → vault 경로(/api/healthz)",
    run: async () => {
      const { res, text } = await get(BASE + "/api/healthz");
      if (res.status !== 200) throw new Error(`status ${res.status}`);
      let body;
      try { body = JSON.parse(text); } catch { throw new Error("JSON 아님"); }
      // api는 vault가 죽어도 200을 주므로 안쪽까지 본다
      if (body.api !== "ok") throw new Error("api 응답 이상");
      if (!body.vault || body.vault.error) throw new Error("vault 연결 실패");
    },
  },
  {
    name: "5. 로그인 화면(Cognito)",
    skip: () => !LOGIN_DOMAIN || !LOGIN_CLIENT_ID,
    run: async () => {
      // 실제 로그인은 하지 않는다. 로그인 시작 주소가 오류 없이 로그인 화면으로 넘겨 주는지만 본다.
      // 값은 사이트가 보내는 것과 같은 형식. code_challenge는 확인용 고정값이라 토큰은 만들어지지 않는다.
      const q = new URLSearchParams({
        response_type: "code",
        client_id: LOGIN_CLIENT_ID,
        redirect_uri: BASE + "/auth/callback.html",
        scope: "openid email profile",
        code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        code_challenge_method: "S256",
      });
      const { res } = await get(`${LOGIN_DOMAIN}/oauth2/authorize?${q}`, { redirect: "manual" });
      const to = res.headers.get("location") || "";
      if (res.status !== 302) throw new Error(`status ${res.status} (302 기대)`);
      if (to.includes("error=")) throw new Error("Cognito가 오류로 돌려보냄 (주소 등록 확인)");
      if (!to.includes("/login")) throw new Error("로그인 화면으로 가지 않음");
    },
  },
];

exports.handler = async () => {
  if (!BASE) throw new Error("TARGET_URL 환경 변수가 없습니다.");
  const failures = [];
  for (const c of checks) {
    if (c.skip && c.skip()) { console.log(`SKIP ${c.name}`); continue; }
    try {
      await c.run();
      console.log(`OK   ${c.name}`);
    } catch (e) {
      console.log(`FAIL ${c.name}: ${e.message}`);
      failures.push(`${c.name}: ${e.message}`);
    }
  }
  if (failures.length) throw new Error(failures.join(" | "));
  return "all checks passed";
};
