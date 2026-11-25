# Connecting to the CÉCI clusters with VS Code (Remote-SSH)

Setup guide for colleagues. Written 2026-10-13 from a working Windows 11 + VS Code setup on `lemaitre4`.
Items marked **(unverified)** were not checked against the official CÉCI documentation; always confirm hostnames,
fingerprints and policies on the official CÉCI/CISM pages (links at the end).

## 0. What you need

- A CÉCI account, with your SSH public key registered on it (see the CÉCI quick-start guide).
- Windows: the built-in **OpenSSH client** (`ssh.exe`, usually `C:\Windows\System32\OpenSSH\ssh.exe`).
  Check in PowerShell: `ssh -V`. Linux/macOS: `ssh` is already there.
- VS Code with the **Remote - SSH** extension (Microsoft).

## 1. Generate an SSH key (once)

In PowerShell / a terminal:

```
ssh-keygen -t rsa -b 4096 -f $env:USERPROFILE\.ssh\id_rsa.ceci
```

- Use a **passphrase**. Never share the private key (`id_rsa.ceci`); only the `.pub` file is registered on your CÉCI account.
- Key type and size: the CÉCI guide may recommend a specific type (unverified); follow their guide if it differs.

## 2. SSH config

CÉCI clusters are reached **through a gateway** (`gwceci.cism.ucl.ac.be`). The gateway is a jump host only: you cannot
log into it interactively. Put this in `~/.ssh/config` (Windows: `C:\Users\<you>\.ssh\config`):

```
Host gwceci
    HostName gwceci.cism.ucl.ac.be
    User <your_ceci_login>
    IdentityFile ~/.ssh/id_rsa.ceci

Host lyra lemaitre4 hercules nic5 dragon2 dragon3 manneback
    User <your_ceci_login>
    IdentityFile ~/.ssh/id_rsa.ceci
    ProxyJump gwceci
    ServerAliveInterval 120
    ServerAliveCountMax 100

Host lemaitre4
    HostName lemaitre4.cism.ucl.ac.be
Host lyra
    HostName lyra.ulb.be
Host hercules
    HostName hercules.ptci.unamur.be
Host dragon2
    HostName dragon2.umons.ac.be
Host dragon3
    HostName dragon3.umons.ac.be
Host nic5
    HostName nic5.uliege.be
Host manneback
    HostName manneback.cism.ucl.ac.be
```

Replace `<your_ceci_login>` with your CÉCI username. Keep only the clusters you use. Hostnames above come from a working
config; check them against the CÉCI documentation.

If your OpenSSH is too old to know `ProxyJump`, replace that line with:
`ProxyCommand ssh gwceci -W %h:%p`.

## 3. Test in a terminal first

```
ssh lemaitre4
```

- First connection: SSH shows a host fingerprint. Compare it with the fingerprint published on the CÉCI "Access" page
  **before** typing `yes`.
- You may be asked for your passphrase twice (gateway, then cluster). Use an SSH agent to avoid this (Windows:
  `Get-Service ssh-agent`, start it, then `ssh-add $env:USERPROFILE\.ssh\id_rsa.ceci`).
- If this does not work, VS Code will not work either. Fix it here first.

## 4. Connect from VS Code

1. Install the extension **Remote - SSH**.
2. `Ctrl+Shift+P` → **Remote-SSH: Connect to Host…** → choose `lemaitre4` (the list comes from your `~/.ssh/config`).
3. When asked for the platform of the remote, choose **Linux**.
4. Open a **small** folder (`File > Open Folder…`), e.g. your project folder.

## 5. Recommended VS Code settings (important on shared login nodes)

On `lemaitre4` our account is limited to **1400 tasks (processes + threads) on the login node**. We hit this limit
with VS Code Server (about 260 threads per Node process) and got `bash: fork: Resource temporarily unavailable`.
The limit may differ on other clusters **(unverified)**.

- **Disable the AI features on the remote**: in Settings, tab *Remote [SSH: <host>]*, tick `chat.disableAIFeatures`,
  then restart the server (see section 6). In our case this cut the usage from about 1160 to about 580 tasks.
- Keep **one VS Code window** connected per cluster. An extra session costs about 260 tasks.
- Do not open huge folders (e.g. a whole scratch directory): file watching adds threads.
- Install few extensions on the remote.
- Do **heavy computation with `sbatch`/`srun`**, never on the login node. Jobs run on compute nodes, outside
  the login-node task limit **(unverified for every cluster)**.

## 6. Troubleshooting

| Symptom | What to try |
|---|---|
| `Could not establish connection ... spawn UNKNOWN` | VS Code cannot start `ssh.exe`. Set `remote.SSH.path` to `C:\Windows\System32\OpenSSH\ssh.exe`, reload the window, check that `ssh <host>` works in a terminal. If it persists, antivirus / IT policy may block it. |
| `bash: fork: Resource temporarily unavailable` | Task limit reached. Check usage: `cat /sys/fs/cgroup/pids/user.slice/user-$(id -u).slice/pids.current` (limit: `systemctl show user-$(id -u).slice -p TasksMax`). Apply section 5. |
| Old VS Code servers piling up | From a plain terminal (not inside VS Code): `ssh <host> "pkill -u <login> -f vscode-server"`, then reconnect. This does not touch SLURM jobs. |
| `ProxyJump` rejected | Old OpenSSH: use the `ProxyCommand` line from section 2. |
| Host key warning | Do not accept blindly: compare with the fingerprint on the CÉCI Access page. |

## 7. Monitoring jobs from the terminal

```
squeue --me                 # your jobs (PD = pending, R = running)
squeue --me --start         # estimated start time
sacct -j <jobid> --format=JobID,State,ExitCode,Elapsed,MaxRSS
scancel <jobid>
```

## Sources

- [CISM: Connection from the outer world (SSH gateways)](https://www.cism.ucl.ac.be/doc/_contents/Security/sshgateways.html)
- [CÉCI/CISM training: Connecting with SSH from Windows and Linux on CÉCI clusters](https://indico.cism.ucl.ac.be/event/148/contributions/159/)
- CÉCI quick-start "Connecting to the clusters from a Unix computer" (support.ceci-hpc.be): authoritative source for
  gateway hostnames, fingerprints and per-cluster aliases (not retrieved when this guide was written).
