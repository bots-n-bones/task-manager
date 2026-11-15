begin;
set local role service_role;
do $$
declare p text:='checks/gc-'||gen_random_uuid(); paths jsonb;
begin
 perform file_stage(p);
 assert not(file_cleanup_claim() @> to_jsonb(p));
 update storage_uploads set expires_at=now()-interval '1 minute' where path=p;
 paths:=file_cleanup_claim();
 assert (select state from storage_uploads where path=p)='collecting';
 assert not(paths @> to_jsonb(p));
 begin
   perform file_stage(p);
   raise exception 'Collected upload revived';
 exception when serialization_failure then null; end;
 update storage_uploads set claimed_at=now()-interval '6 minutes' where path=p;
 assert file_cleanup_claim() @> to_jsonb(p);
 perform file_cleanup_done(array[p]);
 assert (select state from storage_uploads where path=p)='deleted';
 assert not(file_cleanup_claim() @> to_jsonb(p));
end $$;
rollback;
