# AI Usage Herdr plugin

Cursor, ChatGPT, Claude 남은 사용량을 Herdr 상태 pane과 팝업 대시보드에 보여 줍니다. 메뉴바 앱과 같은 조회·저장 경로를 쓰고, 스냅샷과 저장 계정은 `~/Library/Application Support/AIUsage`를 공유합니다.

표시 형식은 메뉴바와 같습니다.

- Cursor: `Auto` · `Other`
- ChatGPT / Claude: `5h` · `Weekly`
- 퍼센트가 없고 API 비용만 있으면 `API $…`

## 설치

```bash
scripts/build.sh
herdr plugin link /path/to/ai-usage
herdr plugin action invoke ai-usage.watch-start
herdr server reload-config
```

단축키:

```toml
[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "ai-usage.open"
description = "AI 사용량"
```

`herdr server reload-config` 후 prefix+u 로 대시보드를 엽니다.

## 동작

- 감시 프로세스는 네트워크만 갱신합니다. macOS 메뉴바 아이콘은 띄우지 않습니다.
- 현재 워크스페이스의 각 탭 아래에 상태 pane을 미리 붙입니다. 탭을 옮겨도 레이아웃이 다시 나뉘지 않습니다. 닫히거나 두꺼워지면 감시 프로세스가 다시 열고 높이를 맞춘 뒤, 아래에 붙어 있던 내용은 다시 하단으로 맞춥니다.
- 마지막 네트워크 요청 후 1분이 지나기 전에는 다시 요청하지 않습니다. 메뉴바 앱과 같은 설정 도메인을 씁니다.
- 429가 난 서비스는 5분 동안 건너뜁니다.
- 대시보드: `r` 새로고침, `c`/`g`/`l` 현재 Cursor·ChatGPT·Claude 세션 저장, 번호로 저장 계정 적용, `x번호` 삭제, `vc`/`vg`/`vl` 표시 전환, `q` 닫기.

Herdr를 다시 띄우면 startup hook이 감시를 다시 시작합니다.
