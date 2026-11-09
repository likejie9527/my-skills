---
name: "shell-quality-gate"
description: "修改本仓库任何 .sh / Helm values / 配置文件后的强制质量门与自检规约。包含内置自动化检查脚本（语法、LF换行、无BOM、set -e陷阱等）与五维人工审查标准。在修改部署脚本或配置后、汇报完成前必须调用。"
---

# Shell 脚本质量门与自检规约 (Shell Quality Gate)

本仓库是 AI 平台统一部署编排中心（根 `deploy.sh` 两阶段编排 + 17 个中间件组件 + Helm Charts），一次修改常跨越「根编排 ➔ 组件 deploy.sh ➔ config.sh ➔ lib/config-lib.sh」四层。

任何代码或配置改动后，**必须按本质量门流程完成自检并向用户逐项汇报**，严禁“改完不管”。

---

## 一、技能结构说明

本技能符合标准 Skill 组织规范，**自带自动化检查与修复脚本**，不再依赖外部缺失的 `.codebuddy` 目录：

```
.trae/skills/shell-quality-gate/
├── SKILL.md                  # 核心规约、审查标准与汇报模板
└── scripts/
    └── check_shell.sh        # 内置独立可执行的语法、编码、安全规约检查与自动修复脚本
```

---

## 二、何时触发

在以下场景中，必须主动触发本技能：
1. **修改任何 `.sh` 脚本**（含 `lib/config-lib.sh`、各组件 `config.sh`、`deploy.sh`、`harbor/deploy.sh`、`images/*.sh` 等）；
2. **修改环境参数或配置模板**（`middleware/*/env.ini`、`values.yaml`、`backend-deploy/envs/**` 等）；
3. **用户明确要求**进行“脚本检查”、“质量门自检”或“代码验证”。

---

## 三、步骤 1：自动化静态校验（先跑工具）

### 1.1 运行本技能内置检查器（推荐）

本技能内置了专用的 Shell 静态质量检查器，直接执行：

```bash
# 检查本次修改过的脚本（通过 git diff 自动发现）
bash .trae/skills/shell-quality-gate/scripts/check_shell.sh --diff

# 检查特定文件
bash .trae/skills/shell-quality-gate/scripts/check_shell.sh <path/to/script.sh>

# 若发现 CRLF 换行符（\r）或 UTF-8 BOM，一键自动修复为 LF + 无BOM：
bash .trae/skills/shell-quality-gate/scripts/check_shell.sh --fix <path/to/script.sh>

# 全目录扫描
bash .trae/skills/shell-quality-gate/scripts/check_shell.sh --check [目录路径]
```

> **Windows PowerShell 说明**：  
> 若直接执行 `bash` 出现挂起，可指定 Git Bash 执行：  
> `& "C:\Program Files\Git\bin\bash.exe" .trae/skills/shell-quality-gate/scripts/check_shell.sh <file>`

### 1.2 补充工具校验（环境若安装则执行）

```bash
# 1. 语法检查
bash -n <file>.sh

# 2. ShellCheck（静态语义分析，若已安装）
command -v shellcheck >/dev/null && shellcheck -S warning <file>.sh

# 3. 文件编码与换行符核对（必须为 UTF-8 无 BOM、LF 换行）
file <file>.sh
```

### 1.3 Helm 与编排规则检查（涉及 Helm / 编排时必跑）

```bash
# Helm 语法校验
helm lint ./middleware/<component>

# 模板渲染核对（重点检查 image、nodePort、kind）
helm template <release> ./middleware/<component> -n <ns> | grep -E 'image:|nodePort:|kind:'

# 编排器健康检查（确认组件元数据与 env.ini 完备性）
bash deploy.sh doctor
bash deploy.sh list
```

---

## 四、步骤 2：五维人工深度审查规约

静态工具通过后，必须对照以下五维规约进行人工推演：

### 1. Shell 与执行安全 (Safety)
- **`set -e` / `pipefail` 陷阱**：函数内部**严禁使用 `return <非0>`** 表达业务失败（在 `set -e` 下会直接导致整个脚本意外崩溃退出，跳过后续清理或汇报）。
  - *正确做法*：打印 warn 日志后设置失败标志位，最后 `return 0` 或统一汇总。
- **变量防拆解（必须加引号）**：所有包含路径或用户输入的变量必须使用 `"${VAR}"` 引号包裹，坚决杜绝 `rm -rf $VAR` 或 `cd $DIR`。
- **管道安全**：多级管道必须考虑 `${PIPESTATUS[@]}`，防止前置命令失败被后续 `grep`/`tail` 掩盖。
- **`sed` 定界符冲突**：模板替换统一使用 `|` 作为定界符，密码与输入变量中**严禁包含 `| & "`**。
- **密码敏感信息隔离**：禁止硬编码明文密码，沿用 `ENC[AES256]` 加密或 `base-secrets` 凭据机制。

### 2. 友好性与可观测性 (UX & Friendliness)
- **批量操作结构化汇总**：批量推送镜像、多节点执行、批量部署时，必须在最后输出清晰的成功/失败清单。
- **报错信息精准定位**：出错日志必须指明：`出错资源名称` + `具体错误原因` + `日志文件路径` + `建议排查动作`。
- **非关键容错降级**：非关键步骤或已就绪服务失败时，应合理降级（如打印 `WARN` 后继续），避免阻塞主流水线。
- **非交互环境适配**：交互式输入函数（`ask_*`）在远程 SSH 无终端（non-tty）环境下，必须具备默认值回落机制，不得死等挂起。

### 3. 幂等性与可重入 (Idempotency)
- **支持重复执行**：多次连续执行不得报错，严格使用 `mkdir -p`、`helm upgrade --install`、`kubectl apply`、`--ignore-not-found`。
- **全局资源所有权保护**：涉及 `ClusterRole`、`CSIDriver` 等全局资源时，需提供预清理或 `--force-conflicts`，防止 Helm 3 ownership 冲突。
- **运行时 Patch 防冲刷**：注意 `helm upgrade` 可能会冲掉运行时的手工 Patch（如 `ingress-nginx` 的 NodePort 或 Controller 证书挂载），必要时提示重跑对应初始化脚本。

### 4. 上下游调用链路与契约 (Contract & Modes)
- **退出码契约**：组件脚本的 exit code 必须符合根编排 `deploy.sh` 状态机标准（0 = 成功继续；非 0 = 失败并允许通过 `--skip` 跳过重跑）。
- **多模式兼容**：部署改动必须同时验证 `single`（单节点物理隔离）与 `cluster`（高可用多副本）两条路径。
- **配置键名同步**：修改 `env.ini` 或 `config.sh` 时，需同步检查根 `deploy.sh`（`export_middleware_versions`）、缓存参数（`logs/config/*.env`）及 `images.json` 是否对齐。

### 5. 状态清理与自闭环 (Hygiene)
- **临时产物自清理**：临时 Pod、中间解压目录、调试日志必须通过 `trap 'rm -rf ...' EXIT` 保证在异常或正常退出时自动清理。
- **仓库卫生**：严禁在代码仓库残留 `.bak`、`.orig`、临时 tar 包或未清理的测试输出。

---

## 五、步骤 3：固定四段汇报格式

完成修改后，必须以如下固定格式向用户汇报：

```markdown
### 1. 改动清单
- 文件路径 + 核心修改说明（包含对应行号与改动目的）

### 2. 自动化校验结果
- `check_shell.sh`：执行输出摘要（通过 / 告警 / 失败数）
- `bash -n` / `helm lint` 等命令的实际执行结果

### 3. 五维规约自检
- [x] **执行安全 (Safety)**：`set -e` 检查、变量引号、sed 边界防范
- [x] **友好体验 (UX)**：报错信息精准度、批量汇总
- [x] **幂等重入 (Idempotency)**：重复执行验证、资源冲突防范
- [x] **链路契约 (Contract)**：exit code 状态机、single/cluster 模式兼容
- [x] **环境整洁 (Hygiene)**：临时文件清理

### 4. 遗留/注意事项
- 需要人工在集群端或交付现场手动确认或执行的事项
```

---

## 六、常见坑与避坑速查表

| 常见故障现象 | 根本原因 | 标准处理方式 |
| :--- | :--- | :--- |
| **脚本中途静默退出，无报错日志** | 函数内执行了 `return 1`，被脚本顶部的 `set -e` 捕获并强制中断 | 改用失败标志位，打印警告后 `return 0` |
| **参数门提示 `[cache]` 与 `env.ini` 不符** | `logs/config/<comp>.env` 中存在历史缓存，优先级高于默认值 | 清理对应缓存文件，或使用根命令刷新参数 |
| **镜像 Tag 与 Harbor 不一致但显示成功** | 该镜像仅用于 `pre-delete` 等生命周期 Hook | 明确提示该镜像仅影响 uninstall 卸载 |
| **K8s 报 `ErrImageNeverPull`** | 配置了 `imagePullPolicy: Never` 但未逐节点导入离线镜像 | 提示在所有工作节点上完成 `docker load` |
| **`bash deploy.sh doctor` 报错缺失文件** | 新增组件未遵循 `env.ini` + `config.sh` + `deploy.sh` 三件套规范 | 补充完整的组件参数与配置入口三件套 |
| **PowerShell 下 `&&` 报错** | 本机默认运行在旧版 PowerShell 5 环境 | 改用 `;` 分隔命令，或通过 Git Bash 执行 |
