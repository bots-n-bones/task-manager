"""Remove only the disposable profiles recorded by check-http.mjs."""
import json
import pathlib
import re
import subprocess
import sys

log = pathlib.Path(sys.argv[1] if len(sys.argv)>1 else "/opt/team-task-manager/deploy/http-check.log").read_text()
record = next(line[8:] for line in log.splitlines() if line.startswith("CLEANUP "))
profiles = json.loads(record)
ids = [entry["id"] for entry in profiles]
if not ids or any(not re.fullmatch(r"[a-f0-9-]{36}", value) for value in ids):
    raise ValueError("Invalid disposable profile manifest")
selection = ",".join("'" + value + "'" for value in ids)
task_filter = f"task_id in (select id from public.tasks where author_id in ({selection}))"
sql = "begin;\n"
for table in ["notification_deliveries", "task_events", "task_reviews", "task_attachments", "task_results", "task_assignees", "task_admins"]:
    sql += f"delete from public.{table} where {task_filter};\n"
sql += f"delete from public.web_requests where user_id in ({selection});\n"
sql += f"delete from public.tasks where author_id in ({selection});\n"
for table in ["web_sessions", "bot_sessions", "telegram_link_codes", "project_admins"]:
    sql += f"delete from public.{table} where user_id in ({selection});\n"
for value in ids:
    sql += f"delete from public.storage_uploads where path like '{value}/%';\n"
sql += f"delete from public.users where id in ({selection});\n"
for entry in profiles:
    auth = entry.get("authId")
    if auth:
        if not re.fullmatch(r"[a-f0-9-]{36}", auth):
            raise ValueError("Invalid disposable Auth ID")
        sql += f"delete from auth.users where id='{auth}';\n"
sql += "commit;"
subprocess.run(["docker", "exec", "-i", "deploy-db-1", "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres"], input=sql, text=True, check=True)
print("Disposable HTTP verification profiles and tasks removed")
