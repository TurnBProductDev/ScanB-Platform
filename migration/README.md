# Moving to a new laptop

Everything travels through OneDrive. The code already does; this kit adds what
OneDrive does not carry: the local database, your Claude Code memory and settings,
.NET user secrets, and your Desktop, Documents and other user folders.

The kit is a folder in your OneDrive called `ScanB-Migration-Kit`. Everything
sensitive in it is locked with a passphrase you choose (7-Zip, AES-256, file
names hidden too). Remember the passphrase, and don't write it anywhere in
OneDrive.

## 1. Old laptop: make the kit

1. Double-click `Export-OldMachine.cmd` in this folder.
2. Answer its questions:
   - **Take all databases?** Press Enter for no. That takes only
     `TurnretailVMConfigDB`, which the local Web App needs.
   - **Take your user folders?** Press Enter for yes (about 8 GB).
   - **Passphrase:** at least 12 characters, typed twice.
3. Wait for "Everything packed and encrypted", then wait until the OneDrive icon
   says **Up to date**. Uploading the user folders can take a while.

You can keep working on the old laptop as normal.

`Export-OldMachine.ps1 -DryRun` shows the plan and the upload size without
writing anything.

## 2. New laptop: first day

1. Sign in to Windows, then to OneDrive with the account that holds ScanB
   (Shankar.N).
2. In File Explorer, right-click `ScanB-Migration-Kit` and choose
   **Always keep on this device**. Wait for the green ticks.
3. Open `ScanB-Migration-Kit` and double-click `Setup-NewMachine.cmd`. Just
   double-click; don't use "Run as administrator".
4. A **second window** opens and asks for admin rights: click **Yes**. That
   window installs the tools and SQL Server, asks for your passphrase, restores
   the databases and puts back your settings and files. Click **Yes** if Windows
   asks to trust a certificate. When it says so, press Enter to close it.
5. Back in the first window, it asks **"Is the old laptop done with the repos?"**
   Answer **No** if you still use the old laptop.
6. If it says to restart, restart and double-click `Setup-NewMachine.cmd` again.
   It skips what is already done.

The repo steps run in the first, normal window on purpose: OneDrive will not
download files for a program running as administrator.

## 3. Switch day

1. Old laptop: save your work, wait for OneDrive to say **Up to date**, then quit
   OneDrive (right-click its icon > Quit).
2. New laptop: open Docker Desktop once and accept its terms.
3. New laptop: double-click `Setup-NewMachine.cmd` again and answer **Yes**.
   It fixes the paths, rebuilds what each project needs, and checks all four
   projects. To redo only this part later, double-click
   `Setup-NewMachine-Cutover.cmd`.
4. Read the summary at the end. Anything red or yellow says what to do.

## 4. By hand afterwards

Logins are never copied:

- `az login`
- Claude Code and the Claude desktop app
- GitHub (the first `git fetch` opens a browser)
- Power BI Desktop, Docker Desktop
- the Sophos Connect VPN profile from IT

Then delete the `ScanB-Migration-Kit` folder from OneDrive.

Not migrated on purpose: Oracle XE, the `OnPremTestDB` Power BI gateway and
Docker images.

Logs: `logs\` in the kit for the export, `%LOCALAPPDATA%\ScanB-Setup` for the setup.
