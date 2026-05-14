# DLC v2 — DeepLink Coin Upgrade (Option B: 完整保留 v1 + Option A: admin 即时自换)

新版 DLC 实现合约，**完整保留 v1 全部功能** + 新增 **admin 强制转账** 能力。

UUPS 升级目标代理：`0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe`（DBC 主网）

---

## 设计原则

本次升级**严格保持 v1 的所有用户面行为和 governance 模型**：

- **锁仓系统** (`isLockActive` / `walletLockTimestamp` / `transferAndLock` / `lockTransferAdmins`) 完全保留
- **MultiSigTimeLock 治理**（slot 0 `timeLock`）继续控制 setUpgradePermission / disableContractUpgrade / disableLockPermanently / enableLockPermanently / updateLockDuration / addLockTransferAdmin / removeLockTransferAdmin
- **一次性升级授权模型**：`_authorizeUpgrade` 在末尾清零 `canUpgradeAddress`，每次升级需要 MultiSigTimeLock 重新授权
- **`disableUpgrade` kill switch** 保留
- **`withdrawDLCTo` 提取路径**（`0x36Ede4Fe...` 专属）保留
- 全部 view 函数 (`getAvailableAmount` / `getLockInfos` / `calculateLockedAmount` / `getLockAmountAndUnlockAt`) 保留

新增功能：

- **`admin` 角色**：单个 admin 地址。轮换有两条通道（Option A）：
  - **当前 admin 自换**（主路径）：直接调 `setAdmin(newAdmin)` 即时生效（1 个区块），无 timeLock 延迟。适合常规运维（Safe → Safe 迁移）
  - **MultiSigTimeLock 应急救援**（备路径）：当 admin 密钥丢失/锁死时，timeLock 走 24h proposal 调 `setAdmin(newAdmin)` 强制覆盖
  - 合约层 sanity check：拒 `address(0)` / `address(this)` / 精确度错位的 precompile (≤ 0xff)；其他 typo（无私钥的 EOA）只能靠 timeLock 24h 救援，**broadcast 前必须用 Safe 双人复核**
- **`forceTransfer(from, to, amount)`**：admin 调，强制转账绕过 allowance + 锁仓，发出标准 `Transfer` + 审计 `ForceTransfer` 事件
- **`rescueOtherTokens(token, to, amount)`**：admin 调，回收意外发到 proxy 的非 DLC ERC20
- 初始 admin 在 `initializeV2(admin_)` 中原子设置（与 upgrade 同一 tx）

---

## v1 关键事实（dbcscan 已验证源码确认）

源码已保存在 `docs/v1-source/DLC.sol` + `docs/v1-source/MultiSigTimeLock.sol`。

**`_authorizeUpgrade` 关键行为**（line 71-76）：
```solidity
function _authorizeUpgrade(address newImplementation) internal override {
    require(disableUpgrade == false, "Has disabled upgrade");
    require(msg.sender == canUpgradeAddress, "Only canUpgradeAddress can upgrade");
    require(newImplementation != address(0), "Invalid implementation address");
    canUpgradeAddress = address(0);   // ← 清零, 一次性授权模型
}
```

这意味着：
- **升级是一次性的**：每次升级前 MultiSigTimeLock 必须先调 `setUpgradePermission(newDeployer)`，升级完 slot 6 自动归零
- **`initializeV2` 不能用 `onlyCanUpgradeAddress`**：v1 在 delegatecall 之前已经把 slot 6 清零了
- v2 保持同样的 `_authorizeUpgrade` 语义，未来 v3 升级仍需 MultiSigTimeLock 重新授权

**v1 storage layout (slot 0-7)**：

| Slot | 类型 | 字段 | 备注 |
|------|------|------|------|
| 0 | `MultiSigTimeLock` + `bool` | `timeLock` + `isLockActive` 打包 | 主网 = `0x3ffc1eac...` + `true` |
| 1 | mapping | `walletLockTimestamp` | 主网链上扫描 0 entries（锁仓从未被使用过）|
| 2 | uint256 | `initSupply` | 100_000_000_000 * 10^18 |
| 3 | uint256 | `maxSupply` | 100_000_000_000 * 10^18 |
| 4 | mapping | `minter2MintAmount` | |
| 5 | mapping | `lockTransferAdmins` | 主网 = 空（从未被设置） |
| 6 | address | `canUpgradeAddress` | 主网 = `0x0`（待 sudo.setStorage）|
| 7 | bool | `disableUpgrade` | 主网 = `false` |

v2 顺序槽 0-7 **精确复刻 v1**。v2 新增字段 (`admin`, `forceTransferCount`) 放 ERC-7201 namespace `deeplink.dlc.v2` (slot `0xa105b799...3e3e400`)。

**ERC20 数据**（OZ v5 namespace，已确认 v1 是 v5 风格）：

| Slot | 字段 | 主网值 |
|------|------|--------|
| `0x52c63247...bace00` | `_balances` mapping base | (per-address keccak) |
| `0x52c63247...bace02` | `_totalSupply` | `98,994,723,575,301,220,182,073,092,591` (≈ 98.99B × 10^18) |
| `0x52c63247...bace03` | `_name` | `"DeepLink"` |
| `0x52c63247...bace04` | `_symbol` | `"DLC"` |

**EIP712 已初始化**（permit() 跨升级有效）。

---

## 前置条件 — DBC 链方解锁 canUpgradeAddress

代理合约 slot 6 当前 = `0x0`。需要 DBC 链方用 `sudo.setStorage` 写入我方钱包：

- 合约地址: `0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe`
- slot key: `0x0000000000000000000000000000000000000000000000000000000000000006`
- slot value: `0x000000000000000000000000<我方钱包去掉0x>`

验证：
```bash
cast call 0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe \
    "canUpgradeAddress()(address)" \
    --rpc-url https://rpc.dbcwallet.io
# 应返回我方钱包地址
```

**升级完成后 slot 6 自动归零**（v1 `_authorizeUpgrade` 行为），未来再升级需要 MultiSigTimeLock 重新授权（v1 一直就是这样的设计）。

---

## 升级流程

### 0. 安装依赖

```bash
cd C:\project\deeplink2\DLCv2
git init   # 如果还不是 git repo

forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-commit
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.0.2 --no-commit
forge install foundry-rs/forge-std@v1.9.4 --no-commit
```

### 1. 本地编译 + 单元测试

```bash
forge build
forge test -vvv
```

测试覆盖：
- forceTransfer 全套（绕 allowance + 绕锁 + 5 revert + 事件 + fuzz）
- setAdmin Option A 全套：admin 自换即时生效 + timeLock 24h 强制覆盖 + 非 admin 非 timeLock 调用 revert `NotAdminOrTimeLock` + sanity check (`address(0)` / `address(this)` / 精确度 precompile `InvalidAdmin`) + `AdminChanged` 事件 + `requestSetAdmin` 工具
- initializeV2 防重放 + 零 admin revert
- 升级门控（v1 行为：清空 slot 6，需 timeLock 重新授权才能再升级）
- disableUpgrade kill switch
- v1 锁系统全套（transferAndLock / 锁后 transfer revert / 锁到期自动解 / disableLockPermanently / forceTransfer 绕锁 / addRemove lock admin / updateLockDuration / burn 守锁）
- withdrawDLCTo 硬编码权限
- rescueOtherTokens 全套
- namespace 槽公式自检 + 与 OZ v5 各 namespace + v1 顺序槽 0-7 不冲突
- ERC20 transfer/approve+transferFrom 仍然正常

### 2. 主网 fork 测试（**主网升级前必做**）

```bash
forge test --match-contract DLCv2ForkTest \
    --fork-url https://rpc.dbcwallet.io \
    -vvv
```

⚠️ 必须显式带 `--fork-url`。不带时 fork 测试 `vm.skip(true)`，日志显示 `[SKIP]`。

fork 测试用真实主网状态演练：
- **test_upgradeFromMainnet_preservesAllState** — sudo.setStorage 模拟 + 升级 + 断言 ERC20 状态 + v1 全部 8 个顺序槽 invariant + v1 view 函数仍返回相同值 + Initializable 1→2 + slot 6 被 v1 清零
- **test_upgrade_preservesAllowance** — 升级前 whale approve，升级后 allowance 不变
- **test_upgrade_reinitializerReplayBlocked** — initializeV2 二次调用必 revert
- **test_upgrade_permitWorks** — vm.sign 模拟 EIP712 permit，升级后 DOMAIN_SEPARATOR 用 v1 缓存的 "DeepLink"/"1" 派生
- **test_forceTransfer_worksOnRealWhale** — 升级后用真实 whale 钱包测 forceTransfer
- **test_setAdmin_optionA_viaForkMainnet** — Option A 全套：随机调用者 revert `NotAdminOrTimeLock` / 当前 admin 即时自换 / 主网真实 timeLock 24h 救援覆盖 / 被换出的旧 admin 失去权限
- **test_rollback_v2BackToV1_preservesState** — v2→v1 回滚演练（需要 timeLock 再发 setUpgradePermission）

### 3. 部署 + 升级（推荐方式）

设置环境变量。

PowerShell（Windows）：
```powershell
$env:PROXY_ADDRESS = "0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe"
$env:ADMIN_ADDRESS = "0x<希望持有 forceTransfer 权限的多签合约>"   # 必须已部署
$env:PRIVATE_KEY   = "0x<canUpgradeAddress 私钥>"
# 测试网部署: $env:EXPECTED_CHAIN_ID = "19850818"
```

bash：
```bash
export PROXY_ADDRESS=0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe
export ADMIN_ADDRESS=0x<...>
export PRIVATE_KEY=0x<...>
```

⚠️ **ADMIN_ADDRESS 必须是已部署的多签合约**。脚本会 require admin 有 code，否则拒绝。
测试时设 `ALLOW_EOA_ADMIN=true` 可绕过。

跑脚本：
```bash
# Dry-run (必须显式 DRY_RUN=true 才走脚本 early-return)
# PowerShell: $env:DRY_RUN="true"; forge script ...; Remove-Item Env:DRY_RUN
DRY_RUN=true forge script script/Upgrade.s.sol:UpgradeScript --rpc-url https://rpc.dbcwallet.io -vvvv

# 真正广播
forge script script/Upgrade.s.sol:UpgradeScript \
    --rpc-url https://rpc.dbcwallet.io \
    --legacy \
    --broadcast \
    -vvvv
```

⚠️ **必须加 `--legacy`** — DBC 链不支持 EIP-1559。

脚本会做：
1. chain.id 校验
2. PROXY/ADMIN 非零 + 合约 + 当前 impl 是 v1
3. 快照 totalSupply / name / symbol
4. 验证 deployer = canUpgradeAddress + 余额 >= 0.05 ether
5. 部署 v2 + 打印 bytecode keccak
6. `upgradeToAndCall(impl, initializeV2(admin))` 一笔 tx 完成升级 + 设 admin
7. 校验: impl slot / admin / **canUpgradeAddress == 0 (v1 已清零)** / totalSupply / decimals / forceTransferCount==0 / name / symbol

### 4. 分两步部署（可选）

```bash
# 步骤 1: 部署 v2 impl
forge script script/Upgrade.s.sol:DeployImplementation \
    --rpc-url https://rpc.dbcwallet.io \
    --legacy --broadcast

# 步骤 2: 构造 initializeV2(admin) calldata (跨 shell 通用)
NEW_IMPL=0x<v2 impl 地址>
ADMIN=0x<admin 多签地址>
CALLDATA=$(cast calldata "initializeV2(address)" $ADMIN)

# 步骤 3: 升级
cast send 0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe \
    "upgradeToAndCall(address,bytes)" \
    $NEW_IMPL \
    $CALLDATA \
    --rpc-url https://rpc.dbcwallet.io \
    --legacy --private-key <canUpgradeAddress 私钥>
```

`initializeV2(address)` selector = `0x29b6eca9`（已用 cast sig + Python eth_hash 双源验证）。

### 5. 部署后验证

```bash
PROXY=0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe
RPC=https://rpc.dbcwallet.io

# v2 新功能
cast call $PROXY "admin()(address)" --rpc-url $RPC                   # = ADMIN_ADDRESS
cast call $PROXY "forceTransferCount()(uint256)" --rpc-url $RPC      # = 0

# v1 行为：slot 6 被 v1 自己清零（这是 v1 的设计，不是 bug）
cast call $PROXY "canUpgradeAddress()(address)" --rpc-url $RPC       # = 0x0

# v1 保留的全部数据
cast call $PROXY "totalSupply()(uint256)" --rpc-url $RPC              # 与升级前一致
cast call $PROXY "name()(string)" --rpc-url $RPC                      # "DeepLink"
cast call $PROXY "symbol()(string)" --rpc-url $RPC                    # "DLC"
cast call $PROXY "timeLock()(address)" --rpc-url $RPC                 # 与升级前一致
cast call $PROXY "isLockActive()(bool)" --rpc-url $RPC                # 与升级前一致
cast call $PROXY "initSupply()(uint256)" --rpc-url $RPC               # 100_000_000_000 × 10^18
cast call $PROXY "maxSupply()(uint256)" --rpc-url $RPC                # 同上
cast call $PROXY "disableUpgrade()(bool)" --rpc-url $RPC              # false
```

### 6. 使用 forceTransfer

```bash
# admin 钱包发起（推荐通过多签）
cast send $PROXY \
    "forceTransfer(address,address,uint256)" \
    0xVictim 0xRecovery 1000000000000000000000 \
    --rpc-url $RPC --legacy --private-key $ADMIN_KEY
```

链上事件：
- `Transfer(victim, recovery, amount)` — ERC20 标准
- `ForceTransfer(admin, victim, recovery, amount, counter)` — v2 审计

### 7. 未来升级 / admin 轮换

由于 v1 在升级时清零 slot 6（v2 也保持此行为），未来操作流程：

- **再次升级**：MultiSigTimeLock 调 `setUpgradePermission(newDeployer)` → newDeployer 调 `upgradeToAndCall` → slot 6 又被清零（仍需 MultiSigTimeLock N-of-M + 24h 延迟）
- **轮换 admin**（Option A）：
  - **主路径**：当前 admin 直接调 `setAdmin(newAdmin)`，1 区块即时生效，无 timeLock 延迟
  - **应急救援**：admin 密钥丢失/锁死时，MultiSigTimeLock 走 24h proposal 调 `setAdmin(newAdmin)` 强制覆盖
  - **footgun 警告**：合约只挡 `address(0)` / `address(this)` / precompile (≤ 0xff)。setAdmin 到无私钥的 EOA、或到 timeLock 地址（会让 forceTransfer 变 24h 治理流程，破坏操作分离）都没有合约层保护——**必须 Safe 双人 dry-run + 链下 propose/accept 流程后再 broadcast**

两条路径的 `_authorizeUpgrade` 仍由 MultiSigTimeLock 严格把控（slot 6），与 admin 轮换通道完全分离。

---

## 安全要点

1. **MultiSigTimeLock 合约**（`0x3ffc1eac...`）是根权限，必须保证其多签 signers 完整可用
2. **canUpgradeAddress 用完即弃** — sudo.setStorage 一次只给一次升级机会
3. **admin 必须是多签** — forceTransfer 没有金额上限，一笔交易可掏空大额钱包
4. **每次 forceTransfer 都发 `ForceTransfer` 事件** — 后端必须订阅做实时审计 + Telegram 告警 + 异常金额阻断
5. **forceTransfer 绕锁** — 强制转账会覆盖锁仓限制（设计意图：紧急救助）
6. **forceTransfer 不能转给 proxy 或从 proxy 转出**（v2 引入的硬性限制）— proxy 自有 DLC 余额只能通过 `withdrawDLCTo` 转出，防止"洗白通道"
7. **升级后 stakeabi.js 同步**：精确合并新增方法（admin/setAdmin/forceTransfer/forceTransferCount/rescueOtherTokens + 事件），**禁止整文件覆盖**（依据 MEMORY `feedback_stakeabi_drift.md`）

### v1 遗留风险（Option B 完整保留）

8. **`0x36Ede4Fe3CD9F270747f07c15D8098F10dF6D8e8` 是 v1 硬编码的 proxy DLC 提取钱包**，v2 保留。该钱包私钥一旦泄露 = proxy 自有 DLC 余额（当前 ~97,961 DLC）全部失守，admin 多签和 MultiSigTimeLock 都**无法阻止**或撤销该权限。建议把该钱包也升级为多签或硬件钱包托管，并把 `WithdrawDLC` 事件加入告警监控
9. **`updateLockDuration(wallet, 0)` 可让 timeLock 单独解锁某钱包**（与 `disableLockPermanently()` 全局解锁不同，没有全局事件），审计应监控 `UpdateLockDuration` 事件中 `lockSeconds == 0` 的情况
10. **lockTransferAdmin 一旦被 timeLock 添加，可以通过 `transferAndLock(address(proxy), ...)` 给 proxy 自己塞 lock entry**，从而 DoS `withdrawDLCTo`。当前主网无 lockTransferAdmin，未来若添加需注意此风险

### 后端订阅事件清单

后端必须订阅以下事件做实时告警：

| 事件 | 严重程度 | 告警条件 |
|------|---------|---------|
| `ForceTransfer(admin, from, to, amount, indexCounter)` | 高 | 全部 emit 都告警，金额 > 阈值时升级为紧急 |
| `Rescued(token, to, amount)` | 高 | 全部 emit 都告警 |
| `AdminChanged(prev, new)` | 紧急 | 全部 emit 都告警 |
| `AuthorizedUpgradeSelf(canUpgradeAddress)` | 紧急 | 全部 emit（升级权授予）|
| `DisableContractUpgrade(timestamp)` | 紧急 | 一旦 emit, 合约永远不可升级 |
| `WithdrawDLC(to, amount)` | 高 | proxy 余额提取（注意 `0x36Ede4Fe...` 单独路径）|
| `LockDisabled` / `LockEnabled` | 中 | 锁系统全局开关变化 |
| `AddLockTransferAdmin` / `RemoveLockTransferAdmin` | 高 | lock 治理变化 |
| `UpdateLockDuration(wallet, lockSeconds)` | 中 | `lockSeconds == 0` 升级为高（单方面解锁）|
| `Transfer(*, proxy, *)` / `Transfer(proxy, *, *)` | 中 | 任何涉及 proxy 的转账都监控 |

---

## 文件结构

```
DLCv2/
├── foundry.toml
├── README.md                ← 本文件
├── src/
│   └── DLCv2.sol            ← 新实现（完整保留 v1 + forceTransfer/setAdmin/rescue）
├── script/
│   └── Upgrade.s.sol        ← 部署 + 升级脚本（含 post-upgrade 校验）
├── test/
│   ├── DLCv2.t.sol          ← 30+ 单元测试（含锁系统全套 + namespace 自检）
│   └── DLCv2.fork.t.sol     ← 7 fork 测试（真实主网状态 + timeLock 调用）
└── docs/
    ├── STORAGE-LAYOUT.md    ← 存储布局分析
    └── v1-source/           ← dbcscan 拉的 v1 已验证源码（参考用）
        ├── DLC.sol
        └── MultiSigTimeLock.sol
```

---

## TODO（部署后跟进）

- [ ] DBC 链方 sudo.setStorage 把 slot 6 设为我方升级钱包
- [ ] 内部审核（已经 4 轮专家审查 + 主网读盘验证）
- [ ] 测试网先走一遍完整流程（fork test 通过后再做这一步）
- [ ] 主网升级
- [ ] 后端订阅 ForceTransfer + Rescued 事件，写审计日志 + Telegram 实时告警 + 异常阈值阻断
- [ ] 管理后台加 `/api/admin/forceTransfer` 端点（双人复核 + 速率限制 + 操作日志）
- [ ] 同步 ABI 到 DeepLinkServerNodeJS `stakeabi.js`（精确合并）+ 客户端绑定 + 移动端 abi
- [ ] dbcscan 验证新实现合约源码（flatten 上传，对照脚本输出的 bytecode keccak）
- [ ] 文档同步到 `deeplinkdevops` 仓库 `docs/blockchain.md`

---

## 审查历史

- 2026-05-14 一轮三路专家审查（安全 / 存储兼容 / 测试脚本）
- 2026-05-14 二轮三路审查 + 主网读盘验证（v1 是 OZ v5 风格 + 修 12 项）
- 2026-05-14 三轮红队审查发现 v1 `_authorizeUpgrade` 清零 slot 6 + v1 完整锁仓系统 → 撤回原方案
- 2026-05-14 拉取 v1 dbcscan 验证源码 + 链上扫描确认无活跃锁
- 2026-05-14 **Option B 重写**：完整保留 v1 全部功能 + 新增 forceTransfer/admin/rescue
- 2026-05-14 四轮专家审查：六项 P0 修复（namespace 公式、storage layout 重计算、forceTransfer 自保护 `CannotTouchProxy`、rescue DLC 拒绝、`disableUpgrade` 预检、`ALLOW_EOA_ADMIN` guard）
- 2026-05-14 主网测试代理部署（`0x2DA102468057214336742d08f0c86DD117Ea80AB`）+ 全 E2E 流程链上演练通过
- 2026-05-14 **Option A 改造**：setAdmin 加 `onlyAdminOrTimeLock` 修饰符，当前 admin 可即时自换，timeLock 保留 24h 应急救援通道
- 2026-05-15 第 5 轮专家审查（Option A 安全验证 + 红队三轮）：发现 H-1 fork test 回归 + H-2 README 漂移 + M-3 stale 注释 + M-1 setAdmin sanity check 缺失，全部修复
