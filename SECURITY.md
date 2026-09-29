# Security

## 보안 구조

앱은 계정 인증 파일을 직접 읽지 않습니다. 사용량 조회는 로컬 공식 Codex helper의 읽기 전용 RPC를 통해 수행합니다. 모델 요청 및 quota 변경 메서드는 전송 열거형에 없습니다.

helper를 시작하기 직전에 macOS Security framework로 앱 번들과 실행 파일의 서명을 모두 검증합니다. Apple Developer ID 인증서 체인, OpenAI Team ID `2DC432GLL2`, 앱 ID `com.openai.codex`, helper ID `codex`를 요구합니다. 새 배포 구조의 중첩 `CodexCLI.app`도 별도로 검증합니다. 이 값은 공개 코드 서명 식별자이며 사용자 개인정보나 인증정보가 아닙니다. 심볼릭 링크 실행 경로는 거부합니다. 검증 실패 시 실행하지 않고 `Rate limit unavailable`을 표시합니다. OpenAI가 서명 식별자를 바꾸면 검토 후 업데이트가 필요합니다.

서명 검사는 helper 시작 시에만 수행합니다. 이미 연결된 프로세스의 5분 갱신마다 전체 앱을 다시 검사하지 않습니다. 같은 사용자 권한의 악성 코드나 관리자에 의한 실행 시점 파일 교체까지 완전히 방어하는 보안 격리를 제공하지는 않습니다.

참고: [Apple 코드 서명 검증](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:)), [Apple 코드 서명 요구사항](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

## 진단 파일

기본값은 로그 비활성화입니다. 명시적으로 지정한 진단 파일은 `openat`과 `O_EXCL | O_NOFOLLOW`로 새 파일만 생성합니다. 소유자와 디렉터리 권한을 확인하고 파일 권한은 0600으로 제한합니다. 기존 파일, 심볼릭 링크, 하드 링크를 덮어쓰지 않습니다. 로그 생성 실패는 조회 기능에 영향을 주지 않습니다.

사용량과 시각도 개인 활동 정보입니다. 진단 로그와 실제 검증 자료는 공개 저장소에 포함하지 않아야 합니다. 빌드 캐시, 앱 바이너리, 인증 파일 이름과 진단 파일 패턴을 gitignore에 추가했습니다. gitignore는 이미 추적된 파일이나 과거 Git 이력에서 자료를 지워주지는 않습니다.

## 검증 범위

테스트는 남은 비율/시간 경계값, 한도 버킷 구분, 로그인 오류, 요청 메서드 제한, persistent helper 재사용, 종료 응답성, 진단 파일 보호 및 서명 거부 동작을 검증합니다. 실제 계정 정보를 사용하지 않는 가짜 서버로 전송을 검증합니다. 선택적으로 `./scripts/test.sh --verify-codex /path/to/Official.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`로 설치된 공식 파일 서명만 검증할 수 있습니다. 이 옵션은 해당 앱을 실행하거나 사용량을 조회하지 않습니다.

배포 앱 자체는 ad-hoc 서명입니다. Developer ID 서명·공증 및 다른 Mac에서의 실행, 실제 재부팅 후 자동 실행은 별도 배포 검증이 필요합니다. 공개 패키지 검사는 과거에 별도로 업로드된 자료나 다른 저장소의 이력을 검사한 결과가 아닙니다.

2026-09-30 검증: 새 경로의 공식 Codex 앱/실행 파일 서명 검증과 45개 테스트 통과. 실제 메뉴바에 Weekly 사용량과 reset 시간이 표시되었고 새 설치본의 `SMAppService.mainApp` 자동 실행 등록 상태가 `enabled`로 확인되었으며, 진단 이벤트는 `initialize`, `initialized`, `account/read`, `account/rateLimits/read`만 기록했습니다. 다른 Codex 작업이 동시에 실행 중이면 사용량 전후 비교로 조회 자체의 1% 미만 변화 여부까지 분리할 수는 없습니다.
