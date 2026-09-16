# Weekly Menu

Codex의 남은 사용량을 표시하는 Swift / SwiftUI 네이티브 macOS 메뉴바 앱입니다. Dock 아이콘과 메인 창, 외부 패키지 의존성이 없습니다.

기본 표시 예: `W72% · 3일23시간`. 숫자는 예시입니다.

- 남은 % = `100 - usedPercent`, 0–100 범위로 제한하고 소수점은 내립니다.
- 24시간 이상 `3일23시간`, 24시간 미만 `18시간32분`, 1시간 미만 `42분`.
- 클릭하면 5H/Weekly 남은 %, reset까지 남은 시간, 마지막 업데이트 시각을 표시합니다.
- Refresh, Launch at Login, Quit를 제공하며 다크/라이트 모드를 따릅니다.
- 오류 표시는 `W-- · --`, 상세 원인은 `Codex not running`, `Not signed in`, `Rate limit unavailable`입니다.
- 서버에서 5H가 제공되지 않으면 해당 항목만 `--`로 표시합니다. 다른 모델의 한도를 대신 사용하지 않습니다.

## 조회와 성능

공식 OpenAI 서명을 확인한 로컬 Codex app-server 하나를 시작하여 표준 입출력 연결을 재사용합니다. 실행 중인 Codex 데스크톱과 기존 로그인 세션이 필요합니다. API 키 입력은 필요하지 않습니다.

허용하는 RPC는 `initialize`, `initialized`, `account/read` (`refreshToken: false`), `account/rateLimits/read`뿐입니다. 모델·프롬프트·inference·completion·Responses 요청이나 quota/credit 소비·구매·reset 메서드를 호출하지 않습니다. 사용량 조회 자체는 모델 사용량을 소비하지 않습니다. 같은 계정의 다른 작업으로 표시값이 줄어들 수 있습니다.

앱은 인증 파일을 직접 읽거나 토큰을 저장하지 않으며, HTTP 클라이언트도 포함하지 않습니다. 공식 Codex helper가 기존 인증으로 OpenAI의 사용량 서버에 접근합니다. 제3자 서버에 인증정보를 전달하는 기능은 없습니다. helper의 analytics와 OTEL export는 비활성화합니다.

실행 시 조회하고, 이후 300초 고정 주기 및 수동 Refresh로 갱신합니다. 수동 조회는 자동 주기를 변경하지 않습니다. 타이머 tolerance는 0이지만 macOS 잠자기·스케줄링 지연 중 정확한 실행 시각은 보장되지 않습니다. 놓친 조회를 몰아서 실행하지 않습니다. 남은 시간만 1분마다 메모리에서 계산하며 파일 감시나 초 단위 polling은 없습니다. helper는 갱신마다 새로 실행하지 않습니다.

## 설치 및 빌드

Apple Silicon, macOS 13 이상, 빌드에는 Xcode Command Line Tools 또는 Xcode가 필요합니다.

```sh
./scripts/test.sh
./scripts/build.sh
```

결과는 `dist/Weekly Menu.app`, 임시 빌드 파일은 `.build/`에 생성됩니다. 앱을 Applications에 복사한 뒤 실행하고 메뉴에서 Launch at Login을 켭니다. macOS가 승인을 요구하면 시스템 설정에서 허용합니다. 자동 실행은 `SMAppService.mainApp`을 사용합니다.

이전 개인 빌드를 교체한다면 먼저 기존 앱에서 Launch at Login을 끄고 Quit한 뒤 교체하세요. 새 빌드는 일반화한 bundle ID를 사용하므로 새 앱에서 자동 실행을 다시 설정해야 합니다.

빌드 스크립트의 서명은 로컬 ad-hoc 서명이며 Developer ID 서명과 공증은 포함하지 않습니다. 공개 바이너리 배포 시 배포자가 별도 서명·공증해야 합니다.

## 진단 및 공개 범위

진단 로그는 기본적으로 꺼져 있습니다. 필요할 때만 `--audit /absolute/private-directory/new-file.jsonl` 인수를 사용하세요. 본인 소유이며 다른 사용자가 쓰기 불가능한 폴더 안에 새 파일을 권한 0600으로 생성합니다. 기존 파일·링크·부적절한 경로는 거부하고 로그 없이 정상 실행합니다.

로그에는 인증정보나 계정 ID는 기록하지 않지만, 사용량·reset 시각·조회 시각·프로세스/자원 수치가 포함됩니다. 개인 활동 기록이므로 공개하지 마세요. 소스 패키지는 실제 계정 기록, 진단 로그, 빌드 캐시를 포함하지 않습니다.

- [설계 비교와 라이선스 조사](RESEARCH.md)
- [보안 정책과 검증 범위](SECURITY.md)
- [MIT 라이선스](LICENSE)
