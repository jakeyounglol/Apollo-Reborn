#!/usr/bin/env python3
"""Repository-local documentation generator and verifier.

Managed by the Boneman_Projects fleet documentation contract.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

MAX_PASSES = 3
MERMAID_RENDER_STAMP = '{"renderer":"mermaid-cli 11.10.1 chromium-png-scale2-v2"}'
MARKER_START = "<!-- documentation-health:start -->"
MARKER_END = "<!-- documentation-health:end -->"
MERMAID_RE = re.compile(r"(?ms)^```mermaid[ \t]*\n(.*?)^```[ \t]*$")
IMAGE_RE = re.compile(r"!\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)|<img\s+[^>]*src=[\"']([^\"']+)", re.I)
EXCLUDED_PARTS = {".git", "node_modules", "vendor", ".venv", "dist", "build", "coverage"}
SCRIPT_RELATIVE_PATH = Path("scripts/documentation_health.py")
WORKFLOW_RELATIVE_PATH = Path(".github/workflows/documentation-health.yml")


@dataclass
class Finding:
    repository: str
    code: str
    message: str


def run(args: list[str], *, cwd: Path, timeout: int = 900, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(args)}\n"
            f"{(result.stderr or result.stdout)[-4000:]}"
        )
    return result


def git_files(root: Path) -> list[Path]:
    result = run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root)
    return [root / item for item in result.stdout.split("\0") if item]


def maintained_documents(root: Path) -> list[Path]:
    return [
        path
        for path in git_files(root)
        if path.suffix.lower() in {".md", ".mdx", ".html"}
        and not any(part in EXCLUDED_PARTS for part in path.relative_to(root).parts)
    ]


def is_external_or_generated_document(root: Path, document: Path) -> bool:
    relative = document.relative_to(root).as_posix()
    return (
        relative.startswith("docs/reference/")
        or relative.startswith(".agents/")
        or relative.startswith(".github/prompts/")
        or relative.startswith(".github/chatmodes/")
        or relative.startswith("skills/")
        or relative.startswith("optional-skills/")
        or "/templates/" in relative
    )


def implementation_fingerprint(root: Path) -> str:
    excluded_prefixes = (
        "docs/",
        ".github/",
        "scripts/documentation_health.py",
        "README.md",
        "README.",
    )
    result = run(["git", "ls-files", "-s"], cwd=root)
    lines = []
    for line in result.stdout.splitlines():
        path = line.split("\t", 1)[-1]
        if path == "README.md" or path.startswith(excluded_prefixes):
            continue
        lines.append(line)
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()[:16]


def repository_name(root: Path) -> str:
    result = run(["git", "remote", "get-url", "origin"], cwd=root, check=False)
    match = re.search(r"github\.com[/:]([^/]+/[^/]+?)(?:\.git)?$", result.stdout.strip())
    return match.group(1) if match else root.name


def default_branch(root: Path) -> str:
    github_base_ref = os.environ.get("GITHUB_BASE_REF", "").strip()
    if github_base_ref:
        return github_base_ref
    repository_default_branch = os.environ.get("REPOSITORY_DEFAULT_BRANCH", "").strip()
    if repository_default_branch:
        return repository_default_branch
    remote_head = run(
        ["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
        cwd=root,
        check=False,
    )
    if remote_head.returncode == 0 and remote_head.stdout.strip():
        return remote_head.stdout.strip().removeprefix("origin/")
    result = run(["git", "branch", "--show-current"], cwd=root, check=False)
    return result.stdout.strip() or "detached"


def detect_areas(root: Path) -> dict[str, list[str]]:
    tracked = {str(path.relative_to(root)) for path in git_files(root)}
    top = {path.split("/", 1)[0] for path in tracked}
    interfaces: list[str] = []
    implementation: list[str] = []
    state: list[str] = []
    operations: list[str] = []

    def any_path(*values: str) -> bool:
        return any(value in top or value in tracked for value in values)

    if any(path.endswith(".xcodeproj/project.pbxproj") or path.startswith("Sources/") for path in tracked):
        interfaces.append("Apple / Swift interface")
    if any_path("app", "src", "frontend", "web", "website"):
        interfaces.append("Application / web interface")
    if any_path("api", "server", "backend"):
        interfaces.append("API / server interface")
    if any_path("bin", "cli") or any(path.endswith((".sh", ".command")) for path in tracked):
        interfaces.append("CLI / automation entrypoints")
    if any_path("Dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"):
        interfaces.append("Container interface")

    for candidate, label in (
        ("src", "Source modules"),
        ("app", "Application modules"),
        ("Sources", "Swift modules"),
        ("scripts", "Automation modules"),
        ("playbooks", "Ansible playbooks"),
        ("packages", "Workspace packages"),
        ("deploy", "Deployment modules"),
    ):
        if candidate in top:
            implementation.append(label)
    for candidate, label in (
        ("config", "Versioned configuration"),
        ("data", "Local data assets"),
        ("db", "Data layer"),
        ("migrations", "Schema migrations"),
        ("assets", "Product assets"),
    ):
        if candidate in top:
            state.append(label)
    if any(path.startswith(".github/workflows/") for path in tracked):
        operations.append("GitHub Actions")
    if "tests" in top or "test" in top or any("/tests/" in path for path in tracked):
        operations.append("Tests and validation")
    if "docs" in top:
        operations.append("Maintained documentation")

    return {
        "interfaces": interfaces[:3] or ["Repository consumers"],
        "implementation": implementation[:4] or ["Repository implementation"],
        "state": state[:3] or ["Versioned repository state"],
        "operations": operations[:3] or ["Git history and review"],
    }


def svg_text(value: str) -> str:
    return html.escape(value, quote=True)


def overview_svg(repo: str, areas: dict[str, list[str]]) -> str:
    short = repo.split("/")[-1]
    columns = [
        (70, "Interfaces", areas["interfaces"], "#2f80ff"),
        (560, "Implementation", areas["implementation"], "#35c98a"),
        (1050, "State & operations", areas["state"] + areas["operations"], "#9b8afb"),
    ]
    groups = []
    for x, title, items, color in columns:
        groups.append(
            f'<rect x="{x}" y="190" width="420" height="500" rx="28" fill="#121926" stroke="#344158" stroke-width="2"/>'
            f'<rect x="{x + 26}" y="220" width="8" height="30" rx="4" fill="{color}"/>'
            f'<text x="{x + 54}" y="245" fill="#f5f7fb" font-size="26" font-weight="700">{svg_text(title)}</text>'
        )
        for index, item in enumerate(items[:6]):
            y = 285 + index * 66
            groups.append(
                f'<rect x="{x + 28}" y="{y}" width="364" height="48" rx="14" fill="#192235" stroke="{color}"/>'
                f'<text x="{x + 48}" y="{y + 31}" fill="#dce4f2" font-size="18">{svg_text(item)}</text>'
            )
    arrows = (
        '<path d="M 490 440 L 550 440" stroke="#2f80ff" stroke-width="5" marker-end="url(#arrow)"/>'
        '<path d="M 980 440 L 1040 440" stroke="#2f80ff" stroke-width="5" marker-end="url(#arrow)"/>'
    )
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="800" viewBox="0 0 1600 800" role="img" aria-labelledby="title description">
  <title id="title">{svg_text(short)} system architecture</title>
  <desc id="description">Generated from the current tracked repository structure.</desc>
  <defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" fill="#2f80ff"/></marker></defs>
  <rect width="1600" height="800" fill="#0b0f17"/>
  <text x="70" y="80" fill="#f5f7fb" font-size="38" font-weight="800" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif">{svg_text(short)} system architecture</text>
  <text x="70" y="122" fill="#aab4c6" font-size="20" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif">Current repository structure rendered as a committed, viewer-compatible asset</text>
  <g font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif">{''.join(groups)}{arrows}</g>
  <text x="70" y="754" fill="#aab4c6" font-size="16" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif">Editable SVG source and PNG rendering are verified on every commit.</text>
</svg>
'''


def render_svg(svg_path: Path, png_path: Path) -> None:
    if shutil.which("sips"):
        run(["sips", "-s", "format", "png", str(svg_path), "--out", str(png_path)], cwd=svg_path.parent)
        return
    if shutil.which("rsvg-convert"):
        run(["rsvg-convert", "--width", "1600", "--output", str(png_path), str(svg_path)], cwd=svg_path.parent)
        return
    raise RuntimeError("rendering requires sips on macOS or rsvg-convert on Linux")


def mermaid_command(source: Path, output: Path) -> list[str]:
    command = ["npx", "-y", "@mermaid-js/mermaid-cli@11.10.1", "-i", str(source), "-o", str(output), "-b", "transparent"]
    if output.suffix.lower() == ".png":
        command.extend(["--scale", "2"])
    return command


def render_mermaid(root: Path, source: str, digest: str) -> tuple[Path, Path, Path]:
    generated = root / "docs/architecture/generated"
    generated.mkdir(parents=True, exist_ok=True)
    mmd_path = generated / f"mermaid-{digest}.mmd"
    svg_path = generated / f"mermaid-{digest}.svg"
    png_path = generated / f"mermaid-{digest}.png"
    stamp_path = generated / f"mermaid-{digest}.render.json"
    legacy_stamp_path = generated / f"mermaid-{digest}.rendered"
    if (
        not stamp_path.exists()
        and legacy_stamp_path.exists()
        and legacy_stamp_path.read_text(encoding="utf-8", errors="replace").strip()
        == "mermaid-cli 11.10.1 chromium-png-scale2-v2"
        and mmd_path.exists()
        and svg_path.exists()
        and png_path.exists()
    ):
        stamp_path.write_text(MERMAID_RENDER_STAMP + "\n", encoding="utf-8")
    legacy_stamp_path.unlink(missing_ok=True)
    clean_source = "\n".join(line.rstrip() for line in source.strip().splitlines())
    render_source = re.sub(r"(?m)^(\s*(?:flowchart|graph))\s+(?:LR|RL)\b", r"\1 TD", clean_source, count=1)
    valid_stamp = stamp_path.exists() and stamp_path.read_text(encoding="utf-8", errors="replace").strip() == MERMAID_RENDER_STAMP
    if mmd_path.exists() and svg_path.exists() and png_path.exists() and valid_stamp:
        if mmd_path.read_text(encoding="utf-8", errors="replace").strip() == render_source:
            return mmd_path, svg_path, png_path
    current_source = mmd_path.read_text(encoding="utf-8", errors="replace").strip() if mmd_path.exists() else ""
    source_changed = current_source != render_source
    if source_changed:
        mmd_path.write_text(render_source + "\n", encoding="utf-8")
        svg_path.unlink(missing_ok=True)
    png_path.unlink(missing_ok=True)
    stamp_path.unlink(missing_ok=True)
    env = os.environ.copy()
    env.setdefault("PUPPETEER_SKIP_DOWNLOAD", "1")
    chrome = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    if chrome.exists():
        env.setdefault("PUPPETEER_EXECUTABLE_PATH", str(chrome))
    if not svg_path.exists():
        result = subprocess.run(
            mermaid_command(mmd_path, svg_path),
            cwd=root,
            text=True,
            capture_output=True,
            timeout=900,
            env=env,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Mermaid render failed for {mmd_path}: {(result.stderr or result.stdout)[-3000:]}")
    if not png_path.exists():
        result = subprocess.run(
            mermaid_command(mmd_path, png_path),
            cwd=root,
            text=True,
            capture_output=True,
            timeout=900,
            env=env,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Mermaid PNG render failed for {mmd_path}: {(result.stderr or result.stdout)[-3000:]}")
    stamp_path.write_text(MERMAID_RENDER_STAMP + "\n", encoding="utf-8")
    return mmd_path, svg_path, png_path


def replace_mermaid_blocks(root: Path) -> int:
    replacements = 0
    for document in maintained_documents(root):
        if is_external_or_generated_document(root, document):
            continue
        if document.suffix.lower() not in {".md", ".mdx"}:
            continue
        original = document.read_text(encoding="utf-8", errors="replace")

        def replace(match: re.Match[str]) -> str:
            nonlocal replacements
            source = match.group(1).strip()
            digest = hashlib.sha256(source.encode()).hexdigest()[:12]
            _mmd, _svg, png = render_mermaid(root, source, digest)
            relative = os.path.relpath(png, document.parent).replace(os.sep, "/")
            replacements += 1
            return f"![Rendered system diagram]({relative})\n"

        updated = MERMAID_RE.sub(replace, original)
        if updated != original:
            document.write_text(updated.rstrip() + "\n", encoding="utf-8")
    return replacements


def normalize_existing_mermaid_assets(root: Path) -> int:
    normalized = 0
    generated = root / "docs/architecture/generated"
    if not generated.exists():
        return normalized
    for mmd_path in sorted(generated.glob("mermaid-*.mmd")):
        source = mmd_path.read_text(encoding="utf-8", errors="replace").strip()
        clean_source = "\n".join(line.rstrip() for line in source.splitlines())
        vertical = re.sub(r"(?m)^(\s*(?:flowchart|graph))\s+(?:LR|RL)\b", r"\1 TD", clean_source, count=1)
        stamp = mmd_path.with_name(f"{mmd_path.stem}.render.json")
        valid_stamp = stamp.exists() and stamp.read_text(encoding="utf-8", errors="replace").strip() == MERMAID_RENDER_STAMP
        if vertical != source or not valid_stamp:
            digest = mmd_path.stem.removeprefix("mermaid-")
            render_mermaid(root, source, digest)
            normalized += 1
    return normalized


def cleanup_orphaned_mermaid_assets(root: Path) -> int:
    generated = root / "docs/architecture/generated"
    if not generated.exists():
        return 0
    consumers = "\n".join(
        document.read_text(encoding="utf-8", errors="replace")
        for document in maintained_documents(root)
    )
    removed = 0
    for mmd_path in sorted(generated.glob("mermaid-*.mmd")):
        if f"{mmd_path.stem}.png" in consumers:
            continue
        for suffix in (".mmd", ".svg", ".png", ".rendered"):
            candidate = mmd_path.with_suffix(suffix)
            if candidate.exists():
                candidate.unlink()
                removed += 1
        render_metadata = mmd_path.with_name(f"{mmd_path.stem}.render.json")
        if render_metadata.exists():
            render_metadata.unlink()
            removed += 1
    return removed


def repair_image_links(root: Path) -> int:
    repaired = 0
    tracked = git_files(root)
    by_name: dict[str, list[Path]] = {}
    for path in tracked:
        if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"}:
            by_name.setdefault(path.name, []).append(path)
    for document in maintained_documents(root):
        if is_external_or_generated_document(root, document):
            continue
        original = document.read_text(encoding="utf-8", errors="replace")

        def replace(match: re.Match[str]) -> str:
            nonlocal repaired
            reference = next((group for group in match.groups() if group), "")
            if (
                not reference
                or re.match(r"^(?:https?:|data:|#|/)", reference)
                or reference in {"...", ".", "url"}
                or any(character in reference for character in "<>{}")
                or reference.startswith("cid:")
            ):
                return match.group(0)
            clean = reference.split("#", 1)[0]
            if (document.parent / clean).resolve().exists() or (root / clean.lstrip("./")).resolve().exists():
                return match.group(0)
            candidates = [
                root / "docs" / clean.lstrip("./"),
                root / "website/static" / clean.lstrip("./"),
                root / "website/static/img" / clean.lstrip("./"),
            ]
            candidates.extend(by_name.get(Path(clean).name, []))
            existing = sorted({path.resolve() for path in candidates if path.exists()})
            if len(existing) != 1:
                return match.group(0)
            replacement = os.path.relpath(existing[0], document.parent).replace(os.sep, "/")
            repaired += 1
            return match.group(0).replace(reference, replacement, 1)

        updated = IMAGE_RE.sub(replace, original)
        if updated != original:
            document.write_text(updated.rstrip() + "\n", encoding="utf-8")
    return repaired


def choose_overview(root: Path) -> tuple[Path, Path]:
    architecture = root / "docs/architecture"
    architecture.mkdir(parents=True, exist_ok=True)
    candidates = sorted(architecture.glob("*system-architecture.png"))
    if candidates:
        png = candidates[0]
        svg = png.with_suffix(".svg")
        if svg.exists():
            return svg, png
    slug = re.sub(r"[^a-z0-9]+", "-", root.name.lower()).strip("-")
    svg = architecture / f"{slug}-system-architecture.svg"
    png = architecture / f"{slug}-system-architecture.png"
    svg.write_text(overview_svg(repository_name(root), detect_areas(root)), encoding="utf-8")
    render_svg(svg, png)
    return svg, png


def readme_section(root: Path, overview_png: Path) -> str:
    readme = root / "README.md"
    relative = os.path.relpath(overview_png, readme.parent).replace(os.sep, "/")
    areas = detect_areas(root)
    display_name = repository_name(root).split("/")[-1]
    area_summary = ", ".join(areas["implementation"] + areas["operations"])
    return f'''{MARKER_START}

## Current repository state

![{display_name} system architecture]({relative})

- **Default branch:** `{default_branch(root)}`
- **Implementation fingerprint:** `{implementation_fingerprint(root)}`
- **Detected structure:** {area_summary}.
- **Documentation contract:** editable diagram sources, committed PNG renderings,
  resolved local image links, and generated state are checked on every commit.
- **Refresh command:** `python3 scripts/documentation_health.py --write`

See [repository state](docs/REPOSITORY_STATE.md) and the
[architecture asset guide](docs/architecture/README.md).
{MARKER_END}'''


def update_readme(root: Path, overview_png: Path) -> None:
    readme = root / "README.md"
    if not readme.exists():
        readme.write_text(f"# {root.name}\n\n", encoding="utf-8")
    text = readme.read_text(encoding="utf-8", errors="replace").rstrip()
    section = readme_section(root, overview_png)
    if MARKER_START in text and MARKER_END in text:
        text = re.sub(
            re.escape(MARKER_START) + r".*?" + re.escape(MARKER_END),
            section,
            text,
            flags=re.S,
        )
    else:
        text += "\n\n" + section
    readme.write_text(text.rstrip() + "\n", encoding="utf-8")


def write_repository_state(root: Path) -> None:
    areas = detect_areas(root)
    documents = maintained_documents(root)
    diagrams = [
        path
        for path in git_files(root)
        if path.suffix.lower() in {".png", ".svg", ".mmd"} and "architecture" in path.parts
    ]
    lines = [
        "# Repository State",
        "",
        f"Updated: {datetime.now(timezone.utc).date().isoformat()}",
        "",
        "This file is generated from the tracked repository tree. It is committed so",
        "the documentation record advances with implementation changes.",
        "",
        f"- Repository: `{repository_name(root)}`",
        f"- Default branch: `{default_branch(root)}`",
        f"- Implementation fingerprint: `{implementation_fingerprint(root)}`",
        f"- Maintained documents: {len(documents)}",
        f"- Architecture assets: {len(diagrams)}",
        "",
        "## Detected architecture",
        "",
    ]
    for key, title in (
        ("interfaces", "Interfaces"),
        ("implementation", "Implementation"),
        ("state", "State"),
        ("operations", "Operations"),
    ):
        lines.append(f"### {title}")
        lines.append("")
        lines.extend(f"- {item}" for item in areas[key])
        lines.append("")
    lines += [
        "## Update policy",
        "",
        "The documentation-health workflow runs for every push and pull request. On",
        "push it regenerates deterministic documentation and commits drift; on pull",
        "requests it fails when generated documentation or rendered diagrams are stale.",
        "",
    ]
    path = root / "docs/REPOSITORY_STATE.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def write_architecture_guide(root: Path) -> None:
    path = root / "docs/architecture/README.md"
    existing = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    contract = '''<!-- fleet-documentation-contract:start -->

## Rendering contract

PNG files are the viewer-compatible diagrams embedded in repository documents.
Same-basename SVG files are editable sources; converted Mermaid sources are
also retained as `.mmd` files under `generated/`.

Run `python3 scripts/documentation_health.py --write` after architecture or
documentation changes. The per-commit workflow rejects Mermaid-only diagrams,
missing image targets, invalid PNG files, and stale generated repository state.
<!-- fleet-documentation-contract:end -->'''
    if "<!-- fleet-documentation-contract:start -->" in existing:
        existing = re.sub(
            r"<!-- fleet-documentation-contract:start -->.*?<!-- fleet-documentation-contract:end -->",
            contract,
            existing,
            flags=re.S,
        )
    elif existing.strip():
        existing = existing.rstrip() + "\n\n" + contract
    else:
        existing = "# Architecture Assets\n\n" + contract
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(existing.rstrip() + "\n", encoding="utf-8")


def normalize_modified_document_endings(root: Path) -> None:
    result = run(["git", "diff", "--name-only", "-z", "--", "*.md", "*.mdx"], cwd=root)
    for relative in (item for item in result.stdout.split("\0") if item):
        path = root / relative
        if path.exists():
            path.write_text(path.read_text(encoding="utf-8", errors="replace").rstrip() + "\n", encoding="utf-8")


def png_dimensions(path: Path) -> tuple[int, int] | None:
    try:
        data = path.read_bytes()[:24]
    except OSError:
        return None
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", data[16:24])


def verify(root: Path) -> list[Finding]:
    repo = repository_name(root)
    findings: list[Finding] = []
    readme = root / "README.md"
    if not readme.exists():
        findings.append(Finding(repo, "missing-readme", "README.md is missing"))
    else:
        text = readme.read_text(encoding="utf-8", errors="replace")
        if MARKER_START not in text or MARKER_END not in text:
            findings.append(Finding(repo, "missing-state-section", "README lacks generated current-state section"))
        if ".png" not in text:
            findings.append(Finding(repo, "missing-readme-diagram", "README does not embed a PNG diagram"))

    for document in maintained_documents(root):
        text = document.read_text(encoding="utf-8", errors="replace")
        if MERMAID_RE.search(text) and not is_external_or_generated_document(root, document):
            findings.append(Finding(repo, "mermaid-text", f"{document.relative_to(root)} contains unrendered Mermaid"))
        for match in IMAGE_RE.finditer(text):
            if is_external_or_generated_document(root, document):
                continue
            reference = next((group for group in match.groups() if group), "")
            if (
                not reference
                or re.match(r"^(?:https?:|data:|#|/)", reference)
                or reference in {"...", ".", "url"}
                or any(character in reference for character in "<>{}")
                or reference.startswith("cid:")
            ):
                continue
            clean_reference = reference.split("#", 1)[0]
            local_target = (document.parent / clean_reference).resolve()
            root_target = (root / clean_reference.lstrip("./")).resolve()
            if not local_target.exists() and not root_target.exists():
                findings.append(Finding(repo, "missing-image", f"{document.relative_to(root)} -> {reference}"))

    architecture = root / "docs/architecture"
    pngs = sorted(architecture.rglob("*.png")) if architecture.exists() else []
    if not pngs:
        findings.append(Finding(repo, "missing-png", "docs/architecture has no PNG rendering"))
    for png in pngs:
        dimensions = png_dimensions(png)
        if dimensions is None:
            findings.append(Finding(repo, "invalid-png", str(png.relative_to(root))))
            continue
        svg = png.with_suffix(".svg")
        mmd = png.with_suffix(".mmd")
        if not svg.exists() and not mmd.exists():
            findings.append(Finding(repo, "missing-editable-source", str(png.relative_to(root))))
        if png.parent.name == "generated":
            stamp = png.with_name(f"{png.stem}.render.json")
            if not stamp.exists() or stamp.read_text(encoding="utf-8", errors="replace").strip() != MERMAID_RENDER_STAMP:
                findings.append(Finding(repo, "unverified-mermaid-renderer", str(png.relative_to(root))))

    state = root / "docs/REPOSITORY_STATE.md"
    if not state.exists():
        findings.append(Finding(repo, "missing-state", "docs/REPOSITORY_STATE.md is missing"))
    else:
        expected = implementation_fingerprint(root)
        if expected not in state.read_text(encoding="utf-8", errors="replace"):
            findings.append(Finding(repo, "stale-state", f"implementation fingerprint should be {expected}"))
    if not (root / WORKFLOW_RELATIVE_PATH).exists():
        findings.append(Finding(repo, "missing-workflow", str(WORKFLOW_RELATIVE_PATH)))
    if not (root / SCRIPT_RELATIVE_PATH).exists():
        findings.append(Finding(repo, "missing-checker", str(SCRIPT_RELATIVE_PATH)))
    return findings


WORKFLOW = '''name: Documentation health

on:
  push:
    branches:
      - "**"
  pull_request:

permissions:
  contents: write

concurrency:
  group: documentation-health-${{ github.repository }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  documentation-health:
    runs-on: ubuntu-latest
    env:
      REPOSITORY_DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}
    steps:
      - name: Check out repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
      - name: Install SVG renderer
        run: sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends librsvg2-bin
      - name: Refresh generated documentation
        run: python3 scripts/documentation_health.py --write
      - name: Verify documentation and rendered diagrams
        run: python3 scripts/documentation_health.py --check
      - name: Require generated files in pull requests
        if: github.event_name == 'pull_request'
        run: |
          git diff --check
          if git status --porcelain | grep -q .; then
            git status --short
            echo "Generated documentation is stale. Run: python3 scripts/documentation_health.py --write"
            exit 1
          fi
      - name: Commit self-healed documentation
        if: github.event_name == 'push'
        run: |
          if ! git status --porcelain | grep -q .; then
            exit 0
          fi
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add -A
          git commit -m "docs: refresh generated repository state [skip ci]"
          git push
'''


LOCAL_CHECKER_HEADER = '''#!/usr/bin/env python3
"""Repository-local documentation generator and verifier.

Managed by the Boneman_Projects fleet documentation contract.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

'''


def local_checker_source() -> str:
    source = Path(__file__).read_text(encoding="utf-8")
    start = source.index("MAX_PASSES = 3")
    end = source.index("\ndef discover_repositories(")
    body = source[start:end]
    entry = '''

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.write:
        repair_image_links(root)
        replace_mermaid_blocks(root)
        cleanup_orphaned_mermaid_assets(root)
        normalize_existing_mermaid_assets(root)
        _svg, png = choose_overview(root)
        update_readme(root, png)
        write_architecture_guide(root)
        write_repository_state(root)
        normalize_modified_document_endings(root)
    findings = verify(root)
    if findings:
        for finding in findings:
            print(f"{finding.code}: {finding.message}", file=sys.stderr)
        return 1
    print(f"Documentation health passed for {repository_name(root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''
    return LOCAL_CHECKER_HEADER + body + entry


def install_contract(root: Path) -> None:
    checker = root / SCRIPT_RELATIVE_PATH
    checker.parent.mkdir(parents=True, exist_ok=True)
    checker.write_text(local_checker_source(), encoding="utf-8")
    checker.chmod(0o755)
    workflow = root / WORKFLOW_RELATIVE_PATH
    workflow.parent.mkdir(parents=True, exist_ok=True)
    workflow.write_text(WORKFLOW, encoding="utf-8")


def repair(root: Path) -> int:
    install_contract(root)
    repair_image_links(root)
    converted = replace_mermaid_blocks(root)
    cleanup_orphaned_mermaid_assets(root)
    normalize_existing_mermaid_assets(root)
    _svg, png = choose_overview(root)
    update_readme(root, png)
    write_architecture_guide(root)
    write_repository_state(root)
    normalize_modified_document_endings(root)
    return converted



def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.write:
        repair_image_links(root)
        replace_mermaid_blocks(root)
        cleanup_orphaned_mermaid_assets(root)
        normalize_existing_mermaid_assets(root)
        _svg, png = choose_overview(root)
        update_readme(root, png)
        write_architecture_guide(root)
        write_repository_state(root)
        normalize_modified_document_endings(root)
    findings = verify(root)
    if findings:
        for finding in findings:
            print(f"{finding.code}: {finding.message}", file=sys.stderr)
        return 1
    print(f"Documentation health passed for {repository_name(root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
