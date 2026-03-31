"""Add a repo source."""

from scripts import output, git_ops
from scripts.manifest import Manifest


def run_add_repo(ctx, manifest: Manifest, args) -> None:
    name = args.name
    url = args.url
    branch = getattr(args, "branch", "main") or "main"

    if manifest.has_repo(name):
        output.warn(f"Repo '{name}' already exists in manifest")
        return

    manifest.add_repo(name, url, branch)
    dest = ctx.repos_dir / manifest.repo_to_dir(name)

    print(f"Cloning {name} from {url} (sparse)...")
    git_ops.clone_sparse(url, dest, branch)
    output.success(f"Done. Run 'scan' to discover and install skills from this repo.")
