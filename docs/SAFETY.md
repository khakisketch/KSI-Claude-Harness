# 안전 자세 (SAFETY) — 읽고 결정하기

이 하네스의 원작자는 **자율성을 최대화**하는 구성을 쓴다. 팀에 그대로 권장하되, 각자 **무엇을 켜는지 이해하고** 선택해야 한다. dangerous mode는 한 번 켜면 에이전트가 권한 프롬프트 없이 행동한다.

## 원작자 기본 구성 (권장값)
- `~/.bashrc` alias로 `claude` 실행 시 **`--dangerously-skip-permissions`(권한 프롬프트 전부 끔) + ultracode(xhigh+workflow 자동)** 상시 ON.
- `settings.json`에 `skipDangerousModePermissionPrompt` + `skipAutoPermissionPrompt`.
- **permission deny-list 없음**(backstop 0). 유일한 안전망 = 모델의 자기절제 + doctrine("알아서 진행은 되돌리기 어려운 실행까지 승인한 게 아니다" — 대상·환경이 특정된 승인만 유효).

## 왜 이렇게 쓰나 (맥락)
- 개인 **개발 전용 머신**에서, 끝까지 자율 실행을 강하게 선호하는 1인 워크플로에 최적화됨.
- 잘못된 tier의 재작업·매 단계 허락이 가장 비싼 비용이라는 판단.

## 팀이 따져야 할 것 (정직한 trade-off)
1. **passwordless sudo 증폭:** 에이전트 계정에 passwordless sudo가 있으면 dangerous mode와 곱해져 blast radius가 워크스페이스 → 호스트 전역이 된다. 에이전트 머신에서 sudo를 좁히는 걸 권장.
2. **소프트 게이트의 한계:** "되돌리기 어려운 작업은 먼저 확인"은 모델이 스스로 지켜야 발동한다. deny-list 같은 하드 차단은 없다. 위임한 서브에이전트(Explore·reviewer)도 dangerous를 상속하지만 둘 다 read-only 계약이라 push/배포/마이그레이션 같은 되돌리기 어려운 실행 자체는 메인이 직접 한다 — 위임 경로로 이 확인을 우회할 수 없다.
3. **플러그인 훅 = 임의 셸 실행:** 이 플러그인의 훅(`ruff-check.sh`, `ui-render-check.sh`)을 포함해, 모든 플러그인 훅은 셸 스크립트를 돌린다. 설치 전 스크립트를 읽고 신뢰를 판단한다(여기 둘은 read-mostly·advisory·graceful-skip이며 파일을 수정하지 않는다).

## 더 안전하게 쓰고 싶다면 (opt-out / 보강)
- **dangerous alias를 안 넣는다** → 일반 권한 프롬프트가 유지된다(ultracode만 쓰려면 `/effort ultracode`로 세션마다 켠다).
- **deny-list 추가** (`~/.claude/settings.json` `permissions.deny`): 자기절제와 무관하게 항상 막을 것 —
  ```json
  { "permissions": { "deny": [
      "Bash(sudo:*)", "Bash(rm -rf:*)",
      "Bash(git push:*)", "Bash(curl:*)", "Bash(wget:*)"
  ] } }
  ```
  deny는 dangerous mode에서도 우선 적용되므로 "확인 게이트"를 doctrine→권한으로 승격한다.
- **조직 강제가 필요하면** `managed-settings.json`(관리자 전용)으로 `permissions`·`effortLevel`·`allowManagedHooksOnly`를 강제할 수 있다(사용자/프로젝트 설정으로 override 불가).

## 한 줄 요약
> dangerous+ultracode는 **개인 선택**으로는 합리적인 생산성 trade-off다. 팀 배포에서는 각자 이 문서를 읽고, **최소한 `Bash(sudo:*)`·`rm -rf`·`git push` deny-list**를 깔거나 dangerous를 끄는 것을 권장한다. 자율성은 유지하되 비가역 사고만 하드 차단하는 게 비용 대비 가장 효율적이다.
