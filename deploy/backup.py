"""Back up the dedicated task-manager database and immutable file volume."""
import datetime
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tarfile

destination = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/opt/team-task-manager/backups")
destination.mkdir(parents=True, exist_ok=True, mode=0o700)
os.umask(0o077)
name = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
staging = destination / (name + ".incomplete")
staging.mkdir()
with (staging / "database.dump").open("wb") as output:
    subprocess.run(["docker", "exec", "deploy-db-1", "pg_dump", "-U", "postgres", "-Fc", "postgres"], stdout=output, check=True)
with (staging / "files.tar").open("wb") as output:
    subprocess.run(["docker", "run", "--rm", "--entrypoint", "tar", "-v", "deploy_files:/files:ro", "nginx:alpine", "-C", "/files", "-cf", "-", "."], stdout=output, check=True)
manifest = {}
for path in staging.iterdir():
    manifest[path.name] = hashlib.file_digest(path.open("rb"), "sha256").hexdigest()
file_hashes = {}
with tarfile.open(staging / "files.tar") as archive:
    for entry in archive.getmembers():
        if entry.isfile():
            with archive.extractfile(entry) as source:
                file_hashes[entry.name] = hashlib.file_digest(source, "sha256").hexdigest()
manifest["file_hashes"] = file_hashes
(staging / "manifest.json").write_text(json.dumps(manifest, indent=2))
final = destination / name
staging.rename(final)
print(final)
