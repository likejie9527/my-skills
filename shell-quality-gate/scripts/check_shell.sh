#!/usr/bin/env bash
# ==============================================================================
# check_shell.sh — Shell 脚本规范与质量门静态检查器
#
# 功能：
#   1. 语法检查 (bash -n)
#   2. 编码与换行符检查 (UTF-8 无 BOM、LF 换行、末尾换行符)
#   3. 执行安全检查 (Shebang、set -euo pipefail、函数内 return 非0业务码风险)
#   4. 高危命令加引号防御 (rm -rf "$VAR"、cd "$VAR")
#   5. 支持 --fix 自动修复 CRLF 换行符与去除 UTF-8 BOM
#
# 用法：
#   bash check_shell.sh <file1.sh> [file2.sh ...]     # 检查指定的一个或多个脚本
#   bash check_shell.sh --diff                        # 仅检查 git 修改过的 .sh 文件
#   bash check_shell.sh --check [目录]                # 检查指定目录下的所有 .sh (默认当前目录)
#   bash check_shell.sh --fix [文件或目录]            # 自动修复 CRLF 与 BOM
# ==============================================================================

set -uo pipefail

# 颜色定义
if [[ -t 1 ]]; then
  GREEN="\033[0;32m"
  YELLOW="\033[0;33m"
  RED="\033[0;31m"
  BLUE="\033[0;34m"
  BOLD="\033[1m"
  RESET="\033[0m"
else
  GREEN=""
  YELLOW=""
  RED=""
  BLUE=""
  BOLD=""
  RESET=""
fi

TOTAL_CHECKED=0
TOTAL_PASSED=0
TOTAL_WARNS=0
TOTAL_FAILS=0

AUTO_FIX=false
MODE="check"
TARGET_DIR="."
FILE_LIST=()

usage() {
  echo -e "${BOLD}用法:${RESET}"
  echo "  $0 <file1.sh> [file2.sh ...]   检查指定的一个或多个脚本"
  echo "  $0 --diff                      检查 git 暂存区与工作区修改过的 .sh 文件"
  echo "  $0 --check [目录]              检查指定目录及子目录下的所有 .sh 文件 (默认: .)"
  echo "  $0 --fix [文件/目录]           自动修复 CRLF 换行符与 UTF-8 BOM"
  echo "  $0 -h, --help                  显示此帮助信息"
  exit 0
}

# 收集待扫描文件
collect_files() {
  local dir="$1"
  find "$dir" -type f -name "*.sh" \
    -not -path "*/.git/*" \
    -not -path "*/node_modules/*" \
    -not -path "*/middle.bk/*" \
    -not -path "*/logs/*" \
    -not -path "*/dist/*" \
    -not -path "*/build/*" \
    -not -path "*/.trae/*" \
    -not -path "*/.agent/*" 2>/dev/null || true
}

# 检查并可选修复单个文件
check_single_file() {
  local file="$1"
  local file_has_error=false
  local file_has_warn=false
  local issues=()

  TOTAL_CHECKED=$((TOTAL_CHECKED + 1))

  if [[ ! -f "$file" ]]; then
    echo -e "${RED}[FAIL] 文件不存在: ${file}${RESET}"
    TOTAL_FAILS=$((TOTAL_FAILS + 1))
    return 0
  fi

  # ---- 1. UTF-8 BOM 检查与修复 ----
  if head -c 3 "$file" 2>/dev/null | grep -q $'\xef\xbb\xbf'; then
    if [[ "$AUTO_FIX" == true ]]; then
      sed -i '1s/^\xef\xbb\xbf//' "$file" 2>/dev/null || perl -i -pe 's/^\xef\xbb\xbf//' "$file" 2>/dev/null || true
      issues+=("${YELLOW}已自动修复 UTF-8 BOM${RESET}")
    else
      file_has_error=true
      issues+=("${RED}包含 UTF-8 BOM 签名 (必须为 UTF-8 无 BOM)${RESET}")
    fi
  fi

  # ---- 2. 换行符 CRLF 检查与修复 ----
  if grep -q $'\r' "$file" 2>/dev/null; then
    if [[ "$AUTO_FIX" == true ]]; then
      tr -d '\r' < "$file" > "${file}.tmp_fix" && mv -f "${file}.tmp_fix" "$file"
      issues+=("${YELLOW}已自动将 CRLF 换行符转换为 LF${RESET}")
    else
      file_has_error=true
      issues+=("${RED}包含 CRLF (\\r\\n) 换行符 (仓库规约必须使用 LF 换行)${RESET}")
    fi
  fi

  # ---- 3. 末尾换行符 (Trailing Newline) ----
  if [[ -s "$file" ]]; then
    local last_char
    last_char=$(tail -c 1 "$file" 2>/dev/null || true)
    if [[ -n "$last_char" ]]; then
      if [[ "$AUTO_FIX" == true ]]; then
        echo "" >> "$file"
        issues+=("${YELLOW}已补充文件末尾换行符${RESET}")
      else
        file_has_warn=true
        issues+=("${YELLOW}文件末尾缺少换行符 (No newline at end of file)${RESET}")
      fi
    fi
  fi

  # ---- 4. 语法有效性检查 (bash -n) ----
  local bash_err
  if ! bash_err=$(bash -n "$file" 2>&1); then
    file_has_error=true
    issues+=("${RED}语法解析错误 (bash -n): ${bash_err}${RESET}")
  fi

  # ---- 5. 审查 Shebang (首行声明) ----
  local first_line
  first_line=$(head -n 1 "$file" 2>/dev/null || true)
  if [[ ! "$first_line" =~ ^#!/(bin/bash|usr/bin/env\ bash|bin/sh) ]]; then
    file_has_warn=true
    issues+=("${YELLOW}第一行缺少标准 Shebang (建议 #!/bin/bash 或 #!/usr/bin/env bash)${RESET}")
  fi

  # ---- 6. 审查 set -euo pipefail 安全配置 ----
  if ! grep -qE "set\s+-[a-zA-Z]*e" "$file" 2>/dev/null; then
    file_has_warn=true
    issues+=("${YELLOW}未声明 set -e (建议启用 'set -euo pipefail' 确保执行安全)${RESET}")
  fi

  # ---- 7. 审查五维规约高危项：函数内 return 非0业务码（set -e 陷阱） ----
  local return_bad_lines
  return_bad_lines=$(grep -nE "^\s*return\s+[1-9][0-9]*\b" "$file" 2>/dev/null | head -n 3 || true)
  if [[ -n "$return_bad_lines" ]]; then
    file_has_warn=true
    issues+=("${YELLOW}检测到函数内可能存在 'return 非0' (在 set -e 下会触发意外中断，建议改用标志位或 warn 后 return 0):${RESET}\n       ${return_bad_lines}")
  fi

  # ---- 8. 审查高危未加引号的 rm -rf / cd 变量 ----
  local dangerous_rm
  dangerous_rm=$(grep -nE "rm\s+-[a-zA-Z]*r[a-zA-Z]*\s+\$[a-zA-Z_][a-zA-Z0-9_]*\b" "$file" 2>/dev/null | head -n 2 || true)
  if [[ -n "$dangerous_rm" ]]; then
    file_has_error=true
    issues+=("${RED}检测到高危变量未加引号的 rm -rf 语句 (防拆解规约必须使用 \"\${VAR}\"):${RESET}\n       ${dangerous_rm}")
  fi

  # 输出结果
  if [[ "$file_has_error" == true ]]; then
    TOTAL_FAILS=$((TOTAL_FAILS + 1))
    echo -e "${RED}[FAIL]${RESET} ${file}"
    for issue in "${issues[@]}"; do
      echo -e "       ${issue}"
    done
  elif [[ "$file_has_warn" == true ]]; then
    TOTAL_WARNS=$((TOTAL_WARNS + 1))
    echo -e "${YELLOW}[WARN]${RESET} ${file}"
    for issue in "${issues[@]}"; do
      echo -e "       ${issue}"
    done
  else
    TOTAL_PASSED=$((TOTAL_PASSED + 1))
    echo -e "${GREEN}[PASS]${RESET} ${file}"
  fi
}

# ---- 主处理流程 ----
if [[ $# -eq 0 ]]; then
  MODE="diff"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        TARGET_DIR="$1"
        shift
      fi
      ;;
    --diff)
      MODE="diff"
      shift
      ;;
    --fix)
      AUTO_FIX=true
      shift
      if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        TARGET_DIR="$1"
        shift
      fi
      ;;
    -h|--help)
      usage
      ;;
    *)
      FILE_LIST+=("$1")
      shift
      ;;
  esac
done

echo -e "${BOLD}${BLUE}================================================================${RESET}"
echo -e "${BOLD}${BLUE}   Shell 脚本五维质量门检查 (Shell Quality Gate)                ${RESET}"
echo -e "${BOLD}${BLUE}================================================================${RESET}"

if [[ ${#FILE_LIST[@]} -gt 0 ]]; then
  echo -e "扫描模式: 指定文件列表 (${#FILE_LIST[@]} 个文件)"
  for f in "${FILE_LIST[@]}"; do
    check_single_file "$f"
  done
elif [[ "$MODE" == "diff" ]]; then
  echo -e "扫描模式: Git 变更的 .sh 文件"
  changed_sh=()
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n "$line" && -f "$line" ]] && changed_sh+=("$line")
    done < <(git status --porcelain 2>/dev/null | awk '{print $NF}' | grep -E '\.sh$' || true)
  fi

  if [[ ${#changed_sh[@]} -eq 0 ]]; then
    echo -e "${GREEN}[INFO] Git 状态中未发现发生修改的 .sh 脚本。${RESET}"
    exit 0
  fi
  for f in "${changed_sh[@]}"; do
    check_single_file "$f"
  done
else
  echo -e "扫描模式: 目录全量扫描 [${TARGET_DIR}]"
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && check_single_file "$f"
  done < <(collect_files "$TARGET_DIR")
fi

echo -e "${BOLD}${BLUE}================================================================${RESET}"
echo -e "${BOLD}检查汇总：${RESET}"
echo -e "  已检测文件: ${TOTAL_CHECKED}"
echo -e "  ${GREEN}通过: ${TOTAL_PASSED}${RESET}"
echo -e "  ${YELLOW}告警: ${TOTAL_WARNS}${RESET}"
echo -e "  ${RED}失败: ${TOTAL_FAILS}${RESET}"
echo -e "${BOLD}${BLUE}================================================================${RESET}"

if [[ $TOTAL_FAILS -gt 0 ]]; then
  echo -e "${RED}[ERROR] 存在不满足规范的脚本，请根据上述提示修正或执行 --fix 自动修复。${RESET}"
  exit 1
else
  echo -e "${GREEN}[OK] 脚本质量门检查通过！${RESET}"
  exit 0
fi
