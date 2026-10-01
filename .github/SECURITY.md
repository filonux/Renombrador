# Security Policy

## How to report a vulnerability

Do not open a public issue. In order of preference:

1. **GitHub private report**: the repository's **Security** tab → **Report a vulnerability**.
2. If that option does not appear, write to the maintainer through the contact channels on their [GitHub profile](https://github.com/filonux).
3. If that is not possible either, open an issue **with no technical details** asking for a private channel.

It helps a lot if the report includes:

- The version (`./renombrador.sh --version`), the distro and the Bash version.
- How you run it: terminal, right-click in Nemo or command line (with the exact flags).
- The minimal steps to reproduce it, with the commands that create the files or names involved.
- The impact you think it has.

This is a small project maintained in spare time, so there are no guaranteed deadlines. The maintainer will acknowledge receipt and let you know when a fix is available.

## Supported versions

Only the latest version in the repository; fixes are not backported to earlier versions.

## What counts as a security flaw

Renombrador runs with the permissions of whoever launches it, on files that person can already modify. What matters is anything that breaks that boundary:

- A file name, pattern, template or regular expression ending up executing commands.
- Something being written, overwritten or deleted through a symbolic link, or a link being followed outside the chosen folder.
- Undoing a batch touching files that were not part of that batch or that changed after it was applied.
- Terminal control sequences from a name, template or history reaching the screen unsanitized.
- Configuration or history being created with overly open permissions.

A flaw that does not cross that boundary is a regular bug: open an issue with the bug report template.

**Out of scope:**

- Anything that requires prior write access to the victim's home directory (`$HOME`) (`~/.config/renombrador/`, `~/.local/share/renombrador/` or the Nemo action): with that access the same can already be done without Renombrador.
- Flaws in Bash, `zenity`, `kdialog`, `exiftool`, Nemo or the package manager: report them to their own projects.
- Anything the user explicitly asked for, such as `--conflicto sobrescribir`.

## What the test suite already checks

`./tests/run.sh` verifies that:

- `~/.config/renombrador/` and `historial/` end up with `700` permissions, even if they already existed with other permissions.
- It refuses to write through symbolic links in its configuration (templates included) and in the icon. Histories that are links are ignored, and `--seguir-enlaces` does not follow links that point outside the chosen folder.
- Names containing `;`, quotes, line breaks or a leading `-`, and `$(...)` in `--buscar` with `--regex`, are treated as text: nothing is executed. The script does not use `eval`.
- ESC and the 8-bit CSI (U+009B) in names, templates, history or `--lang` are shown as `?`, and a `\033` typed as text stays text.
- Undo does not touch anything that changed after the batch was applied, and does not undo old or corrupt histories.

If you find a way around any of these guarantees, it is a valid report.

## Privileges

`sudo` is only used to install `zenity` with the system package manager (`apt`, `dnf`, `pacman` or `zypper`), and only if you accept the prior prompt. The rest of the script asks for no privileges.
