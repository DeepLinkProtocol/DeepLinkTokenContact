# DLC 存储布局推导和升级安全性

## 关键事实（2026-05-14 主网读盘已确认）

**v1 实现 `0xa72e3ebb05131fb6a1dfe6546c0a72c30f424477` 使用 OpenZeppelin Upgradeable v5 + ERC-7201 命名空间存储**。这是通过直接 `eth_getStorageAt` 读取主网代理并与公开 ERC20 view 函数结果交叉验证得出的结论，**不是推断**。

---

## 主网验证脚本（可重复执行）

依赖：`pip install 'eth-hash[pycryptodome]'`（urllib 是标准库）

```python
import json, urllib.request
from eth_hash.auto import keccak

PROXY = "0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe"
WHALE = "0xAF49734cF87d36AA4881F5B2f05A65F08063818b"
RPC   = "https://rpc.dbcwallet.io"

def rpc(m, p):
    r = json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode()
    req = urllib.request.Request(RPC, data=r, headers={"Content-Type":"application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())["result"]

# 验证 1: v5 ERC20 namespace 的 _balances[WHALE] 等于 balanceOf(WHALE)
ERC20_NS = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00
whale_int = int(WHALE, 16)
slot_int = int.from_bytes(
    keccak(whale_int.to_bytes(32,'big') + ERC20_NS.to_bytes(32,'big')),
    'big'
)
raw = rpc("eth_getStorageAt", [PROXY, hex(slot_int), "latest"])
storage_bal = int(raw, 16)

# selector("balanceOf(address)") = 0x70a08231
call_data = "0x70a08231" + WHALE[2:].lower().zfill(64)
public_bal = int(rpc("eth_call", [{"to": PROXY, "data": call_data}, "latest"]), 16)

assert storage_bal == public_bal, f"v5 namespace mismatch: {storage_bal} vs {public_bal}"
print(f"VERIFIED: v1 uses OZ v5 ERC20 namespace (balance match: {storage_bal})")
```

实测结果：
```
balanceOf(WHALE) public call: 1,093,611,597,677,108,368,207,159,099
storage[v5 ns _balances[WHALE]]: 1,093,611,597,677,108,368,207,159,099  ← MATCH
```

---

## v1 存储映射（dbcscan 已验证源码 + 主网读盘确认）

完整 v1 源码已保存在 `docs/v1-source/DLC.sol`。

| 位置 | 类型 | 字段 | 主网值 |
|------|------|------|--------|
| 顺序槽 0 | `MultiSigTimeLock` + `bool` packed | `timeLock` + `isLockActive` | `0x3ffc1eac6148529d0c672a1b69acb652a41b828a` + `true` |
| 顺序槽 1 | mapping | `walletLockTimestamp` (LockInfo[]) | base = 0, 当前无活跃锁 |
| 顺序槽 2 | uint256 | `initSupply` | `100,000,000,000 × 10^18` |
| 顺序槽 3 | uint256 | `maxSupply` | 同上 |
| 顺序槽 4 | mapping | `minter2MintAmount` | base = 0 |
| 顺序槽 5 | mapping | `lockTransferAdmins` | base = 0, 链上扫描未发现任何 admin |
| 顺序槽 6 | address | `canUpgradeAddress` | `0x0`（待 sudo.setStorage） |
| 顺序槽 7 | bool | `disableUpgrade` | `false` |
| `0x52c63247...bace00` | mapping base | `_balances` | OZ v5 ERC20 namespace |
| `0x52c63247...bace02` | uint256 | `_totalSupply` | `98,994,723,575,301,220,182,073,092,591` |
| `0x52c63247...bace03` | string | `_name` | `"DeepLink"` |
| `0x52c63247...bace04` | string | `_symbol` | `"DLC"` |
| `0xf0c57e16...c6a00` | uint64 | Initializable `_initialized` | `1` |
| `keccak(EIP712NS-1) & ~0xff` +2 | string | EIP712 `_name` | `"DeepLink"` |
| `keccak(EIP712NS-1) & ~0xff` +3 | string | EIP712 `_version` | `"1"` |

**关键 v1 行为**（来自 v1 源码 `_authorizeUpgrade`）:
- 升级前 `canUpgradeAddress` 必须 ≠ 0 + `msg.sender == canUpgradeAddress`
- 升级时 `disableUpgrade` 必须 = false
- **升级末尾把 `canUpgradeAddress = address(0)` 清零**（一次性授权）
- 未来再升级需要 MultiSigTimeLock 调 `setUpgradePermission(newDeployer)` 重新授权

---

## v2 升级安全保证（Option B：完整保留）

v2 (`src/DLCv2.sol`) 设计原则：**顺序槽 0-7 精确复刻 v1**，新增字段全部放 ERC-7201 namespace。

### 1. v1 顺序槽 → v2 显式声明同名同序

v2 在源码中按 v1 完全相同的顺序声明 8 个 sequential storage 变量：
```solidity
contract DLCv2 is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, ... {
    address public timeLock;             // slot 0
    bool public isLockActive;            // slot 0 packed
    mapping(address => LockInfo[]) private walletLockTimestamp;  // slot 1
    uint256 public initSupply;           // slot 2
    uint256 public maxSupply;            // slot 3
    mapping(address => uint256) public minter2MintAmount;  // slot 4
    mapping(address => bool) public lockTransferAdmins;    // slot 5
    address public canUpgradeAddress;    // slot 6
    bool public disableUpgrade;          // slot 7
}
```

因为 OZ v5 upgradeable 父合约（Initializable / ERC20Upgradeable / ERC20PermitUpgradeable / ERC20BurnableUpgradeable / ReentrancyGuardUpgradeable / UUPSUpgradeable）**全部使用 namespace 存储不占顺序槽**，v2 的 sequential 变量从 slot 0 开始排列，与 v1 完全对齐。

v1 的全部用户面行为（transfer/transferFrom/burn 守锁 + transferAndLock + 全套 view 函数 + MultiSigTimeLock 治理 + withdrawDLCTo）都在 v2 中按原样保留。

### 2. v1 ERC20 / EIP712 / Initializable namespace 数据 → v2 全部继承

v2 继承同一组 OZ v5 父合约，namespace 公式一致，所以 v2 调用 `balanceOf` / `totalSupply` / `name` / `symbol` / `permit` 读到的就是 v1 的同一份数据。

### 3. v2 新字段 (admin, forceTransferCount) → 独立命名空间

namespace 字符串：`"deeplink.dlc.v2"`

槽位公式：
```
keccak256(abi.encode(uint256(keccak256("deeplink.dlc.v2")) - 1)) & ~bytes32(uint256(0xff))
= 0xa105b799014e58afea5b116d74012b577c3a5c13b3ed2f3b9dfeaf0377e3e400
```

**这个值用 Python eth_hash 独立复算确认（2026-05-14）**。测试 `test_namespace_slot_matches_formula` 在 Solidity 层重算并 assertEq 自检。

### 4. 与已知 OZ v5 namespace 不冲突

| Namespace | 槽位 |
|-----------|------|
| `openzeppelin.storage.ERC20` | `0x52c63247...bace00` |
| `openzeppelin.storage.Initializable` | `0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00` |
| `openzeppelin.storage.EIP712` | （计算式同上） |
| `openzeppelin.storage.Nonces` | （计算式同上） |
| ERC1967 implementation | `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` |
| **`deeplink.dlc.v2`** | **`0xa105b799014e58afea5b116d74012b577c3a5c13b3ed2f3b9dfeaf0377e3e400`** |

前 8 字节 `0xa105b799` 与任何已知 namespace 完全不同；与顺序槽 0~∞ 撞库概率为 1/2^256。测试 `test_namespace_does_not_collide` 显式断言不冲突。

### 5. reinitializer(2) 安全

v1 Initializable 当前 `_initialized = 1`（已通过 v1 的 initialize() 调用一次）。v2 的 `initializeV2(address)` 用 `reinitializer(2)`，会把 `_initialized` 升到 2，再调时 revert。

### 6. canUpgradeAddress 显式声明在 slot 6

v2 把 `address public canUpgradeAddress;` 作为第 7 个顺序状态变量声明（前面 6 个分别是 timeLock/isLockActive/walletLockTimestamp/initSupply/maxSupply/minter2MintAmount/lockTransferAdmins），Solidity 自动把它分配到 slot 6 — **与 v1 完全相同**。

v2 的 `_authorizeUpgrade` 直接通过 Solidity 状态变量读写 slot 6（自动生成的 `canUpgradeAddress()` getter + `canUpgradeAddress = address(0);` 赋值），无需 assembly。行为镜像 v1：一次性授权后归零。

### 7. v2 不引入新顺序槽

除了精确镜像 v1 的 slot 0-7，v2 不在顺序槽上声明任何新字段。新字段（admin / forceTransferCount）全部进 ERC-7201 namespace。这确保未来 v3 升级仍有完整顺序槽预算。

---

## v1 Initializable namespace 槽位修正

之前文档误把 OZ v5 Initializable namespace 写成 `0xf0c57e16840df040f15088dc2f81fe391c3923bea127e5a0d9a0ad3c01ecc77e`，正确值是 `0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00`（已用 Python eth_hash 独立复算确认，并对照 OZ 源码 `Initializable.sol`）。

---

## ERC20Permit / EIP712 兼容性

v1 EIP712 namespace 已经通过 v1 的 initialize 调用初始化过：
- `_name = "DeepLink"`（string）
- `_version = "1"`（string）

所以 v2 继承 `ERC20PermitUpgradeable` 后，`permit()` 的 DOMAIN_SEPARATOR 计算用的是与 v1 完全一致的 name/version，**外部已签好的 permit 签名升级后仍然有效**。

v2 的 `initializeV2()` **不调** `__EIP712_init` 或 `__ERC20_init` — 这是有意的（重复初始化会破坏现有 namespace 状态）。

---

## 升级前手动 sanity 检查清单

主网升级前必跑（脚本里也已做硬性 `require`）：

```bash
PROXY=0x6f8F70C74FE7d7a61C8EAC0f35A4Ba39a51E1BEe
RPC=https://rpc.dbcwallet.io

# 1. 当前 impl 必须是 v1
cast storage $PROXY 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $RPC
# 应返回 0x...a72e3ebb05131fb6a1dfe6546c0a72c30f424477

# 2. v5 namespace _totalSupply 非零
cast storage $PROXY 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace02 --rpc-url $RPC
# 应返回 0x...013fde841e3f47137d892129ef (= 98,994,723,575,301,220,182,073,092,591 ≈ 98.99B DLC × 10^18)
#       注: 该值会随 burn / mint 历史变化, 升级时实测可能与此 hex 不完全一致。

# 3. canUpgradeAddress 是我方钱包（DBC 链方 sudo.setStorage 完成后）
cast call $PROXY "canUpgradeAddress()(address)" --rpc-url $RPC
# 应返回我方部署钱包

# 4. 任何已知大户余额能从 namespace 反推出来
HOLDER=0xAF49734cF87d36AA4881F5B2f05A65F08063818b
SLOT=$(cast keccak $(cast abi-encode "f(address,uint256)" $HOLDER 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00))
cast storage $PROXY $SLOT --rpc-url $RPC
# 与 cast call $PROXY "balanceOf(address)(uint256)" $HOLDER --rpc-url $RPC 一致
```

---

## 回滚方案

UUPS 回滚是单笔 tx：从 canUpgradeAddress 调用 `upgradeToAndCall(V1_IMPL, "")` 把实现指回 `0xa72e3ebb...`。

v2 写入命名空间槽的数据 (admin / forceTransferCount) 在回滚后仍然存在，但 v1 不读它，无害。v1 顺序槽 0/2/3/6 数据 v2 从未触碰，回滚立即可用。

**`test/DLCv2.fork.t.sol::test_rollback_v2BackToV1_preservesState`** 用主网 fork 演练这一流程，部署前必须跑通。
