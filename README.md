# OpenSshPort ("OpenSSH Settings") — roothide 中文汉化版

> 本仓库为上游 [Blanxd/OpenSshPort](https://gitlab.com/blanxd/OpenSshPort) 1.1.0 的 **roothide 汉化构建**：界面中文化（设置页_plist_ 与代码内 UI 字面量），架构 `iphoneos-arm64e`，由 GitHub Actions 自动构建，产物见 [Releases](https://github.com/xiaofeifei996/OpenSshPort/releases)。下文英文原文以英文为准。

---

# OpenSshPort ("OpenSSH Settings")
An iOS (jailbroken) Settings.app menu for
1. changing the port(s) that OpenSSH listens on
2. toggling
    - OpenSSH server on/off
    - whether root login is allowed
    - whether password is required
    - whether pubkey is required
    - whether only localhost is allowed to connect (USB/local app)
    - whether the SSH server stays off or starts up after rebooting/re-jailbreaking
    - whether active sessions get disconnected when turning it off from here or the toggle tweaks
    - whether the toggle tweaks (eg. [OpenSSH CC Toggle](https://gitlab.com/blanxd/OpenSshCC)) can be used while the device is locked
3. viewing the list of active sessions, and logging them off forcefully.

This is the GUI frontend for [SSHswitch](https://gitlab.com/blanxd/SSHswitch), it used to be bundled in the all-in-one tweak called `SSHonCC` ("SSH Toggle and Port") together with [OpenSshCC](https://gitlab.com/blanxd/OpenSshCC) and [SSHswitch](https://gitlab.com/blanxd/SSHswitch). It was broken up into separate packages for everyone to have a choice about some dependencies et al, most of the development really happens in `SSHswitch` anyway. It started in 2018, since there wasn't anything similar for iOS11 long after it got publicly jailbroken, like there used to be on earlier jailbreaks. And the 1st public jb for iOS11 had OpenSSH server forcibly installed without an option to turn it off so to me it actually felt like a security issue, because not everyone knows what it is in the 1st place so most were probably walking around listening for anyone to log in on the default port with the default password.

## Building
- By default this Makefile builds it for rootless jbs (since OpenSshPort ver.1.1.0), with the default toolchain on the system. To build for rootful environments and/or use the old ABI for arm64e, append RF=1 to the make commandline, eg. `make RF=1` or `make package FINALPACKAGE=1 RF=1`, in this case it tries to find an Xcode 11 toolchain for the job (don't forget to `make clean` between RF and RL).  
- The version number/string is always read from version.txt (used for decisions about logging, and written into the control file when packaging), the Makefile handles all that.  
- A recent [Theos](https://theos.dev/) is recommended (post 2023-03-26), but it also does the rootless job with older Theos versions.  

## Changelog
The [Changelog.md](Changelog.md) shows how it has evolved, it mostly just follows what's being added to, or changed in `SSHswitch`.  

