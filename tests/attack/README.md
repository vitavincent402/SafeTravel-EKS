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
