# AI Developer Rules & Knowledge Base
> **Last Updated:** 2025/12/25
> **Scope:** Project-Specific Compliance & Coding Standards

> ⚠️ **Critical:** Before modifying any Sing-box config, you MUST study the migration guide:
> **File:** `singbox/docs/migration.md`

### 1.1 Coding Standards
* **Systemd**: Service runs as `User=root`, so file permissions (logs, configs) MUST be `root:root`.
* **IPv6 Handling**: Always quote IPv6 addresses when performing JSON injection (e.g., in `jq`).
* **jq Syntax**: Use robust initialization to prevent null errors:  
  `jq '.endpoints = (.endpoints // [])'`

### 1.2 WARP Specifics
* **Naming Convention**: The WireGuard endpoint tag **MUST** be `"WARP"` (Strictly forbidden: `warp-endpoint` linked to a `WARP` outbound).
  
---

## 2. Xray-core Compliance (Target: v25.12.8+)
### 2.1 VLESS Post-Quantum Encryption (ML-KEM-768)
* **Minimum Version**: v25.8.31+
* **Core Technology**: ML-KEM-768 (Quantum-Safe Key Encapsulation Mechanism).
* **Key Generation**: 
  Use the built-in command to generate `decryption` / `encryption` keys:
  ```bash
  xray vlessenc

  
    1.ENC抗量子加密（ML-KEM-768）技术更新：从 Xray v25.8.31 版本开始，正式支持了 VLESS Post-Quantum Encryption（后量子加密）。使用了ML-KEM-768（量子安全密钥封装机制），利用 xray vlessenc 命令动态生成 decryption（解密）和 encryption（加密）所需的密钥信息。读取并学习参考示例https://raw.githubusercontent.com/yahuisme/vless-encryption/main/install.sh相关内容
    

