# Note Deck

갤럭시 노트10을 USB로 꽂아 Mac용 스트림덱처럼 쓰는 프로젝트. 폰은 USB MIDI 장치로 동작하고, Mac 메뉴바 앱이 신호를 받아 동작을 실행한다. 루팅·네트워크 서버 없음.

```
폰 (Note Deck 앱) ──USB MIDI──▶ Mac (NoteDeck.app, 메뉴바)
   버튼 = Note On/Off               note:<n> → 액션 (출력 전환, 음소거, 셸, 단축어 …)
   페이더 = CC                     cc:<n>   → 볼륨 등
                ◀── 피드백: 활성 출력·음소거 = Note On/Off, 볼륨 = CC
```

- `mac/` — Mac 메뉴바 앱 + 테스트 CLI. 액션 종류·설정 형식은 [mac/README.md](mac/README.md)
- `app/` — Android 앱 (Kotlin). 버튼 격자 + 볼륨 페이더, 가로/세로, 전체화면

## 쓰는 순서
1. Mac: `mac/build-app.sh` → `open mac/NoteDeck.app`. 메뉴바 오른쪽 위 격자 아이콘이 생긴다. 로그인 항목에 넣어 두면 편함.
2. 폰: USB로 꽂고 알림창 "USB 충전 중" → **MIDI** 선택. (개발자 옵션 → 기본 USB 구성을 MIDI로 두면 매번 안 골라도 됨)
3. 폰 앱 실행. 오른쪽 위 점이 초록이면 연결됨. 버튼은 Mac이 어느 출력을 쓰는지에 따라 파랗게 켜지고, 페이더는 Mac 볼륨을 따라간다.

## 버튼 바꾸기 — Mac 설정 창
Mac 메뉴바 아이콘 → **설정 창 열기**. 3×2 격자에서 버튼을 누르고 오른쪽에서 편집하면 폰에 바로 전송된다.
- 6개 모두 이름·아이콘 변경 가능. 윗줄 3개(출력 전환 2개 + 음소거)는 동작이 고정, 아랫줄 3개는 동작 자유.
- 아이콘: 내장 41종(Material 아이콘 + Claude·Anthropic·OpenAI 로고, 출처는 `mac/icons/SOURCES.md`) / 이모지·짧은 글자 / 이미지 파일.
  이미지는 128px로 줄여 폰으로 보낸다. **움직이는 GIF는 프레임째 보내 폰에서 재생**된다(48프레임·600KB 제한).
  전송은 3KB 조각마다 폰의 ACK를 받고 다음 조각을 보낸다(폰 USB MIDI 수신 버퍼가 16KB라 한 번에 쏘면 유실됨). 폰은 받은 이미지를 해시와 함께 저장해 두고, 없거나 바뀐 것만 요청한다.
- 설정 창 왼쪽 아래 **로그인 시 자동 실행** 스위치로 Mac 시작 때 자동 실행(시스템 설정 → 로그인 항목에도 표시).
- 폰에서 현재 활성인 출력 장치·음소거 버튼은 파란 테두리로 표시.
- 동작: 앱 열기, URL, 파일/폴더, 셸 명령, 단축어, 키 입력, 출력/입력 장치 전환, 음소거, AppleScript, 알림.
- 같은 내용이 `~/Library/Application Support/NoteDeck/config.json`에 저장된다. 손으로 고쳐도 1초 안에 반영.
- CLI로도 가능: `mac/.build/release/notedeck-cli icon 65 some.gif` (버튼 6에 아이콘 지정)

폰 앱은 Mac이 보낸 배치를 `files/deck.json`과 `files/icon_<note>.png`에 저장해 두고, 다음 연결 때까지 그대로 보여 준다.

## 빌드 / 설치 (Android)
```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
minSdk 28, compileSdk 36, Kotlin 2.2, AGP 8.13. USB MIDI 주변기기 모드는 Android 6+이고 삼성은 기본 지원.

## 알아둘 것
- 폰 앱은 `android.media.midi`로 "Android USB 주변기기 포트"를 연다. 폰이 MIDI 모드가 아니면 점이 빨강.
- 폰 앱은 연결 직후 CC 119를 보내 Mac에 배치와 현재 상태를 요청한다. Mac → 폰 배치·이미지는 SysEx(`F0 7D 'N' 'D' cmd …`)로 간다.
- Mac 쪽 로그: `~/Library/Logs/NoteDeck.log`. 폰 쪽: `adb logcat -s MidiLink MainActivity`
- 블루투스 HID 버전(첫 시도)은 제거됨. 필요하면 git 히스토리 이전 파일 참고.
