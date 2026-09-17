#!/usr/bin/env bash
# 제품 repo 공통 안전망 (PreToolUse hook)
#
# 왜: 제품 repo 에는 안전망이 하나도 없었다(2026-07-31 감사에서 전 제품 repo 누락 확인).
#     control repo 의 hook 은 `.claude/../observability/hooks/` 경로에 묶여 있어 이식 불가라
#     자립형으로 만든다. 원본: zerolane-control/templates/product-repo/guard.sh
#
# 설계 원칙: **fail-open.** 이 스크립트의 어떤 내부 오류도 세션을 막지 않는다.
#            막는 것은 전사 헌법(zerolane-control/CLAUDE.md §2·§8)이 금지한 것뿐.
#
# 차단 규약: exit 2 + stderr 메시지

# ⚠️ 여기에 `exec 2>/dev/tty 2>/dev/null || true` 가 있었다 — 제거했다(2026-08-15).
#    bash 는 리다이렉션을 왼쪽부터 적용하므로 최종 fd2 는 **/dev/null** 이 된다.
#    즉 /dev/tty 가 열리는 환경(사장님 터미널 세션)에서는 block() 의 차단 사유가
#    통째로 사라지고 exit 2 만 남아, 에이전트가 **왜 막혔는지 모른 채 재시도**한다.
#    이 환경에서 사유가 보였던 건 /dev/tty 가 없어 exec 가 통째로 실패한 덕이다 — 우연이다.
#    hook 의 stderr 는 Claude Code 가 읽어 사유로 쓴다. 건드리지 않는 것이 맞다.
INPUT=$(cat 2>/dev/null) || exit 0

block() { echo "🚫 [zerolane 헌법] $1" >&2; exit 2; }

CMD=$(printf '%s' "$INPUT" | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    ti=d.get("tool_input") or {}
    print(ti.get("command","") if isinstance(ti,dict) else "")
except Exception:
    print("")
' 2>/dev/null) || exit 0
[ -z "$CMD" ] && exit 0

# ── 되돌릴 수 없는 파괴 (예외 없음) ─────────────────────
case "$CMD" in
  *"git push"*--force*|*"git push"*" -f "*)
    block "git push --force 금지. 이력을 지운다" ;;
  *"git reset --hard origin/main"*)
    block "git reset --hard origin/main 금지. 로컬 작업이 통째로 사라진다" ;;
  *"--no-verify"*)
    block "--no-verify 금지. 훅을 우회하면 안전망이 무의미해진다" ;;
  *"rm -rf /"*|*"rm -rf ~"*)
    block "위험한 rm -rf 대상" ;;
esac

# ── main 직접 push 금지 → 브랜치 + PR ───────────────────
# 자동 리뷰(review-prs)가 claude/ 브랜치 PR 을 리뷰·머지한다. main 에 직접 넣으면
# 3-리뷰어 게이트를 통째로 건너뛴다.
#
# ⚠️ 2026-09-16 (zerolane-os#1155): 문자열 부분일치(`*" main"*` 등)는 대상 ref 를
#    **명시한** push 만 잡는다. `git push` / `git push origin` 처럼 대상을 생략하고
#    업스트림 트래킹에 맡기는 형태는 명령어 어디에도 "main" 이 나타나지 않아 통과된다.
#    zerolane-erp 가 정확히 이 경로로 main 에 직접 push 됐다(#1155 자체보고).
#    작업 트리가 main 에 서 있는 상태(흔한 기본값)에서 커밋 후 `git push` 만 치면 뚫린다.
#    central hook(zerolane-control/observability/hooks/pre-tool-approval.sh)의
#    토큰 분리 방식을 가져오되, "대상 ref 를 아예 안 적은 경우"에는 **현재 브랜치**를 본다.
zl_push_targets_protected() {
  local c="$1" w seen_push=0 nonflag=0
  [[ "$c" =~ (^|[^[:alnum:]_])git[[:space:]]+push([[:space:]]|$) ]] || return 1
  for w in $c; do
    if [ "$seen_push" = "1" ]; then
      case "$w" in
        -*) continue ;;                              # 플래그는 건너뛴다
        main|master|*:main|*:master) return 0 ;;     # 대상 ref 가 보호 브랜치로 명시됨
        *) nonflag=$((nonflag+1)) ;;                  # 원격/다른 브랜치가 명시됨
      esac
    fi
    [ "$w" = "push" ] && seen_push=1
  done
  # 원격+브랜치를 둘 다 명시했다(예: git push origin feature-x) → main 이 아니었으니 안전
  [ "$nonflag" -ge 2 ] && return 1
  # bare `git push` 또는 `git push <remote>` — 대상은 업스트림 트래킹, 즉 현재 브랜치다
  local cur
  cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 1
  case "$cur" in
    main|master) return 0 ;;
  esac
  return 1
}

if zl_push_targets_protected "$CMD"; then
  block "main 직접 push 금지. claude/{agent}/{날짜}-{slug} 브랜치 + PR 로. (자동리뷰가 리뷰·머지한다. 대상을 생략한 bare git push 도 현재 브랜치가 main/master 면 차단된다)"
fi

# ── 이슈 발행권 · owner:human 경계 ──────────────────────
# 이슈는 zerolane-os/zerolane-os 단일 트래커. 발행은 PM 단독.
case "$CMD" in
  *"gh issue create"*)
    block "이슈 발행은 PM 단독. routine 종료 코멘트의 '## PM 발행 요청' 섹션으로 요청하라" ;;
esac
if printf '%s' "$CMD" | grep -qE 'gh issue (close|reopen)'; then
  N=$(printf '%s' "$CMD" | grep -oE 'gh issue (close|reopen) +#?[0-9]+' | grep -oE '[0-9]+$' | head -1)
  if [ -n "$N" ]; then
    LB=$(gh issue view "$N" -R zerolane-os/zerolane-os --json labels,title \
         --jq '(.labels|map(.name)|join(",")) + " " + .title' 2>/dev/null || echo "")
    case "$LB" in
      *owner:human*|*"[H]"*)
        block "owner:human 이슈는 사장님만 상태를 바꾼다 (#$N). 코멘트는 허용" ;;
    esac
  fi
fi

exit 0
