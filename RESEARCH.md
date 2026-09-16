# 비교 조사와 설계 선택

조사일: 2026-09-12. 아래 표는 README만이 아니라 해당 커밋의 Swift 소스와 LICENSE를 직접 확인한 결과입니다.

| 프로젝트 | Codex 조회 | 메뉴바와 클릭 UI | Refresh | Reset 시간 | 라이선스 |
|---|---|---|---|---|---|
| [gameofbitcoins/codex-usage-menubar](https://github.com/gameofbitcoins/codex-usage-menubar/tree/4e4be27e11cc03f2ca20deba1544c0865846b49e) | 매 조회에 `codex app-server --listen stdio://` 실행, 초기화 뒤 `account/rateLimits/read`. 명시적 `codex` 버킷 우선 | AppKit NSStatusItem/NSMenu, 두 한도의 남은 %, reset credit 수도 표시 | 60초 Timer + 수동. 조회 프로세스 종료, 45초 timeout | Unix 초를 Date로 변환. 절대시각과 일/시간/분 countdown | MIT, Codex Usage contributors |
| [estay-inc/codex-usage-app](https://github.com/estay-inc/codex-usage-app/tree/7f72ef7a293456dc13300c808cb68bf2cda8802d) | **지속되는 app-server**와 JSONL 연결. 요청 ID별 callback, `account/rateLimits/read` | AppKit 메뉴바. 5h, T(weekly), 일일 사용량 D와 사용 이력 관련 표시 | 120초 Timer + 수동. 서버 재사용 | `resetsAt`의 Unix 초. 메뉴에 현지 reset 시각; 일일 사용량은 저장된 샘플로 추정 | MIT, Codex Usage App contributors |
| [CMMUU/codex-usage-bar](https://github.com/CMMUU/codex-usage-bar/tree/8e0d365a3e262b1a907eabc0436bb654129d9046) | 조회마다 app-server probe. `account/read(refreshToken:false)` + `account/rateLimits/read`. 환경/전송 플래그별 fallback | SwiftUI MenuBarExtra, 남은 주간 %, 상세 화면, WidgetKit 및 다른 서비스 지원 | 기본 sleep 300초 뒤 fetch 반복. fetch 시간이 주기에 더해짐. 메뉴가 오래됐을 때 추가 갱신 | Unix 초를 Date로 변환, 현지 월/일/시각 표시 | MIT, CMMUU |
| [ZHANGLAOJIU/CodexQuotaMenu](https://github.com/ZHANGLAOJIU/CodexQuotaMenu/tree/1234b4c0379857dda66a64b00482f8217ba86114) | `auth.json` 직접 읽기. `chatgpt.com/backend-api/wham/usage` 및 reset-credit 목록에 GET. 실패 시 로컬 로그 SQLite fallback | AppKit 상태 아이콘 및 직접 그린 5H/weekly 계기와 countdown. 추가 서비스·계정 기능 | Codex 30초 Timer + 수동. 다른 서비스는 60/120/300초 backoff | `reset_at` Unix 초, 일/시간/분. 로그 fallback은 기록 당시 값일 수 있음 | MIT, CeZhang |

소스 확인 위치:

- gameofbitcoins: `src/CodexUsageMenu.swift`의 `CodexUsageService.fetch`, `applicationDidFinishLaunching`, `relativeReset`.
- estay-inc: `Sources/CodexUsageMenuBar.swift`의 app-server client, `LimitWindow`, 120초 Timer.
- CMMUU: `Sources/CodexUsageCore/CodexAppServerClient.swift`, `CodexModels.swift`, `Sources/CodexUsageBar/State/UsageViewModel.swift`, `Sources/CodexUsageShared/AppLanguage.swift`.
- ZHANGLAOJIU: `CodexQuotaMenu.swift`의 usage reader, `formatCountdown`, 30초 Timer 및 `QuotaModel.swift`.

## 선택

**지속되는 로컬 app-server 1개 + 제한된 read-only JSONL 클라이언트 + 네이티브 상태 항목**을 선택했습니다. estay의 연결 유지 아이디어, CMMUU의 로그인 상태 확인, gameofbitcoins의 공통 Codex 버킷 우선 선택을 참고했습니다. 인증 직접 처리와 로그 이력 추정은 도입하지 않았습니다.

기존 데스크톱의 내부 IPC나 비공개 소켓 경로에 의존하지 않고, 공식 stdio app-server를 한 번 시작해 재사용합니다. 연결 실패 또는 종료 후 다음 조회 때 다시 연결합니다. 별도 helper의 메모리가 필요하지만 5분마다 프로세스를 새로 생성하는 비용은 없습니다.

## 읽기 전용과 quota

[공식 OpenAI app-server 문서](https://learn.chatgpt.com/docs/app-server)는 `account/read`와 `account/rateLimits/read`, `usedPercent`, `windowDurationMins`, Unix 초 단위 `resetsAt`을 정의합니다. 사용량 읽기와 earned reset 소비는 서로 다른 메서드입니다.

[OpenAI의 backend-client 구현](https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client/rate_limit_resets.rs)에서 일반 usage reader는 GET으로 `/wham/usage` 또는 `/api/codex/usage`를 읽습니다. reset 소비는 별도의 POST 함수에 있습니다. 새 앱은 읽기 RPC만 허용하며 해당 소비 경로, 모델 입력, turn 시작 경로를 호출하지 않습니다.

이는 모델 요청이 없는 구조라는 근거입니다. 실험에서 정수 퍼센트가 같다고 해서 1% 미만의 사용까지 실측해 0임을 증명하는 것은 아닙니다. 다른 Codex 작업이 동시에 실행되면 같은 계정의 실제 남은 한도는 줄 수 있습니다. 검증은 전송 메서드 제한, 공식 조회 구현, 계산 및 전송 테스트를 사용합니다.

## 라이선스 처리

네 저장소 모두 해당 커밋의 LICENSE가 MIT였습니다. MIT는 코드 재사용 시 저작권·허가문 유지가 필요합니다. 이번 구현은 소스·아이콘·화면 자산을 복사하지 않았으며, 조사용 checkout은 배포 앱/소스 패키지에 포함하지 않습니다. 위 링크로 구조 참고 출처를 남깁니다.

자동 실행에는 Apple의 [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)과 [register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register())를 사용합니다. 임의의 LaunchAgent plist를 설치하지 않습니다.
