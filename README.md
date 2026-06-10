# mdm-scripts

Scripts and generators for deploying Endor Labs configuration via MDM.

---

## Contents

### [`package-firewall/`](package-firewall/README.md)

Generates self-contained MDM scripts that configure developer machines to route package installations through the [Endor Package Firewall](https://docs.endorlabs.com/integrations/package-firewall).

| Platform | Directory | MDM tools |
|---|---|---|
| macOS / Linux | [`package-firewall/bash/`](package-firewall/bash/README.md) | Kandji, Jamf Pro, generic MDM |
| Windows | [`package-firewall/powershell/`](package-firewall/powershell/README.md) | Microsoft Intune, generic MDM |

### [`doc/`](doc/)

Testing guides for validating the package firewall configuration against real package managers.

| File | Covers |
|---|---|
| [`PACKAGE_FIREWALL_TESTING.md`](doc/PACKAGE_FIREWALL_TESTING.md) | pip, uv, poetry (macOS/Linux) |
| [`PACKAGE_FIREWALL_WINDOWS_TESTING.md`](doc/PACKAGE_FIREWALL_WINDOWS_TESTING.md) | pip, uv, poetry (Windows) |