# Note Deck for Mac

메뉴바 상주 앱. 폰(USB MIDI)에서 오는 MIDI 신호를 받아 설정 파일에 적힌 동작을 실행하고,
현재 상태(선택된 출력 장치·음소거·볼륨)를 폰으로 되돌려 준다.

## 빌드 / 실행
```bash
./build-app.sh        # → NoteDeck.app, .build/release/notedeck-cli
open NoteDeck.app
```
로그인 시 자동 실행: 시스템 설정 → 일반 → 로그인 항목에 NoteDeck.app 추가.

## 설정 파일
`~/Library/Application Support/NoteDeck/config.json` — 처음 실행하면 기본값이 생긴다. 저장하면 1초 안에 자동 반영.
메뉴바 → "설정 파일 열기"로 바로 연다.

```json
{
  "midi": { "device_match": "", "channel": 0 },
  "feedback": { "enabled": true, "volume_cc": 7 },
  "triggers": {
    "note:60": { "name": "Mac Speaker", "actions": [ { "type": "audio_output", "device": "MacBook" } ] },
    "note:61": { "name": "USB Audio",   "actions": [ { "type": "audio_output", "device": "USB-Audio" } ] },
    "note:62": { "name": "Mute",        "actions": [ { "type": "mute_toggle" } ] },
    "cc:7":    { "name": "Volume",      "actions": [ { "type": "volume_set" } ] }
  }
}
```

- `midi.device_match` — MIDI 장치 이름 일부(대소문자 무시). 비우면 모든 장치. 예: `"SM-N976"`
- `midi.channel` — 1~16, 0이면 모든 채널
- `triggers` 키 — `note:<0-127>` (버튼) 또는 `cc:<0-127>` (슬라이더). 한 트리거에 액션 여러 개를 순서대로 실행.
- `device` 는 장치 이름 일부로 매칭 (`notedeck-cli audio` 로 이름 확인)

### 액션 종류
| type | 필드 | 설명 |
|---|---|---|
| `audio_output` | `device` | 기본 출력 장치 변경 |
| `audio_input` | `device` | 기본 입력 장치 변경 |
| `mute_toggle` | `device?` | 음소거 토글 (기본: 현재 출력) |
| `mute` | `on`, `device?` | 음소거 켜기/끄기 |
| `volume_set` | `value?`, `device?` | 볼륨 설정. `value`(0~127) 없으면 CC 값 사용 → 슬라이더용 |
| `volume_step` | `delta` | 볼륨 ±퍼센트 (기본 6) |
| `open` | `app` / `url` / `path` | 앱·URL·파일 열기 |
| `shell` | `command` | `zsh -lc` 로 실행 |
| `applescript` | `script` | osascript |
| `shortcut` | `name` | macOS 단축어 실행 |
| `keystroke` | `key`, `mods` | 키 입력 (cmd/alt/ctrl/shift). 손쉬운 사용 권한 필요 |
| `notify` | `title`, `message` | macOS 알림 |
| `display_sleep` | — | Mac 모니터 끄기(`pmset displaysleepnow`). Mac 화면이 꺼지면 폰 화면도 검게(CC 116) |
| `display_wake` | — | Mac 모니터 켜기 |
| `phone_screen` | `on` | 폰 화면만 검게/복귀 |

예: 한 버튼으로 USB 출력 전환 + 알림
```json
"note:61": { "name": "USB Audio", "actions": [
  { "type": "audio_output", "device": "USB-Audio" },
  { "type": "notify", "message": "USB Audio로 전환" }
] }
```

## 피드백 (Mac → 폰)
`feedback.enabled` 가 켜져 있으면 상태가 바뀔 때마다 폰으로 보낸다. 폰 앱은 이걸로 버튼 LED와 슬라이더를 맞춘다.
- `audio_output` / `audio_input` 트리거의 노트: 그 장치가 현재 기본이면 Note On(127), 아니면 Note Off
- `mute_toggle` / `mute` 트리거의 노트: 음소거면 Note On
- 현재 출력 볼륨: `volume_cc` 번 CC, 값 0~127

## 폰 → Mac 프로토콜
- 버튼 누름: Note On (벨로시티 > 0). Note Off는 무시.
- 슬라이더: Control Change, 값 0~127.
- 채널은 설정에서 고정하지 않으면 무시.
- CC 116 (Mac→폰): 0 = 폰 화면 검게, 1 = 복귀. Mac 모니터가 꺼지고 켜질 때 자동으로 보내며, 화면이 꺼진 동안 폰 버튼을 누르면 Mac 모니터를 깨운다.
- CC 119: 동기화 요청. 폰이 연결 직후 보내면 Mac이 전체 상태(피드백)를 다시 보낸다. 트리거로 쓰지 않는다.

## 테스트 (폰 없이)
```bash
.build/release/notedeck-cli audio          # 오디오 장치 목록
.build/release/notedeck-cli midi           # MIDI 소스/목적지 목록
.build/release/notedeck-cli note 62        # 가상 MIDI 소스로 Note 62 전송 (= Mute)
.build/release/notedeck-cli cc 7 64        # 볼륨 50%
.build/release/notedeck-cli listen 5       # 앱이 보내는 피드백 수신
.build/release/notedeck-cli fire note:60   # MIDI 없이 트리거 직접 실행
```
메뉴바 메뉴의 "트리거 실행 (테스트)"로도 같은 걸 할 수 있다. 로그: `~/Library/Logs/NoteDeck.log`
