# 33 — Windows 패널 Ctrl+P 프로필 전환 후 입력창 포커스 복귀

## 증상

Windows 패널에서 Ctrl+P로 프로필 드롭다운을 열어 프로필을 바꾼 뒤, 포커스가
ComboBox에 남아 곧바로 타이핑할 수 없었다. mac은 정상 (팝업이
`refusesFirstResponder = true`라 처음부터 입력 필드가 포커스를 유지).

## 원인

WPF ComboBox는 드롭다운을 닫아도 포커스를 스스로 쥔다. mac의 NSPopUpButton은
first responder를 거부하도록 만들어 두었지만, Windows 포트에는 대응 처리가 없었다.

## 수정 (PromptWindow — mac 무변경)

- `PromptWindow.xaml` — ComboBox에 `DropDownClosed="ProfileBox_DropDownClosed"`.
- `PromptWindow.xaml.cs` — 핸들러에서 `InputBox`로 포커스 복귀. 단, `DropDownClosed`
  시점에 바로 세팅하면 ComboBox가 닫히며 포커스를 되찾아 무시되므로
  `Dispatcher.BeginInvoke(..., DispatcherPriority.Input)`으로 지연 실행.

Ctrl+P → 프로필 선택(키보드 ⏎/화살표 또는 마우스) → 드롭다운 닫힘 → 입력창 포커스.
선택 없이 Esc/바깥 클릭으로 닫아도 입력창으로 복귀 (Ctrl+P의 의도가 프로필 조작이라
무해).

## 수동 테스트 (사용자 실측 필요 — GUI)

1. 핫키로 패널 표시 → Ctrl+P → ↑↓/⏎ 또는 마우스로 프로필 선택.
2. 선택 직후 커서가 아래 입력창에 있고 바로 타이핑되는지 확인.
3. Ctrl+P로 열고 Esc로 닫아도 입력창으로 포커스가 돌아오는지 확인.
