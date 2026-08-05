#!/usr/bin/env python3
"""Kubernetes patch releases upstream has published but we have not built yet.

Golden images are cut per (distro, flavour, arch) and published to quay as

    v<semver>[-doca]-<arch>

so the registry is already the build ledger: a version is built for a given
workflow and distro exactly when both arch tags are present. Diffing that
ledger against dl.k8s.io is enough to decide what a scheduled run should
dispatch, and it keeps no state in the repository that could drift from what
was actually published.

Which minor series are tracked:

  * every series already present in quay. An image line, once started, follows
    its upstream patches by itself; an end-of-life series simply stops moving
    upstream, so it stops producing work without needing to be pruned here.
  * plus the series of the overall stable.txt, so a brand new minor is picked
    up in the release it appears rather than waiting for a human to notice.

Tags carrying a trailing build suffix (-cilium) are deliberately not matched:
they come from a different branch of this repository and are dispatched by
that branch's own schedule, not this one.

A candidate is dropped when the packages the build needs are not published
yet. dl.k8s.io flips to a new version before the apt index and the matching
cri-tools release are necessarily in place, and a build started inside that
window fails deep inside packer instead of at the gate.

Usage:
  pending-kube-builds.py             stdout: JSON array, stderr: human log
  pending-kube-builds.py --quiet     suppress the human log

Output — one object per workflow dispatch that should happen:
  [{"workflow": "main.yaml", "os": "ubuntu", "kube_version": "v1.35.7",
    "missing": ["amd64", "aarch64"]}]

Exit status is non-zero when a lookup fails. Reporting "nothing is built" from
a failed registry query would rebuild every image in the catalogue, so an
incomplete picture must never be mistaken for an empty one.
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.request

QUAY_NAMESPACE = "edgestack"
USER_AGENT = "capi-image-builder-release-watch"
HTTP_TIMEOUT = 60

# Image repository -> the `os` input the build workflows expect.
IMAGE_REPOS = (
    ("ubuntu-2404-kube", "ubuntu"),
    ("rocky-9-uefi-kube", "rocky"),
)

# Tag flavour suffix -> the workflow file that produces it. Declaration order is
# dispatch order, so the plain image of a version lands before its DOCA variant.
FLAVOURS = (
    ("", "main.yaml"),
    ("-doca", "doca_image.yaml"),
)
WORKFLOW_ORDER = {workflow: index for index, (_flavour, workflow) in enumerate(FLAVOURS)}

# Both must exist before a version counts as built. The workflows build them in
# one dispatch (one job per arch), so a half-published version is re-dispatched
# whole; re-pushing the arch that already succeeded is idempotent.
ARCHES = ("amd64", "aarch64")

TAG_RE = re.compile(
    r"^v(?P<version>\d+\.\d+\.\d+)(?P<flavour>-doca)?-(?P<arch>amd64|aarch64)$"
)
SEMVER_RE = re.compile(r"^v\d+\.\d+\.\d+$")


def log(message):
    print(message, file=sys.stderr)


def http_get(url):
    """Fetch a URL as text. Returns None on 404, raises on anything else."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            return response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def quay_tags(repo):
    """Every active tag in a quay repository.

    Paginated deliberately: the signature/SBOM/attestation sidecars
    (sha256-....sig and friends) outnumber the version tags several times over,
    so a single page is nowhere near the whole ledger.
    """
    tags = set()
    page = 1
    while True:
        url = (
            "https://quay.io/api/v1/repository/"
            "{ns}/{repo}/tag/?onlyActiveTags=true&limit=100&page={page}".format(
                ns=QUAY_NAMESPACE, repo=repo, page=page
            )
        )
        body = http_get(url)
        if body is None:
            raise RuntimeError("quay repository not found: {}".format(repo))
        payload = json.loads(body)
        for tag in payload.get("tags", []):
            tags.add(tag["name"])
        if not payload.get("has_additional"):
            return tags
        page += 1
        if page > 200:
            raise RuntimeError("quay pagination did not terminate for {}".format(repo))


def index_tags(tags):
    """(flavour, version) -> set of built arches, plus the series seen."""
    built = {}
    series = set()
    for tag in tags:
        match = TAG_RE.match(tag)
        if not match:
            continue
        version = match.group("version")
        flavour = match.group("flavour") or ""
        built.setdefault((flavour, version), set()).add(match.group("arch"))
        series.add(version.rsplit(".", 1)[0])
    return built, series


def series_of(version):
    return version.lstrip("v").rsplit(".", 1)[0]


def sort_key(version):
    return tuple(int(part) for part in version.lstrip("v").split("."))


def upstream_stable(series=None):
    """Latest patch of a series, or the overall latest when series is None."""
    url = "https://dl.k8s.io/release/stable{suffix}.txt".format(
        suffix="" if series is None else "-" + series
    )
    body = http_get(url)
    if body is None:
        return None
    body = body.strip()
    # A missing marker is served as an XML error document rather than a 404, so
    # the shape of the answer is what decides whether it is one.
    return body if SEMVER_RE.match(body) else None


def deb_published(series, version):
    """Is the kubeadm deb for this exact patch in the pkgs.k8s.io index?

    The build workflows resolve the deb revision from this same index, and fall
    back to a guessed `-1.1` when they cannot find one. Checking here keeps that
    fallback from quietly installing the wrong patch.
    """
    index = http_get(
        "https://pkgs.k8s.io/core:/stable:/v{series}/deb/Packages".format(series=series)
    )
    if index is None:
        return False
    return re.search(r"^Version: {}-".format(re.escape(version)), index, re.M) is not None


def crictl_published(series):
    """Is cri-tools v<series>.0 released?

    Every build pins crictl to <minor>.0, so for a brand new minor this is the
    gate that matters: kubernetes ships before cri-tools does.
    """
    url = (
        "https://github.com/kubernetes-sigs/cri-tools/releases/download/"
        "v{series}.0/crictl-v{series}.0-linux-amd64.tar.gz.sha256".format(series=series)
    )
    return http_get(url) is not None


def resolve_targets(series_set):
    """series -> latest upstream patch, dropping anything not ready to build."""
    targets = {}
    for series in sorted(series_set, key=lambda s: tuple(int(p) for p in s.split("."))):
        version = upstream_stable(series)
        if version is None:
            log("skip  v{}: upstream publishes no stable marker".format(series))
            continue
        if not deb_published(series, version.lstrip("v")):
            log("skip  {}: not in the pkgs.k8s.io deb index yet".format(version))
            continue
        if not crictl_published(series):
            log("skip  {}: cri-tools v{}.0 is not released yet".format(version, series))
            continue
        targets[series] = version
        log("track {}: latest patch of v{}".format(version, series))
    return targets


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--quiet", action="store_true", help="suppress the human-readable log on stderr"
    )
    args = parser.parse_args()
    if args.quiet:
        global log
        log = lambda _message: None  # noqa: E731 - deliberate no-op sink

    ledgers = []
    series_set = set()
    for repo, os_input in IMAGE_REPOS:
        built, series = index_tags(quay_tags(repo))
        ledgers.append((repo, os_input, built))
        series_set |= series
        log("quay  {}: {} built (distro, flavour, version) combinations".format(repo, len(built)))

    if not series_set:
        raise RuntimeError("no version tags found in quay - refusing to treat that as 'nothing built'")

    latest = upstream_stable()
    if latest is not None and series_of(latest) not in series_set:
        log("new   v{}: minor series not built before".format(series_of(latest)))
        series_set.add(series_of(latest))

    targets = resolve_targets(series_set)

    pending = []
    for repo, os_input, built in ledgers:
        for flavour, workflow in FLAVOURS:
            for version in targets.values():
                have = built.get((flavour, version.lstrip("v")), set())
                missing = [arch for arch in ARCHES if arch not in have]
                if not missing:
                    continue
                pending.append(
                    {
                        "workflow": workflow,
                        "os": os_input,
                        "kube_version": version,
                        "missing": missing,
                    }
                )

    # Newest first, vanilla before doca: the runners are one per arch, so the
    # dispatch order is the order the queue drains in.
    pending.sort(
        key=lambda item: (
            [-part for part in sort_key(item["kube_version"])],
            WORKFLOW_ORDER[item["workflow"]],
            item["os"],
        )
    )

    for item in pending:
        log(
            "build {version} {os} via {workflow} (missing: {missing})".format(
                version=item["kube_version"],
                os=item["os"],
                workflow=item["workflow"],
                missing=", ".join(item["missing"]),
            )
        )
    log("{} dispatch(es) pending".format(len(pending)))

    json.dump(pending, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - the message is the whole point
        print("pending-kube-builds: {}".format(error), file=sys.stderr)
        sys.exit(1)
