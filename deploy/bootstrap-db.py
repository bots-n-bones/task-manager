"""Initialize roles in the dedicated application database container."""
import pathlib
import subprocess
env = dict(line.split("=", 1) for line in pathlib.Path(__file__).with_name(".env.production").read_text().splitlines() if "=" in line)
password = env["POSTGRES_PASSWORD"]
if not all(c in "0123456789abcdef" for c in password):
    raise ValueError("Expected generated hexadecimal database password")
roles = ["postgres", "anon", "authenticated", "authenticator", "dashboard_user", "service_role", "supabase_auth_admin", "supabase_storage_admin", "supabase_etl_admin", "supabase_functions_admin", "supabase_privileged_role", "supabase_read_only_user", "supabase_replication_admin"]
sql = "begin;\n"
for role in roles:
    sql += f"do $$ begin if not exists(select 1 from pg_roles where rolname='{role}') then create role {role}; end if; end $$;\n"
sql += f"alter role postgres with login superuser password '{password}';\n"
for role in ["authenticator", "supabase_auth_admin", "supabase_storage_admin"]:
    sql += f"alter role {role} with login password '{password}';\n"
sql += "alter role supabase_auth_admin set search_path=auth,public,extensions; alter role supabase_storage_admin set search_path=storage,public,extensions;\nalter role service_role bypassrls; grant anon, authenticated, service_role to authenticator; grant anon, authenticated, service_role to supabase_storage_admin;\ncommit;\n"
subprocess.run(["docker", "exec", "-i", "deploy-db-1", "psql", "-U", "supabase_admin", "-d", "postgres", "-v", "ON_ERROR_STOP=1"], input=sql, text=True, check=True, stdout=subprocess.DEVNULL)
print("Dedicated database roles initialized")
