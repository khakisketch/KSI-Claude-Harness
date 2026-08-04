---
name: release-risk
description: 배포·릴리즈·DB 마이그레이션·데이터 백필·인프라·CI/CD·결제/과금·롤백·관측·장애 등 '프로덕션 준비도·전달 리스크'를 점검한다. 추상적 아키텍처 순수성보다 구체적 실패 모드·blast radius·롤아웃 순서·롤백 계획을 본다.
when_to_use: 배포·릴리즈·마이그레이션·백필·결제 경로 변경·인프라/CI 변경·롤백 계획 전, 또는 고객영향 롤아웃을 '되돌리기 어려운 작업'으로 사용자에게 1줄 확인할 때. 한국어 트리거 — 배포·운영·릴리즈·migration·infra·결제·rollback·장애·observability.
---

# Release Risk — 전달·운영 리스크 점검

## 체크리스트 (해당하는 것만 — 단순 변경엔 과한 점검도 비용)
- 스코프·non-goals가 명확한가, 로컬 개발 리스크와 프로덕션 리스크를 구분했나
- 하위/상위 호환 — 구 클라이언트·구 스키마와 공존 구간을 견디나
- 마이그레이션 **배포 순서**가 안전한가(expand→migrate→contract, 코드/스키마 선후)
- 롤백 계획이 존재하고 **현실적**인가(데이터 손실 없이 되돌리나)
- 데이터 백필·정리가 필요한가
- 관측/로깅/메트릭이 충분한가(실패를 *볼 수* 있나 — blind deploy 금지)
- feature flag·단계적 롤아웃(카나리)이 필요한가
- 비밀/IAM/환경 변경이 문서화됐나
- 과금/고객 영향이 이해됐나(자금 경로면 멱등·환불≤수금 불변식 점검 — 프로젝트 `## 도메인 불변식`과 대조)
- 기존 통합·어댑터가 영향받나
- 테스트가 **임계 실패 경로**를 커버하나(happy-path 말고 타임아웃·부분실패·rate-limit)
- **SCA**: 의존성 변경 동반이면 pip-audit/npm audit high+ 미해결 없나(sca-check 훅 자동 발화 — 미설치면 미검증으로 표기)

## 워크플로
1. 릴리즈 단위와 영향 시스템을 식별.
2. 데이터 변경·의존성·롤아웃 순서를 식별.
3. 실패 모드와 blast radius를 식별(외부의존·상태기계면 운영조건/fault-injection 렌즈와 동일).
4. 릴리즈 전/후 검증을 정의.
5. 롤백 또는 완화책을 정의.
6. `Approved` / `Needs changes` / `Blocked` 판정 — 증거 부족이면 조건부 또는 Blocked(green≠작동).

**티어링:** 고위험(자금·마이그·배포)의 최종 verify는 reviewer tier(opus·high·read-only)로, verify끼리 모순이면 메인 tiebreak 1회. verify가 부분 실패하면 DEGRADED로 표기하고 낙관 결론 보류(승인 금지). 큰 릴리즈 surface는 `/codebase-audit`(운영조건/fault-injection 렌즈)로 fan-out.

## 출력
```md
## Release Verdict
Approved / Needs changes / Blocked  (+ DEGRADED 여부)

## 핵심 리스크 (실패 모드 + blast radius)

## 전달 전 필수 변경

## 롤아웃 계획 (순서·카나리·flag)

## 롤백 계획

## 관측 / 검증 (전/후)

## 잔여 리스크
```
