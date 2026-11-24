# 위험 파드 예시 (서버 dry-run 전용)

멘토 키트(hannctl_mentoring)의 `k8s/attack` 예시를 keeper에 맞게 옮긴 것입니다.
**실제로 만들지 않고** API 서버에서 검사만 받습니다(`--dry-run=server`). 모두 거부되어야 정상입니다.

```powershell
foreach ($f in Get-ChildItem tests\attack\*.yaml) {
  kubectl apply -n keeper --dry-run=server -f $f.FullName
}
```

| 파일 | 위험 | 막는 곳 |
|---|---|---|
| `privileged-pod.yaml` | 특권 컨테이너 → 노드 장악 | PSA restricted + 입장 정책 |
| `hostpath-pod.yaml` | 노드 루트 파일시스템 연결 | PSA restricted + 입장 정책 |
| `root-pod.yaml` | root(UID 0) 실행 | PSA restricted + 입장 정책 |
| `untrusted-registry-pod.yaml` | 보안 설정은 정상, 이미지 출처만 외부 | 입장 정책(우리 ECR만 허용) |

마지막 파일은 PSA 기준은 모두 통과하도록 만들어서, "출처"만으로 거부되는지를 따로 확인합니다.

## RED 시험 권한 (keeper-red)

`keeper-red`는 EKS 접근 등급 `tester`다. 클러스터 조회 + `keeper` 네임스페이스에 파드 **만들기**만 가능하다(Secret 조회, exec, 삭제·수정은 불가).
위 시험 파드가 거부되는지 서버 dry-run으로 확인하려면 파드 `create` 권한이 필요해서 따로 열어 둔 권한이다.

```powershell
aws eks update-kubeconfig --name keeper-eks --region ap-northeast-2
kubectl auth can-i create pods -n keeper          # yes
kubectl auth can-i get secrets -n keeper          # no
kubectl auth can-i create pods/exec -n keeper     # no
```

WAF 차단 기록은 CloudWatch Logs `aws-waf-logs-keeper`에서 본다 (조회 권한은 `scripts/grant-log-read.ps1 -User keeper-red -LogGroup aws-waf-logs-keeper`로 한 번 부여).

```powershell
aws logs filter-log-events --log-group-name aws-waf-logs-keeper --region ap-northeast-2 --filter-pattern BLOCK --max-items 20
```

## 앱 서비스 어카운트 도용 (sa-hijack-*.yaml)
- keeper-api 같은 앱 서비스 어카운트를 파드·Deployment에 붙여 그 앱의 IAM 권한(IRSA)을 얻으려는 시도. 파드 생성 주체는 컨트롤러라 Deployment 등에도 정책이 걸려 있다.
- 정책 keeper-restrict-app-service-accounts 가 Deny 일 때만 거부된다(Warn+Audit 기간에는 경고만). image 의 REPLACE_ECR_REGISTRY 를 실제 ECR 주소로 바꿔서 쓴다.
- 배포 주체(GitHub Actions 역할, Terraform 실행 계정)와 컨트롤러는 허용된다. NetworkPolicy는 라벨(만드는 쪽이 정함)로 동작하므로 이 경로의 방어선이 아니다.
- 시험 때는 관리자 계정이 아니라 keeper-red(tester)로 해야 거부 장면이 된다.

