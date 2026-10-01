# How to contribute

Thanks for your interest. This guide covers the basics so your contribution can be reviewed and accepted quickly.

## Before writing code

- For large changes, or ones that alter current behavior, open an issue first (using the feature request template) to discuss the approach before investing time in the implementation.
- For one-off bugs or small improvements, you can go straight to a *pull request*.

## Submitting the Pull Request

1. Fork the repository, create a branch and make your changes there.
2. Before opening the PR, run locally the same checks as CI (`.github/workflows/quality.yml`):

   ```bash
   ./tests/lint.sh                               # requires exactly ShellCheck 0.11.0
   ./tests/run.sh                                # functional suite; uses python3 (standard library only)
   git show --check --oneline --no-renames HEAD  # same as CI's last step; run it after committing
   ```

3. If you change a message, edit `TXT_ES` and `TXT_EN` together: same keys and same placeholders (`%s`, `%d`...), and the English without accents or ñ.
4. If you change usage, a flag or an exit code, update `README.es.md` and `README.md` together.
5. A bug fix comes with its test: a `*_test` function in `tests/run.sh`, added to the `TESTS` list.
6. Fill in the PR template: what changes, why, and how you tested it.

The suite also checks permissions: `script/renombrador.sh` at `644`, `tests/run.sh` at `755` and `tests/lint.sh` executable. To try the script without changing its mode, run it with `bash script/renombrador.sh`.

## Reporting bugs or suggesting ideas

Use the repository's issue templates; they show up automatically when you create a new issue. The more context (distro, `zenity` version, exact steps), the faster it can be diagnosed.

For security issues, do not open a public issue — see [`SECURITY.md`](SECURITY.md).
