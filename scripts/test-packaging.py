#!/usr/bin/env python3
"""Tests for the signing and packaging setup.

Run with:

    python3 scripts/test-packaging.py

Two things are being protected here, and only one of them is "the script
works".

The other is that this repository is public. A Team ID, a certificate name or
a provisioning profile committed by accident is not recoverable by deleting it
in a later commit — it is in the history. So the leak tests below run against
the *tracked* files rather than the working tree, and the redaction tests drive
the real script with fabricated credentials and assert they do not come back
out in its output.

No certificates are needed: every packaging path is exercised through
``--dry-run``, which prints the plan and runs nothing.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "scripts" / "package-app.sh"
EXAMPLE = ROOT / "scripts" / "signing.env.example"

# Fabricated, and deliberately distinctive: a substring that appears nowhere
# else means an assertion that it is absent cannot pass by coincidence.
FAKE = {
    "BVX_TEAM_ID": "ZZ9PLURAL9",
    "BVX_BUNDLE_ID": "com.qjam.bvx",
    "BVX_DEVELOPER_ID_APP": "Developer ID Application: Nemo Nobody (ZZ9PLURAL9)",
    "BVX_NOTARY_PROFILE": "test-notary-profile",
    "BVX_APP_STORE_APP": "Apple Distribution: Nemo Nobody (ZZ9PLURAL9)",
    "BVX_APP_STORE_INSTALLER": "3rd Party Mac Developer Installer: Nemo Nobody (ZZ9PLURAL9)",
    "BVX_PROVISION_PROFILE": "/nowhere/secret-team.provisionprofile",
}

failures: list[str] = []
passed = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global passed
    if condition:
        passed += 1
        print(f"  ok    {name}")
    else:
        failures.append(f"{name}: {detail}" if detail else name)
        print(f"  FAIL  {name}" + (f"  ({detail})" if detail else ""))


def run_package(*args: str, env_extra: dict[str, str] | None = None,
                config: Path | None = None) -> subprocess.CompletedProcess[str]:
    """Run package-app.sh with the fake credentials in the environment."""
    env = dict(os.environ)
    env.update(FAKE)
    # Point at a config file that does not exist unless the test supplies one,
    # so a developer's real scripts/signing.env cannot influence the result.
    env["BVX_SIGNING_CONFIG"] = str(config) if config else "/nonexistent/signing.env"
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        ["bash", str(PACKAGE), *args],
        capture_output=True, text=True, env=env, cwd=ROOT,
    )


# Which settings are actually secret.
#
# BVX_BUNDLE_ID is not: `com.qjam.bvx` is committed in Info.plist, in the
# scripts and in the Swift sources, deliberately. Scanning for it flagged nine
# tracked files the first time this ran against a real config — and a leak
# detector that cries wolf on its first real use is one people learn to ignore.
#
# BVX_NOTARY_PROFILE is not secret either: it names a keychain profile, while
# the credential it stores stays in the keychain.
SECRET_KEYS = {
    "BVX_TEAM_ID",
    "BVX_DEVELOPER_ID_APP",
    "BVX_APP_STORE_APP",
    "BVX_APP_STORE_INSTALLER",
    "BVX_PROVISION_PROFILE",
}


def parse_env_file(path: Path) -> dict[str, str]:
    """Read KEY=value lines, ignoring comments and blanks."""
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def parse_config_secrets(path: Path) -> list[tuple[str, str]]:
    """The secret (key, value) pairs actually configured on this machine.

    Values still equal to the template's placeholders are skipped: a config
    copied from `signing.env.example` and only partly filled in would otherwise
    report the example file as leaking its own placeholders.
    """
    placeholders = set(parse_env_file(EXAMPLE).values())
    out: list[tuple[str, str]] = []
    for key, value in parse_env_file(path).items():
        if key not in SECRET_KEYS:
            continue
        if not value or value in placeholders or value.startswith("$"):
            continue
        out.append((key, value))
    return out


def tracked_files() -> list[Path]:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [ROOT / name for name in out.split("\0") if name]


# ---------------------------------------------------------------------------


def test_dry_runs_do_not_leak() -> None:
    """The point of the redaction: fake IDs go in, none come out."""
    print("\nRedaction")
    for mode in ("--sign", "--dmg", "--app-store"):
        result = run_package(mode, "--dry-run")
        combined = result.stdout + result.stderr
        check(f"{mode} --dry-run succeeds", result.returncode == 0,
              combined.strip()[-300:])
        check(f"{mode} --dry-run does not print the Team ID",
              FAKE["BVX_TEAM_ID"] not in combined,
              "the Team ID appeared in the output")
        check(f"{mode} --dry-run does not print a certificate name",
              "Nemo Nobody" not in combined,
              "a certificate common name appeared in the output")
        check(f"{mode} --dry-run does not print the profile path",
              "secret-team.provisionprofile" not in combined)
        check(f"{mode} --dry-run says it changed nothing",
              "dry run" in combined)


def test_redaction_covers_unrelated_identities() -> None:
    """Masking the configured values is not enough on its own.

    `security find-identity` lists every certificate in the keychain, so a
    build for one team can print another team's ID. The pattern-based pass is
    what covers that, and this checks it is actually applied.
    """
    print("\nRedaction of identities the build does not use")
    result = run_package("--sign", "--dry-run",
                         env_extra={"BVX_DEVELOPER_ID_APP":
                                    "Developer ID Application: Someone Else (QQ1OTHER77)"})
    combined = result.stdout + result.stderr
    check("a differently-shaped identity is still masked",
          "QQ1OTHER77" not in combined, combined.strip()[-200:])


def test_missing_config_is_a_clear_error() -> None:
    print("\nMissing configuration")
    env_cleared = {k: "" for k in FAKE}
    result = run_package("--dmg", "--dry-run", env_extra=env_cleared)
    combined = result.stdout + result.stderr
    check("a missing certificate fails", result.returncode != 0)
    check("the error names the file to create",
          "signing.env" in combined, combined.strip()[-200:])


def test_config_file_is_read_and_env_wins() -> None:
    print("\nConfiguration precedence")
    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / "signing.env"
        config.write_text(
            'BVX_TEAM_ID=FILE123456\n'
            'BVX_DEVELOPER_ID_APP="Developer ID Application: From File (FILE123456)"\n'
        )
        # Nothing in the environment: the file supplies the values.
        env = {k: "" for k in FAKE}
        result = run_package("--sign", "--dry-run", env_extra=env, config=config)
        combined = result.stdout + result.stderr
        check("a config file alone is enough", result.returncode == 0,
              combined.strip()[-200:])
        check("values from the file are masked too",
              "FILE123456" not in combined)

        # With both, the environment wins — which is how CI supplies secrets
        # without writing them into the checkout.
        result = run_package("--sign", "--dry-run", config=config)
        check("the environment overrides the file", result.returncode == 0)
        check("neither value leaks when both are present",
              "FILE123456" not in (result.stdout + result.stderr)
              and FAKE["BVX_TEAM_ID"] not in (result.stdout + result.stderr))


def test_app_store_entitlements_are_generated_not_committed() -> None:
    print("\nApp Store entitlements")
    template = ROOT / "Resources" / "entitlements" / "app-store.entitlements.template"
    check("the template exists", template.exists())
    text = template.read_text()
    check("the template has a placeholder, not a Team ID",
          "__TEAM_ID__" in text)
    check("the template contains no 10-character team-shaped literal",
          not re.search(r"<string>[A-Z0-9]{10}\.", text))

    expanded = ROOT / ".build" / "dist" / "app-store.entitlements"
    check("the expanded file is gitignored",
          subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", str(expanded)]
                         ).returncode == 0,
          "an expanded entitlements file would be committable")


def test_signing_env_is_ignored() -> None:
    print("\nThe config file cannot be committed")
    target = ROOT / "scripts" / "signing.env"
    ignored = subprocess.run(
        ["git", "-C", str(ROOT), "check-ignore", "-q", str(target)]
    ).returncode == 0
    check("scripts/signing.env is gitignored", ignored,
          "the file holding the Team ID is committable")

    check("the example template is NOT ignored",
          subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", str(EXAMPLE)]
                         ).returncode != 0,
          "the template should be committed")

    profile = ROOT / "some-team.provisionprofile"
    check("provisioning profiles are gitignored",
          subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", str(profile)]
                         ).returncode == 0)

    # Regression: the rule was the exact filename, so `scripts/signing.env` was
    # ignored while vim's `.signing.env.swp` — holding the same buffer, Team ID
    # and all — sat next to it untracked and committable. Every file an editor
    # leaves beside the real one carries the same contents.
    for leftover in (".signing.env.swp", ".signing.env.swo", "signing.env~",
                     "signing.env.bak", "signing.env.save", "signing.env.orig"):
        path = ROOT / "scripts" / leftover
        check(f"editor leftover {leftover} is gitignored",
              subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", str(path)]
                             ).returncode == 0,
              "it would hold the same Team ID as signing.env")


def test_no_tracked_file_carries_credentials() -> None:
    """The regression test for the thing that cannot be undone.

    Scans every file git tracks. If a real Team ID is configured on this
    machine, its literal value is searched for as well — which is the check
    that would actually catch a leak, since a placeholder looks nothing like
    the real thing.
    """
    print("\nNo credentials in tracked files")

    real_values = parse_config_secrets(ROOT / "scripts" / "signing.env")

    offenders: list[str] = []
    apple_id_re = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")
    for path in tracked_files():
        if not path.is_file():
            continue
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        for key, value in real_values:
            if value in text:
                # The key is named so the report is actionable; the value never
                # is, because this output goes wherever test output goes.
                offenders.append(f"{path.relative_to(ROOT)} contains {key}")
        # An Apple ID would most plausibly arrive inside the example file or
        # the docs, as someone's address pasted over the placeholder.
        if path.name in ("signing.env.example", "package-app.sh"):
            for match in apple_id_re.findall(text):
                if not match.endswith("example.com"):
                    offenders.append(f"{path.relative_to(ROOT)} contains {match}")

    check("no tracked file carries a configured signing value",
          not offenders, "; ".join(offenders))

    if real_values:
        names = ", ".join(sorted(key for key, _ in real_values))
        print(f"        (checked against {len(real_values)} configured value(s): {names})")
    else:
        # Said out loud, because a silent pass here would otherwise look like
        # proof of something it did not check.
        print("        (no scripts/signing.env on this machine — literal-value "
              "check did not run)")


def test_the_leak_scan_still_detects() -> None:
    """Narrowing the scan must not have switched it off.

    Two directions, because a detector that never fires and a detector that
    always fires are equally useless — and the second is how the first happens,
    since people stop reading it.
    """
    print("\nThe leak scan itself")
    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / "signing.env"
        config.write_text(
            "BVX_TEAM_ID=QQ1OTHER77\n"
            "BVX_BUNDLE_ID=com.qjam.bvx\n"
            "BVX_NOTARY_PROFILE=bvx-notary\n"
            'BVX_DEVELOPER_ID_APP="Developer ID Application: Nemo Nobody (QQ1OTHER77)"\n'
        )
        secrets = dict(parse_config_secrets(config))

        check("a real Team ID is scanned for", "BVX_TEAM_ID" in secrets)
        check("a real certificate name is scanned for",
              "BVX_DEVELOPER_ID_APP" in secrets)
        # The false positive that started this: com.qjam.bvx is committed in
        # Info.plist, the scripts and the Swift sources, on purpose.
        check("the bundle id is not treated as a secret",
              "BVX_BUNDLE_ID" not in secrets)
        check("the notary profile name is not treated as a secret",
              "BVX_NOTARY_PROFILE" not in secrets)

    with tempfile.TemporaryDirectory() as tmp:
        # A config copied from the template and not yet filled in has nothing
        # worth scanning for, and must not report the template as leaking its
        # own placeholders.
        config = Path(tmp) / "signing.env"
        config.write_text(EXAMPLE.read_text())
        check("untouched placeholders are not scanned for",
              parse_config_secrets(config) == [],
              str(parse_config_secrets(config)))


def test_example_holds_only_placeholders() -> None:
    print("\nThe committed template")
    text = EXAMPLE.read_text()
    check("the example exists and mentions the Team ID", "BVX_TEAM_ID" in text)
    check("the example's Team ID is the documented placeholder",
          "ABCDE12345" in text)
    check("the example tells you the file is gitignored",
          "gitignored" in text)
    check("the example does not hard-code a real-looking Apple ID",
          "@" not in text or "example.com" in text)


def test_short_values_are_not_masked() -> None:
    """Regression: the ad-hoc identity is a single hyphen.

    Masking it blindly replaced every `-` in the output — flags, paths and
    prose all turned into `<DEVELOPER_ID_APP>`. Only values long enough to be
    a credential are masked.
    """
    print("\nShort values")
    result = run_package("--sign", "--dry-run",
                         env_extra={"BVX_DEVELOPER_ID_APP": "-"})
    combined = result.stdout + result.stderr
    check("an ad-hoc identity leaves flags intact",
          "--force" in combined and "--timestamp" in combined,
          combined.strip()[-200:])
    check("an ad-hoc identity leaves paths intact",
          "developer-id.entitlements" in combined)
    check("an ad-hoc build warns that it is not distributable",
          "ad-hoc" in combined)


def test_ad_hoc_cannot_be_notarized() -> None:
    print("\nAd-hoc guard rails")
    result = run_package("--dmg", "--dry-run",
                         env_extra={"BVX_DEVELOPER_ID_APP": "-"})
    combined = result.stdout + result.stderr
    check("notarizing an ad-hoc signature is refused", result.returncode != 0)
    check("the refusal points at the fix",
          "--no-notarize" in combined or "BVX_DEVELOPER_ID_APP" in combined,
          combined.strip()[-200:])


def test_real_app_store_run() -> None:
    """Exercises the App Store path for real, as far as certificates allow.

    Everything up to `productbuild` runs: staging, removing the CLI, embedding
    the profile, expanding the entitlements and signing the sandboxed bundle.
    `productbuild` then refuses the ad-hoc identity, which is correct — so the
    assertions are about the artifacts, not the exit code.
    """
    print("\nApp Store build (ad-hoc, as far as it goes)")
    app = ROOT / ".build" / "bvx.app"
    if not app.is_dir():
        # Said out loud rather than silently passing: a skipped check that
        # looks like a green one is worse than no check.
        print("        (no .build/bvx.app — run ./scripts/build-app.sh first; "
              "these checks did not run)")
        return

    with tempfile.TemporaryDirectory() as tmp:
        profile = Path(tmp) / "fake.provisionprofile"
        profile.write_text("not a real profile")
        run_package("--app-store", env_extra={
            "BVX_APP_STORE_APP": "-",
            "BVX_APP_STORE_INSTALLER": "-",
            "BVX_PROVISION_PROFILE": str(profile),
        })

    entitlements = ROOT / ".build" / "dist" / "app-store.entitlements"
    check("the entitlements were generated", entitlements.exists())
    if entitlements.exists():
        text = entitlements.read_text()
        check("no placeholder survived substitution",
              "__TEAM_ID__" not in text and "__BUNDLE_ID__" not in text)
        check("the Team ID was substituted in",
              f"{FAKE['BVX_TEAM_ID']}.{FAKE['BVX_BUNDLE_ID']}" in text)
        check("the generated file is valid plist",
              subprocess.run(["plutil", "-lint", str(entitlements)],
                             capture_output=True).returncode == 0)
        # It carries the Team ID, so it should not be world-readable on a
        # shared machine either.
        check("the generated file is not world-readable",
              (entitlements.stat().st_mode & 0o077) == 0,
              oct(entitlements.stat().st_mode))

    staged = ROOT / ".build" / "dist" / "stage" / "bvx.app"
    check("the App Store bundle drops the CLI",
          not (staged / "Contents" / "MacOS" / "bvx-cli").exists(),
          "a sandboxed app cannot install it, so shipping it invites review questions")
    check("the provisioning profile is embedded",
          (staged / "Contents" / "embedded.provisionprofile").exists())
    check("the input bundle was not mutated",
          (app / "Contents" / "MacOS" / "bvx-cli").exists(),
          "packaging must work on a copy")


def test_check_reports_per_channel() -> None:
    """--check answers "can I ship?", not "are some settings present?".

    The first version printed CONFIG OK with nothing configured at all, which
    reads as a green light for a machine that cannot sign anything.
    """
    print("\n--check")
    empty = {k: "" for k in FAKE}
    result = run_package("--check", env_extra=empty)
    combined = result.stdout + result.stderr
    check("nothing configured fails", result.returncode != 0, combined.strip()[-200:])
    check("it names both channels",
          "--dmg" in combined and "--app-store" in combined)

    # A Developer ID build without notarization needs no notary profile, so
    # this is a legitimately complete configuration. Signed ad-hoc because a
    # real certificate name would have to be in this machine's keychain —
    # `--check` verifies that, which is the point of it.
    result = run_package("--check", "--no-notarize",
                         env_extra={"BVX_NOTARY_PROFILE": "",
                                    "BVX_DEVELOPER_ID_APP": "-"})
    check("a Developer ID identity alone is enough with --no-notarize",
          result.returncode == 0, (result.stdout + result.stderr).strip()[-200:])
    check("--check masks the values it reports",
          FAKE["BVX_TEAM_ID"] not in (result.stdout + result.stderr))
    check("--check does not print the values, only whether they are set",
          "set" in result.stdout)


def test_help_and_bad_flags() -> None:
    print("\nInterface")
    result = run_package("--help")
    check("--help succeeds", result.returncode == 0)
    check("--help lists the modes",
          "--dmg" in result.stdout and "--app-store" in result.stdout)

    result = run_package("--nonsense")
    check("an unknown flag is rejected", result.returncode == 2)

    result = run_package()
    check("no mode is rejected rather than doing something", result.returncode == 2)


def test_build_app_forwards() -> None:
    print("\nbuild-app.sh hand-off")
    text = (ROOT / "scripts" / "build-app.sh").read_text()
    for flag in ("--sign", "--dmg", "--app-store", "--dry-run", "--no-notarize"):
        check(f"build-app.sh accepts {flag}", flag in text)
    check("build-app.sh delegates rather than reimplementing",
          "package-app.sh" in text)
    check("a distribution build forces --release", "implies --release" in text)


def main() -> int:
    print("Packaging and signing tests")
    check("package-app.sh is executable", os.access(PACKAGE, os.X_OK))
    syntax = subprocess.run(["bash", "-n", str(PACKAGE)], capture_output=True, text=True)
    check("package-app.sh parses", syntax.returncode == 0, syntax.stderr.strip())

    test_dry_runs_do_not_leak()
    test_redaction_covers_unrelated_identities()
    test_missing_config_is_a_clear_error()
    test_config_file_is_read_and_env_wins()
    test_app_store_entitlements_are_generated_not_committed()
    test_signing_env_is_ignored()
    test_no_tracked_file_carries_credentials()
    test_the_leak_scan_still_detects()
    test_example_holds_only_placeholders()
    test_short_values_are_not_masked()
    test_ad_hoc_cannot_be_notarized()
    test_real_app_store_run()
    test_check_reports_per_channel()
    test_help_and_bad_flags()
    test_build_app_forwards()

    print()
    if failures:
        print(f"{len(failures)} failed, {passed} passed")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"{passed} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
