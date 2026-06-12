# mdm-scripts

Scripts and generators for deploying Endor Labs configuration via MDM.

---

## Contents of this repo

### [`package-firewall/`](package-firewall/README.md)

Generates self-contained MDM scripts that configure developer machines to route package installations through the [Endor Package Firewall](https://docs.endorlabs.com/integrations/package-firewall).

### [`agent-governance/`](agent-governance/README.md)

Generates MDM-deployable hook configurations for AI coding agents (Claude Code, Cursor) that wire every session/tool/file action to `endorctl ai-audit` for governance — across macOS, Linux, and Windows.