import warnings

warnings.filterwarnings("ignore")

import re
import httpx
from lxml import html
from tqdm.rich import tqdm
from subprocess import run


semver = re.compile(
    r"^((0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\+[0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*)?)/?$"
)


def main():
    build_cmd = "docker build . -t renpy:{renpy_version} --build-arg renpy_version={renpy_version}"
    test_cmd = "docker run --rm -it renpy:{renpy_version} 'renutil launch -v {renpy_version} --headless -d -a \"--help\"'"

    r = httpx.get("https://www.renpy.org/dl/")
    tree = html.fromstring(r.text)
    links = tree.xpath("//a/text()")
    versions = []
    for link in links:
        m = semver.match(link)
        if not m:
            continue
        versions.append(m.group(1))

    versions.sort(reverse=True)

    versions = versions[:2]

    for version in tqdm(versions, desc="Building images", unit="image"):
        tqdm.write(f"Creating image for Ren'Py version {version}")
        cmd = build_cmd.format(renpy_version=version)
        tqdm.write(f"Building with: {cmd}")
        run(cmd, shell=True, check=True)
        cmd = test_cmd.format(renpy_version=version)
        tqdm.write(f"Testing with: {cmd}")
        run(cmd, shell=True, check=True, capture_output=True)
        # TODO: push to docker hub


if __name__ == "__main__":
    main()
