// SafeTravel Keeper 무중단 배포 검증 (k6, WEB 담당)
// 배포(rollout restart)하는 동안 일정한 속도로 요청을 보내고, 실패가 몇 건 나는지 센다.
// 로그인 경로는 보내지 않는다(SOC 요청). 요청 수는 낮게 시작한다(기본 초당 5건).
//
// 실행 예 (PowerShell)
//   k6 run -e BASE_URL=https://travelsafe.click -e LABEL=before tests/zero-downtime/keeper-zero-downtime.js
// 환경 변수
//   BASE_URL  대상 주소 (필수)
//   LABEL     결과 파일 이름에 붙일 이름 (before / after / dryrun)
//   RATE      초당 요청 수 (기본 5)
//   DURATION  시험 시간 (기본 10m)
// 결과: tests/zero-downtime/results/<LABEL>-summary.txt, <LABEL>-summary.json
//       요청별 시각은 실행할 때 --out csv=tests/zero-downtime/results/<LABEL>-requests.csv 로 남긴다 (README 참고)
// 실패는 두 묶음으로 따로 센다 (SOC 요청)
//   배포 영향: 502·503·504·500·연결 실패/시간 초과(상태 0)  ← 무중단 여부를 보는 숫자
//   WAF 영향 : 403·429                                    ← 요청 제한에 걸린 것. 측정에서 분리

import http from "k6/http";
import exec from "k6/execution";
import { Counter, Rate, Trend } from "k6/metrics";

const BASE = (__ENV.BASE_URL || "").replace(/\/$/, "");
const LABEL = __ENV.LABEL || "run";
const RATE = Number(__ENV.RATE || 5);
const DURATION = __ENV.DURATION || "10m";
const PATHS = ["/", "/healthz", "/api/healthz"];
const WAF_STOP = 5; // 403이 모두 합쳐 이만큼 나오면 WAF에 걸린 것으로 보고 멈춘다

const okRate = new Rate("keeper_ok");
const failed = new Counter("keeper_failed");          // 모든 실패
const failDeploy = new Counter("keeper_fail_deploy");  // 502·503·504·500·0(연결 실패·시간 초과)
const failWaf = new Counter("keeper_fail_waf");        // 403·429
// 무효: 우리 nginx(EKS)가 아닌 곳이 답한 응답 (예: DNS 캐시로 간 옛 2.5차 CloudFront).
// 성공·실패 어디에도 넣지 않고 따로 센다. 1건이라도 있으면 그 구간은 재측정한다 (SOC 요청)
const invalid = new Counter("keeper_invalid");
const DEPLOY_CODES = [0, 500, 502, 503, 504];
const WAF_CODES = [403, 429];
const latency = new Trend("keeper_latency", true);

// 상태 코드별·주소별 실패 수를 요약에 나오게 하려고 표시용 기준을 건다 (항상 통과하는 조건)
const STATUSES = ["0", "502", "503", "504", "500", "403", "429", "404"];
const thresholds = { keeper_ok: ["rate>=0"] };
STATUSES.forEach((s) => { thresholds[`keeper_failed{status:${s}}`] = ["count>=0"]; });
// 403·429는 WAF 차단이라 합쳐서 WAF_STOP 건이 되면 시험을 멈춘다 (SOC 요청: 걸리면 바로 중단하고 알림)
thresholds.keeper_fail_waf = [{ threshold: `count<${WAF_STOP}`, abortOnFail: true }];
thresholds.keeper_fail_deploy = ["count>=0"];
thresholds.keeper_invalid = ["count>=0"];
PATHS.forEach((p) => { thresholds[`keeper_failed{path:${p}}`] = ["count>=0"]; });

export const options = {
  scenarios: {
    steady: {
      executor: "constant-arrival-rate",
      rate: RATE,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: Math.max(5, RATE * 2),
      maxVUs: Math.max(20, RATE * 6),
    },
  },
  thresholds,
  userAgent: "keeper-zero-downtime-test", // SOC가 로그에서 이 시험 요청만 골라낼 수 있게
  discardResponseBodies: true,
  summaryTrendStats: ["avg", "p(95)", "p(99)", "max"],
};

export function setup() {
  if (!BASE) { throw new Error("BASE_URL 이 필요합니다. 예: -e BASE_URL=https://travelsafe.click"); }
  const startedAt = new Date().toISOString();
  console.log(`START ${startedAt} label=${LABEL} base=${BASE} rate=${RATE}/s duration=${DURATION}`);
  return { startedAt };
}

export default function () {
  const path = PATHS[exec.scenario.iterationInTest % PATHS.length];
  const res = http.get(BASE + path, { timeout: "10s", tags: { path } });
  // DNS가 아직 옛 2.5차 CloudFront를 가리키면 결과가 섞인다 (11/24 발견) → 무효로 따로 세고 판정에서 뺀다
  const server = String(res.headers["Server"] || "");
  if (res.status !== 0 && (res.headers["Via"] || res.headers["X-Amz-Cf-Id"] || (server && !/^nginx/i.test(server)))) {
    invalid.add(1, { path });
    console.warn(`INVALID ${new Date().toISOString()} ${path} status=${res.status} ip=${res.remote_ip || "-"} server=${server || "-"} (EKS가 아닌 곳이 답함, 재측정 필요)`);
    return;
  }
  const good = res.status === 200;
  okRate.add(good, { path });
  latency.add(res.timings.duration, { path });
  if (!good) {
    failed.add(1, { path, status: String(res.status) });
    if (WAF_CODES.indexOf(res.status) >= 0) { failWaf.add(1, { path }); }
    else if (DEPLOY_CODES.indexOf(res.status) >= 0) { failDeploy.add(1, { path }); }
    // 실패 시각을 초 단위로 남긴다 (SOC 로그·restart 시각과 맞춰 보기 위해)
    // 접속한 IP를 같이 남겨, 그 시각의 ALB IP(측정 전 nslookup)와 다르면 DNS 탓, 같으면 서비스 탓으로 가른다
    console.warn(`FAIL ${new Date().toISOString()} ${path} status=${res.status} ip=${res.remote_ip || "-"}${res.error ? " error=" + res.error : ""}`);
  }
}

export function teardown(data) {
  console.log(`END ${new Date().toISOString()} label=${LABEL} (started ${data.startedAt})`);
}

function count(data, name) {
  const m = data.metrics[name];
  return m && m.values ? (m.values.count || 0) : 0;
}

export function handleSummary(data) {
  const reqs = count(data, "http_reqs");
  const fails = count(data, "keeper_failed");
  const lat = (data.metrics.keeper_latency || {}).values || {};
  const ms = (v) => (v === undefined ? "-" : `${Math.round(v)}ms`);
  const lines = [
    `SafeTravel Keeper 무중단 배포 검증 결과 (${LABEL})`,
    `끝난 시각: ${new Date().toISOString()}`,
    `대상: ${BASE}   속도: 초당 ${RATE}건   시간: ${DURATION}`,
    ``,
    `전체 요청: ${reqs}건 (무효 포함)`,
    `실패: ${fails}건 (${reqs ? ((fails / reqs) * 100).toFixed(2) : "0.00"}%)`,
    `  배포 영향 (502·503·504·500·연결 실패): ${count(data, "keeper_fail_deploy")}건   ← 무중단 판단 기준`,
    `  WAF 영향 (403·429): ${count(data, "keeper_fail_waf")}건`,
    `무효 (EKS가 아닌 곳의 응답, 성공·실패에서 뺌): ${count(data, "keeper_invalid")}건`,
    count(data, "keeper_invalid") > 0 ? `→ 무효가 있어 이 구간은 재측정해야 합니다.` : `→ 무효 0건: 이 구간의 결과를 그대로 씁니다.`,
    `응답 시간: 평균 ${ms(lat.avg)}, p95 ${ms(lat["p(95)"])}, p99 ${ms(lat["p(99)"])}, 최대 ${ms(lat.max)}`,
    ``,
    `상태 코드별 실패 (0 = 연결 실패·시간 초과):`,
    ...STATUSES.map((s) => `  ${s}: ${count(data, `keeper_failed{status:${s}}`)}건`),
    `주소별 실패:`,
    ...PATHS.map((p) => `  ${p}: ${count(data, `keeper_failed{path:${p}}`)}건`),
    ``,
    `실패 시각은 실행 화면의 FAIL 줄, 요청별 시각은 ${LABEL}-requests.csv 를 보세요.`,
  ];
  const text = lines.join("\n") + "\n";
  return {
    stdout: "\n" + text,
    [`tests/zero-downtime/results/${LABEL}-summary.txt`]: text,
    [`tests/zero-downtime/results/${LABEL}-summary.json`]: JSON.stringify(data, null, 2),
  };
}
