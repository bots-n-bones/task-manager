"""Restore a backup into a disposable database and verify application integrity."""
import hashlib
import json
import pathlib
import subprocess
import sys
import uuid
import tarfile
import tempfile
import time

started = time.monotonic()
backup = pathlib.Path(sys.argv[1]).resolve()
manifest = json.loads((backup / "manifest.json").read_text())
for name in ["database.dump", "files.tar"]:
    with (backup / name).open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != manifest[name]:
            raise ValueError("Backup checksum mismatch")
database = "task_restore_" + uuid.uuid4().hex
archive = "/tmp/" + database + ".dump"
def run(*args):
    return subprocess.run(["docker", "exec", "deploy-db-1", *args], check=True, capture_output=True, text=True).stdout
try:
    subprocess.run(["docker", "cp", str(backup / "database.dump"), "deploy-db-1:" + archive], check=True)
    run("createdb", "-U", "postgres", "-T", "template0", database)
    run("pg_restore", "-U", "postgres", "-d", database, "--exit-on-error", archive)
    count = run("psql", "-U", "postgres", "-d", database, "-At", "-v", "ON_ERROR_STOP=1", "-c",
        "select count(*) from public.tasks; select count(*) from public.users; select count(*) from auth.users; select count(*) from storage.objects;")
    run("psql", "-U", "postgres", "-d", database, "-v", "ON_ERROR_STOP=1", "-c",
        "do $$ begin if exists(select 1 from public.task_attachments a left join public.task_results r on r.id=a.result_id where r.id is null) then raise exception 'Broken attachment'; end if; end $$;")
    restored_files = 0
    with tempfile.TemporaryDirectory(prefix="task-files-restore-") as directory:
        root = pathlib.Path(directory)
        with tarfile.open(backup / "files.tar") as files:
            expected = manifest.get("file_hashes")
            if expected is None:
                expected = {}
                for entry in files.getmembers():
                    if entry.isfile():
                        with files.extractfile(entry) as source:
                            expected[entry.name] = hashlib.file_digest(source, "sha256").hexdigest()
            files.extractall(root, filter="data")
        for name, digest in expected.items():
            restored = root / name
            if not restored.resolve().is_relative_to(root):
                raise ValueError("Unsafe backup path")
            with restored.open("rb") as source:
                if hashlib.file_digest(source, "sha256").hexdigest() != digest:
                    raise ValueError("Restored file content mismatch")
            restored_files += 1
    (backup / "restore-verified.json").write_text(json.dumps({"verified": True, "row_counts": count.splitlines(), "restored_files": restored_files, "elapsed_seconds": round(time.monotonic()-started, 2)}, indent=2))
    print(f"Backup restored successfully; {restored_files} file contents verified")
finally:
    subprocess.run(["docker", "exec", "deploy-db-1", "dropdb", "-U", "postgres", "--if-exists", database], check=True)
    subprocess.run(["docker", "exec", "deploy-db-1", "rm", "-f", archive], check=True)
