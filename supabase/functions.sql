-- 自動匯出：Supabase public schema 的全部函式（2026-11-23，報名必須上傳證件）

CREATE OR REPLACE FUNCTION public.admin_actor(p_token text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select a.username from public.admin_sessions s join public.admins a on a.id = s.admin_id
  where s.token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex') and s.expires_at > now();
$function$
;

CREATE OR REPLACE FUNCTION public.admin_add_attendance(p_token text, p_event uuid, p_national_id text, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_pid uuid; v_id uuid;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select id into v_pid from public.people where national_id = upper(btrim(coalesce(p_national_id,'')));
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'no_person'); end if;
  if p_date is null then return jsonb_build_object('ok', false, 'error', 'bad_value'); end if;
  if exists (select 1 from public.attendance where person_id = v_pid and event_id = p_event and work_date = p_date) then
    return jsonb_build_object('ok', false, 'error', 'exists');
  end if;
  insert into public.attendance(person_id, event_id, work_date, source, note) values (v_pid, p_event, p_date, 'manual', '管理員補登') returning id into v_id;
  insert into public.audit_log(actor, action, table_name, row_id) values (v_actor, 'attendance_added', 'attendance', v_id);
  return jsonb_build_object('ok', true, 'id', v_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_approve_attendance(p_token text, p_id uuid, p_kind text, p_on boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_kind = 'early' then
    update public.attendance set early_approved_by = case when p_on then v_actor end, early_approved_at = case when p_on then now() end where id = p_id;
  elsif p_kind = 'overtime' then
    update public.attendance set ot_approved_by = case when p_on then v_actor end, ot_approved_at = case when p_on then now() end where id = p_id;
  else return jsonb_build_object('ok', false, 'error', 'bad_kind'); end if;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'attendance_' || p_kind || case when p_on then '_approved' else '_unapproved' end, 'attendance', p_id, null);
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_archive_event(p_token text, p_event uuid, p_archived boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 封存只影響後台顯示：活動、薪資單、工讀生端都不變，可隨時取消封存
declare v_actor text := public.admin_actor(p_token); e public.events;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into e from public.events where id = p_event for update;
  if e.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if coalesce(p_archived, false) then
    if e.archived_at is null then
      update public.events set archived_at = now(), archived_by = v_actor where id = e.id;
      update public.checkin_shares set revoked_at = now(), revoked_by = v_actor where event_id = e.id and revoked_at is null;
      insert into public.audit_log(actor, action, table_name, row_id) values (v_actor, 'event_archived', 'events', e.id);
    end if;
  else
    if e.archived_at is not null then
      update public.events set archived_at = null, archived_by = null where id = e.id;
      insert into public.audit_log(actor, action, table_name, row_id) values (v_actor, 'event_unarchived', 'events', e.id);
    end if;
  end if;
  return jsonb_build_object('ok', true, 'archived', coalesce(p_archived, false));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_attendance(p_token text, p_event uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return jsonb_build_object('ok', true,
    'settings', (select jsonb_build_object('default_break_minutes', default_break_minutes, 'default_hourly_rate', default_hourly_rate, 'insured_salary', insured_salary) from public.events where id = p_event),
    'default_break_minutes', (select default_break_minutes from public.events where id = p_event),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'person_id', a.person_id, 'name', p.name, 'work_date', a.work_date,
      'clock_in', to_char(a.clock_in at time zone 'Asia/Taipei', 'YYYY-MM-DD"T"HH24:MI'),
      'clock_out', to_char(a.clock_out at time zone 'Asia/Taipei', 'YYYY-MM-DD"T"HH24:MI'),
      'break_minutes', a.break_minutes, 'source', a.source, 'scheduled_text', a.scheduled_text, 'note', a.note,
      'sched_in', to_char(a.sched_in at time zone 'Asia/Taipei', 'YYYY-MM-DD"T"HH24:MI'), 'sched_out', to_char(a.sched_out at time zone 'Asia/Taipei', 'YYYY-MM-DD"T"HH24:MI'),
      'in_notice', a.in_notice, 'in_notice_minutes', a.in_notice_minutes, 'in_notice_text', a.in_notice_text,
      'out_notice', a.out_notice, 'out_notice_minutes', a.out_notice_minutes, 'out_notice_text', a.out_notice_text,
      'early_approved', a.early_approved_at is not null, 'ot_approved', a.ot_approved_at is not null,
      'minutes', public.att_minutes(a),
      'holiday', (select h.name from public.holidays h where h.day = a.work_date),
      'staff', (select jsonb_build_object('role', s.role, 'relation', s.relation, 'pay_type', s.pay_type, 'rate', s.rate, 'insured_salary', s.insured_salary, 'deduct_insurance', s.deduct_insurance)
                from public.event_staff s where s.event_id = a.event_id and s.person_id = a.person_id))
      order by a.work_date desc, p.name)
      from public.attendance a join public.people p on p.id = a.person_id where a.event_id = p_event), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_calendar(p_token text, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then return jsonb_build_object('ok', false, 'error', 'bad_range'); end if;
  return jsonb_build_object('ok', true,
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'start_date', e.start_date, 'end_date', coalesce(e.end_date, e.start_date),
        'location', e.location, 'has_shifts', exists (select 1 from public.shifts s where s.event_id = e.id)) order by e.start_date, e.name)
      from public.events e where e.start_date is not null and e.start_date <= p_to and coalesce(e.end_date, e.start_date) >= p_from), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(public.shift_json(s) || jsonb_build_object('event_id', s.event_id,
        'names', coalesce((select jsonb_agg(p.name order by p.name) from public.application_shifts x join public.applications a on a.id = x.application_id
          join public.people p on p.id = a.person_id where x.shift_id = s.id and x.status = 'accepted' and a.status = 'active'), '[]'::jsonb))
        order by s.work_date, s.start_time)
      from public.shifts s where s.work_date between p_from and p_to), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_change_password(p_token text, p_old text, p_new text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v public.admins;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into v from public.admins where username = v_actor for update;
  if v.password_hash <> extensions.crypt(coalesce(p_old,''), v.password_hash) then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
  if length(coalesce(p_new,'')) < 8 then return jsonb_build_object('ok', false, 'error', 'too_short'); end if;
  update public.admins set password_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)) where id = v.id;
  delete from public.admin_sessions where admin_id = v.id and token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex');
  insert into public.audit_log(actor, action, table_name) values (v_actor, 'admin_password_changed', 'admins');
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_checkin_code(p_token text, p_event uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_code text;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  v_code := public.checkin_make_code(p_event, floor(extract(epoch from now()) / 60)::bigint);
  if v_code is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'code', v_code, 'refresh_in', 60 - floor(extract(epoch from now()))::bigint % 60);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_contract(p_token text, p_app uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); a public.applications;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into a from public.applications where id = p_app;
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'accepted_at', a.contract_accepted_at, 'text', coalesce(a.contract_text, public.payroll_contract_text(a.id)));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_create_admin(p_token text, p_username text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_user text := lower(btrim(coalesce(p_username,'')));
begin
  perform pg_advisory_xact_lock(hashtext('admin_roster'));
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if v_user !~ '^[a-z0-9._@-]{3,60}$' then return jsonb_build_object('ok', false, 'error', 'bad_username'); end if;
  if length(coalesce(p_password,'')) < 8 then return jsonb_build_object('ok', false, 'error', 'too_short'); end if;
  if exists (select 1 from public.admins where username = v_user) then return jsonb_build_object('ok', false, 'error', 'taken'); end if;
  insert into public.admins(username, password_hash) values (v_user, extensions.crypt(p_password, extensions.gen_salt('bf', 10)));
  insert into public.audit_log(actor, action, table_name, detail) values (v_actor, 'admin_created', 'admins', jsonb_build_object('username', v_user));
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_create_event(p_token text, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_id uuid; v_s date; v_e date; v_pay date; v_days int;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if length(btrim(coalesce(p_patch->>'name',''))) < 2 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  begin
    v_s := (p_patch->>'start_date')::date; v_e := coalesce(nullif(p_patch->>'end_date','')::date, v_s);
  exception when others then return jsonb_build_object('ok', false, 'error', 'bad_date'); end;
  if v_s is null or v_e < v_s then return jsonb_build_object('ok', false, 'error', 'bad_date'); end if;
  begin
    v_pay := nullif(p_patch->>'pay_date','')::date; v_days := nullif(p_patch->>'pay_within_days','')::int;
  exception when others then return jsonb_build_object('ok', false, 'error', 'bad_pay'); end;
  if v_pay is not null and v_pay < v_e then return jsonb_build_object('ok', false, 'error', 'pay_before_end'); end if;
  if v_days is not null and (v_days < 0 or v_days > 90) then return jsonb_build_object('ok', false, 'error', 'bad_pay'); end if;
  if v_pay is not null then v_days := null; end if;
  insert into public.events(employer_id, name, start_date, end_date, pay_date, pay_within_days, default_break_minutes)
  select id, btrim(p_patch->>'name'), v_s, v_e, v_pay, v_days, coalesce(nullif(p_patch->>'default_break_minutes','')::int, 0)
  from public.employers order by created_at limit 1 returning id into v_id;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'event_created', 'events', v_id, p_patch);
  return jsonb_build_object('ok', true, 'id', v_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_decide(p_token text, p_items jsonb, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); it jsonb; v_app uuid; v_shift uuid; a public.applications; s public.shifts; v_done int := 0;
  full_list jsonb := '[]'::jsonb; clash_list jsonb := '[]'::jsonb; v_old text; plan_list jsonb := '[]'::jsonb;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_status not in ('applied','accepted','waitlist','rejected') then return jsonb_build_object('ok', false, 'error', 'bad_status'); end if;
  for it in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) order by value->>'app', value->>'shift' loop
    v_app := (it->>'app')::uuid; v_shift := (it->>'shift')::uuid;
    select * into a from public.applications where id = v_app for update;
    if a.id is null then continue; end if;
    select * into s from public.shifts where id = v_shift and event_id = a.event_id for update;
    if s.id is null then continue; end if;
    perform 1 from public.people where id = a.person_id for update;
    select status into v_old from public.application_shifts where application_id = v_app and shift_id = v_shift for update;
    if v_old is null or v_old = p_status then continue; end if;
    -- 方案報名：整組錄取只能走 admin_decide_plan（它會設 payroll.plan_decide）；名單制不分方案
    if p_status = 'accepted' and a.plan_id is not null and coalesce(current_setting('payroll.plan_decide', true), '') <> '1' and public.recruit_mode() <> 'pool' then
      plan_list := plan_list || to_jsonb((select name from public.people where id = a.person_id)); continue;
    end if;
    if p_status = 'accepted' and (select count(*) from public.application_shifts x join public.applications ax on ax.id = x.application_id
        where x.shift_id = v_shift and x.status = 'accepted' and ax.status = 'active') >= s.headcount then
      full_list := full_list || to_jsonb(to_char(s.work_date, 'MM/DD') || ' ' || coalesce(s.role, '')); continue;
    end if;
    if p_status = 'accepted' and exists (select 1 from public.application_shifts x2 join public.applications a2 on a2.id = x2.application_id join public.shifts s2 on s2.id = x2.shift_id
        where a2.person_id = a.person_id and a2.status = 'active' and x2.status = 'accepted' and s2.id <> s.id and s2.work_date between s.work_date - 1 and s.work_date + 1
          and (s2.work_date + s2.start_time, s2.work_date + s2.end_time + case when s2.end_time <= s2.start_time then interval '1 day' else interval '0' end)
              overlaps (s.work_date + s.start_time, s.work_date + s.end_time + case when s.end_time <= s.start_time then interval '1 day' else interval '0' end)) then
      clash_list := clash_list || to_jsonb(to_char(s.work_date, 'MM/DD') || ' ' || to_char(s.start_time, 'HH24:MI') || ' ' || coalesce(s.role, '')); continue;
    end if;
    update public.application_shifts set status = p_status, decided_at = now() where application_id = v_app and shift_id = v_shift;
    if p_status = 'accepted' then
      insert into public.event_staff(event_id, person_id, role) values (a.event_id, a.person_id, s.role)
      on conflict (event_id, person_id) do update set role = coalesce(public.event_staff.role, excluded.role);
    end if;
    if p_status = 'accepted' or v_old = 'accepted' then perform public.contract_recheck_app(v_app); end if;
    insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'shift_' || p_status, 'application_shifts', v_app, jsonb_build_object('shift', v_shift));
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('ok', true, 'updated', v_done, 'full', full_list, 'clash', clash_list, 'plan', plan_list);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_delete_shift(p_token text, p_shift uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if exists (select 1 from public.application_shifts where shift_id = p_shift and status = 'accepted') then return jsonb_build_object('ok', false, 'error', 'has_accepted'); end if;
  delete from public.shifts where id = p_shift;
  insert into public.audit_log(actor, action, table_name, row_id) values (v_actor, 'shift_deleted', 'shifts', p_shift);
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_event(p_token text, p_event uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return jsonb_build_object('ok', true,
    'event_issues', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'severity', i.severity, 'code', i.code, 'detail', i.detail, 'resolved', i.resolved) order by i.id)
        from public.data_issues i where i.event_id = p_event and i.payslip_id is null and i.person_id is null), '[]'::jsonb),
    'payslips', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'person_id', s.person_id, 'name', p.name, 'national_id', p.national_id, 'role', s.role, 'relation', s.relation,
        'basis', s.basis, 'period_start', s.period_start, 'period_end', s.period_end, 'pay_date', s.pay_date,
        'gross', s.gross, 'allowances', s.allowances, 'deductions', s.deductions, 'net', s.net, 'status', s.status,
        'pay_bank_code', s.pay_bank_code, 'pay_bank_branch', s.pay_bank_branch, 'pay_account_name', s.pay_account_name, 'pay_account', s.pay_account,
        'pay_method', s.pay_method, 'cash_paid_at', s.cash_paid_at, 'cash_paid_by', s.cash_paid_by,
        'missing', public.person_incomplete_text(p.id), 'phone', p.phone, 'has_line', p.line_user_id is not null, 'has_password', p.password_hash is not null,
        'issues', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'severity', i.severity, 'code', i.code, 'detail', i.detail, 'resolved', i.resolved) order by i.id)
            from public.data_issues i where i.payslip_id = s.id or (i.payslip_id is null and i.person_id = s.person_id and (i.event_id is null or i.event_id = s.event_id))), '[]'::jsonb)
      ) order by s.source_row nulls last, p.name)
      from public.payslips s join public.people p on p.id = s.person_id where s.event_id = p_event), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_event_staff(p_token text, p_event uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return jsonb_build_object('ok', true,
    'signup_open', (select coalesce(end_date, start_date) >= v_today - 1 from public.events where id = p_event),
    'has_shifts', exists (select 1 from public.shifts where event_id = p_event),
    'staff', coalesce((select jsonb_agg(jsonb_build_object(
      'person_id', p.id, 'name', p.name, 'national_id', p.national_id, 'phone', p.phone, 'source', p.profile_source,
      'staff', (select jsonb_build_object('role', s.role, 'relation', s.relation, 'pay_type', s.pay_type, 'rate', s.rate, 'insured_salary', s.insured_salary, 'deduct_insurance', s.deduct_insurance)
                from public.event_staff s where s.event_id = p_event and s.person_id = p.id),
      'days', (select count(*) from public.attendance a where a.event_id = p_event and a.person_id = p.id),
      'open', (select count(*) from public.attendance a where a.event_id = p_event and a.person_id = p.id and a.clock_in is not null and a.clock_out is null),
      'docs', (select count(*) from public.people_documents d where d.person_id = p.id and d.kind <> 'photo'),
      'has_bank', p.bank_account is not null,
      'accepted_shifts', (select count(*) from public.application_shifts x join public.applications ap on ap.id = x.application_id where ap.event_id = p_event and ap.person_id = p.id and x.status = 'accepted'),
      'today_shift', (select to_char(sh.start_time, 'HH24:MI') || '–' || to_char(sh.end_time, 'HH24:MI') from public.application_shifts x join public.applications ap on ap.id = x.application_id
                      join public.shifts sh on sh.id = x.shift_id where ap.event_id = p_event and ap.person_id = p.id and x.status = 'accepted' and sh.work_date = v_today order by sh.start_time limit 1),
      'contract', (select ap.contract_accepted_at from public.applications ap where ap.event_id = p_event and ap.person_id = p.id),
      'slip', (select jsonb_build_object('id', s.id, 'status', s.status, 'relation', s.relation, 'role', s.role, 'net', s.net)
               from public.payslips s where s.event_id = p_event and s.person_id = p.id and s.status <> 'void' order by s.generated desc limit 1)
      ) order by p.name)
      from public.people p
      where p.id in (select person_id from public.event_staff where event_id = p_event
                     union select person_id from public.attendance where event_id = p_event
                     union select person_id from public.payslips where event_id = p_event and status <> 'void')), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_generate_payslips(p_token text, p_event uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); e public.events; pr record; g jsonb;
  v_created int := 0; v_replaced int := 0; skipped jsonb := '[]'::jsonb;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into e from public.events where id = p_event for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  for pr in select distinct p.id, p.name
            from public.attendance a join public.people p on p.id = a.person_id
            where a.event_id = p_event and a.source in ('qr','manual') order by p.name loop
    g := public.payslip_regenerate(p_event, pr.id);
    if g->>'result' = 'created' then v_created := v_created + 1;
    elsif g->>'result' = 'replaced' then v_replaced := v_replaced + 1;
    else skipped := skipped || jsonb_build_object('name', pr.name, 'reason', g->>'reason'); end if;
  end loop;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'payslips_generated', 'events', p_event, jsonb_build_object('created', v_created, 'replaced', v_replaced, 'skipped', skipped));
  return jsonb_build_object('ok', true, 'created', v_created, 'replaced', v_replaced, 'skipped', skipped);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_recompute_payslip(p_token text, p_event uuid, p_person uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 核對時改完某人的出勤後，只重算這個人的薪資單草稿
declare v_actor text := public.admin_actor(p_token); g jsonb;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  perform 1 from public.events where id = p_event for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  g := public.payslip_regenerate(p_event, p_person);
  if g->>'result' = 'skipped' then return jsonb_build_object('ok', false, 'error', 'skipped', 'reason', g->>'reason'); end if;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'payslip_recomputed', 'payslips', (g->>'id')::uuid, jsonb_build_object('event', p_event, 'person', p_person, 'gross', g->'gross', 'net', g->'net'));
  return jsonb_build_object('ok', true, 'id', g->>'id', 'gross', g->'gross', 'net', g->'net');
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_holidays(p_token text, p_set jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_set is not null then
    begin
      if nullif(btrim(coalesce(p_set->>'name','')),'') is null then delete from public.holidays where day = (p_set->>'day')::date;
      else insert into public.holidays(day, name) values ((p_set->>'day')::date, btrim(p_set->>'name')) on conflict (day) do update set name = excluded.name; end if;
    exception when others then return jsonb_build_object('ok', false, 'error', 'bad_value'); end;
    insert into public.audit_log(actor, action, table_name, detail) values (v_actor, 'holiday_changed', 'holidays', p_set);
  end if;
  return jsonb_build_object('ok', true, 'holidays', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'name', name) order by day) from public.holidays where day >= current_date - 30), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_line_overview(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  -- 只算 LINE（LINE 每月額度）；Email 另外統計
  return jsonb_build_object('ok', true, 'basic_id', public.setting('line_basic_id'), 'enabled', coalesce(public.setting('line_enabled'), 'true') = 'true',
    'linked', (select count(*) from public.people where line_user_id is not null), 'people', (select count(*) from public.people),
    'pending', (select count(*) from public.notifications where status = 'pending' and channel = 'line'),
    'month', (select jsonb_build_object('sent', count(*) filter (where status = 'sent'), 'skipped', count(*) filter (where status = 'skipped'), 'failed', count(*) filter (where status = 'failed'))
              from public.notifications where channel = 'line' and created_at >= date_trunc('month', now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei'),
    'mail_month', (select count(*) from public.notifications where channel = 'mail' and status = 'sent' and created_at >= date_trunc('month', now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei'),
    'recent', coalesce((select jsonb_agg(x) from (select jsonb_build_object('kind', n.kind, 'name', p.name, 'event', e.name, 'status', n.status, 'error', n.error,
        'at', coalesce(n.sent_at, n.created_at), 'body', n.body, 'channel', n.channel) x
      from public.notifications n join public.people p on p.id = n.person_id left join public.events e on e.id = n.event_id order by n.created_at desc limit 40) t), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_line_settings(p_token text, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_id text;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_patch ? 'basic_id' then
    v_id := lower(btrim(coalesce(p_patch->>'basic_id', '')));
    if v_id <> '' and left(v_id, 1) <> '@' then v_id := '@' || v_id; end if;
    if v_id <> '' and v_id !~ '^@[a-z0-9._-]{3,30}$' then return jsonb_build_object('ok', false, 'error', 'bad_basic_id'); end if;
    update public.app_settings set value = nullif(v_id, '') where key = 'line_basic_id';
  end if;
  if p_patch ? 'enabled' then update public.app_settings set value = case when (p_patch->>'enabled')::boolean then 'true' else 'false' end where key = 'line_enabled'; end if;
  insert into public.audit_log(actor, action, table_name, detail) values (v_actor, 'line_settings', 'app_settings', p_patch);
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_line_test(p_token text, p_national_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); p public.people;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into p from public.people where national_id = upper(btrim(coalesce(p_national_id, '')));
  if p.id is null then return jsonb_build_object('ok', false, 'error', 'no_person'); end if;
  if p.line_user_id is null then return jsonb_build_object('ok', false, 'error', 'not_linked'); end if;
  insert into public.notifications(person_id, kind, body) values (p.id, 'test', '【沃克思】這是測試訊息，收到代表 LINE 通知已設定完成。');
  return jsonb_build_object('ok', true, 'name', p.name);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_list_admins(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return jsonb_build_object('ok', true, 'me', v_actor, 'admins', coalesce((select jsonb_agg(jsonb_build_object('username', a.username, 'created_at', a.created_at,
      'is_self', a.username = v_actor, 'locked', a.locked_until is not null and a.locked_until > now(),
      'last_login', (select max(l.at) from public.audit_log l where l.actor = a.username and l.action = 'admin_login'),
      'created_by', (select l.actor from public.audit_log l where l.action = 'admin_created' and l.detail->>'username' = a.username order by l.at desc limit 1)
    ) order by a.created_at) from public.admins a), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_log_export(p_token text, p_kind text, p_rows integer, p_detail jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_kind is null or p_kind not in ('insurance_roster', 'accepted_list', 'event_step', 'missing_docs') then return jsonb_build_object('ok', false, 'error', 'bad_kind'); end if;
  insert into public.audit_log(actor, action, table_name, detail)
  values (v_actor, 'export_' || p_kind, 'people', jsonb_build_object('rows', greatest(coalesce(p_rows, 0), 0), 'filter', left(coalesce(p_detail, '{}'::jsonb)::text, 2000)));
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_login(p_username text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.admins; v_token text; v_fail int;
begin
  select * into v from public.admins where username = lower(btrim(coalesce(p_username,''))) for update;
  if not found then
    perform extensions.crypt(coalesce(p_password,''), extensions.gen_salt('bf', 10));
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  if v.locked_until is not null and v.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked', 'retry_after_minutes', ceil(extract(epoch from v.locked_until - now()) / 60));
  end if;
  if v.password_hash <> extensions.crypt(coalesce(p_password,''), v.password_hash) then
    v_fail := v.failed_logins + 1;
    if v_fail >= 5 then
      update public.admins set failed_logins = 0, locked_until = now() + interval '15 minutes' where id = v.id;
      return jsonb_build_object('ok', false, 'error', 'locked', 'retry_after_minutes', 15);
    end if;
    update public.admins set failed_logins = v_fail where id = v.id;
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  update public.admins set failed_logins = 0, locked_until = null where id = v.id;
  delete from public.admin_sessions where expires_at < now();
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.admin_sessions(token_hash, admin_id, expires_at)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v.id, now() + interval '8 hours');
  insert into public.audit_log(actor, action, table_name) values (v.username, 'admin_login', 'admins');
  return jsonb_build_object('ok', true, 'token', v_token, 'username', v.username);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_logout(p_token text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with d as (delete from public.admin_sessions where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex') returning 1)
  select jsonb_build_object('ok', true);
$function$
;

CREATE OR REPLACE FUNCTION public.admin_min_wages(p_token text, p_set jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_set is not null then
    begin
      if coalesce((p_set->>'hourly')::numeric, 0) < 100 or coalesce((p_set->>'monthly')::numeric, 0) < 10000 then
        return jsonb_build_object('ok', false, 'error', 'bad_value');
      end if;
      insert into public.min_wages(effective_from, hourly, monthly) values ((p_set->>'effective_from')::date, (p_set->>'hourly')::numeric, (p_set->>'monthly')::numeric)
      on conflict (effective_from) do update set hourly = excluded.hourly, monthly = excluded.monthly;
    exception when others then return jsonb_build_object('ok', false, 'error', 'bad_value'); end;
    insert into public.audit_log(actor, action, table_name, detail) values (v_actor, 'min_wage_set', 'min_wages', p_set);
  end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((select jsonb_agg(jsonb_build_object('effective_from', effective_from, 'hourly', hourly, 'monthly', monthly) order by effective_from desc) from public.min_wages), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_overview(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return jsonb_build_object('ok', true, 'username', v_actor,
    'employer', (select jsonb_build_object('id', id, 'name', name, 'legal_name', legal_name, 'tax_id', tax_id, 'contact', public.setting('contact_info')) from public.employers order by created_at limit 1),
    'events', coalesce((select jsonb_agg(x order by (x->>'start_date') desc nulls last) from (
      select jsonb_build_object('id', e.id, 'name', e.name, 'start_date', e.start_date, 'end_date', e.end_date,
        'pay_date', e.pay_date, 'pay_within_days', e.pay_within_days, 'closed_at', e.closed_at, 'archived_at', e.archived_at, 'recruiting', e.recruiting,
        'total', count(s.id), 'draft', count(s.id) filter (where s.status = 'draft'),
        'published', count(s.id) filter (where s.status = 'published'), 'void', count(s.id) filter (where s.status = 'void'),
        'net_sum', coalesce(sum(s.net) filter (where s.status <> 'void'), 0),
        'cash_pending', count(s.id) filter (where s.status = 'published' and s.pay_method = 'cash' and s.cash_paid_at is null),
        'open_issues', (select count(*) from public.data_issues i where not i.resolved and i.severity <> 'info'
            and (i.event_id = e.id or i.payslip_id in (select id from public.payslips where event_id = e.id)))) x
      from public.events e left join public.payslips s on s.event_id = e.id group by e.id) t), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_payout(p_token text, p_event uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 匯款清單只含轉帳；現金另列（簽收單用），並附已上傳的簽收單照片清單
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  insert into public.audit_log(actor, action, table_name, row_id) values (v_actor, 'payout_exported', 'events', p_event);
  return jsonb_build_object('ok', true, 'rows', coalesce((select jsonb_agg(jsonb_build_object(
      'name', p.name, 'national_id', p.national_id, 'bank_code', p.bank_code, 'bank_branch', p.bank_branch, 'account_name', p.bank_account_name,
      'account', p.bank_account, 'net', s.net, 'pay_date', s.pay_date,
      'hold', case
        when s.pay_date is null then 'no_pay_date'
        when p.bank_account is null or p.bank_account !~ '^\d{6,16}$' or coalesce(p.bank_code, '') !~ '^\d{3}$' then 'bad_account'
        when exists (select 1 from public.data_issues i where i.person_id = p.id and i.code = 'bank_changed' and not i.resolved) then 'bank_pending'
        when btrim(regexp_replace(coalesce(p.bank_account_name, ''), '[（(].*$', '')) <> p.name then 'payee_mismatch'
        else null end) order by p.name)
    from public.payslips s join public.people p on p.id = s.person_id
    where s.event_id = p_event and s.status = 'published' and s.relation = 'employment' and s.pay_method = 'transfer'), '[]'::jsonb),
    'cash_rows', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', p.name, 'national_id', p.national_id, 'net', s.net, 'pay_date', s.pay_date,
        'paid_at', s.cash_paid_at, 'paid_by', s.cash_paid_by) order by p.name)
      from public.payslips s join public.people p on p.id = s.person_id
      where s.event_id = p_event and s.status = 'published' and s.relation = 'employment' and s.pay_method = 'cash'), '[]'::jsonb),
    'receipts', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'uploaded_by', r.uploaded_by, 'uploaded_at', r.uploaded_at) order by r.uploaded_at)
      from public.payout_receipts r where r.event_id = p_event), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_payslip(p_token text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); r jsonb;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select jsonb_build_object('id', s.id, 'status', s.status, 'relation', s.relation, 'role', s.role, 'basis', s.basis, 'generated', s.generated,
    'work_dates_text', s.work_dates_text, 'period_start', s.period_start, 'period_end', s.period_end, 'pay_date', s.pay_date,
    'gross', s.gross, 'allowances', s.allowances, 'deductions', s.deductions, 'net', s.net, 'note', s.note,
    'pay_bank_code', s.pay_bank_code, 'pay_bank_branch', s.pay_bank_branch, 'pay_account_name', s.pay_account_name, 'pay_account', s.pay_account,
    'person', jsonb_build_object('id', p.id, 'name', p.name, 'national_id', p.national_id, 'phone', p.phone, 'birth_date', p.birth_date,
        'has_password', p.password_hash is not null, 'password_changed', p.password_changed_at is not null,
        'locked', p.locked_until is not null and p.locked_until > now()),
    'items', coalesce((select jsonb_agg(jsonb_build_object('kind', i.kind, 'label', i.label, 'work_date', i.work_date, 'hours', i.hours, 'rate', i.rate, 'amount', i.amount) order by i.work_date nulls last, i.sort, i.id)
        from public.payslip_items i where i.payslip_id = s.id), '[]'::jsonb),
    'attendance', coalesce((select jsonb_agg(jsonb_build_object('work_date', a.work_date,
        'clock_in', to_char(a.clock_in at time zone 'Asia/Taipei', 'HH24:MI'), 'clock_out', to_char(a.clock_out at time zone 'Asia/Taipei', 'HH24:MI'),
        'break_minutes', a.break_minutes, 'source', a.source, 'scheduled_text', a.scheduled_text) order by a.work_date)
        from public.attendance a where a.person_id = s.person_id and a.event_id = s.event_id), '[]'::jsonb),
    'issues', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'severity', i.severity, 'code', i.code, 'detail', i.detail, 'resolved', i.resolved) order by i.id)
        from public.data_issues i where i.payslip_id = s.id or (i.payslip_id is null and i.person_id = s.person_id and (i.event_id is null or i.event_id = s.event_id))), '[]'::jsonb)
  ) into r from public.payslips s join public.people p on p.id = s.person_id where s.id = p_id;
  if r is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'payslip', r);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_people(p_token text, p_q text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_q text := btrim(coalesce(p_q,''));
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return jsonb_build_object('ok', true, 'total', (select count(*) from public.people),
    'people', coalesce((select jsonb_agg(x) from (
      select jsonb_build_object('id', p.id, 'name', p.name, 'national_id', p.national_id, 'phone', p.phone, 'source', p.profile_source, 'created_at', p.created_at, 'disabled', p.disabled_at is not null,
        'docs', (select count(*) from public.people_documents d where d.person_id = p.id and d.kind in ('id_front','id_back','bankbook')),
        'apps', (select count(*) from public.applications a where a.person_id = p.id),
        'open_issues', (select count(*) from public.data_issues i where i.person_id = p.id and i.payslip_id is null and not i.resolved and i.severity <> 'info')) x
      from public.people p
      where (v_q = '' and p.disabled_at is null) or v_q <> '' and (p.name ilike '%' || v_q || '%' or p.national_id ilike v_q || '%' or p.phone like '%' || v_q || '%')
      order by p.created_at desc, p.name limit 60) t), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_person(p_token text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); r jsonb;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select jsonb_build_object('id', p.id, 'name', p.name, 'nickname', p.nickname, 'admin_note', p.admin_note, 'national_id', p.national_id, 'birth_date', p.birth_date, 'birth_raw', p.birth_raw,
    'phone', p.phone, 'email', p.email, 'address', p.address, 'bank_code', p.bank_code, 'bank_branch', p.bank_branch, 'bank_account_name', p.bank_account_name,
    'bank_account', p.bank_account, 'source', p.profile_source, 'created_at', p.created_at, 'consent_at', p.consent_at,
    'disabled_at', p.disabled_at, 'disabled_by', p.disabled_by,
    'can_delete', not exists (select 1 from public.payslips x where x.person_id = p.id) and not exists (select 1 from public.attendance x where x.person_id = p.id),
    'has_password', p.password_hash is not null, 'password_changed', p.password_changed_at is not null, 'locked', p.locked_until is not null and p.locked_until > now(),
    'documents', coalesce((select jsonb_object_agg(d.kind, d.uploaded_at) from public.people_documents d where d.person_id = p.id), '{}'::jsonb),
      'doc_meta', coalesce((select jsonb_object_agg(d.kind, jsonb_build_object('link_only', d.path is null, 'drive', d.drive_file_id is not null, 'proof', d.downgraded_at is not null)) from public.people_documents d where d.person_id = p.id), '{}'::jsonb),
      'docs_verified_at', p.docs_verified_at, 'docs_verified_by', p.docs_verified_by,
    'issues', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'severity', i.severity, 'code', i.code, 'detail', i.detail, 'resolved', i.resolved) order by i.id)
        from public.data_issues i where i.person_id = p.id and i.payslip_id is null), '[]'::jsonb),
    'payslips', coalesce((select jsonb_agg(jsonb_build_object('event', e.name, 'net', s.net, 'status', s.status, 'period_start', s.period_start) order by s.period_start desc nulls last)
        from public.payslips s join public.events e on e.id = s.event_id where s.person_id = p.id), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(h order by h->>'start_date' desc nulls last) from (
        select jsonb_build_object('event_id', e.id, 'event', e.name, 'start_date', e.start_date, 'end_date', e.end_date, 'archived', e.archived_at is not null,
          'applied', exists (select 1 from public.applications a where a.event_id = e.id and a.person_id = p.id),
          'accepted', exists (select 1 from public.applications a join public.application_shifts x on x.application_id = a.id where a.event_id = e.id and a.person_id = p.id and a.status = 'active' and x.status = 'accepted'),
          'days', (select count(*) from public.attendance t where t.event_id = e.id and t.person_id = p.id),
          'slip', (select jsonb_build_object('id', s.id, 'status', s.status, 'gross', s.gross, 'net', s.net, 'role', s.role) from public.payslips s where s.event_id = e.id and s.person_id = p.id order by (s.status = 'void'), s.created_at desc limit 1)) h
        from public.events e
        where e.id in (select event_id from public.applications where person_id = p.id union select event_id from public.attendance where person_id = p.id union select event_id from public.payslips where person_id = p.id)) q), '[]'::jsonb)
  ) into r from public.people p where p.id = p_id;
  if r is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'person', r);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_recruit(p_token text, p_event uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return (select jsonb_build_object('ok', true, 'mode', public.recruit_mode(), 'require_line', public.recruit_need_line(),
    'event', jsonb_build_object('location', e.location, 'description', e.description, 'recruiting', e.recruiting, 'form', e.form_config, 'signup_code', e.signup_code,
       'signup_open', coalesce(e.end_date, e.start_date) >= (now() at time zone 'Asia/Taipei')::date - 1),
    'shifts', coalesce((select jsonb_agg(public.shift_json(s) order by s.work_date, s.start_time) from public.shifts s where s.event_id = e.id), '[]'::jsonb),
    'plans', coalesce((select jsonb_agg(public.plan_json(p) || jsonb_build_object('code', p.code, 'disabled_at', p.disabled_at, 'created_at', p.created_at)
        order by p.disabled_at nulls first, p.created_at) from public.recruit_plans p where p.event_id = e.id), '[]'::jsonb),
    'applicants', coalesce((select jsonb_agg(jsonb_build_object('app_id', a.id, 'person_id', p.id, 'name', p.name, 'national_id', p.national_id, 'phone', p.phone,
        'source', p.profile_source, 'answers', a.answers, 'experience', a.experience, 'created_at', a.created_at, 'contract_accepted_at', a.contract_accepted_at,
        'plan_id', a.plan_id, 'nda_at', a.nda_accepted_at, 'apply_contract_at', a.apply_contract_at, 'linked', p.line_user_id is not null, 'has_email', coalesce(btrim(p.email), '') <> '',
        'has_photo', exists (select 1 from public.people_documents d where d.person_id = p.id and d.kind = 'photo'),
        'docs', (select count(*) from public.people_documents d where d.person_id = p.id and d.kind <> 'photo'),
        'past_events', (select count(distinct s2.event_id) from public.payslips s2 where s2.person_id = p.id and s2.event_id <> e.id),
        'shifts', coalesce((select jsonb_object_agg(x.shift_id, x.status) from public.application_shifts x where x.application_id = a.id), '{}'::jsonb)
      ) order by a.created_at) from public.applications a join public.people p on p.id = a.person_id where a.event_id = e.id and a.status = 'active'), '[]'::jsonb))
    from public.events e where e.id = p_event);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_remove_admin(p_token text, p_username text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text; v_user text := lower(btrim(coalesce(p_username,'')));
begin
  perform pg_advisory_xact_lock(hashtext('admin_roster'));
  v_actor := public.admin_actor(p_token);
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if v_user = v_actor then return jsonb_build_object('ok', false, 'error', 'self'); end if;
  if (select count(*) from public.admins) <= 1 then return jsonb_build_object('ok', false, 'error', 'last'); end if;
  delete from public.admins where username = v_user;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  insert into public.audit_log(actor, action, table_name, detail) values (v_actor, 'admin_removed', 'admins', jsonb_build_object('username', v_user));
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_reset_admin(p_token text, p_username text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_user text := lower(btrim(coalesce(p_username,'')));
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if v_user = v_actor then return jsonb_build_object('ok', false, 'error', 'self'); end if;
  if length(coalesce(p_password,'')) < 8 then return jsonb_build_object('ok', false, 'error', 'too_short'); end if;
  update public.admins set password_hash = extensions.crypt(p_password, extensions.gen_salt('bf', 10)), failed_logins = 0, locked_until = null where username = v_user;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  delete from public.admin_sessions where admin_id = (select id from public.admins where username = v_user)
    and (v_user <> v_actor or token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex'));
  insert into public.audit_log(actor, action, table_name, detail) values (v_actor, 'admin_password_reset', 'admins', jsonb_build_object('username', v_user));
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_reset_password(p_token text, p_person uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_bd date;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select birth_date into v_bd from public.people where id = p_person;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_bd is null then return jsonb_build_object('ok', false, 'error', 'no_birth_date'); end if;
  update public.people set
    password_hash = extensions.crypt(lpad((extract(year from v_bd)::int - 1911)::text, 3, '0') || to_char(v_bd, 'MMDD'), extensions.gen_salt('bf', 10)),
    password_changed_at = null, failed_logins = 0, locked_until = null, updated_at = now()
  where id = p_person;
  delete from public.sessions where person_id = p_person;
  insert into public.audit_log(actor, action, table_name, row_id) values (v_actor, 'password_reset', 'people', p_person);
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_resolve_issue(p_token text, p_issue bigint, p_resolved boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  update public.data_issues set resolved = coalesce(p_resolved, true) where id = p_issue;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  insert into public.audit_log(actor, action, table_name, detail) values (v_actor, 'issue_resolved', 'data_issues', jsonb_build_object('id', p_issue, 'resolved', p_resolved));
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_roster(p_token text, p_filter jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor text := public.admin_actor(p_token);
  f jsonb := coalesce(p_filter, '{}'::jsonb);
  v_q text := nullif(btrim(coalesce(f->>'q', '')), '');
  v_ev uuid; v_from date; v_to date; v_st text[]; v_rows jsonb; v_n int;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  begin
    v_ev := nullif(f->>'event_id', '')::uuid; v_from := nullif(f->>'from', '')::date; v_to := nullif(f->>'to', '')::date;
  exception when others then return jsonb_build_object('ok', false, 'error', 'bad_filter'); end;
  select coalesce(array_agg(x), array['accepted']) into v_st from jsonb_array_elements_text(case when jsonb_typeof(f->'statuses') = 'array' then f->'statuses' else '[]'::jsonb end) x
    where x in ('accepted', 'applied', 'waitlist', 'rejected', 'attended');
  with src as (
    select e.id event_id, e.name event_name, e.start_date event_start, p.id person_id, s.work_date, to_char(s.start_time, 'HH24:MI') t_start, to_char(s.end_time, 'HH24:MI') t_end, s.role, x.status, e.archived_at is not null archived
      from public.application_shifts x
      join public.applications a on a.id = x.application_id and a.status = 'active'
      join public.shifts s on s.id = x.shift_id
      join public.events e on e.id = s.event_id
      join public.people p on p.id = a.person_id
     where x.status = any(v_st)
    union all
    -- 沒開班次的活動（舊表匯入）：以出勤紀錄當工作日
    select distinct e.id, e.name, e.start_date, p.id, t.work_date, null, null, null, 'attended', e.archived_at is not null
      from public.attendance t
      join public.events e on e.id = t.event_id
      join public.people p on p.id = t.person_id
     where 'attended' = any(v_st) and not exists (select 1 from public.shifts s2 where s2.event_id = e.id)
  ), flt as (
    select src.* from src
     where (v_ev is null or src.event_id = v_ev) and (v_ev is not null or not src.archived)
       and (v_q is null or strpos(src.event_name, v_q) > 0)
       and (v_from is null or src.work_date >= v_from)
       and (v_to is null or src.work_date <= v_to)
  )
  select count(*), coalesce(jsonb_agg(r order by r.event_start desc nulls last, r.event_name, r.name, r.work_date, r.t_start) filter (where r.rn <= 5000), '[]'::jsonb)
    into v_n, v_rows
    from (select flt.event_id, flt.event_name, flt.event_start, flt.person_id, flt.work_date, flt.t_start, flt.t_end, flt.status,
                 coalesce(flt.role, es.role, ps.role) role, p.name, p.national_id, p.birth_date,
                 -- 身分：活動人員設定優先，其次是這場的薪資單（舊表匯入時標的承攬／僱傭）
                 coalesce(es.relation, ps.relation, 'employment') relation, coalesce(es.insured_salary, e.insured_salary) insured_salary,
                 coalesce(public.valid_tw_id(p.national_id), false) id_valid,
                 row_number() over (order by flt.event_start desc nulls last, flt.event_name, p.name, flt.work_date) rn
            from flt join public.people p on p.id = flt.person_id join public.events e on e.id = flt.event_id
            left join public.event_staff es on es.event_id = flt.event_id and es.person_id = flt.person_id
            left join lateral (select x.relation, x.role from public.payslips x where x.event_id = flt.event_id and x.person_id = flt.person_id and x.status <> 'void'
                               order by x.created_at desc limit 1) ps on true) r;
  return jsonb_build_object('ok', true, 'total', v_n, 'truncated', v_n > 5000, 'rows', v_rows);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_save_event_info(p_token text, p_event uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); q jsonb; v_qs jsonb := '[]'::jsonb; n int := 0;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_patch ? 'form' then
    for q in select * from jsonb_array_elements(coalesce(p_patch->'form'->'questions', '[]'::jsonb)) loop
      n := n + 1;
      if length(btrim(coalesce(q->>'label',''))) = 0 then continue; end if;
      if coalesce(q->>'type','text') not in ('text','choice') then return jsonb_build_object('ok', false, 'error', 'bad_question'); end if;
      if q->>'type' = 'choice' and jsonb_array_length(coalesce(q->'options','[]'::jsonb)) < 2 then return jsonb_build_object('ok', false, 'error', 'few_options', 'question', q->>'label'); end if;
      v_qs := v_qs || jsonb_build_object('id', coalesce(nullif(q->>'id',''), 'q' || n || '_' || substr(md5(random()::text), 1, 6)), 'label', left(btrim(q->>'label'), 100),
        'type', coalesce(q->>'type','text'), 'required', coalesce((q->>'required')::boolean, false),
        'options', case when q->>'type' = 'choice' then (select jsonb_agg(left(btrim(o), 50)) from jsonb_array_elements_text(q->'options') o where btrim(o) <> '') else '[]'::jsonb end);
    end loop;
  end if;
  update public.events set
    location = case when p_patch ? 'location' then nullif(btrim(p_patch->>'location'),'') else location end,
    description = case when p_patch ? 'description' then nullif(btrim(p_patch->>'description'),'') else description end,
    recruiting = case when p_patch ? 'recruiting' then coalesce((p_patch->>'recruiting')::boolean, recruiting) else recruiting end,
    form_config = case when p_patch ? 'form' then jsonb_build_object('experience', coalesce((p_patch->'form'->>'experience')::boolean, false),
       'photo', coalesce((p_patch->'form'->>'photo')::boolean, false), 'questions', v_qs) else form_config end
  where id = p_event;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'event_info_saved', 'events', p_event, p_patch);
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_save_shifts(p_token text, p_event uuid, p_shift uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_from date; v_to date; v_start time; v_end time; v_n int := 0; dd date; v_head int; v_rate numeric; r record;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  begin
    v_from := (p_patch->>'work_date')::date; v_to := coalesce(nullif(p_patch->>'until_date','')::date, v_from);
    v_start := (p_patch->>'start')::time; v_end := (p_patch->>'end')::time;
    v_head := coalesce(nullif(p_patch->>'headcount','')::int, 1); v_rate := nullif(p_patch->>'rate','')::numeric;
  exception when others then return jsonb_build_object('ok', false, 'error', 'bad_value'); end;
  if v_from is null or v_start is null or v_end is null or v_to < v_from or v_to > v_from + 60 or v_start = v_end or v_head < 1 or v_head > 500 or v_rate < 0 then
    return jsonb_build_object('ok', false, 'error', 'bad_value');
  end if;
  -- 班次要落在活動日期內，否則之後存活動設定會被日期檢查擋下
  if exists (select 1 from public.events where id = p_event and (v_from < start_date or v_to > coalesce(end_date, start_date))) then
    return (select jsonb_build_object('ok', false, 'error', 'outside_event', 'start_date', start_date, 'end_date', coalesce(end_date, start_date)) from public.events where id = p_event);
  end if;
  if p_shift is not null then
    -- 先鎖受影響的報名，再鎖班次、人員，與錄取流程同順序
    perform 1 from public.applications where id in (select application_id from public.application_shifts where shift_id = p_shift) order by id for update;
    perform 1 from public.shifts where id = p_shift and event_id = p_event for update;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
    perform 1 from public.people where id in (select a.person_id from public.application_shifts x join public.applications a on a.id = x.application_id where x.shift_id = p_shift and x.status = 'accepted') order by id for update;
    if v_head < (select count(*) from public.application_shifts x join public.applications a on a.id = x.application_id where x.shift_id = p_shift and x.status = 'accepted' and a.status = 'active') then
      return jsonb_build_object('ok', false, 'error', 'below_accepted');
    end if;
    if exists (select 1 from public.application_shifts x join public.applications a on a.id = x.application_id
        join public.application_shifts x2 on x2.status = 'accepted' and x2.shift_id <> p_shift
        join public.applications a2 on a2.id = x2.application_id and a2.person_id = a.person_id and a2.status = 'active'
        join public.shifts s2 on s2.id = x2.shift_id
        where x.shift_id = p_shift and x.status = 'accepted' and a.status = 'active'
          and (s2.work_date + s2.start_time, s2.work_date + s2.end_time + case when s2.end_time <= s2.start_time then interval '1 day' else interval '0' end)
              overlaps (v_from + v_start, v_from + v_end + case when v_end <= v_start then interval '1 day' else interval '0' end)) then
      return jsonb_build_object('ok', false, 'error', 'overlap');
    end if;
    update public.shifts set work_date = v_from, start_time = v_start, end_time = v_end, role = nullif(btrim(coalesce(p_patch->>'role','')),''),
      headcount = v_head, rate = v_rate, note = nullif(btrim(coalesce(p_patch->>'note','')),'') where id = p_shift;
    for r in select distinct application_id from public.application_shifts where shift_id = p_shift and status = 'accepted' order by application_id loop
      perform public.contract_recheck_app(r.application_id);
    end loop;
    v_n := 1;
  else
    for dd in select generate_series(v_from, v_to, interval '1 day')::date loop
      insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount, rate, note)
      values (p_event, dd, v_start, v_end, nullif(btrim(coalesce(p_patch->>'role','')),''), v_head, v_rate, nullif(btrim(coalesce(p_patch->>'note','')),''));
      v_n := v_n + 1;
    end loop;
  end if;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'shifts_saved', 'shifts', p_event, p_patch);
  return jsonb_build_object('ok', true, 'count', v_n);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_set_attendance(p_token text, p_id uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_in timestamptz; v_out timestamptz; v_break int;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  begin
    v_in := nullif(p_patch->>'clock_in','')::timestamp at time zone 'Asia/Taipei';
    v_out := nullif(p_patch->>'clock_out','')::timestamp at time zone 'Asia/Taipei';
    v_break := coalesce(nullif(p_patch->>'break_minutes','')::int, 0);
  exception when others then return jsonb_build_object('ok', false, 'error', 'bad_value'); end;
  if v_in is not null and v_out is not null and v_out <= v_in then return jsonb_build_object('ok', false, 'error', 'out_before_in'); end if;
  if v_break < 0 or v_break > 240 then return jsonb_build_object('ok', false, 'error', 'bad_value'); end if;
  update public.attendance set clock_in = v_in, clock_out = v_out, break_minutes = v_break,
    note = nullif(btrim(coalesce(p_patch->>'note','')), ''),
    source = case when source = 'qr' and (clock_in is distinct from v_in or clock_out is distinct from v_out) then 'manual' else source end
  where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'attendance_updated', 'attendance', p_id, p_patch);
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_set_staff(p_token text, p_event uuid, p_person uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_rate numeric; v_ins numeric;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  begin
    v_rate := nullif(p_patch->>'rate','')::numeric; v_ins := nullif(p_patch->>'insured_salary','')::numeric;
  exception when others then return jsonb_build_object('ok', false, 'error', 'bad_value'); end;
  if coalesce(p_patch->>'pay_type','hourly') not in ('hourly','daily') or coalesce(p_patch->>'relation','employment') not in ('employment','contract')
     or v_rate < 0 or v_rate > 100000 then return jsonb_build_object('ok', false, 'error', 'bad_value'); end if;
  insert into public.event_staff(event_id, person_id, role, relation, pay_type, rate, insured_salary, deduct_insurance)
  values (p_event, p_person, nullif(btrim(coalesce(p_patch->>'role','')),''), coalesce(p_patch->>'relation','employment'), coalesce(p_patch->>'pay_type','hourly'),
    v_rate, v_ins, coalesce((p_patch->>'deduct_insurance')::boolean, true))
  on conflict (event_id, person_id) do update set role = excluded.role, relation = excluded.relation, pay_type = excluded.pay_type,
    rate = excluded.rate, insured_salary = excluded.insured_salary, deduct_insurance = excluded.deduct_insurance;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'staff_updated', 'event_staff', p_person, p_patch || jsonb_build_object('event', p_event));
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_set_status(p_token text, p_ids uuid[], p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_done int; v_skip int := 0; v_blocked int := 0;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_status not in ('draft','published','void') then return jsonb_build_object('ok', false, 'error', 'bad_status'); end if;
  perform 1 from public.payslips where id = any(p_ids) order by id for update;
  if p_status = 'published' then
    select count(*) into v_skip from public.payslips where id = any(p_ids) and (net is null or gross is null);
    select count(*) into v_blocked from public.payslips p where p.id = any(p_ids) and p.status <> 'published' and p.net is not null and p.gross is not null and public.payslip_blocked(p);
  end if;
  with u as (
    update public.payslips p set status = p_status, published_at = case when p_status = 'published' then now() else null end
    where p.id = any(p_ids) and p.status <> p_status and (p_status <> 'published' or (p.net is not null and p.gross is not null and not public.payslip_blocked(p)))
    returning p.id
  ), l as (
    insert into public.audit_log(actor, action, table_name, row_id, detail) select v_actor, 'payslip_' || p_status, 'payslips', id, null from u returning 1
  )
  select count(*) into v_done from l;
  return jsonb_build_object('ok', true, 'updated', v_done, 'skipped_no_amount', v_skip, 'blocked_errors', v_blocked);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_setup(p_code text, p_username text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_hash text := encode(extensions.digest(btrim(coalesce(p_code,'')), 'sha256'), 'hex'); v_user text := lower(btrim(coalesce(p_username,''))); v_used text;
begin
  if v_user !~ '^[a-z0-9._@-]{3,60}$' then return jsonb_build_object('ok', false, 'error', 'bad_username'); end if;
  if length(coalesce(p_password,'')) < 8 then return jsonb_build_object('ok', false, 'error', 'too_short'); end if;
  if exists (select 1 from public.admins where username = v_user) then return jsonb_build_object('ok', false, 'error', 'taken'); end if;
  update public.admin_setup_codes set used_at = now() where code_hash = v_hash and used_at is null and expires_at > now() returning code_hash into v_used;
  if v_used is null then return jsonb_build_object('ok', false, 'error', 'bad_code'); end if;
  insert into public.admins(username, password_hash) values (v_user, extensions.crypt(p_password, extensions.gen_salt('bf', 10)));
  insert into public.audit_log(actor, action, table_name, detail) values (v_user, 'admin_created', 'admins', jsonb_build_object('username', v_user, 'via', 'setup_code'));
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_signup_code(p_token text, p_event uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return coalesce((select jsonb_build_object('ok', true, 'code', signup_code, 'open', coalesce(end_date, start_date) >= (now() at time zone 'Asia/Taipei')::date - 1) from public.events where id = p_event),
    jsonb_build_object('ok', false, 'error', 'not_found'));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_update_employer(p_token text, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_id uuid;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_patch ? 'tax_id' and nullif(btrim(p_patch->>'tax_id'),'') is not null and btrim(p_patch->>'tax_id') !~ '^\d{8}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_tax_id');
  end if;
  if length(coalesce(p_patch->>'contact', '')) > 200 then return jsonb_build_object('ok', false, 'error', 'contact_too_long'); end if;
  select id into v_id from public.employers order by created_at limit 1;
  update public.employers set
    legal_name = case when p_patch ? 'legal_name' then nullif(btrim(p_patch->>'legal_name'),'') else legal_name end,
    tax_id = case when p_patch ? 'tax_id' then nullif(btrim(p_patch->>'tax_id'),'') else tax_id end
  where id = v_id;
  if p_patch ? 'contact' then
    update public.app_settings set value = nullif(btrim(p_patch->>'contact'), '') where key = 'contact_info';
  end if;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'employer_updated', 'employers', v_id, p_patch);
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_update_event(p_token text, p_id uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); v_n int := 0; e public.events; v_pay date; v_days int; v_apply boolean := coalesce((p_patch->>'apply_to_payslips')::boolean, false);
  v_name text; v_start date; v_end date; v_out int;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into e from public.events where id = p_id for update;
  if e.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  -- 活動名稱與日期（可不帶，沒帶就維持原值）
  v_name := case when p_patch ? 'name' then btrim(coalesce(p_patch->>'name','')) else e.name end;
  if v_name = '' or length(v_name) > 100 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  begin
    v_start := case when p_patch ? 'start_date' then nullif(p_patch->>'start_date','')::date else e.start_date end;
    v_end := case when p_patch ? 'end_date' then nullif(p_patch->>'end_date','')::date else e.end_date end;
  exception when others then return jsonb_build_object('ok', false, 'error', 'bad_date'); end;
  if v_start is null or (v_end is not null and v_end < v_start) then return jsonb_build_object('ok', false, 'error', 'bad_date'); end if;
  -- 已開的班次或出勤不能落在新的日期範圍外
  select count(*) into v_out from (
    select work_date from public.shifts where event_id = p_id union all select work_date from public.attendance where event_id = p_id) x
  where x.work_date < v_start or x.work_date > coalesce(v_end, v_start);
  if v_out > 0 then return jsonb_build_object('ok', false, 'error', 'outside_dates', 'count', v_out); end if;
  begin
    v_pay := case when p_patch ? 'pay_date' then nullif(p_patch->>'pay_date','')::date else e.pay_date end;
    v_days := case when p_patch ? 'pay_within_days' then nullif(p_patch->>'pay_within_days','')::int else e.pay_within_days end;
  exception when others then return jsonb_build_object('ok', false, 'error', 'bad_pay'); end;
  if v_pay is not null and v_pay < coalesce(v_end, v_start) and (p_patch ? 'pay_date' or p_patch ? 'end_date' or p_patch ? 'start_date') then return jsonb_build_object('ok', false, 'error', 'pay_before_end'); end if;
  if v_days is not null and (v_days < 0 or v_days > 90) then return jsonb_build_object('ok', false, 'error', 'bad_pay'); end if;
  -- 兩種方式互斥：指定日期優先
  if p_patch ? 'pay_date' and v_pay is not null then v_days := null; end if;
  begin
    update public.events set
      name = v_name, start_date = v_start, end_date = v_end,
      pay_date = v_pay, pay_within_days = v_days,
      default_break_minutes = case when p_patch ? 'default_break_minutes' then coalesce(nullif(p_patch->>'default_break_minutes','')::int, 0) else default_break_minutes end,
      default_hourly_rate = case when p_patch ? 'default_hourly_rate' then nullif(p_patch->>'default_hourly_rate','')::numeric else default_hourly_rate end,
      insured_salary = case when p_patch ? 'insured_salary' then coalesce(nullif(p_patch->>'insured_salary','')::numeric, 11100) else insured_salary end
    where id = p_id;
  exception when others then return jsonb_build_object('ok', false, 'error', 'bad_value'); end;
  if v_apply and (p_patch ? 'pay_date' or p_patch ? 'pay_within_days') then
    update public.payslips set pay_date = coalesce(v_pay, case when v_days is not null then coalesce(v_end, v_start) + v_days end)
    where event_id = p_id and status <> 'void';
    get diagnostics v_n = row_count;
  end if;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'event_updated', 'events', p_id, p_patch);
  return jsonb_build_object('ok', true, 'payslips_updated', v_n, 'pay_date', coalesce(v_pay, case when v_days is not null then coalesce(v_end, v_start) + v_days end));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_update_payslip(p_token text, p_id uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_patch ? 'relation' and p_patch->>'relation' not in ('employment','contract') then return jsonb_build_object('ok', false, 'error', 'bad_relation'); end if;
  update public.payslips set
    relation = coalesce(p_patch->>'relation', relation),
    pay_date = case when p_patch ? 'pay_date' then nullif(p_patch->>'pay_date','')::date else pay_date end,
    note = case when p_patch ? 'note' then nullif(btrim(p_patch->>'note'),'') else note end
  where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'payslip_updated', 'payslips', p_id, p_patch);
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.att_minutes(a attendance)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case when a.clock_in is null or a.clock_out is null then null
    else greatest(floor(extract(epoch from public.att_pay_out(a) - public.att_pay_in(a)) / 60)::int - a.break_minutes, 0) end $function$
;

CREATE OR REPLACE FUNCTION public.att_pay_in(a attendance)
 RETURNS timestamp with time zone
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case when a.sched_in is not null and a.clock_in < a.sched_in and a.early_approved_at is null then a.sched_in else a.clock_in end $function$
;

CREATE OR REPLACE FUNCTION public.att_pay_out(a attendance)
 RETURNS timestamp with time zone
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case when a.sched_out is not null and a.clock_out > a.sched_out and a.ot_approved_at is null then a.sched_out else a.clock_out end $function$
;

CREATE OR REPLACE FUNCTION public.checkin_make_code(p_event uuid, p_slot bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select replace(e.id::text,'-','') || '.' || p_slot || '.' ||
    left(encode(extensions.hmac(replace(e.id::text,'-','') || '.' || p_slot, e.checkin_secret, 'sha256'), 'hex'), 20)
  from public.events e where e.id = p_event;
$function$
;

CREATE OR REPLACE FUNCTION public.checkin_state(p_person uuid, p_event uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with open_row as (
    select * from public.attendance a where a.person_id = p_person and a.event_id = p_event
      and a.clock_in is not null and a.clock_out is null and a.clock_in > now() - interval '20 hours'
    order by a.clock_in desc limit 1
  ), today_row as (
    select * from public.attendance a where a.person_id = p_person and a.event_id = p_event
      and a.work_date = (now() at time zone 'Asia/Taipei')::date limit 1
  )
  select jsonb_build_object(
    'state', case when exists (select 1 from open_row) then 'in' when exists (select 1 from today_row where clock_out is not null) then 'done' else 'none' end,
    'clock_in', coalesce((select to_char(clock_in at time zone 'Asia/Taipei', 'HH24:MI') from open_row), (select to_char(clock_in at time zone 'Asia/Taipei', 'HH24:MI') from today_row)),
    'clock_out', (select to_char(clock_out at time zone 'Asia/Taipei', 'HH24:MI') from today_row where not exists (select 1 from open_row)),
    'now', to_char(now() at time zone 'Asia/Taipei', 'HH24:MI'));
$function$
;

CREATE OR REPLACE FUNCTION public.contract_recheck_app(p_app uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.applications; v_hash text; v_text text; v_full text;
begin
  select * into a from public.applications where id = p_app for update;
  if a.id is null then return; end if;
  if a.contract_accepted_at is not null then
    select text_hash into v_hash from public.contract_history where application_id = p_app and superseded_at is null order by id desc limit 1;
    -- 已確認的內容與新版或舊版模板任一相符就仍有效（換模板本身不讓已確認的契約失效）
    if v_hash is null or (v_hash is distinct from md5(coalesce(public.payroll_contract_text(p_app), ''))
                          and v_hash is distinct from md5(coalesce(public.payroll_contract_text_v2(p_app), ''))
                          and v_hash is distinct from md5(coalesce(public.payroll_contract_text_v1(p_app), ''))) then
      update public.applications set contract_accepted_at = null, contract_text = null, updated_at = now() where id = p_app;
      a.contract_accepted_at := null;
    end if;
  end if;
  -- 報名時已同意的契約：錄取的班次與內容和報名時一字不差就直接生效；不同（只錄取部分、名單制排班、活動資料改過）就要本人重新確認
  if a.contract_accepted_at is null and a.apply_contract_hash is not null then
    v_text := public.payroll_contract_text(p_app);
    if v_text is not null and md5(v_text) = a.apply_contract_hash then
      update public.contract_history set superseded_at = now() where application_id = p_app and superseded_at is null;
      v_full := v_text || E'\n\n' || '乙方於 ' || to_char(a.apply_contract_at at time zone 'Asia/Taipei', 'YYYY/MM/DD HH24:MI') || ' 報名時以本人帳號登入系統線上確認同意。';
      update public.applications set contract_text = v_full, contract_accepted_at = a.apply_contract_at, updated_at = now() where id = p_app;
      insert into public.contract_history(application_id, text, text_hash, accepted_at) values (p_app, v_full, md5(v_text), a.apply_contract_at);
      insert into public.audit_log(actor, action, table_name, row_id, detail) values (a.person_id::text, 'contract_accepted', 'applications', p_app, jsonb_build_object('at_apply', true));
    end if;
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.doc_import_ok(p_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select length(coalesce(p_key, '')) >= 32
    and coalesce(public.setting('doc_import_key_expires'), '') <> ''
    and public.setting('doc_import_key_expires')::timestamptz > now()
    and encode(extensions.digest(p_key, 'sha256'), 'hex') = public.setting('doc_import_key_hash');
$function$
;

CREATE OR REPLACE FUNCTION public.line_bind(p_code text, p_user text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid; v_name text;
begin
  perform pg_advisory_xact_lock(hashtext('line_link'));
  delete from public.line_bind_failures where at < now() - interval '1 day';
  if (select count(*) from public.line_bind_failures where line_user_id = p_user and at > now() - interval '1 hour') >= 5
     or (select count(*) from public.line_bind_failures where at > now() - interval '10 minutes') >= 60 then
    return jsonb_build_object('ok', false, 'error', 'too_many');
  end if;
  delete from public.line_link_codes c where c.code = p_code and c.expires_at > now()
    and exists (select 1 from public.people p where p.id = c.person_id and p.disabled_at is null) returning c.person_id into v_pid;
  if v_pid is null then
    insert into public.line_bind_failures(line_user_id) values (p_user);
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  delete from public.line_link_codes where person_id = v_pid;
  update public.people set line_user_id = null, line_linked_at = null where line_user_id = p_user and id <> v_pid;
  update public.people set line_user_id = p_user, line_linked_at = now() where id = v_pid returning name into v_name;
  insert into public.audit_log(actor, action, table_name, row_id) values (v_pid::text, 'line_linked', 'people', v_pid);
  return jsonb_build_object('ok', true, 'name', v_name);
end $function$
;

CREATE OR REPLACE FUNCTION public.line_cron_ok(p_token text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select length(coalesce(p_token, '')) >= 32 and length(coalesce(public.setting('cron_token'), '')) >= 32 and p_token = public.setting('cron_token');
$function$
;

CREATE OR REPLACE FUNCTION public.line_unfollow(p_user text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform pg_advisory_xact_lock(hashtext('line_link'));
  update public.people set line_user_id = null, line_linked_at = null where line_user_id = p_user;
end $function$
;

CREATE OR REPLACE FUNCTION public.notify_batch(p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_claim uuid := gen_random_uuid(); r record; out jsonb := '[]'::jsonb; v_text text; v_lines text; v_site text := public.setting('site_url'); s public.payslips;
begin
  for r in select n.*, p.name, p.line_user_id, e.name as event_name from public.notifications n join public.people p on p.id = n.person_id
           left join public.events e on e.id = n.event_id
           where n.channel = 'line' and ((n.status = 'pending' and n.send_after <= now()) or (n.status = 'sending' and n.claimed_at < now() - interval '10 minutes')) order by n.created_at limit p_limit for update of n skip locked loop
    if r.status = 'sending' and r.attempts >= 3 then
      update public.notifications set status = 'failed', error = coalesce(error, 'stuck'), claim = null where id = r.id; continue;
    end if;
    if coalesce(public.setting('line_enabled'), 'true') <> 'true' then
      update public.notifications set status = 'skipped', error = 'disabled' where id = r.id; continue;
    end if;
    if (r.kind in ('reminder', 'checkout', 'test') and r.created_at < now() - interval '24 hours') or r.created_at < now() - interval '7 days' then
      update public.notifications set status = 'skipped', error = 'expired' where id = r.id; continue;
    end if;
    if r.line_user_id is null then
      update public.notifications set status = 'skipped', error = 'not_linked' where id = r.id; continue;
    end if;
    v_text := r.body;
    if r.kind = 'accepted' then
      select string_agg(to_char(sh.work_date, 'MM/DD') || '（' || (array['日','一','二','三','四','五','六'])[extract(dow from sh.work_date)::int + 1] || '）'
          || to_char(sh.start_time, 'HH24:MI') || '–' || to_char(sh.end_time, 'HH24:MI') || coalesce('　' || sh.role, ''), E'\n' order by sh.work_date, sh.start_time)
      into v_lines
      from public.application_shifts x join public.applications a on a.id = x.application_id join public.shifts sh on sh.id = x.shift_id
      where a.person_id = r.person_id and a.event_id = r.event_id and a.status = 'active' and x.status = 'accepted';
      if v_lines is null then update public.notifications set status = 'skipped', error = 'no_longer_accepted' where id = r.id; continue; end if;
      v_text := '【沃克思】' || r.name || ' 你好，你已錄取「' || r.event_name || '」：' || E'\n' || v_lines || E'\n\n'
        || case when exists (select 1 from public.applications ca where ca.person_id = r.person_id and ca.event_id = r.event_id and ca.contract_accepted_at is not null) then '勞動契約已確認，可登入查看：' else '請登入確認勞動契約，確認後才算完成排班：' end || E'\n' || v_site;
    elsif r.kind = 'payslip' then
      select * into s from public.payslips where id = r.ref_id;
      if s.id is null or s.status <> 'published' then update public.notifications set status = 'skipped', error = 'not_published' where id = r.id; continue; end if;
      v_text := '【沃克思】「' || r.event_name || '」的薪資單已發布' || E'\n' || ''
        || '發薪日 ' || coalesce(to_char(s.pay_date, 'YYYY/MM/DD'), '另行通知') || E'\n'
        || coalesce('目前還缺：' || public.person_incomplete_text(r.person_id) || '，補齊後才看得到薪資單。' || E'\n', '')
        || '登入查看明細：' || v_site;
    elsif r.kind = 'docs' then
      v_lines := public.person_incomplete_text(r.person_id);
      if v_lines is null then update public.notifications set status = 'skipped', error = 'already_complete' where id = r.id; continue; end if;
      v_text := '【沃克思】要在系統看到「' || coalesce(r.event_name, '活動') || '」的薪資單，還需要你補上：' || v_lines || E'\n' || '請登入補齊：' || v_site;
    elsif r.kind = 'checkout' then
      if exists (select 1 from public.attendance where id = r.ref_id and clock_out is not null) then
        update public.notifications set status = 'skipped', error = 'already_out' where id = r.id; continue;
      end if;
    end if;
    update public.notifications set body = v_text, status = 'sending', claimed_at = now(), claim = v_claim where id = r.id;
    out := out || jsonb_build_object('id', r.id, 'claim', v_claim, 'to', r.line_user_id, 'text', left(v_text, 4900));
  end loop;
  return out;
end $function$
;

CREATE OR REPLACE FUNCTION public.notify_enqueue_checkout()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n int;
begin
  insert into public.notifications(person_id, event_id, kind, ref_id, body, dedupe_key)
  select at.person_id, at.event_id, 'checkout', at.id,
    '【沃克思】你在「' || e.name || '」' || to_char(at.work_date, 'MM/DD') || ' 還沒簽退。下班時請掃現場 QR 碼簽退；如果已經離開，請告訴現場負責人實際下班時間。',
    'checkout:' || at.id
  from public.attendance at join public.events e on e.id = at.event_id
  where at.clock_in is not null and at.clock_out is null and at.clock_in > now() - interval '24 hours'
    and now() > coalesce(
      (select max(s.work_date + s.end_time + case when s.end_time <= s.start_time then interval '1 day' else interval '0' end) at time zone 'Asia/Taipei' + interval '30 minutes'
       from public.application_shifts x join public.applications a on a.id = x.application_id join public.shifts s on s.id = x.shift_id
       where a.person_id = at.person_id and a.event_id = at.event_id and x.status = 'accepted' and s.work_date = at.work_date),
      at.clock_in + interval '10 hours')
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.notify_enqueue_reminders()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_tomorrow date := (now() at time zone 'Asia/Taipei')::date + 1; n int;
begin
  insert into public.notifications(person_id, event_id, kind, body, dedupe_key)
  select a.person_id, e.id, 'reminder',
    '【沃克思】提醒你明天 ' || to_char(v_tomorrow, 'MM/DD') || '（' || (array['日','一','二','三','四','五','六'])[extract(dow from v_tomorrow)::int + 1] || '）有「' || e.name || '」的班：' || E'\n'
      || string_agg(to_char(s.start_time, 'HH24:MI') || '–' || to_char(s.end_time, 'HH24:MI') || coalesce('　' || s.role, ''), E'\n' order by s.start_time) || E'\n'
      || coalesce('地點：' || e.location || E'\n', '')
      || '到場請用手機掃現場 QR 碼簽到，下班記得簽退。如果不能出勤，請盡快告訴活動負責人。',
    'reminder:' || a.person_id || ':' || e.id || ':' || v_tomorrow
  from public.application_shifts x join public.applications a on a.id = x.application_id join public.shifts s on s.id = x.shift_id join public.events e on e.id = a.event_id
  where x.status = 'accepted' and a.status = 'active' and s.work_date = v_tomorrow
  group by a.person_id, e.id, e.name, e.location
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.notify_mark(p_results jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update public.notifications n set
    attempts = n.attempts + case when x.status in ('sent', 'retry', 'failed') then 1 else 0 end,
    status = case
      when x.status = 'release' then 'pending'
      when x.status = 'retry' then (case when n.attempts + 1 >= 3 then 'failed' else 'pending' end)
      else x.status end,
    send_after = case when x.status = 'retry' then now() + interval '10 minutes' when x.status = 'release' then now() + interval '30 minutes' else n.send_after end,
    error = x.error, sent_at = case when x.status = 'sent' then now() end, claimed_at = null, claim = null
  from jsonb_to_recordset(p_results) as x(id uuid, claim uuid, status text, error text)
  where n.id = x.id and n.status = 'sending' and n.claim = x.claim and x.status in ('sent', 'retry', 'failed', 'release');
$function$
;

CREATE OR REPLACE FUNCTION public.notify_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.notify_enqueue_checkout();
  perform public.mail_flush();
  if exists (select 1 from public.notifications where channel = 'line' and ((status = 'pending' and send_after <= now()) or (status = 'sending' and claimed_at < now() - interval '10 minutes'))) then
    perform net.http_post(
      url := 'https://rxekuiadnzjfvjcgmrxr.supabase.co/functions/v1/line',
      body := jsonb_build_object('action', 'flush'),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', public.setting('cron_token')),
      timeout_milliseconds := 20000);
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.parse_roc_birth(raw text)
 RETURNS date
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare s text := regexp_replace(coalesce(raw,''), '\s', '', 'g'); y int; m int; d int; p text[];
begin
  if s ~ '^(19|20)\d{6}$' then
    y := substr(s,1,4)::int; m := substr(s,5,2)::int; d := substr(s,7,2)::int;
  elsif s ~ '^\d{7}$' then
    y := substr(s,1,3)::int + 1911; m := substr(s,4,2)::int; d := substr(s,6,2)::int;
  elsif s ~ '^\d{6}$' then
    y := substr(s,1,2)::int + 1911; m := substr(s,3,2)::int; d := substr(s,5,2)::int;
  elsif s ~ '^\d{2,3}[/.\-]\d{1,2}[/.\-]\d{1,2}$' then
    p := regexp_split_to_array(s, '[/.\-]');
    y := p[1]::int + 1911; m := p[2]::int; d := p[3]::int;
  else
    return null;
  end if;
  return make_date(y,m,d);
exception when others then
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_accept_contract(p_token text, p_app uuid, p_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token); a public.applications; v_text text; v_hash text; v_open text;
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into a from public.applications where id = p_app and person_id = v_pid for update;
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  -- 鎖住契約內容的來源，條款修改與確認互相等待
  perform 1 from public.events where id = a.event_id for share;
  perform 1 from public.employers where id = (select employer_id from public.events where id = a.event_id) for share;
  perform 1 from public.shifts where id in (select shift_id from public.application_shifts where application_id = a.id and status = 'accepted') order by id for share;
  v_text := public.payroll_contract_text(a.id);
  if v_text is null then return jsonb_build_object('ok', false, 'error', 'no_accepted'); end if;
  v_hash := md5(v_text);
  if v_hash is distinct from p_hash then return jsonb_build_object('ok', false, 'error', 'changed'); end if;
  if a.contract_accepted_at is not null then
    select text_hash into v_open from public.contract_history where application_id = a.id and superseded_at is null order by id desc limit 1;
    if v_open = v_hash then return jsonb_build_object('ok', true, 'already', true); end if;
  end if;
  update public.contract_history set superseded_at = now() where application_id = a.id and superseded_at is null;
  v_text := v_text || E'\n\n' || '乙方於 ' || to_char(now() at time zone 'Asia/Taipei', 'YYYY/MM/DD HH24:MI') || ' 以本人帳號登入系統線上確認同意。';
  update public.applications set contract_text = v_text, contract_accepted_at = now(), updated_at = now() where id = a.id;
  insert into public.contract_history(application_id, text, text_hash, accepted_at) values (a.id, v_text, v_hash, now());
  insert into public.audit_log(actor, action, table_name, row_id) values (v_pid::text, 'contract_accepted', 'applications', a.id);
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_apply(p_token text, p_join text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token); e public.events; t record; v_view jsonb; v_kind text; v_plan uuid; pl public.recruit_plans;
  v_app uuid; v_ids uuid[]; q jsonb; v_ans jsonb := '{}'::jsonb; v text; v_old_plan uuid; v_has_acc boolean := false; v_ctext text;
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into t from public.join_target(p_join);
  select * into e from public.events where id = t.event_id;
  if not found or coalesce(e.end_date, e.start_date) < (now() at time zone 'Asia/Taipei')::date - 1 then return jsonb_build_object('ok', false, 'error', 'bad_join'); end if;
  if not e.recruiting then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  if public.recruit_need_line() and not exists (select 1 from public.people where id = v_pid and line_user_id is not null) then
    return jsonb_build_object('ok', false, 'error', 'need_line');
  end if;
  v_view := public.recruit_view(e.id, t.plan_id); v_kind := v_view->>'kind';
  select a.plan_id, exists (select 1 from public.application_shifts x where x.application_id = a.id and x.status = 'accepted')
    into v_old_plan, v_has_acc from public.applications a where a.event_id = e.id and a.person_id = v_pid and a.status = 'active' for update of a;
  v_has_acc := coalesce(v_has_acc, false);
  -- 已錄取的方案報名：不能經主連結改成自選，也不能改報別的方案（名單制不動班次，不受限）
  if v_has_acc and v_old_plan is not null and v_kind <> 'pool' and (v_kind = 'pick' or nullif(p_data->>'plan_id', '') is distinct from v_old_plan::text) then
    return jsonb_build_object('ok', false, 'error', 'has_accepted');
  end if;
  if v_kind = 'pool' then
    -- 名單制：只報名這場活動，班次由管理員安排，這裡不動班次
    v_ids := null;
  elsif v_kind = 'pick' then
    begin
      select coalesce(array_agg(x::uuid), '{}') into v_ids from jsonb_array_elements_text(coalesce(p_data->'shift_ids','[]'::jsonb)) x;
    exception when others then return jsonb_build_object('ok', false, 'error', 'bad_shift'); end;
    if exists (select 1 from public.shifts where event_id = e.id) and cardinality(v_ids) = 0 then return jsonb_build_object('ok', false, 'error', 'no_shift'); end if;
    if exists (select 1 from unnest(v_ids) i where not exists (select 1 from public.shifts s where s.id = i and s.event_id = e.id)) then
      return jsonb_build_object('ok', false, 'error', 'bad_shift');
    end if;
  else
    -- 方案：整組報名，只能選這個連結看得到的方案
    begin v_plan := nullif(p_data->>'plan_id', '')::uuid; exception when others then return jsonb_build_object('ok', false, 'error', 'bad_plan'); end;
    if v_plan is null then return jsonb_build_object('ok', false, 'error', 'no_plan'); end if;
    if not exists (select 1 from jsonb_array_elements(v_view->'plans') x where (x->>'id')::uuid = v_plan) then return jsonb_build_object('ok', false, 'error', 'bad_plan'); end if;
    select * into pl from public.recruit_plans where id = v_plan;
    if exists (select 1 from unnest(pl.shift_ids) i where not exists (select 1 from public.shifts s where s.id = i and s.event_id = e.id)) then
      return jsonb_build_object('ok', false, 'error', 'bad_shift');
    end if;
    -- 已經有錄取的班次：不能改報別的方案（請聯絡負責人）
    if v_has_acc and v_old_plan is distinct from v_plan then return jsonb_build_object('ok', false, 'error', 'has_accepted'); end if;
    if v_old_plan is distinct from v_plan and (public.plan_json(pl)->>'full')::boolean then return jsonb_build_object('ok', false, 'error', 'plan_full'); end if;
    v_ids := pl.shift_ids;
  end if;
  for q in select * from jsonb_array_elements(coalesce(e.form_config->'questions', '[]'::jsonb)) loop
    v := btrim(coalesce(p_data->'answers'->>(q->>'id'), ''));
    if coalesce((q->>'required')::boolean, false) and v = '' then return jsonb_build_object('ok', false, 'error', 'missing_answer', 'question', q->>'label'); end if;
    if q->>'type' = 'choice' and v <> '' and not exists (select 1 from jsonb_array_elements_text(coalesce(q->'options','[]'::jsonb)) o where o = v) then
      return jsonb_build_object('ok', false, 'error', 'bad_answer', 'question', q->>'label');
    end if;
    if v <> '' then v_ans := v_ans || jsonb_build_object(q->>'id', left(v, 500)); end if;
  end loop;
  if coalesce((e.form_config->>'experience')::boolean, false) and length(btrim(coalesce(p_data->>'experience',''))) < 2 then
    return jsonb_build_object('ok', false, 'error', 'missing_experience');
  end if;
  if coalesce((e.form_config->>'photo')::boolean, false) and not exists (select 1 from public.people_documents where person_id = v_pid and kind = 'photo') then
    return jsonb_build_object('ok', false, 'error', 'missing_photo');
  end if;
  if jsonb_array_length(public.person_missing_docs(v_pid)) > 0 then
    return jsonb_build_object('ok', false, 'error', 'missing_docs', 'missing', public.person_missing_docs(v_pid));
  end if;
  if coalesce((p_data->>'nda')::boolean, false) is not true then return jsonb_build_object('ok', false, 'error', 'need_nda'); end if;
  if v_ids is not null and cardinality(v_ids) > 0 then
    v_ctext := public.payroll_contract_text_for(e.id, v_pid, v_ids);
    if v_ctext is not null and (p_data->>'contract_hash') is distinct from md5(v_ctext) then
      return jsonb_build_object('ok', false, 'error', case when nullif(p_data->>'contract_hash', '') is null then 'need_contract' else 'contract_changed' end);
    end if;
  end if;
  insert into public.applications(event_id, person_id, answers, experience, plan_id)
  values (e.id, v_pid, v_ans, nullif(left(btrim(coalesce(p_data->>'experience','')), 2000), ''), v_plan)
  on conflict (event_id, person_id) do update set answers = excluded.answers, experience = excluded.experience, status = 'active', updated_at = now(),
    plan_id = case when v_kind = 'pool' then public.applications.plan_id else excluded.plan_id end
  returning id into v_app;
  if v_ids is not null then
    delete from public.application_shifts where application_id = v_app and status in ('applied','waitlist','rejected') and not (shift_id = any(v_ids));
    insert into public.application_shifts(application_id, shift_id, status) select v_app, i, 'applied' from unnest(v_ids) i on conflict do nothing;
  end if;
  update public.applications set nda_accepted_at = now(), nda_hash = md5(public.payroll_nda_text()),
    apply_contract_text = case when v_kind = 'pool' then apply_contract_text else v_ctext end,
    apply_contract_hash = case when v_kind = 'pool' then apply_contract_hash else md5(v_ctext) end,
    apply_contract_at = case when v_kind = 'pool' then apply_contract_at when v_ctext is not null then now() end
  where id = v_app;
  perform public.contract_recheck_app(v_app);
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_pid::text, 'applied', 'applications', v_app,
    jsonb_build_object('shifts', coalesce(cardinality(v_ids), 0), 'mode', v_kind, 'plan', v_plan));
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_change_password(p_token text, p_old text, p_new text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token); v public.people; v_fail int;
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  -- 工讀生密碼至少 7 個字（與預設的民國生日 7 碼一致）；管理員仍至少 8 個字
  if length(coalesce(p_new,'')) < 7 then return jsonb_build_object('ok', false, 'error', 'too_short'); end if;
  select * into v from public.people where id = v_pid for update;
  -- 與登入共用錯誤次數與鎖定（錯 10 次鎖 15 分鐘）：拿到 session 也不能無限猜舊密碼
  if v.locked_until is not null and v.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked', 'retry_after_minutes', ceil(extract(epoch from v.locked_until - now()) / 60));
  end if;
  if v.password_hash is null or v.password_hash <> extensions.crypt(coalesce(p_old,''), v.password_hash) then
    v_fail := v.failed_logins + 1;
    if v_fail >= 10 then
      update public.people set failed_logins = 0, locked_until = now() + interval '15 minutes' where id = v_pid;
      insert into public.audit_log(actor, action, table_name, row_id) values (v_pid::text, 'password_change_locked', 'people', v_pid);
      return jsonb_build_object('ok', false, 'error', 'locked', 'retry_after_minutes', 15);
    end if;
    update public.people set failed_logins = v_fail where id = v_pid;
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  update public.people set password_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)),
    password_changed_at = now(), failed_logins = 0, updated_at = now() where id = v_pid;
  delete from public.sessions where person_id = v_pid
    and token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex');
  insert into public.audit_log(actor, action, table_name, row_id) values (v_pid::text, 'password_changed', 'people', v_pid);
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_checkin_ticket(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare parts text[] := string_to_array(coalesce(p_code,''), '.'); v_now bigint := floor(extract(epoch from now()) / 60);
  v_slot bigint; e public.events; v_ticket text;
begin
  if coalesce(array_length(parts,1),0) <> 3 or parts[1] !~ '^[0-9a-f]{32}$' or parts[2] !~ '^\d{1,12}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_code');
  end if;
  v_slot := parts[2]::bigint;
  select * into e from public.events where replace(id::text,'-','') = parts[1];
  if not found or public.checkin_make_code(e.id, v_slot) <> p_code then return jsonb_build_object('ok', false, 'error', 'bad_code'); end if;
  if v_slot > v_now or v_slot < v_now - 2 then return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  delete from public.checkin_tickets where expires_at < now();
  v_ticket := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.checkin_tickets(ticket_hash, event_id, expires_at)
  values (encode(extensions.digest(v_ticket, 'sha256'), 'hex'), e.id, now() + interval '15 minutes');
  return jsonb_build_object('ok', true, 'ticket', v_ticket, 'event', e.name);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_clean_profile(p jsonb, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare v_phone text := regexp_replace(coalesce(p->>'phone',''), '\D', '', 'g');
  v_code text := btrim(coalesce(p->>'bank_code','')); v_acct text := regexp_replace(coalesce(p->>'bank_account',''), '\D', '', 'g');
  v_an text := btrim(coalesce(p->>'bank_account_name','')); v_addr text := btrim(coalesce(p->>'address','')); v_email text := lower(btrim(coalesce(p->>'email','')));
begin
  if v_phone !~ '^09\d{8}$' then return jsonb_build_object('error', 'bad_phone'); end if;
  if length(v_addr) < 8 then return jsonb_build_object('error', 'bad_address'); end if;
  if v_email = '' then return jsonb_build_object('error', 'no_email'); end if;
  if length(v_email) > 120 or v_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then return jsonb_build_object('error', 'bad_email'); end if;
  if v_code !~ '^\d{3}$' then return jsonb_build_object('error', 'bad_bank_code'); end if;
  if v_acct !~ '^\d{6,16}$' then return jsonb_build_object('error', 'bad_bank_account'); end if;
  if v_an <> btrim(p_name) then return jsonb_build_object('error', 'payee_not_self'); end if;
  return jsonb_build_object('phone', v_phone, 'address', v_addr, 'email', nullif(v_email,''), 'bank_code', v_code,
    'bank_branch', nullif(btrim(coalesce(p->>'bank_branch','')),''), 'bank_account_name', v_an, 'bank_account', v_acct);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_clock(p_token text, p_ticket text, p_action text, p_ack boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token); e public.events; v_open public.attendance; v_today date := (now() at time zone 'Asia/Taipei')::date; v_mins int;
  v_s_in timestamptz; v_s_out timestamptz; v_kind text; v_n int; v_text text; v_now timestamptz := now(); v_pay_in timestamptz; v_pay_out timestamptz;
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select ev.* into e from public.checkin_tickets t join public.events ev on ev.id = t.event_id
  where t.ticket_hash = encode(extensions.digest(coalesce(p_ticket,''), 'sha256'), 'hex') and t.expires_at > now();
  if not found then return jsonb_build_object('ok', false, 'error', 'ticket'); end if;
  select s_in, s_out into v_s_in, v_s_out from public.today_schedule(v_pid, e.id, v_today);
  if p_action = 'status' then
    return jsonb_build_object('ok', true, 'event', e.name, 'block', case
        when e.start_date is null or v_today < e.start_date or v_today > coalesce(e.end_date, e.start_date) then 'not_event_day'
        when exists (select 1 from public.shifts where event_id = e.id) and v_s_in is null then 'not_scheduled'
        end,
      'sched_in', to_char(v_s_in at time zone 'Asia/Taipei', 'HH24:MI'), 'sched_out', to_char(v_s_out at time zone 'Asia/Taipei', 'HH24:MI')) || public.checkin_state(v_pid, e.id);
  end if;
  if e.start_date is null or v_today < e.start_date or v_today > coalesce(e.end_date, e.start_date) + 1 then
    return jsonb_build_object('ok', false, 'error', 'not_event_day', 'event', e.name);
  end if;
  select * into v_open from public.attendance a where a.person_id = v_pid and a.event_id = e.id
    and a.clock_in is not null and a.clock_out is null and a.clock_in > now() - interval '20 hours' order by a.clock_in desc limit 1;
  if p_action = 'in' then
    if v_today > coalesce(e.end_date, e.start_date) then return jsonb_build_object('ok', false, 'error', 'not_event_day', 'event', e.name); end if;
    if exists (select 1 from public.shifts where event_id = e.id) and v_s_in is null then
      return jsonb_build_object('ok', false, 'error', 'not_scheduled', 'event', e.name) || public.checkin_state(v_pid, e.id);
    end if;
    if v_open.id is not null then return jsonb_build_object('ok', false, 'error', 'already_in', 'event', e.name) || public.checkin_state(v_pid, e.id); end if;
    if exists (select 1 from public.attendance where person_id = v_pid and event_id = e.id and work_date = v_today) then
      return jsonb_build_object('ok', false, 'error', 'already_done', 'event', e.name) || public.checkin_state(v_pid, e.id);
    end if;
    -- 提早到：從表定時間起算；遲到：照實際簽到時間起算，不另扣
    if v_s_in is not null and v_now < v_s_in - interval '1 minute' then
      v_kind := 'early'; v_n := ceil(extract(epoch from v_s_in - v_now) / 60);
      v_text := format('表定上班時間為 %s，你提早 %s 分鐘到場。提早到場的時間不計入工時，工資自 %s 起算。如果是主管要求你提早開始工作，請告訴現場主管，由主管在系統核准後改從實際簽到時間計薪。',
        to_char(v_s_in at time zone 'Asia/Taipei', 'HH24:MI'), v_n, to_char(v_s_in at time zone 'Asia/Taipei', 'HH24:MI'));
    elsif v_s_in is not null and v_now >= v_s_in + interval '1 minute' then
      v_kind := 'late'; v_n := floor(extract(epoch from v_now - v_s_in) / 60);
      v_text := format('表定上班時間為 %s，你已遲到 %s 分鐘。工資自實際簽到時間 %s 起算，只少算未出勤的分鐘數，不另外扣款。',
        to_char(v_s_in at time zone 'Asia/Taipei', 'HH24:MI'), v_n, to_char(v_now at time zone 'Asia/Taipei', 'HH24:MI'));
    end if;
    if v_kind is not null and not coalesce(p_ack, false) then
      return jsonb_build_object('ok', false, 'error', 'need_ack', 'event', e.name, 'notice', jsonb_build_object('kind', v_kind, 'minutes', v_n, 'text', v_text)) || public.checkin_state(v_pid, e.id);
    end if;
    insert into public.attendance(person_id, event_id, work_date, clock_in, source, sched_in, sched_out, in_notice, in_notice_minutes, in_notice_text, in_ack_at)
    values (v_pid, e.id, v_today, v_now, 'qr', v_s_in, v_s_out, v_kind, v_n, v_text, case when v_kind is not null then v_now end);
    insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_pid::text, 'clock_in', 'events', e.id, case when v_kind is not null then jsonb_build_object('notice', v_kind, 'minutes', v_n) end);
  elsif p_action = 'out' then
    if v_open.id is null then return jsonb_build_object('ok', false, 'error', 'not_in', 'event', e.name) || public.checkin_state(v_pid, e.id); end if;
    -- 超過表定下班：延長工時需主管核准才計薪
    if v_open.sched_out is not null and v_now >= v_open.sched_out + interval '1 minute' then
      v_kind := 'overtime'; v_n := floor(extract(epoch from v_now - v_open.sched_out) / 60);
      v_text := format('表定下班時間為 %s，現在已超過 %s 分鐘。延長工時須經現場主管核准才計薪，未核准的部分工資計算到 %s。如果是主管要求你留下工作，請告訴主管在系統核准。',
        to_char(v_open.sched_out at time zone 'Asia/Taipei', 'HH24:MI'), v_n, to_char(v_open.sched_out at time zone 'Asia/Taipei', 'HH24:MI'));
      if not coalesce(p_ack, false) then
        return jsonb_build_object('ok', false, 'error', 'need_ack', 'event', e.name, 'notice', jsonb_build_object('kind', v_kind, 'minutes', v_n, 'text', v_text)) || public.checkin_state(v_pid, e.id);
      end if;
    end if;
    v_pay_in := case when v_open.sched_in is not null and v_open.clock_in < v_open.sched_in and v_open.early_approved_at is null then v_open.sched_in else v_open.clock_in end;
    v_pay_out := case when v_open.sched_out is not null and v_now > v_open.sched_out and v_open.ot_approved_at is null then v_open.sched_out else v_now end;
    v_mins := greatest(floor(extract(epoch from v_pay_out - v_pay_in) / 60), 0);
    update public.attendance set clock_out = v_now,
      break_minutes = case when v_mins >= 240 then least(e.default_break_minutes, v_mins) else 0 end,
      out_notice = v_kind, out_notice_minutes = v_n, out_notice_text = v_text, out_ack_at = case when v_kind is not null then v_now end
    where id = v_open.id;
    insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_pid::text, 'clock_out', 'events', e.id, case when v_kind is not null then jsonb_build_object('notice', v_kind, 'minutes', v_n) end);
  else
    return jsonb_build_object('ok', false, 'error', 'bad_action');
  end if;
  return jsonb_build_object('ok', true, 'event', e.name, 'done', p_action) || public.checkin_state(v_pid, e.id);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_compute(p_event uuid, p_person uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  e public.events; st public.event_staff; a record;
  v_rate numeric; v_type text; v_rh numeric; v_ins numeric; v_deduct boolean;
  m int; c int; pos int; dtype text; hol text; nm int; ot int; ot1 int; ot2 int; ot3 int; x int; y int; z int;
  items jsonb := '[]'::jsonb; warns jsonb := '[]'::jsonb; gross numeric := 0; ded numeric := 0; n_days int := 0;
  v_min numeric; r public.labor_ins_rates; v_first date; v_last date; wk record;
  -- 產生一筆應發項目
  amt numeric; v_base_rh numeric; v_r1 numeric; v_r2 numeric;
begin
  select * into e from public.events where id = p_event;
  select * into st from public.event_staff where event_id = p_event and person_id = p_person;
  v_type := coalesce(st.pay_type, 'hourly');
  v_rate := coalesce(st.rate, case when v_type = 'hourly' then coalesce(e.default_hourly_rate, (select max(sh.rate) from public.application_shifts x join public.applications ap on ap.id = x.application_id join public.shifts sh on sh.id = x.shift_id where ap.event_id = p_event and ap.person_id = p_person and x.status = 'accepted')) end);
  v_ins := coalesce(st.insured_salary, e.insured_salary);
  v_deduct := coalesce(st.deduct_insurance, true);
  if v_rate is null or v_rate <= 0 then return jsonb_build_object('ok', false, 'error', 'no_rate'); end if;
  if exists (select 1 from public.attendance where event_id = p_event and person_id = p_person and clock_in is not null and clock_out is null) then
    return jsonb_build_object('ok', false, 'error', 'open_attendance');
  end if;
  v_rh := case when v_type = 'daily' then v_rate / 8 else v_rate end;
  v_base_rh := v_rh;

  -- 同一天多筆出勤（中途離開再簽到）合併成一天計算；兩段之間的空檔算休息
  for a in select work_date, sum(public.att_minutes(t))::int as mins, sum(t.break_minutes)::int as paid_break,
      (sum(t.break_minutes) + round(extract(epoch from max(t.clock_out) - min(t.clock_in)) / 60 - sum(extract(epoch from t.clock_out - t.clock_in) / 60)))::int as break_minutes
    from public.attendance t where event_id = p_event and person_id = p_person and clock_in is not null and clock_out is not null group by work_date order by work_date loop
    m := a.mins;
    if m <= 0 then continue; end if;
    n_days := n_days + 1; v_first := coalesce(v_first, a.work_date); v_last := a.work_date;
    v_rh := v_base_rh;
    if v_type = 'hourly' then
      select min(sh.rate), max(sh.rate) into v_r1, v_r2
      from public.application_shifts x join public.applications ap on ap.id = x.application_id join public.shifts sh on sh.id = x.shift_id
      where ap.event_id = p_event and ap.person_id = p_person and ap.status = 'active' and x.status = 'accepted' and sh.work_date = a.work_date;
      if v_r2 is null then
        v_rh := coalesce(st.rate, e.default_hourly_rate);
        if v_rh is null then
          v_rh := v_base_rh;
          warns := warns || jsonb_build_object('severity','error','code','no_rate_day','detail', format('%s 沒有可用的時薪（班次、人員、活動預設都沒有設定），暫以 %s 元試算，請補上後重算', a.work_date, v_base_rh));
        end if;
      else
        v_rh := v_r2;
        if v_r1 <> v_r2 then warns := warns || jsonb_build_object('severity','warn','code','mixed_rates','detail', format('%s 有不同時薪的班次（%s／%s 元），以較高的 %s 元計算，請人工核對', a.work_date, v_r1, v_r2, v_r2)); end if;
      end if;
    end if;
    select name into hol from public.holidays where day = a.work_date;
    c := 1;
    while c < 60 and exists (select 1 from public.attendance where person_id = p_person and work_date = a.work_date - c) loop c := c + 1; end loop;
    pos := ((c - 1) % 7) + 1;
    dtype := case when hol is not null then 'holiday' when pos = 7 then 'regular_leave' when pos = 6 then 'rest' else 'weekday' end;
    select hourly into v_min from public.min_wages where effective_from <= a.work_date order by effective_from desc limit 1;
    if v_min is not null and v_rh < v_min then
      warns := warns || jsonb_build_object('severity','error','code','below_min_wage','detail', format('%s 時薪 %s 低於最低工資 %s', a.work_date, round(v_rh,2), v_min));
    end if;
    if m > 720 then warns := warns || jsonb_build_object('severity','error','code','over_12h','detail', format('%s 工時 %s 小時，超過單日 12 小時上限（勞基法第32條）', a.work_date, round(m/60.0,2))); end if;
    if m > 240 and a.break_minutes < 30 then warns := warns || jsonb_build_object('severity','warn','code','no_break','detail', format('%s 連續工作超過 4 小時但休息不足 30 分鐘（勞基法第35條）', a.work_date)); end if;

    if dtype in ('weekday','holiday') then
      -- 8 小時內 ×1；第 9–10 小時 ×1.34；第 11–12 小時 ×1.67；超過 12 小時 ×2
      nm := least(m, 480); ot := greatest(m - 480, 0); ot1 := least(ot, 120); ot2 := least(greatest(ot - 120, 0), 120); ot3 := greatest(ot - 240, 0);
      if dtype = 'weekday' then
        amt := case when v_type = 'daily' then round(v_rate) else round(nm / 60.0 * v_rh) end;
        items := items || jsonb_build_object('code','regular','label', case when v_type = 'daily' then '日薪' else '一般工時（×1）' end, 'work_date', a.work_date, 'hours', round(nm/60.0,2), 'rate', case when v_type = 'daily' then null else v_rh end, 'amount', amt, 'sort', 10);
      else
        amt := case when v_type = 'daily' then round(v_rate * 2) else round(nm / 60.0 * v_rh * 2) end;
        items := items || jsonb_build_object('code','holiday','label', '國定假日出勤（' || hol || '，加倍）', 'work_date', a.work_date, 'hours', round(nm/60.0,2), 'rate', round(v_rh * 2, 2), 'amount', amt, 'sort', 10);
      end if;
      gross := gross + amt;
      if ot1 > 0 then amt := round(ot1 / 60.0 * v_rh * 1.34); gross := gross + amt;
        items := items || jsonb_build_object('code','ot_1','label','加班第9–10小時（×1.34）','work_date', a.work_date, 'hours', round(ot1/60.0,2), 'rate', round(v_rh*1.34,2), 'amount', amt, 'sort', 11); end if;
      if ot2 > 0 then amt := round(ot2 / 60.0 * v_rh * 1.67); gross := gross + amt;
        items := items || jsonb_build_object('code','ot_2','label','加班第11–12小時（×1.67）','work_date', a.work_date, 'hours', round(ot2/60.0,2), 'rate', round(v_rh*1.67,2), 'amount', amt, 'sort', 12); end if;
      if ot3 > 0 then amt := round(ot3 / 60.0 * v_rh * 2); gross := gross + amt;
        items := items || jsonb_build_object('code','ot_3','label','加班超過12小時（×2）','work_date', a.work_date, 'hours', round(ot3/60.0,2), 'rate', round(v_rh*2,2), 'amount', amt, 'sort', 13); end if;
    elsif dtype = 'rest' then
      if v_type = 'daily' then m := greatest(m, 480); end if;
      x := least(m, 120); y := least(greatest(m - 120, 0), 360); z := greatest(m - 480, 0);
      amt := round(x / 60.0 * v_rh * 1.34); gross := gross + amt;
      items := items || jsonb_build_object('code','rest_1','label','休息日出勤前2小時（×1.34）','work_date', a.work_date, 'hours', round(x/60.0,2), 'rate', round(v_rh*1.34,2), 'amount', amt, 'sort', 10);
      if y > 0 then amt := round(y / 60.0 * v_rh * 1.67); gross := gross + amt;
        items := items || jsonb_build_object('code','rest_2','label','休息日出勤第3至8小時（×1.67）','work_date', a.work_date, 'hours', round(y/60.0,2), 'rate', round(v_rh*1.67,2), 'amount', amt, 'sort', 11); end if;
      if z > 0 then amt := round(z / 60.0 * v_rh * 2.67); gross := gross + amt;
        items := items || jsonb_build_object('code','rest_3','label','休息日出勤第9小時起（×2.67）','work_date', a.work_date, 'hours', round(z/60.0,2), 'rate', round(v_rh*2.67,2), 'amount', amt, 'sort', 12); end if;
      warns := warns || jsonb_build_object('severity','warn','code','rest_day','detail', format('%s 是連續出勤第 6 天，已依休息日加給計算', a.work_date));
    else
      if v_type = 'daily' then m := greatest(m, 480); end if;
      amt := round(m / 60.0 * v_rh * 2); gross := gross + amt;
      items := items || jsonb_build_object('code','regular_leave','label','例假出勤（加倍）','work_date', a.work_date, 'hours', round(m/60.0,2), 'rate', round(v_rh*2,2), 'amount', amt, 'sort', 10);
      warns := warns || jsonb_build_object('severity','error','code','regular_leave_work','detail', format('%s 是連續出勤第 7 天（例假），除天災事變外不得出勤（勞基法第36、40條），已加倍計算並應另給補休', a.work_date));
    end if;
    -- 休息時間依合約不計入工時（不算進加班門檻），但公司照常給薪：按當日時薪 ×1 另列一項（日薪制已含在日薪內）
    if v_type = 'hourly' and coalesce(a.paid_break, 0) > 0 then
      amt := round(a.paid_break / 60.0 * v_rh); gross := gross + amt;
      items := items || jsonb_build_object('code','paid_break','label','休息時間（照常給薪）','work_date', a.work_date, 'hours', round(a.paid_break/60.0,2), 'rate', v_rh, 'amount', amt, 'sort', 19);
    end if;
  end loop;

  if n_days = 0 then return jsonb_build_object('ok', false, 'error', 'no_attendance'); end if;

  for wk in select date_trunc('week', q.d)::date w, sum(least(q.dm, 480)) mins
            from (select work_date d, sum(public.att_minutes(attendance.*)) dm from public.attendance
                  where event_id = p_event and person_id = p_person and clock_in is not null and clock_out is not null group by 1) q group by 1 loop
    if wk.mins > 2400 then warns := warns || jsonb_build_object('severity','warn','code','week_over_40','detail', format('%s 起該週正常工時合計 %s 小時，超過 40 小時的部分應依加班計算，請人工確認', wk.w, round(wk.mins/60.0,1))); end if;
  end loop;

  if v_deduct then
    select * into r from public.labor_ins_rates where effective_from <= v_first order by effective_from desc limit 1;
    ded := n_days * (round(v_ins * r.ordinary * 0.2 / 30) + round(v_ins * r.employment * 0.2 / 30));
  end if;
  if gross >= coalesce((select monthly from public.min_wages where effective_from <= v_last order by effective_from desc limit 1), 1e9) then
    warns := warns || jsonb_build_object('severity','warn','code','nhi_supplement','detail','單次給付達每月最低工資，請確認是否需代扣二代健保補充保費與所得稅');
  end if;
  return jsonb_build_object('ok', true, 'items', items, 'gross', gross, 'deductions', ded, 'net', gross - ded, 'days', n_days,
    'period_start', v_first, 'period_end', v_last, 'warnings', warns, 'insured_salary', v_ins, 'role', st.role);
end $function$
;

CREATE OR REPLACE FUNCTION public.payslip_regenerate(p_event uuid, p_person uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 依出勤重算一個人在一場活動的薪資單草稿（產生全部與單人重算共用）
-- 重算時保留管理員手動設定的備註與發薪日，以及已標為處理過、內容沒變的問題
declare e public.events; pr public.people; c jsonb; v_id uuid; it jsonb; w jsonb; v_pay date; v_existing public.payslips; v_replaced boolean := false;
  v_done text[] := '{}';
begin
  select * into e from public.events where id = p_event;
  select * into pr from public.people where id = p_person;
  if e.id is null or pr.id is null then return jsonb_build_object('result', 'skipped', 'reason', '找不到活動或人員'); end if;
  v_pay := coalesce(e.pay_date, e.end_date + e.pay_within_days);
  if coalesce((select relation from public.event_staff where event_id = p_event and person_id = pr.id), 'employment') = 'contract' then
    return jsonb_build_object('result', 'skipped', 'reason', '承攬人員不自動算薪');
  end if;
  select * into v_existing from public.payslips where event_id = p_event and person_id = pr.id and status <> 'void' order by generated desc limit 1;
  if v_existing.id is not null and v_existing.cash_paid_at is not null then
    return jsonb_build_object('result', 'skipped', 'reason', '現金已發放，不重算（金額要調整請另行處理）');
  end if;
  if v_existing.id is not null and v_existing.status = 'published' then
    return jsonb_build_object('result', 'skipped', 'reason', '薪資單已發布，請先取消發布再重算');
  end if;
  if v_existing.id is not null and not v_existing.generated then
    return jsonb_build_object('result', 'skipped', 'reason', '已有人工匯入的薪資單');
  end if;
  if v_existing.id is not null and v_existing.relation = 'contract' then
    return jsonb_build_object('result', 'skipped', 'reason', '這張薪資單已改為承攬，不依出勤重算');
  end if;
  c := public.payroll_compute(p_event, pr.id);
  if not (c->>'ok')::boolean then
    return jsonb_build_object('result', 'skipped', 'reason', case c->>'error' when 'no_rate' then '尚未設定時薪或日薪' when 'open_attendance' then '有尚未簽退的出勤' else '沒有完整的出勤紀錄' end);
  end if;
  if v_existing.id is not null then
    if v_existing.pay_date is not null then v_pay := v_existing.pay_date; end if;
    select coalesce(array_agg(code || '|' || detail), '{}') into v_done from public.data_issues where payslip_id = v_existing.id and resolved;
    delete from public.payslips where id = v_existing.id; v_replaced := true;
  end if;
  insert into public.payslips(person_id, event_id, relation, role, period_start, period_end, pay_date, basis, gross, allowances, deductions, net,
    status, generated, note, pay_bank_code, pay_bank_branch, pay_account_name, pay_account)
  values (pr.id, p_event, 'employment', c->>'role', (c->>'period_start')::date, (c->>'period_end')::date, v_pay, 'hourly',
    (c->>'gross')::numeric, 0, (c->>'deductions')::numeric, (c->>'net')::numeric, 'draft', true, v_existing.note, pr.bank_code, pr.bank_branch, pr.bank_account_name, pr.bank_account)
  returning id into v_id;
  if v_existing.pay_method = 'cash' then update public.payslips set pay_method = 'cash' where id = v_id; end if;
  for it in select * from jsonb_array_elements(c->'items') loop
    insert into public.payslip_items(payslip_id, kind, code, label, work_date, hours, rate, amount, sort)
    values (v_id, 'earning', it->>'code', it->>'label', (it->>'work_date')::date, (it->>'hours')::numeric, (it->>'rate')::numeric, (it->>'amount')::numeric, (it->>'sort')::int);
  end loop;
  if (c->>'deductions')::numeric > 0 then
    insert into public.payslip_items(payslip_id, kind, code, label, amount, sort)
    values (v_id, 'deduction', 'labor_ins', format('勞保與就保自付額（%s 日，投保薪資 %s）', c->>'days', c->>'insured_salary'), (c->>'deductions')::numeric, 30);
  end if;
  for w in select * from jsonb_array_elements(c->'warnings') loop
    insert into public.data_issues(event_id, payslip_id, person_id, severity, code, detail, resolved)
    values (p_event, v_id, pr.id, w->>'severity', w->>'code', w->>'detail', (w->>'code') || '|' || (w->>'detail') = any(v_done));
  end loop;
  insert into public.data_issues(event_id, payslip_id, person_id, severity, code, detail, resolved)
  select p_event, v_id, pr.id, 'warn', 'same_day_other_event', x.detail, ('same_day_other_event|' || x.detail) = any(v_done)
  from (select '同一天也在其他活動出勤：' || string_agg(to_char(y.work_date, 'MM/DD') || '「' || y.name || '」', '、' order by y.work_date, y.name) detail
        from (select distinct o2.work_date, e2.name
              from public.attendance a1 join public.attendance o2 on o2.person_id = a1.person_id and o2.work_date = a1.work_date and o2.event_id <> a1.event_id
              join public.events e2 on e2.id = o2.event_id and e2.archived_at is null
              where a1.event_id = p_event and a1.person_id = pr.id) y) x
  where x.detail is not null;
  if pr.bank_account is null and coalesce(v_existing.pay_method, 'transfer') <> 'cash' then
    insert into public.data_issues(event_id, payslip_id, person_id, severity, code, detail, resolved) values (p_event, v_id, pr.id, 'warn', 'no_bank_account', '沒有匯款帳號', 'no_bank_account|沒有匯款帳號' = any(v_done));
  end if;
  if v_pay is null then
    insert into public.data_issues(event_id, payslip_id, person_id, severity, code, detail, resolved) values (p_event, v_id, pr.id, 'warn', 'no_pay_date', '尚未設定發薪日', 'no_pay_date|尚未設定發薪日' = any(v_done));
  end if;
  return jsonb_build_object('result', case when v_replaced then 'replaced' else 'created' end, 'id', v_id, 'gross', (c->>'gross')::numeric, 'net', (c->>'net')::numeric);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_contract(p_token text, p_app uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token); a public.applications; v_text text;
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into a from public.applications where id = p_app and person_id = v_pid;
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if a.contract_accepted_at is not null then return jsonb_build_object('ok', true, 'text', a.contract_text, 'accepted_at', a.contract_accepted_at); end if;
  v_text := public.payroll_contract_text(a.id);
  return jsonb_build_object('ok', true, 'text', v_text, 'hash', md5(coalesce(v_text, '')), 'accepted_at', null);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_contract_text_v1(p_app uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-11-25 前的舊版契約模板，只用來比對已確認的舊契約是否仍有效
declare a public.applications; e public.events; em public.employers; p public.people; lines text; roles text;
begin
  select * into a from public.applications where id = p_app;
  select * into e from public.events where id = a.event_id;
  select * into em from public.employers where id = e.employer_id;
  select * into p from public.people where id = a.person_id;
  select string_agg(format('　%s（%s）%s–%s%s　%s　時薪 %s 元', to_char(s.work_date, 'YYYY/MM/DD'),
      (array['日','一','二','三','四','五','六'])[extract(dow from s.work_date)::int + 1], to_char(s.start_time, 'HH24:MI'), to_char(s.end_time, 'HH24:MI'),
      case when s.end_time <= s.start_time then '（翌日）' else '' end, coalesce(s.role, '活動人員'), trim(to_char(coalesce(s.rate, e.default_hourly_rate), 'FM999999990.##'))),
      E'\n' order by s.work_date, s.start_time),
    string_agg(distinct coalesce(s.role, '活動人員'), '、')
  into lines, roles
  from public.application_shifts x join public.shifts s on s.id = x.shift_id where x.application_id = p_app and x.status = 'accepted';
  if lines is null then return null; end if;
  return '臨時僱用勞動契約' || E'\n\n'
    || '雇主：' || coalesce(em.legal_name, em.name) || coalesce('（統一編號 ' || em.tax_id || '）', '') || E'\n'
    || '勞工：' || p.name || '（身分證字號 ' || public.payroll_mask_id(p.national_id) || '）' || E'\n\n'
    || '一、工作地點：' || coalesce(e.location, '依活動通知之地點') || E'\n'
    || '二、工作內容：擔任「' || e.name || '」' || roles || '，從事活動現場相關工作，並遵守現場負責人之合理指揮。' || E'\n'
    || '三、工作日期與時間：' || E'\n' || lines || E'\n'
    || '　每日連續工作逾 4 小時，於現場安排休息 ' || greatest(e.default_break_minutes, 30) || ' 分鐘，休息時間不計入工時。' || E'\n'
    || '四、工資：依上列時薪，按實際簽到退紀錄（記錄至分鐘）計算給付。延長工時、休息日及國定假日出勤，依勞動基準法第 24 條、第 39 條規定加給。工資不低於最低工資。' || E'\n'
    || '五、發薪：' || case when e.pay_date is not null then '於 ' || to_char(e.pay_date, 'YYYY/MM/DD') when e.pay_within_days is not null then '於活動結束後 ' || e.pay_within_days || ' 日內' else '於活動結束後依雇主通知之日期' end
    || '全額匯入勞工本人帳戶，並於系統提供工資各項目計算方式明細，勞工可隨時查閱及列印。' || E'\n'
    || '六、保險與退休金：雇主依法為勞工投保勞工保險、就業保險及職業災害保險，勞工應自付之保費自工資中扣除；並依勞工退休金條例提繳退休金。' || E'\n'
    || '七、出勤紀錄：勞工應於現場以 QR 碼簽到、簽退。出勤紀錄依法保存五年，勞工得隨時申請副本。' || E'\n'
    || '八、請假與異動：勞工如無法出勤，應儘速於排定日前通知雇主。雇主如需取消或變更排班，應事先通知勞工。' || E'\n'
    || '九、契約期間：本契約為臨時性定期契約，自上列第一個工作日起至最後一個工作日止，期滿自動終止。' || E'\n'
    || '十、本契約未約定事項，依勞動基準法及相關法令辦理。';
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_contract_text_for(p_event uuid, p_person uuid, p_shifts uuid[])
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.applications; e public.events; em public.employers; p public.people; lines text; roles text; rates numeric[]; one_rate boolean;
begin
  select * into e from public.events where id = p_event;
  select * into em from public.employers where id = e.employer_id;
  select * into p from public.people where id = p_person;
  select array_agg(distinct coalesce(s.rate, e.default_hourly_rate)), string_agg(distinct coalesce(s.role, '活動人員'), '、')
  into rates, roles
  from public.shifts s where s.id = any(p_shifts) and s.event_id = p_event;
  if roles is null then return null; end if;
  -- 全部班次同一個時薪就寫在第四條；不同時薪時逐行列出
  one_rate := cardinality(rates) = 1 and rates[1] is not null;
  select string_agg(format('　%s（%s）%s–%s%s%s', to_char(s.work_date, 'YYYY/MM/DD'),
      (array['日','一','二','三','四','五','六'])[extract(dow from s.work_date)::int + 1], to_char(s.start_time, 'HH24:MI'), to_char(s.end_time, 'HH24:MI'),
      case when s.end_time <= s.start_time then '（翌日）' else '' end,
      case when one_rate then '' else '　時薪 ' || coalesce(trim(to_char(coalesce(s.rate, e.default_hourly_rate), 'FM999999990.##')), '（未定）') || ' 元' end),
      E'\n' order by s.work_date, s.start_time)
  into lines
  from public.shifts s where s.id = any(p_shifts) and s.event_id = p_event;
  return '短期性僱用勞動契約' || E'\n\n'
    || '僱用人：' || coalesce(em.legal_name, em.name) || '（下稱甲方）' || E'\n'
    || coalesce('統一編號：' || nullif(btrim(em.tax_id), '') || E'\n', '')
    || '受僱人：' || p.name || '（下稱乙方）' || E'\n'
    || '身分證字號：' || public.payroll_mask_id(p.national_id) || E'\n\n'
    || '一、工作地點：' || coalesce(nullif(btrim(e.location), ''), '依甲方通知之地點') || E'\n'
    || '二、工作內容：乙方擔任「' || e.name || '」' || roles || '，從事活動現場相關工作，並遵守現場負責人之合理指揮。' || E'\n'
    || '三、工作日期與時間：' || E'\n' || lines || E'\n'
    || '　每日連續工作逾 4 小時，於現場安排休息 ' || greatest(e.default_break_minutes, 30) || ' 分鐘，休息時間不計入工時。' || E'\n'
    || '四、工資：' || case when one_rate then '時薪 ' || trim(to_char(rates[1], 'FM999999990.##')) || ' 元，' else '依上列時薪，' end
    || '甲方按乙方實際簽到退紀錄（記錄至分鐘）計算給付。延長工時、休息日及國定假日出勤，依勞動基準法第 24 條、第 39 條規定加給。工資不低於最低工資。' || E'\n'
    || '五、發薪：甲方' || case when e.pay_date is not null then '於 ' || to_char(e.pay_date, 'YYYY/MM/DD') when e.pay_within_days is not null then '於活動結束後 ' || e.pay_within_days || ' 日內' else '於活動結束後依甲方通知之日期' end
    || '全額匯入乙方本人帳戶，並於系統提供工資各項目計算方式明細，乙方可隨時查閱及列印。' || E'\n'
    || '六、保險與退休金：甲方依法為勞工投保勞工保險、就業保險及職業災害保險，乙方應自付之保費自工資中扣除；甲方並依勞工退休金條例提繳退休金。' || E'\n'
    || '七、出勤紀錄：乙方應於現場以 QR 碼簽到、簽退。出勤紀錄依法保存五年，乙方得隨時申請副本。' || E'\n'
    || '八、請假與異動：乙方如無法出勤，應儘速於排定日前通知甲方。甲方如需取消或變更排班，應事先通知乙方。' || E'\n'
    || '九、契約期間：本契約為短期性職務代理人契約，自本契約效力僅於第三項所約定之期間，期滿自動終止。' || E'\n'
    || '十、本契約未約定事項，依勞動基準法及相關法令辦理。';
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_contract_text(p_app uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.payroll_contract_text_for(a.event_id, a.person_id, array(select x.shift_id from public.application_shifts x where x.application_id = a.id and x.status = 'accepted'))
  from public.applications a where a.id = p_app
$function$
;

CREATE OR REPLACE FUNCTION public.payroll_contract_text_v2(p_app uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.applications; e public.events; em public.employers; p public.people; lines text; roles text; rates numeric[]; one_rate boolean;
begin
  select * into a from public.applications where id = p_app;
  select * into e from public.events where id = a.event_id;
  select * into em from public.employers where id = e.employer_id;
  select * into p from public.people where id = a.person_id;
  select array_agg(distinct coalesce(s.rate, e.default_hourly_rate)), string_agg(distinct coalesce(s.role, '活動人員'), '、')
  into rates, roles
  from public.application_shifts x join public.shifts s on s.id = x.shift_id where x.application_id = p_app and x.status = 'accepted';
  if roles is null then return null; end if;
  -- 全部班次同一個時薪就寫在第四條；不同時薪時逐行列出
  one_rate := cardinality(rates) = 1 and rates[1] is not null;
  select string_agg(format('　%s（%s）%s–%s%s%s', to_char(s.work_date, 'YYYY/MM/DD'),
      (array['日','一','二','三','四','五','六'])[extract(dow from s.work_date)::int + 1], to_char(s.start_time, 'HH24:MI'), to_char(s.end_time, 'HH24:MI'),
      case when s.end_time <= s.start_time then '（翌日）' else '' end,
      case when one_rate then '' else '　時薪 ' || coalesce(trim(to_char(coalesce(s.rate, e.default_hourly_rate), 'FM999999990.##')), '（未定）') || ' 元' end),
      E'\n' order by s.work_date, s.start_time)
  into lines
  from public.application_shifts x join public.shifts s on s.id = x.shift_id where x.application_id = p_app and x.status = 'accepted';
  return '短期性僱用勞動契約' || E'\n\n'
    || '僱用人：' || coalesce(em.legal_name, em.name) || '（下稱甲方）' || E'\n'
    || coalesce('統一編號：' || nullif(btrim(em.tax_id), '') || E'\n', '')
    || '受僱人：' || p.name || '（下稱乙方）' || E'\n'
    || '身分證字號：' || public.payroll_mask_id(p.national_id) || E'\n\n'
    || '一、工作地點：' || coalesce(nullif(btrim(e.location), ''), '依甲方通知之地點') || E'\n'
    || '二、工作內容：乙方擔任「' || e.name || '」' || roles || '，從事活動現場相關工作，並遵守現場負責人之合理指揮。' || E'\n'
    || '三、工作日期與時間：' || E'\n' || lines || E'\n'
    || '　每日連續工作逾 4 小時，於現場安排休息 ' || greatest(e.default_break_minutes, 30) || ' 分鐘，休息時間不計入工時。' || E'\n'
    || '四、工資：' || case when one_rate then '時薪 ' || trim(to_char(rates[1], 'FM999999990.##')) || ' 元，' else '依上列時薪，' end
    || '甲方按乙方實際簽到退紀錄（記錄至分鐘）計算給付。延長工時、休息日及國定假日出勤，依勞動基準法第 24 條、第 39 條規定加給。工資不低於最低工資。' || E'\n'
    || '五、發薪：甲方' || case when e.pay_date is not null then '於 ' || to_char(e.pay_date, 'YYYY/MM/DD') when e.pay_within_days is not null then '於活動結束後 ' || e.pay_within_days || ' 日內' else '於活動結束後依甲方通知之日期' end
    || '全額匯入乙方本人帳戶，並於系統提供工資各項目計算方式明細，乙方可隨時查閱及列印。' || E'\n'
    || '六、保險與退休金：甲方依法為勞工投保勞工保險、就業保險及職業災害保險，乙方應自付之保費自工資中扣除；甲方並依勞工退休金條例提繳退休金。' || E'\n'
    || '七、出勤紀錄：乙方應於現場以 QR 碼簽到、簽退。出勤紀錄依法保存五年，乙方得隨時申請副本。' || E'\n'
    || '八、請假與異動：乙方如無法出勤，應儘速於排定日前通知甲方。甲方如需取消或變更排班，應事先通知乙方。' || E'\n'
    || '九、契約期間：本契約為短期性定期契約，效力僅及於第三項所約定之期間，期滿自動終止。' || E'\n'
    || '十、本契約未約定事項，依勞動基準法及相關法令辦理。';
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_event_public(p_join text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e public.events; em public.employers; t record; v jsonb; v_ids uuid[];
begin
  select * into t from public.join_target(p_join);
  select * into e from public.events where id = t.event_id;
  if not found or coalesce(e.end_date, e.start_date) < (now() at time zone 'Asia/Taipei')::date - 1 then return jsonb_build_object('ok', false, 'error', 'bad_join'); end if;
  select * into em from public.employers where id = e.employer_id;
  v := public.recruit_view(e.id, t.plan_id);
  select coalesce(array_agg(distinct x::uuid), '{}') into v_ids from jsonb_array_elements(v->'plans') pj, jsonb_array_elements_text(pj->'shift_ids') x;
  return jsonb_build_object('ok', true, 'event', jsonb_build_object('name', e.name, 'start_date', e.start_date, 'end_date', e.end_date,
      'location', e.location, 'description', e.description, 'recruiting', e.recruiting, 'employer', coalesce(em.legal_name, em.name),
      'default_hourly_rate', e.default_hourly_rate, 'form', e.form_config),
    'mode', v->>'kind', 'plans', v->'plans', 'require_line', public.recruit_need_line(),
    'shifts', case v->>'kind' when 'pool' then '[]'::jsonb
      else coalesce((select jsonb_agg(public.shift_json(s) order by s.work_date, s.start_time) from public.shifts s
        where s.event_id = e.id and (v->>'kind' = 'pick' or s.id = any(v_ids))), '[]'::jsonb) end);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_join_info(p_join text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select jsonb_build_object('ok', true, 'event', e.name, 'employer', em.name)
    from public.events e join public.employers em on em.id = e.employer_id
    where e.id = (select t.event_id from public.join_target(p_join) t) and coalesce(e.end_date, e.start_date) >= (now() at time zone 'Asia/Taipei')::date - 1),
    jsonb_build_object('ok', false, 'error', 'bad_join'));
$function$
;

CREATE OR REPLACE FUNCTION public.payroll_line_code(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token); v_code text; i int := 0;
begin
  perform pg_advisory_xact_lock(hashtext('line_link'));
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if public.setting('line_basic_id') is null then return jsonb_build_object('ok', false, 'error', 'not_configured'); end if;
  delete from public.line_link_codes where person_id = v_pid or expires_at < now();
  loop
    v_code := lpad((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0'); i := i + 1;
    exit when not exists (select 1 from public.line_link_codes where code = v_code) or i > 20;
  end loop;
  insert into public.line_link_codes(code, person_id, expires_at) values (v_code, v_pid, now() + interval '15 minutes');
  return jsonb_build_object('ok', true, 'code', v_code, 'basic_id', public.setting('line_basic_id'));
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_line_status(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token);
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return (select jsonb_build_object('ok', true, 'linked', p.line_user_id is not null, 'linked_at', p.line_linked_at,
    'basic_id', public.setting('line_basic_id')) from public.people p where p.id = v_pid);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_line_unlink(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token);
begin
  perform pg_advisory_xact_lock(hashtext('line_link'));
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  update public.people set line_user_id = null, line_linked_at = null where id = v_pid;
  delete from public.line_link_codes where person_id = v_pid;
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.halfwidth(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  -- 全形英數符號與全形空白轉半形（手機輸入法常打成全形）
  select translate(p, '！＂＃＄％＆＇（）＊＋，－．／０１２３４５６７８９：；＜＝＞？＠ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ［＼］＾＿｀ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ｛｜｝～　', '!"#$%&''()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~ ')
$function$
;
revoke execute on function public.halfwidth(text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.payroll_claim(p_national_id text, p_name text, p_proof text, p_birth_date text, p_consent boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 舊資料缺生日（沒有密碼）的人自行開通：核對姓名＋匯款帳號末 5 碼或手機，補生日後以民國生日 7 碼為密碼。
-- 查無此人、已有密碼或生日、核對不符、被鎖定一律回同樣的 mismatch，不透露帳號是否存在。
declare
  v public.people;
  v_id text := upper(regexp_replace(public.halfwidth(coalesce(p_national_id,'')), '\s', '', 'g'));
  v_name text := translate(regexp_replace(public.halfwidth(coalesce(p_name,'')), '\s', '', 'g'), '黄', '黃');
  v_proof text := regexp_replace(public.halfwidth(coalesce(p_proof,'')), '\D', '', 'g');
  v_bank text; v_phone text; v_ok boolean := false; v_bd date; v_age int; v_pw text; v_fail int; v_token text;
begin
  begin v_bd := btrim(coalesce(p_birth_date,''))::date; exception when others then v_bd := null; end;
  if v_bd is null or v_bd < date '1930-01-01' or v_bd > current_date then return jsonb_build_object('ok', false, 'error', 'bad_birth'); end if;
  v_age := extract(year from age((now() at time zone 'Asia/Taipei')::date, v_bd))::int;
  if v_age < 15 then return jsonb_build_object('ok', false, 'error', 'too_young'); end if;
  if not coalesce(p_consent, false) then return jsonb_build_object('ok', false, 'error', 'no_consent'); end if;
  -- 手機一律正規化成 09 開頭 10 碼；舊資料少了開頭 0 的 9 碼也補 0 後比對
  if length(v_proof) = 9 and v_proof ~ '^9' then v_proof := '0' || v_proof; end if;
  if not (length(v_proof) = 5 or v_proof ~ '^09\d{8}$') then return jsonb_build_object('ok', false, 'error', 'bad_proof'); end if;
  if length(v_name) < 2 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;

  select * into v from public.people where national_id = v_id for update;
  if found and v.disabled_at is null and v.password_hash is null and v.birth_date is null and not (v.locked_until is not null and v.locked_until > now()) then
    v_bank := regexp_replace(coalesce(v.bank_account,''), '\D', '', 'g');
    v_phone := regexp_replace(coalesce(v.phone,''), '\D', '', 'g');
    if v_phone ~ '^8869\d{8}$' then v_phone := '0' || substr(v_phone, 4); end if;
    if v_phone ~ '^9\d{8}$' then v_phone := '0' || v_phone; end if;
    v_ok := translate(regexp_replace(coalesce(v.name,''), '\s', '', 'g'), '黄', '黃') = v_name
      and ((length(v_proof) = 5 and length(v_bank) >= 6 and right(v_bank, 5) = v_proof)
        or (length(v_proof) = 10 and v_phone ~ '^09\d{8}$' and v_phone = v_proof));
    if not v_ok then
      v_fail := v.failed_logins + 1;
      if v_fail >= 10 then
        update public.people set failed_logins = 0, locked_until = now() + interval '15 minutes' where id = v.id;
        insert into public.audit_log(actor, action, table_name, row_id) values (v.id::text, 'claim_locked', 'people', v.id);
      else
        update public.people set failed_logins = v_fail where id = v.id;
      end if;
    end if;
  end if;
  v_pw := lpad((extract(year from v_bd)::int - 1911)::text, 3, '0') || to_char(v_bd, 'MMDD');
  if not v_ok then
    perform extensions.crypt(v_pw, extensions.gen_salt('bf', 10));
    return jsonb_build_object('ok', false, 'error', 'mismatch');
  end if;

  update public.people set birth_date = v_bd, birth_raw = to_char(v_bd, 'YYYY-MM-DD'),
    password_hash = extensions.crypt(v_pw, extensions.gen_salt('bf', 10)), password_changed_at = null,
    failed_logins = 0, locked_until = null, consent_at = coalesce(consent_at, now()), updated_at = now()
  where id = v.id;
  update public.data_issues set resolved = true where person_id = v.id and code = 'birth_unparsed' and not resolved;
  insert into public.data_issues(person_id, severity, code, detail)
  values (v.id, 'warn', 'self_claimed', '本人於 ' || to_char(now() at time zone 'Asia/Taipei', 'YYYY-MM-DD') || ' 補填生日並開通帳號（以' || case when length(v_proof) = 5 then '匯款帳號末 5 碼' else '手機' end || '核對），請核對身分證影本上的生日');
  if v_age < 18 then
    insert into public.data_issues(person_id, severity, code, detail)
    values (v.id, 'warn', 'minor', format('補填的生日顯示未滿 18 歲（%s 歲），請核對年齡證明', v_age));
  end if;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.sessions(token_hash, person_id, expires_at) values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v.id, now() + interval '8 hours');
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v.id::text, 'account_claimed', 'people', v.id, jsonb_build_object('verified_by', case when length(v_proof) = 5 then 'bank_last5' else 'phone' end));
  return jsonb_build_object('ok', true, 'token', v_token, 'name', v.name);
end $function$
;
revoke execute on function public.payroll_claim(text, text, text, text, boolean) from public, authenticated;
grant execute on function public.payroll_claim(text, text, text, text, boolean) to anon;

-- 查看薪資前須補齊：身分證正反面、存摺封面、匯款帳戶（銀行代碼與帳號）
CREATE OR REPLACE FUNCTION public.person_incomplete(p_person uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case when docs = '[]'::jsonb and bank_ok then null
    else jsonb_build_object('docs', docs, 'bank', not bank_ok) end
  from (select public.person_missing_docs(p.id) docs,
      coalesce(p.bank_code,'') ~ '^\d{3}$' and coalesce(p.bank_account,'') ~ '^\d{6,16}$' bank_ok
    from public.people p where p.id = p_person) t;
$function$
;
revoke execute on function public.person_incomplete(uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.payroll_login(p_national_id text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v public.people;
  -- 身分證字號：全形轉半形、去空白、轉大寫（不刪其他符號，避免導向別的帳號）
  v_id text := upper(regexp_replace(public.halfwidth(coalesce(p_national_id,'')), '\s', '', 'g'));
  v_pw text := coalesce(p_password,'');
  v_fail int;
  v_token text;
begin
  select * into v from public.people where national_id = v_id for update;
  -- 失敗一律回同樣的 invalid，不透露帳號是否存在或被鎖；每條路徑都做一次同成本雜湊
  if not found or v.password_hash is null or v.disabled_at is not null then
    perform extensions.crypt(v_pw, extensions.gen_salt('bf', 10));
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  if v.locked_until is not null and v.locked_until > now() then
    perform extensions.crypt(v_pw, v.password_hash);
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  -- 還在用預設生日密碼的人，輸入轉半形（手機常打成全形數字）；改過密碼的照原樣比對。每次只比對一次
  if v.password_changed_at is null then v_pw := public.halfwidth(v_pw); end if;
  if v.password_hash <> extensions.crypt(v_pw, v.password_hash) then
    v_fail := v.failed_logins + 1;
    if v_fail >= 10 then
      update public.people set failed_logins = 0, locked_until = now() + interval '15 minutes' where id = v.id;
      insert into public.audit_log(actor, action, table_name, row_id) values (v.id::text, 'login_locked', 'people', v.id);
    else
      update public.people set failed_logins = v_fail where id = v.id;
    end if;
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  update public.people set failed_logins = 0, locked_until = null where id = v.id;
  delete from public.sessions where expires_at < now();
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.sessions(token_hash, person_id, expires_at)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v.id, now() + interval '8 hours');
  insert into public.audit_log(actor, action, table_name, row_id) values (v.id::text, 'login', 'people', v.id);
  return jsonb_build_object('ok', true, 'token', v_token, 'name', v.name,
    'default_password', v.password_changed_at is null);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_logout(p_token text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with d as (delete from public.sessions where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex') returning 1)
  select jsonb_build_object('ok', true);
$function$
;

CREATE OR REPLACE FUNCTION public.payroll_mask_id(t text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case when t is null then null else substr(t,1,3) || repeat('＊', greatest(length(t)-6,0)) || right(t,3) end;
$function$
;

CREATE OR REPLACE FUNCTION public.payroll_my_application(p_token text, p_join text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token); a public.applications;
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select ap.* into a from public.applications ap where ap.event_id = (select t.event_id from public.join_target(p_join) t) and ap.person_id = v_pid;
  return jsonb_build_object('ok', true,
    'has_photo', exists (select 1 from public.people_documents where person_id = v_pid and kind = 'photo'),
    'documents', coalesce((select jsonb_object_agg(d.kind, d.uploaded_at) from public.people_documents d where d.person_id = v_pid), '{}'::jsonb),
    'missing_docs', public.person_missing_docs(v_pid),
    'linked', exists (select 1 from public.people where id = v_pid and line_user_id is not null),
    'application', case when a.id is null then null else jsonb_build_object('status', a.status, 'answers', a.answers, 'experience', a.experience,
      'contract_accepted_at', a.contract_accepted_at, 'plan_id', a.plan_id,
      'shifts', coalesce((select jsonb_object_agg(x.shift_id, x.status) from public.application_shifts x where x.application_id = a.id), '{}'::jsonb),
      -- 本人報名或被排入的班次（名單制的報名頁不列班表，靠這裡顯示）
      'shift_list', coalesce((select jsonb_agg(public.shift_json(s) || jsonb_build_object('status', x.status) order by s.work_date, s.start_time)
        from public.application_shifts x join public.shifts s on s.id = x.shift_id where x.application_id = a.id), '[]'::jsonb)) end);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_my_events(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token);
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return jsonb_build_object('ok', true, 'events', coalesce((select jsonb_agg(jsonb_build_object(
      'app_id', a.id, 'event', e.name, 'join', e.signup_code, 'location', e.location, 'start_date', e.start_date,
      'contract_needed', exists (select 1 from public.application_shifts x where x.application_id = a.id and x.status = 'accepted') and a.contract_accepted_at is null,
      'contract_accepted_at', a.contract_accepted_at,
      'shifts', coalesce((select jsonb_agg(jsonb_build_object('work_date', s.work_date, 'start', to_char(s.start_time,'HH24:MI'), 'end', to_char(s.end_time,'HH24:MI'), 'role', s.role, 'status', x.status) order by s.work_date, s.start_time)
                 from public.application_shifts x join public.shifts s on s.id = x.shift_id where x.application_id = a.id), '[]'::jsonb)
    ) order by e.start_date desc)
    from public.applications a join public.events e on e.id = a.event_id
    where a.person_id = v_pid and a.status = 'active' and coalesce(e.end_date, e.start_date) >= (now() at time zone 'Asia/Taipei')::date - 14), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_my_payslips(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token); v_inc jsonb;
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  v_inc := public.person_incomplete(v_pid);
  return jsonb_build_object('ok', true,
    'person', (select jsonb_build_object('name', p.name, 'national_id', public.payroll_mask_id(p.national_id),
                 'default_password', p.password_changed_at is null) from public.people p where p.id = v_pid),
    'incomplete', v_inc,
    'payslips', case when v_inc is not null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'event', e.name, 'employer', em.name, 'relation', s.relation, 'role', s.role,
        'period_start', s.period_start, 'period_end', s.period_end, 'pay_date', s.pay_date,
        'gross', s.gross, 'net', s.net) order by coalesce(s.pay_date, s.period_end) desc nulls last, s.created_at desc)
      from public.payslips s join public.events e on e.id = s.event_id join public.employers em on em.id = e.employer_id
      where s.person_id = v_pid and s.status = 'published'), '[]'::jsonb) end);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_payslip(p_token text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token); r jsonb; v_inc jsonb;
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  v_inc := public.person_incomplete(v_pid);
  if v_inc is not null then return jsonb_build_object('ok', false, 'error', 'incomplete', 'incomplete', v_inc); end if;
  select jsonb_build_object(
    'id', s.id, 'event', e.name,
    'employer', jsonb_build_object('name', em.name, 'legal_name', em.legal_name, 'tax_id', em.tax_id),
    'person', jsonb_build_object('name', p.name, 'national_id', public.payroll_mask_id(p.national_id)),
    'relation', s.relation, 'role', s.role, 'basis', s.basis,
    'period_start', s.period_start, 'period_end', s.period_end, 'pay_date', s.pay_date,
    'gross', s.gross, 'allowances', s.allowances, 'deductions', s.deductions, 'net', s.net, 'note', s.note,
    'published_at', s.published_at, 'pay_method', s.pay_method, 'cash_paid_at', s.cash_paid_at,
    'pay_account', jsonb_build_object('bank_code', s.pay_bank_code, 'branch', s.pay_bank_branch,
        'last4', case when s.pay_account is not null then right(s.pay_account, 4) end),
    'items', coalesce((select jsonb_agg(jsonb_build_object('kind', i.kind, 'code', i.code, 'label', i.label,
        'work_date', i.work_date, 'hours', i.hours, 'rate', i.rate, 'amount', i.amount) order by i.work_date nulls last, i.sort, i.id)
        from public.payslip_items i where i.payslip_id = s.id), '[]'::jsonb),
    'attendance', coalesce((select jsonb_agg(jsonb_build_object('work_date', a.work_date,
        'clock_in', to_char(a.clock_in at time zone 'Asia/Taipei', 'HH24:MI'),
        'clock_out', to_char(a.clock_out at time zone 'Asia/Taipei', 'HH24:MI'),
        'break_minutes', a.break_minutes, 'source', a.source, 'minutes', public.att_minutes(a), 'overnight', (a.clock_out at time zone 'Asia/Taipei')::date > a.work_date) order by a.work_date)
        from public.attendance a where a.person_id = s.person_id and a.event_id = s.event_id
          and a.work_date between coalesce(s.period_start, a.work_date) and coalesce(s.period_end, a.work_date)), '[]'::jsonb)
  ) into r
  from public.payslips s join public.events e on e.id = s.event_id join public.employers em on em.id = e.employer_id
  join public.people p on p.id = s.person_id
  where s.id = p_id and s.person_id = v_pid and s.status = 'published';
  if r is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'payslip', r);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_profile(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token);
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return (select jsonb_build_object('ok', true, 'profile', jsonb_build_object(
      'name', p.name, 'national_id', public.payroll_mask_id(p.national_id), 'birth_date', p.birth_date, 'phone', p.phone, 'email', p.email,
      'address', p.address, 'bank_code', p.bank_code, 'bank_branch', p.bank_branch, 'bank_account_name', p.bank_account_name, 'bank_account', p.bank_account,
      'default_password', p.password_changed_at is null,
      'documents', coalesce((select jsonb_object_agg(d.kind, d.uploaded_at) from public.people_documents d where d.person_id = p.id), '{}'::jsonb)))
    from public.people p where p.id = v_pid);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_register(p_join text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e public.events; v_nid text := upper(btrim(coalesce(p_data->>'national_id',''))); v_name text := btrim(coalesce(p_data->>'name',''));
  v_bd date; v_age int; c jsonb; v_id uuid; v_token text; sv public.signup_verifications;
begin
  if btrim(coalesce(p_join,'')) <> '' then
    select * into e from public.events where id = (select t.event_id from public.join_target(p_join) t) and coalesce(end_date, start_date) >= (now() at time zone 'Asia/Taipei')::date - 1;
    if not found then return jsonb_build_object('ok', false, 'error', 'bad_join'); end if;
  else
    select * into sv from public.signup_verifications where ticket_hash = encode(extensions.digest(coalesce(p_data->>'signup_ticket',''), 'sha256'), 'hex')
      and used_at is null and ticket_expires_at > now() for update;
    if sv.id is null then return jsonb_build_object('ok', false, 'error', 'bad_ticket'); end if;
    if sv.national_id <> upper(regexp_replace(public.halfwidth(v_nid), '\s', '', 'g')) then return jsonb_build_object('ok', false, 'error', 'ticket_mismatch'); end if;
  end if;
  if not coalesce((p_data->>'consent')::boolean, false) then return jsonb_build_object('ok', false, 'error', 'no_consent'); end if;
  if not public.valid_tw_id(v_nid) then return jsonb_build_object('ok', false, 'error', 'bad_national_id'); end if;
  if length(v_name) < 2 or length(v_name) > 40 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  begin v_bd := (p_data->>'birth_date')::date; exception when others then v_bd := null; end;
  if v_bd is null or v_bd < date '1930-01-01' or v_bd > current_date then return jsonb_build_object('ok', false, 'error', 'bad_birth'); end if;
  v_age := extract(year from age((now() at time zone 'Asia/Taipei')::date, v_bd))::int;
  if v_age < 15 then return jsonb_build_object('ok', false, 'error', 'too_young'); end if;
  if exists (select 1 from public.people where national_id = v_nid) then return jsonb_build_object('ok', false, 'error', 'exists'); end if;
  c := public.payroll_clean_profile(p_data, v_name);
  if c ? 'error' then return jsonb_build_object('ok', false, 'error', c->>'error'); end if;
  insert into public.people(national_id, name, nickname, phone, email, birth_date, birth_raw, address, bank_code, bank_branch, bank_account_name, bank_account,
    password_hash, profile_source, consent_at)
  values (v_nid, v_name, nullif(btrim(coalesce(p_data->>'nickname','')),''), c->>'phone', c->>'email', v_bd, to_char(v_bd,'YYYY-MM-DD'), c->>'address',
    c->>'bank_code', c->>'bank_branch', c->>'bank_account_name', c->>'bank_account',
    extensions.crypt(lpad((extract(year from v_bd)::int - 1911)::text, 3, '0') || to_char(v_bd, 'MMDD'), extensions.gen_salt('bf', 10)), 'self', now())
  returning id into v_id;
  if sv.id is not null then
    update public.people set email = sv.email where id = v_id;
    update public.signup_verifications set used_at = now() where id = sv.id;
  end if;
  insert into public.data_issues(event_id, person_id, severity, code, detail) values (e.id, v_id, 'warn', 'new_registration', case when sv.id is not null then '新人自行建檔（Email 已驗證），請核對身分證與存摺影本' else '新登錄人員，請核對身分證與存摺影本' end);
  if v_age < 18 then
    insert into public.data_issues(event_id, person_id, severity, code, detail)
    values (e.id, v_id, 'error', 'minor', format('未滿 18 歲（%s 歲），須備置法定代理人同意書及年齡證明文件（勞基法第46條）%s', v_age, case when v_age < 16 then '；未滿 16 歲為童工，工時與工作內容另有限制（第44、47、48條）' else '' end));
  end if;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.sessions(token_hash, person_id, expires_at) values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_id, now() + interval '8 hours');
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_id::text, 'registered', 'people', v_id, jsonb_build_object('event', e.id, 'via', case when sv.id is not null then 'email' else 'join' end));
  return jsonb_build_object('ok', true, 'token', v_token, 'name', v_name, 'event', e.name);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_session_person(p_token text)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- 停用的人即使還有 session 也一律視為未登入
  select s.person_id from public.sessions s join public.people p on p.id = s.person_id and p.disabled_at is null
  where s.token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex') and s.expires_at > now();
$function$
;

CREATE OR REPLACE FUNCTION public.payroll_update_profile(p_token text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token); v public.people; c jsonb;
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into v from public.people where id = v_pid;
  c := public.payroll_clean_profile(p_data, v.name);
  if c ? 'error' then return jsonb_build_object('ok', false, 'error', c->>'error'); end if;
  if v.bank_account is distinct from c->>'bank_account' or v.bank_code is distinct from c->>'bank_code' then
    insert into public.data_issues(person_id, severity, code, detail) values (v_pid, 'warn', 'bank_changed', '本人於 ' || to_char(now() at time zone 'Asia/Taipei', 'YYYY-MM-DD') || ' 更改了匯款帳戶，請核對存摺影本');
  end if;
  update public.people set phone = c->>'phone', email = c->>'email', address = c->>'address', bank_code = c->>'bank_code', bank_branch = c->>'bank_branch',
    bank_account_name = c->>'bank_account_name', bank_account = c->>'bank_account', updated_at = now() where id = v_pid;
  insert into public.audit_log(actor, action, table_name, row_id) values (v_pid::text, 'profile_updated', 'people', v_pid);
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_withdraw(p_token text, p_join text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_pid uuid := public.payroll_session_person(p_token); v_app uuid;
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select a.id into v_app from public.applications a where a.event_id = (select t.event_id from public.join_target(p_join) t) and a.person_id = v_pid;
  if v_app is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if exists (select 1 from public.application_shifts where application_id = v_app and status = 'accepted') then return jsonb_build_object('ok', false, 'error', 'has_accepted'); end if;
  update public.applications set status = 'withdrawn', plan_id = null, apply_contract_text = null, apply_contract_hash = null, apply_contract_at = null, updated_at = now() where id = v_app;
  delete from public.application_shifts where application_id = v_app;
  return jsonb_build_object('ok', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.payslip_blocked(p payslips)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from public.data_issues i where not i.resolved and i.severity = 'error'
    and (i.payslip_id = p.id or (i.payslip_id is null and i.person_id = p.person_id and (i.event_id is null or i.event_id = p.event_id))));
$function$
;

CREATE OR REPLACE FUNCTION public.person_missing_docs(p_person uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(k order by o), '[]'::jsonb) from unnest(array['id_front','id_back','bankbook']) with ordinality t(k, o)
  where not exists (select 1 from public.people_documents d where d.person_id = p_person and d.kind = t.k);
$function$
;

CREATE OR REPLACE FUNCTION public.payroll_contact()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select public.setting('contact_info') $function$
;

CREATE OR REPLACE FUNCTION public.setting(p_key text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select value from public.app_settings where key = p_key $function$
;

CREATE OR REPLACE FUNCTION public.shift_json(s shifts)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object('id', s.id, 'work_date', s.work_date, 'start', to_char(s.start_time, 'HH24:MI'), 'end', to_char(s.end_time, 'HH24:MI'),
    'overnight', s.end_time <= s.start_time, 'role', s.role, 'headcount', s.headcount, 'rate', s.rate, 'note', s.note,
    'accepted', (select count(*) from public.application_shifts x join public.applications a on a.id = x.application_id where x.shift_id = s.id and x.status = 'accepted' and a.status = 'active'),
    'applied', (select count(*) from public.application_shifts x join public.applications a on a.id = x.application_id where x.shift_id = s.id and x.status in ('applied','waitlist') and a.status = 'active'));
$function$
;

CREATE OR REPLACE FUNCTION public.today_schedule(p_person uuid, p_event uuid, p_day date)
 RETURNS TABLE(s_in timestamp with time zone, s_out timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select min((p_day + sh.start_time) at time zone 'Asia/Taipei'),
         max((p_day + sh.end_time + case when sh.end_time <= sh.start_time then interval '1 day' else interval '0' end) at time zone 'Asia/Taipei')
  from public.application_shifts x join public.applications ap on ap.id = x.application_id join public.shifts sh on sh.id = x.shift_id
  where ap.event_id = p_event and ap.person_id = p_person and ap.status = 'active' and x.status = 'accepted' and sh.work_date = p_day
  having count(*) > 0 $function$
;

CREATE OR REPLACE FUNCTION public.trg_contract_superseded()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if old.contract_accepted_at is not null and new.contract_accepted_at is null then
    if not exists (select 1 from public.contract_history where application_id = new.id and superseded_at is null) and old.contract_text is not null then
      insert into public.contract_history(application_id, text, text_hash, accepted_at, superseded_at) values (new.id, old.contract_text, 'legacy', old.contract_accepted_at, now());
    end if;
    update public.contract_history set superseded_at = now() where application_id = new.id and superseded_at is null;
    insert into public.notifications(person_id, event_id, kind, send_after) values (new.person_id, new.event_id, 'accepted', now() + interval '2 minutes') on conflict do nothing;
    insert into public.notifications(person_id, event_id, kind, send_after, channel)
    select new.person_id, new.event_id, 'accepted', now() + interval '2 minutes', 'mail' from public.people p where p.id = new.person_id and coalesce(btrim(p.email), '') <> ''
    on conflict do nothing;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.trg_employer_terms_changed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record;
begin
  if (new.name, new.legal_name, new.tax_id) is distinct from (old.name, old.legal_name, old.tax_id) then
    for r in select ap.id from public.applications ap join public.events e on e.id = ap.event_id
             where e.employer_id = new.id and ap.contract_accepted_at is not null and coalesce(e.end_date, e.start_date) >= (now() at time zone 'Asia/Taipei')::date order by ap.id loop
      perform public.contract_recheck_app(r.id);
    end loop;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.trg_event_terms_changed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record;
begin
  if coalesce(new.end_date, new.start_date) < (now() at time zone 'Asia/Taipei')::date then return new; end if;
  if (new.name, new.location, new.default_hourly_rate, new.default_break_minutes, new.pay_date, new.pay_within_days, new.employer_id)
     is distinct from (old.name, old.location, old.default_hourly_rate, old.default_break_minutes, old.pay_date, old.pay_within_days, old.employer_id) then
    for r in select id from public.applications where event_id = new.id and contract_accepted_at is not null order by id loop
      perform public.contract_recheck_app(r.id);
    end loop;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.trg_notify_accept()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- 錄取通知：有綁 LINE 的發 LINE；有 Email 的另外寄信（同一人連續錄取多班會合併成一則）
  if new.status = 'accepted' and (tg_op = 'INSERT' or old.status is distinct from 'accepted') then
    insert into public.notifications(person_id, event_id, kind, send_after, channel)
    select a.person_id, a.event_id, 'accepted', now() + interval '2 minutes', c.ch
    from public.applications a join public.people p on p.id = a.person_id cross join (values ('line'), ('mail')) c(ch)
    where a.id = new.application_id and ((c.ch = 'line' and p.line_user_id is not null) or (c.ch = 'mail' and coalesce(btrim(p.email), '') <> ''))
    on conflict do nothing;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.trg_notify_payslip()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.status = 'published' and old.status is distinct from 'published' and exists (select 1 from public.people where id = new.person_id and line_user_id is not null) then
    insert into public.notifications(person_id, event_id, kind, ref_id, dedupe_key, send_after)
    values (new.person_id, new.event_id, 'payslip', new.id, 'payslip:' || new.id, now() + interval '2 minutes')
    on conflict do nothing;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.valid_tw_id(id text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare letters text := 'ABCDEFGHJKLMNPQRSTUVXYWZIO'; n int; s int; i int;
begin
  if id !~ '^[A-Z][1289]\d{8}$' then return false; end if;
  n := strpos(letters, substr(id,1,1)) + 9;
  s := (n / 10) + (n % 10) * 9;
  for i in 2..9 loop
    s := s + substr(id,i,1)::int * (10 - i);
  end loop;
  s := s + substr(id,10,1)::int;
  return s % 10 = 0;
end $function$
;

-- 內部函式（沒有登入檢查）只給資料庫內部呼叫
revoke all on function public.payslip_regenerate(uuid, uuid) from public, anon, authenticated;
revoke all on function public.payroll_contract_text_v1(uuid) from public, anon, authenticated;
revoke all on function public.payroll_contract_text_v2(uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_event_people_export(p_token text, p_event uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 活動人員資料下載：錄取、出勤或有薪資單的人；含個資與證件資訊，先寫紀錄再回傳
declare v_actor text := public.admin_actor(p_token); v_rows jsonb;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if not exists (select 1 from public.events where id = p_event) then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('person_id', p.id, 'name', p.name, 'national_id', p.national_id, 'birth_date', p.birth_date,
      'address', p.address, 'bank_code', p.bank_code, 'bank_branch', p.bank_branch, 'bank_account_name', p.bank_account_name, 'bank_account', p.bank_account,
      'docs', (select coalesce(jsonb_object_agg(d.kind, jsonb_build_object('file', d.path is not null,
                 'ext', lower(substring(d.path from '\.([A-Za-z0-9]+)$')),
                 'drive', case when d.drive_file_id is not null then 'https://drive.google.com/file/d/' || d.drive_file_id || '/view' end)), '{}'::jsonb)
               from public.people_documents d where d.person_id = p.id and d.kind in ('id_front', 'id_back', 'bankbook')))
    order by p.name), '[]'::jsonb)
  into v_rows
  from public.people p
  where p.id in (
    select ap.person_id from public.applications ap join public.application_shifts x on x.application_id = ap.id
      where ap.event_id = p_event and ap.status = 'active' and x.status = 'accepted'
    union select person_id from public.attendance where event_id = p_event
    union select person_id from public.payslips where event_id = p_event and status <> 'void');
  insert into public.audit_log(actor, action, table_name, row_id, detail)
  values (v_actor, 'export_event_people', 'events', p_event, jsonb_build_object('rows', jsonb_array_length(v_rows),
    'people', (select coalesce(jsonb_agg(x->'person_id'), '[]'::jsonb) from jsonb_array_elements(v_rows) x)));
  return jsonb_build_object('ok', true, 'rows', v_rows);
end $function$
;
revoke all on function public.admin_event_people_export(text, uuid) from public;
grant execute on function public.admin_event_people_export(text, uuid) to anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_ai_import(p_token text, p_payload jsonb, p_event uuid DEFAULT NULL::uuid, p_commit boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- AI 匯入：claude.ai 匯入台整理好的活動、班別與人員名單。p_commit = false 只檢查並回傳預覽，true 才寫入（有錯的列略過）
-- 新活動或指定既有活動；人員只補空白欄位不覆蓋；出勤為表單填寫的日期（非打卡）；有金額才建薪資單草稿（不會被「依出勤產生」覆蓋）
declare v_actor text := public.admin_actor(p_token); e public.events; ev jsonb := coalesce(p_payload->'event', '{}'::jsonb);
  v_s date; v_e date; v_pay date; v_file text := nullif(btrim(coalesce(p_payload#>>'{source,file_id}','')),'');
  v_dup uuid; x jsonb; d jsonb; sh jsonb; v_rows jsonb := '[]'::jsonb; v_shifts jsonb := '[]'::jsonb;
  v_nid text; v_name text; v_bd date; v_dates date[]; v_days jsonb; v_errs text[]; v_warns text[]; v_fill text[]; pr public.people;
  v_gross numeric; v_ins numeric; v_allow numeric; v_net numeric; v_pid uuid; v_slip uuid; v_i int; v_seen text[] := '{}';
  n_new int := 0; n_upd int := 0; n_att int := 0; n_slip int := 0; n_skip int := 0; n_shift int := 0; v_people jsonb := '[]'::jsonb;
  v_acct_name text; v_acct text; v_cnt int; v_bank text; v_branch text; k text;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if jsonb_typeof(p_payload) is distinct from 'object' or coalesce((p_payload->>'v')::int, 0) <> 1 then return jsonb_build_object('ok', false, 'error', 'bad_payload'); end if;
  if jsonb_typeof(coalesce(p_payload->'people','[]')) <> 'array' or jsonb_typeof(coalesce(p_payload->'shifts','[]')) <> 'array' or jsonb_typeof(coalesce(p_payload->'event','{}')) <> 'object' then return jsonb_build_object('ok', false, 'error', 'bad_payload'); end if;
  if jsonb_array_length(coalesce(p_payload->'people','[]')) > 500 or jsonb_array_length(coalesce(p_payload->'shifts','[]')) > 200 then return jsonb_build_object('ok', false, 'error', 'too_many'); end if;
  if v_file is not null and v_file !~ '^[A-Za-z0-9_-]{20,80}$' then v_file := null; end if;

  -- 活動
  if p_event is not null then
    select * into e from public.events where id = p_event for update;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
    v_s := e.start_date; v_e := coalesce(e.end_date, e.start_date); v_pay := coalesce(e.pay_date, v_e + e.pay_within_days);
  else
    if length(btrim(coalesce(ev->>'name',''))) < 2 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
    begin
      v_s := (ev->>'start_date')::date; v_e := coalesce(nullif(ev->>'end_date','')::date, v_s); v_pay := nullif(ev->>'pay_date','')::date;
    exception when others then return jsonb_build_object('ok', false, 'error', 'bad_date'); end;
    if v_s is null or v_e < v_s then return jsonb_build_object('ok', false, 'error', 'bad_date'); end if;
    if v_pay is not null and v_pay < v_e then return jsonb_build_object('ok', false, 'error', 'pay_before_end'); end if;
    if v_file is not null then
      select id into v_dup from public.events where source_key = 'g:' || v_file;
      if v_dup is not null then return jsonb_build_object('ok', false, 'error', 'duplicate_source', 'event', v_dup); end if;
    end if;
    if p_commit and coalesce(p_payload->>'allow_similar', '') <> 'true' and exists (select 1 from public.events z
        where lower(regexp_replace(z.name, '\s', '', 'g')) = lower(regexp_replace(coalesce(ev->>'name',''), '\s', '', 'g'))
          and z.start_date <= v_e and coalesce(z.end_date, z.start_date) >= v_s) then
      return jsonb_build_object('ok', false, 'error', 'similar_event');
    end if;
  end if;

  -- 班別
  for sh in select * from jsonb_array_elements(coalesce(p_payload->'shifts','[]')) loop
    v_errs := '{}';
    begin
      if (sh->>'work_date')::date not between v_s and v_e then v_errs := v_errs || '日期不在活動期間'::text; end if;
      if nullif(sh->>'start_time','')::time is null or nullif(sh->>'end_time','')::time is null then v_errs := v_errs || '缺上下班時間'::text; end if;
      if coalesce(nullif(sh->>'headcount','')::int, 0) < 1 or (sh->>'headcount')::int > 500 then v_errs := v_errs || '人數不對'::text; end if;
      if nullif(sh->>'rate','')::numeric is not null and ((sh->>'rate')::numeric < 0 or (sh->>'rate')::numeric > 100000) then v_errs := v_errs || '時薪不對'::text; end if;
    exception when others then v_errs := v_errs || '格式不對'::text; end;
    v_shifts := v_shifts || jsonb_build_object('work_date', sh->>'work_date', 'start_time', sh->>'start_time', 'end_time', sh->>'end_time',
      'role', left(btrim(coalesce(sh->>'role','')), 40), 'headcount', sh->>'headcount', 'rate', sh->>'rate', 'errors', to_jsonb(v_errs));
  end loop;

  -- 人員
  v_i := 0;
  for x in select * from jsonb_array_elements(coalesce(p_payload->'people','[]')) loop
    v_i := v_i + 1; v_errs := '{}'; v_warns := '{}'; v_fill := '{}'; v_dates := '{}'; v_days := '[]'; pr := null;
    v_nid := upper(regexp_replace(coalesce(x->>'national_id',''), '\s', '', 'g'));
    v_name := btrim(coalesce(x->>'name',''));
    if not public.valid_tw_id(v_nid) then v_errs := v_errs || '身分證字號格式不對'::text; end if;
    if length(v_name) < 2 or length(v_name) > 40 then v_errs := v_errs || '姓名不對'::text; end if;
    if v_nid = any(v_seen) then v_errs := v_errs || '名單裡重複'::text; end if;
    v_seen := v_seen || v_nid;
    begin v_bd := nullif(x->>'birth_date','')::date; exception when others then v_bd := null; end;
    if v_bd is not null and (v_bd < date '1930-01-01' or v_bd > current_date) then v_bd := null; end if;
    if v_bd is null then v_warns := v_warns || '生日無法判讀（新建的人不會有登入密碼）'::text; end if;
    begin
      select coalesce(array_agg(distinct dd order by dd), '{}') into v_dates from (select (jsonb_array_elements_text(coalesce(x->'work_dates','[]')))::date dd) q;
      for d in select * from jsonb_array_elements(coalesce(x->'days','[]')) loop
        if (d->>'date')::date is null or (d->>'amount')::numeric < 0 or (d->>'amount')::numeric > 100000 then raise exception 'bad'; end if;
        v_days := v_days || jsonb_build_object('date', (d->>'date')::date, 'amount', round((d->>'amount')::numeric), 'label', left(btrim(coalesce(d->>'label','')), 60));
        v_dates := array(select distinct u from unnest(v_dates || (d->>'date')::date) u order by u);
      end loop;
      v_ins := coalesce(round(nullif(x->>'labor_ins','')::numeric), 0); v_allow := coalesce(round(nullif(x->>'allowances','')::numeric), 0);
      v_gross := coalesce((select sum((j->>'amount')::numeric) from jsonb_array_elements(v_days) j), round(nullif(x->>'gross','')::numeric));
      v_net := round(nullif(x->>'net','')::numeric);
      if v_ins < 0 or v_allow < 0 or v_ins > 100000 or v_allow > 100000 or coalesce(v_gross,0) > 1000000 or coalesce(v_gross,0) < 0 then raise exception 'bad'; end if;
    exception when others then v_errs := v_errs || '日期或金額格式不對'::text; v_gross := null; end;
    if exists (select 1 from unnest(v_dates) u where u not between v_s and v_e) then v_errs := v_errs || '工作日期不在活動期間'::text; end if;
    if cardinality(v_dates) = 0 then v_warns := v_warns || '沒有工作日期'::text; end if;
    if v_gross is not null and v_gross + v_allow - v_ins < 0 or v_net < 0 then v_errs := v_errs || '實發是負數'::text; end if;
    if cardinality(v_dates) > 62 then v_errs := v_errs || '工作日期超過 62 天'::text; end if;
    if v_gross is null and v_net is not null then v_warns := v_warns || '只有撥款、沒有應發，不建薪資單'::text; end if;
    if v_gross is not null and v_net is not null and v_net <> v_gross + v_allow - v_ins then
      v_warns := v_warns || format('表上撥款 %s 與計算 %s 不同，以計算為準', v_net, v_gross + v_allow - v_ins);
    end if;
    v_acct := nullif(regexp_replace(coalesce(x->>'bank_account',''), '\D', '', 'g'), '');
    if v_acct is not null and length(v_acct) not between 6 and 16 then v_warns := v_warns || '帳號格式不對，不匯入帳號'::text; v_acct := null; end if;
    v_bank := nullif(substring(coalesce(x->>'bank_code','') from '\d{3}'), '');
    if v_bank is null and btrim(coalesce(x->>'bank_code','')) <> '' then v_warns := v_warns || '銀行代碼看不懂'::text; end if;
    v_branch := nullif(left(btrim(coalesce(x->>'bank_branch','')), 40), '');
    v_acct_name := nullif(left(btrim(coalesce(x->>'bank_account_name','')), 40), '');
    if v_acct_name is not null and v_acct_name <> v_name then v_warns := v_warns || '戶名不是本人'::text; end if;
    if cardinality(v_errs) = 0 then
      select * into pr from public.people where national_id = v_nid;
      if pr.id is not null then
        if pr.name <> v_name then v_warns := v_warns || format('系統姓名是「%s」', pr.name); end if;
        foreach k in array array['phone','address','birth_date','bank_code','bank_branch','bank_account_name','bank_account'] loop
          if (to_jsonb(pr)->>k) is null and nullif(case k when 'bank_account' then v_acct when 'bank_code' then v_bank when 'bank_branch' then v_branch
               when 'bank_account_name' then v_acct_name when 'birth_date' then v_bd::text else btrim(coalesce(x->>k,'')) end, '') is not null then v_fill := v_fill || k; end if;
        end loop;
        if exists (select 1 from public.payslips where person_id = pr.id and event_id = p_event and status <> 'void') and v_gross is not null then
          v_warns := v_warns || '這場活動已有薪資單，不再新增'::text;
        end if;
      end if;
    end if;
    v_rows := v_rows || jsonb_build_object('row', coalesce(nullif(x->>'row','')::int, v_i), 'name', v_name, 'national_id', v_nid,
      'status', case when cardinality(v_errs) > 0 then 'error' when pr.id is not null then 'existing' else 'new' end,
      'role', left(btrim(coalesce(x->>'role','')), 40), 'dates', to_jsonb(v_dates), 'gross', v_gross, 'labor_ins', v_ins, 'allowances', v_allow,
      'net', case when v_gross is not null then v_gross + v_allow - v_ins end, 'fills', to_jsonb(v_fill), 'errors', to_jsonb(v_errs), 'warnings', to_jsonb(v_warns));

    if p_commit and cardinality(v_errs) = 0 then
      if e.id is null then
        insert into public.events(employer_id, name, start_date, end_date, pay_date, location, description, recruiting, source_key, source_file_id)
        select id, left(btrim(ev->>'name'), 120), v_s, v_e, v_pay, nullif(left(btrim(coalesce(ev->>'location','')), 200), ''), nullif(left(btrim(coalesce(ev->>'description','')), 2000), ''),
          false, 'g:' || v_file, v_file
        from public.employers order by created_at limit 1 returning * into e;
      end if;
      if pr.id is null then
        insert into public.people(national_id, name, nickname, phone, birth_date, birth_raw, address, bank_code, bank_branch, bank_account_name, bank_account, password_hash, profile_source)
        values (v_nid, v_name, nullif(left(btrim(coalesce(x->>'nickname','')), 40), ''), nullif(left(btrim(coalesce(x->>'phone','')), 30), ''), v_bd,
          nullif(left(btrim(coalesce(x->>'birth_raw','')), 40), ''), nullif(left(btrim(coalesce(x->>'address','')), 200), ''), v_bank, v_branch, v_acct_name, v_acct,
          case when v_bd is not null then extensions.crypt(lpad((extract(year from v_bd)::int - 1911)::text, 3, '0') || to_char(v_bd, 'MMDD'), extensions.gen_salt('bf', 10)) end, 'legacy')
        returning id into v_pid;
        n_new := n_new + 1;
        if v_bd is null then insert into public.data_issues(event_id, person_id, severity, code, detail) values (e.id, v_pid, 'warn', 'birth_unparsed', 'AI 匯入：生日無法判讀，沒有登入密碼'); end if;
      else
        v_pid := pr.id;
        update public.people set phone = coalesce(phone, nullif(left(btrim(coalesce(x->>'phone','')), 30), '')),
          address = coalesce(address, nullif(left(btrim(coalesce(x->>'address','')), 200), '')),
          birth_date = coalesce(birth_date, v_bd), bank_code = coalesce(bank_code, v_bank), bank_branch = coalesce(bank_branch, v_branch),
          bank_account_name = coalesce(bank_account_name, v_acct_name), bank_account = coalesce(bank_account, v_acct), updated_at = now()
        where id = v_pid;
        if cardinality(v_fill) > 0 then n_upd := n_upd + 1; end if;
        if pr.bank_account is null and v_acct is not null then insert into public.data_issues(event_id, person_id, severity, code, detail) values (e.id, v_pid, 'warn', 'bank_changed', 'AI 匯入補上匯款帳戶，請核對存摺影本'); end if;
        if pr.name <> v_name then insert into public.data_issues(event_id, person_id, severity, code, detail) values (e.id, v_pid, 'warn', 'name_mismatch', format('AI 匯入表上姓名「%s」與系統「%s」不同', v_name, pr.name)); end if;
      end if;
      foreach k in array array['id_front','id_back','bankbook'] loop
        if coalesce(x#>>array['docs',k],'') ~ '^[A-Za-z0-9_-]{20,80}$' then
          insert into public.people_documents(person_id, kind, drive_file_id) values (v_pid, k, x#>>array['docs',k]) on conflict (person_id, kind) do nothing;
        end if;
      end loop;
      insert into public.attendance(person_id, event_id, work_date, scheduled_text, source, note)
      select v_pid, e.id, u, nullif(left(btrim(coalesce(x->>'scheduled_text','')), 200), ''), 'legacy', 'AI 匯入（表單填寫的日期，非打卡紀錄）' from unnest(v_dates) u
      on conflict (person_id, event_id, work_date) do nothing;
      get diagnostics v_cnt = row_count; n_att := n_att + v_cnt;
      if v_gross is not null and not exists (select 1 from public.payslips where person_id = v_pid and event_id = e.id and status <> 'void') then
        insert into public.payslips(person_id, event_id, relation, role, work_dates_text, period_start, period_end, pay_date, basis, gross, allowances, deductions, net,
          status, generated, note, pay_bank_code, pay_bank_branch, pay_account_name, pay_account, source_row)
        select v_pid, e.id, 'employment', nullif(left(btrim(coalesce(x->>'role','')), 40), ''), nullif(left(btrim(coalesce(x->>'scheduled_text','')), 200), ''),
          v_dates[1], v_dates[cardinality(v_dates)], v_pay, 'daily_total', v_gross, v_allow, v_ins, v_gross + v_allow - v_ins, 'draft', false, 'AI 匯入',
          coalesce(v_bank, p.bank_code), coalesce(v_branch, p.bank_branch), coalesce(v_acct_name, p.bank_account_name), coalesce(v_acct, p.bank_account), nullif(x->>'row','')::int
        from public.people p where p.id = v_pid returning id into v_slip;
        insert into public.payslip_items(payslip_id, kind, code, label, work_date, amount, sort)
        select v_slip, 'earning', 'daily_wage', coalesce(nullif(j->>'label',''), coalesce(nullif(btrim(coalesce(x->>'role','')),''), '當日') || ' 日薪'), (j->>'date')::date, (j->>'amount')::numeric, 10 + o::int
        from jsonb_array_elements(v_days) with ordinality t(j, o);
        if jsonb_array_length(v_days) = 0 then
          insert into public.payslip_items(payslip_id, kind, code, label, amount, sort) values (v_slip, 'earning', 'wage_total', '工資（表上僅列總額）', v_gross, 10);
        end if;
        if v_allow > 0 then insert into public.payslip_items(payslip_id, kind, code, label, amount, sort) values (v_slip, 'allowance', 'other', '津貼', v_allow, 20); end if;
        if v_ins > 0 then insert into public.payslip_items(payslip_id, kind, code, label, amount, sort) values (v_slip, 'deduction', 'labor_ins', '勞保自付額', v_ins, 30); end if;
        if v_net is not null and v_net <> v_gross + v_allow - v_ins then
          insert into public.data_issues(event_id, payslip_id, person_id, severity, code, detail) values (e.id, v_slip, v_pid, 'warn', 'net_mismatch', format('AI 匯入：表上撥款 %s，計算 %s', v_net, v_gross + v_allow - v_ins));
        end if;
        if v_acct_name is not null and v_acct_name <> v_name then
          insert into public.data_issues(event_id, payslip_id, person_id, severity, code, detail) values (e.id, v_slip, v_pid, 'warn', 'payee_not_self', format('戶名「%s」不是本人', v_acct_name));
        end if;
        n_slip := n_slip + 1;
      end if;
      v_people := v_people || to_jsonb(v_pid::text);
    elsif cardinality(v_errs) > 0 then n_skip := n_skip + 1;
    end if;
  end loop;

  if p_commit then
    if e.id is null then
      if jsonb_array_length(coalesce(p_payload->'people','[]')) > 0 and n_skip = jsonb_array_length(p_payload->'people')
         and not exists (select 1 from jsonb_array_elements(v_shifts) s where jsonb_array_length(s->'errors') = 0) then
        return jsonb_build_object('ok', false, 'error', 'all_rows_invalid');
      end if;
      insert into public.events(employer_id, name, start_date, end_date, pay_date, location, description, recruiting, source_key, source_file_id)
      select id, left(btrim(ev->>'name'), 120), v_s, v_e, v_pay, nullif(left(btrim(coalesce(ev->>'location','')), 200), ''), nullif(left(btrim(coalesce(ev->>'description','')), 2000), ''),
        jsonb_array_length(coalesce(p_payload->'people','[]')) = 0, 'g:' || v_file, v_file
      from public.employers order by created_at limit 1 returning * into e;
    end if;
    for sh in select * from jsonb_array_elements(v_shifts) loop
      if jsonb_array_length(sh->'errors') = 0 then
        insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount, rate)
        select e.id, (sh->>'work_date')::date, (sh->>'start_time')::time, (sh->>'end_time')::time, nullif(sh->>'role',''), (sh->>'headcount')::int, nullif(sh->>'rate','')::numeric
        where not exists (select 1 from public.shifts z where z.event_id = e.id and z.work_date = (sh->>'work_date')::date and z.start_time = (sh->>'start_time')::time
          and z.end_time = (sh->>'end_time')::time and coalesce(z.role,'') = coalesce(nullif(sh->>'role',''),''));
        get diagnostics v_cnt = row_count; n_shift := n_shift + v_cnt;
      end if;
    end loop;
    insert into public.audit_log(actor, action, table_name, row_id, detail)
    values (v_actor, 'ai_import', 'events', e.id, jsonb_build_object('new_event', p_event is null, 'source', v_file, 'people', v_people,
      'new_people', n_new, 'filled', n_upd, 'attendance', n_att, 'payslips', n_slip, 'shifts', n_shift, 'skipped', n_skip));
    return jsonb_build_object('ok', true, 'event', e.id, 'new_people', n_new, 'filled', n_upd, 'attendance', n_att, 'payslips', n_slip, 'shifts', n_shift, 'skipped', n_skip);
  end if;
  return jsonb_build_object('ok', true, 'preview', true,
    'event', case when p_event is not null then jsonb_build_object('id', e.id, 'name', e.name, 'start_date', v_s, 'end_date', v_e, 'pay_date', v_pay, 'existing', true)
      else jsonb_build_object('name', btrim(ev->>'name'), 'start_date', v_s, 'end_date', v_e, 'pay_date', v_pay, 'location', ev->>'location', 'existing', false,
        'similar', coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'name', z.name, 'start_date', z.start_date, 'end_date', z.end_date, 'archived', z.archived_at is not null) order by z.start_date desc)
          from (select * from public.events z where lower(regexp_replace(z.name, '\s', '', 'g')) = lower(regexp_replace(coalesce(ev->>'name',''), '\s', '', 'g'))
                  and z.start_date <= v_e and coalesce(z.end_date, z.start_date) >= v_s order by z.start_date desc limit 5) z), '[]'::jsonb)) end,
    'shifts', v_shifts, 'people', v_rows);
end $function$
;
revoke all on function public.admin_ai_import(text, jsonb, uuid, boolean) from public;
grant execute on function public.admin_ai_import(text, jsonb, uuid, boolean) to anon, authenticated;

-- notifications.kind 允許 docs（補資料提醒）
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check check (kind = any (array['accepted','reminder','checkout','payslip','test','docs']));
CREATE OR REPLACE FUNCTION public.person_incomplete_text(p_person uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select nullif(concat_ws('、',
    (select string_agg(case k when 'id_front' then '身分證正面' when 'id_back' then '身分證反面' else '存摺封面' end, '、' order by o)
       from jsonb_array_elements_text(i->'docs') with ordinality t(k, o)),
    case when (i->>'bank')::boolean then '匯款帳戶' end), '')
  from (select public.person_incomplete(p_person) i) x where i is not null;
$function$
;
revoke execute on function public.person_incomplete_text(uuid) from public, anon, authenticated;

-- 活動的薪資單附上：工讀生看不看得到、缺什麼、有沒有綁 LINE、能不能登入
CREATE OR REPLACE FUNCTION public.admin_remind_incomplete(p_token text, p_event uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor text := public.admin_actor(p_token); e public.events; v_q int; v_total int; v_noline int;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into e from public.events where id = p_event;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  with t as (
    select distinct s.person_id, p.line_user_id, public.person_incomplete_text(s.person_id) miss
    from public.payslips s join public.people p on p.id = s.person_id
    where s.event_id = p_event and s.status <> 'void'
  ), ins as (
    insert into public.notifications(person_id, event_id, kind, body, dedupe_key)
    select person_id, p_event, 'docs',
      '【沃克思】要在系統看到「' || e.name || '」的薪資單，還需要你補上：' || miss || E'\n' || '請登入補齊：' || coalesce(public.setting('site_url'), ''),
      'docs:' || person_id || ':' || p_event || ':' || ((now() at time zone 'Asia/Taipei')::date)
    from t where miss is not null and line_user_id is not null
    on conflict do nothing returning 1
  )
  select (select count(*) from ins), (select count(*) from t where miss is not null), (select count(*) from t where miss is not null and line_user_id is null)
  into v_q, v_total, v_noline;
  insert into public.audit_log(actor, action, table_name, row_id, detail)
  values (v_actor, 'remind_incomplete', 'events', p_event, jsonb_build_object('queued', v_q, 'incomplete', v_total, 'no_line', v_noline));
  return jsonb_build_object('ok', true, 'queued', v_q, 'incomplete', v_total, 'no_line', v_noline);
end $function$
;
revoke all on function public.admin_remind_incomplete(text, uuid) from public;
grant execute on function public.admin_remind_incomplete(text, uuid) to anon, authenticated;


-- 巡檢第二輪：缺資料名單匯出、登入頁聯絡窗口
insert into public.app_settings(key, value) values ('contact_info', null) on conflict (key) do nothing;
revoke all on function public.payroll_contact() from public;
grant execute on function public.payroll_contact() to anon, authenticated;

-- 打卡 QR 分享頁：沒有督導在場時，把會自動更新的打卡 QR 頁連結交給資深工讀生
-- 一場活動同時只有一條有效連結；連結只存雜湊；活動結束隔天結束時自動失效；可隨時停用
create table if not exists public.checkin_shares (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  token_hash text not null unique,
  created_by text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  revoked_by text
);
create index if not exists checkin_shares_event on public.checkin_shares(event_id);
alter table public.checkin_shares enable row level security;
revoke all on public.checkin_shares from anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_checkin_share(p_token text, p_event uuid, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- p_action：status 看目前連結、create 產生新連結（舊的同時停用）、revoke 停用
declare v_actor text := public.admin_actor(p_token); e public.events; v_tok text; v_exp timestamptz; s public.checkin_shares;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into e from public.events where id = p_event for update;
  if e.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if p_action = 'status' then
    select * into s from public.checkin_shares where event_id = p_event and revoked_at is null and expires_at > now()
      and e.archived_at is null and ((coalesce(e.end_date, e.start_date) + 2)::timestamp at time zone 'Asia/Taipei') > now() order by created_at desc limit 1;
    return jsonb_build_object('ok', true, 'active', s.id is not null, 'created_at', s.created_at, 'created_by', s.created_by, 'expires_at', s.expires_at);
  elsif p_action = 'revoke' then
    update public.checkin_shares set revoked_at = now(), revoked_by = v_actor where event_id = p_event and revoked_at is null;
    insert into public.audit_log(actor, action, table_name, row_id) values (v_actor, 'checkin_share_revoked', 'events', p_event);
    return jsonb_build_object('ok', true, 'active', false);
  elsif p_action = 'create' then
    if e.archived_at is not null then return jsonb_build_object('ok', false, 'error', 'archived'); end if;
    -- 活動結束日的隔天 24:00（台北時間）失效，涵蓋跨夜班
    v_exp := ((coalesce(e.end_date, e.start_date) + 2)::timestamp at time zone 'Asia/Taipei');
    if v_exp <= now() then return jsonb_build_object('ok', false, 'error', 'ended'); end if;
    update public.checkin_shares set revoked_at = now(), revoked_by = v_actor where event_id = p_event and revoked_at is null;
    v_tok := encode(extensions.gen_random_bytes(24), 'hex');
    insert into public.checkin_shares(event_id, token_hash, created_by, expires_at)
    values (p_event, encode(extensions.digest(v_tok, 'sha256'), 'hex'), v_actor, v_exp);
    insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'checkin_share_created', 'events', p_event, jsonb_build_object('expires_at', v_exp));
    return jsonb_build_object('ok', true, 'active', true, 'share', v_tok, 'expires_at', v_exp);
  end if;
  return jsonb_build_object('ok', false, 'error', 'bad_action');
end $function$
;
revoke all on function public.admin_checkin_share(text, uuid, text) from public;
grant execute on function public.admin_checkin_share(text, uuid, text) to anon, authenticated;

CREATE OR REPLACE FUNCTION public.payroll_share_checkin_code(p_share text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 分享頁每分鐘取一次打卡碼；連結失效、被停用或活動封存就不給
declare s public.checkin_shares; e public.events; v_code text;
begin
  if coalesce(p_share, '') !~ '^[0-9a-f]{48}$' then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
  select * into s from public.checkin_shares where token_hash = encode(extensions.digest(p_share, 'sha256'), 'hex');
  if s.id is null or s.revoked_at is not null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
  if s.expires_at <= now() then return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  select * into e from public.events where id = s.event_id;
  if e.id is null or e.archived_at is not null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
  if ((coalesce(e.end_date, e.start_date) + 2)::timestamp at time zone 'Asia/Taipei') <= now() then return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  v_code := public.checkin_make_code(e.id, floor(extract(epoch from now()) / 60)::bigint);
  return jsonb_build_object('ok', true, 'event', e.name, 'start_date', e.start_date, 'end_date', coalesce(e.end_date, e.start_date), 'expires_at', s.expires_at,
    'code', v_code, 'refresh_in', 60 - floor(extract(epoch from now()))::bigint % 60);
end $function$
;
revoke all on function public.payroll_share_checkin_code(text) from public;
grant execute on function public.payroll_share_checkin_code(text) to anon, authenticated;
-- 打卡碼只由資料庫內部函式產生，不開放直接呼叫
revoke all on function public.checkin_make_code(uuid, bigint) from public, anon, authenticated;

-- 新人自行建檔：沒有活動報名連結也能建檔，用 Email 驗證碼確認（驗證碼由 w63068925 的 Apps Script 寄出）
create table if not exists public.signup_verifications (
  id uuid primary key default gen_random_uuid(),
  national_id text not null,
  email text not null,
  code_hash text not null,
  attempts int not null default 0,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  verified_at timestamptz,
  ticket_hash text unique,
  ticket_expires_at timestamptz,
  used_at timestamptz
);
create index if not exists signup_verifications_nid on public.signup_verifications(national_id, created_at);
create index if not exists signup_verifications_email on public.signup_verifications(email, created_at);
alter table public.signup_verifications enable row level security;
revoke all on public.signup_verifications from anon, authenticated;
insert into public.app_settings(key, value) values ('mail_webapp_url', null), ('mail_key', null) on conflict (key) do nothing;

CREATE OR REPLACE FUNCTION public.payroll_signup_start(p_national_id text, p_email text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 寄 6 位數驗證碼到 Email（10 分鐘有效）；同一身分證或 Email 一小時最多 3 次，全站一天最多 300 封
declare v_nid text := upper(regexp_replace(public.halfwidth(coalesce(p_national_id,'')), '\s', '', 'g'));
  v_email text := lower(btrim(public.halfwidth(coalesce(p_email,'')))); v_url text := public.setting('mail_webapp_url'); v_key text := public.setting('mail_key');
  v_code text; v_id uuid;
  v_ip text := nullif(btrim(split_part(coalesce((nullif(current_setting('request.headers', true), ''))::json->>'x-forwarded-for', ''), ',', 1)), '');
begin
  perform pg_advisory_xact_lock(hashtext('payroll_signup_start'));
  perform pg_advisory_xact_lock(hashtext('mail_quota'));
  v_url := nullif(btrim(coalesce(v_url, '')), ''); v_key := nullif(btrim(coalesce(v_key, '')), '');
  if not public.valid_tw_id(v_nid) then return jsonb_build_object('ok', false, 'error', 'bad_national_id'); end if;
  if length(v_email) > 120 or v_email !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then return jsonb_build_object('ok', false, 'error', 'bad_email'); end if;
  if v_ip is not null then
    if (select count(*) from public.signup_attempts where ip = v_ip and created_at > now() - interval '1 hour') >= 10 then return jsonb_build_object('ok', false, 'error', 'too_many'); end if;
    delete from public.signup_attempts where created_at < now() - interval '1 day';
    insert into public.signup_attempts(ip) values (v_ip);
  end if;
  if exists (select 1 from public.people where national_id = v_nid) then return jsonb_build_object('ok', false, 'error', 'exists'); end if;
  if v_url is null or v_key is null then return jsonb_build_object('ok', false, 'error', 'mail_unavailable'); end if;
  if (select count(*) from public.signup_verifications where national_id = v_nid and created_at > now() - interval '1 hour') >= 3
     or (select count(*) from public.signup_verifications where email = v_email and created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'error', 'too_many');
  end if;
  if (select count(*) from public.signup_verifications where created_at > now() - interval '1 day')
     + (select count(*) from public.notifications where channel = 'mail' and (status = 'sending' or (status = 'sent' and sent_at > now() - interval '24 hours'))) >= 95 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  delete from public.signup_verifications where created_at < now() - interval '7 days';
  v_code := lpad(((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  v_id := gen_random_uuid();
  insert into public.signup_verifications(id, national_id, email, code_hash, expires_at)
  values (v_id, v_nid, v_email, encode(extensions.digest(v_id::text || ':' || v_code, 'sha256'), 'hex'), now() + interval '10 minutes');
  -- 不把寄信密鑰放進 pg_net 佇列：只送 HMAC 簽章（佇列表的 PUBLIC 權限由 Supabase 管，不能收回）
  perform net.http_post(url := v_url, body := jsonb_build_object('type', 'signup_code', 'to', v_email, 'code', v_code, 'ts', floor(extract(epoch from now()))::bigint,
      'sig', encode(extensions.hmac(v_email || '|' || v_code || '|' || floor(extract(epoch from now()))::bigint, v_key, 'sha256'), 'hex')),
    headers := '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds := 10000);
  return jsonb_build_object('ok', true);
end $function$
;
revoke all on function public.payroll_signup_start(text, text) from public;
grant execute on function public.payroll_signup_start(text, text) to anon, authenticated;

CREATE OR REPLACE FUNCTION public.payroll_signup_verify(p_national_id text, p_email text, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 驗證碼對了就發一張 30 分鐘、只能用一次的建檔票；同一組驗證碼最多試 5 次
declare v_nid text := upper(regexp_replace(public.halfwidth(coalesce(p_national_id,'')), '\s', '', 'g'));
  v_email text := lower(btrim(public.halfwidth(coalesce(p_email,'')))); v_code text := regexp_replace(public.halfwidth(coalesce(p_code,'')), '\D', '', 'g');
  v public.signup_verifications; v_ticket text;
begin
  select * into v from public.signup_verifications where national_id = v_nid and email = v_email and verified_at is null order by created_at desc limit 1 for update;
  if v.id is null or v.expires_at <= now() then return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  if v.attempts >= 5 then return jsonb_build_object('ok', false, 'error', 'too_many'); end if;
  if v.code_hash <> encode(extensions.digest(v.id::text || ':' || v_code, 'sha256'), 'hex') then
    update public.signup_verifications set attempts = attempts + 1 where id = v.id;
    return jsonb_build_object('ok', false, 'error', 'bad_code', 'left', 4 - v.attempts);
  end if;
  v_ticket := encode(extensions.gen_random_bytes(24), 'hex');
  update public.signup_verifications set verified_at = now(), ticket_hash = encode(extensions.digest(v_ticket, 'sha256'), 'hex'), ticket_expires_at = now() + interval '30 minutes' where id = v.id;
  return jsonb_build_object('ok', true, 'ticket', v_ticket);
end $function$
;
revoke all on function public.payroll_signup_verify(text, text, text) from public;
grant execute on function public.payroll_signup_verify(text, text, text) to anon, authenticated;

-- 新人建檔安全加固（Codex xhigh 審查）：每個 IP 一小時最多 10 次（含「已經有帳號」的查詢）、寄信序列化避免同時送出超過上限、
-- 寄信請求只帶 HMAC 簽章、不帶密鑰（net schema 沒對外開放；佇列表的 PUBLIC 權限屬 Supabase 管理，不能收回）
create table if not exists public.signup_attempts (ip text not null, created_at timestamptz not null default now());
create index if not exists signup_attempts_ip on public.signup_attempts(ip, created_at);
alter table public.signup_attempts enable row level security;
revoke all on public.signup_attempts from anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_mail_settings(p_token text, p_patch jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 新人建檔驗證信的寄信設定：Apps Script 網址與共用密鑰。密鑰只寫不讀（畫面只顯示有沒有設定）；全部欄位驗證通過才寫入
declare v_actor text := public.admin_actor(p_token); v_url text; v_key text;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_patch is not null then
    if p_patch ? 'url' then
      v_url := nullif(btrim(coalesce(p_patch->>'url','')), '');
      if v_url is not null and v_url !~ '^https://script\.google\.com/macros/s/[A-Za-z0-9_-]{20,120}/exec$' then return jsonb_build_object('ok', false, 'error', 'bad_url'); end if;
    end if;
    if p_patch ? 'key' and btrim(coalesce(p_patch->>'key','')) <> '' then
      v_key := btrim(p_patch->>'key');
      if v_key !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false, 'error', 'bad_key'); end if;
    end if;
    if p_patch ? 'url' then update public.app_settings set value = v_url where key = 'mail_webapp_url'; end if;
    if v_key is not null then update public.app_settings set value = v_key where key = 'mail_key'; end if;
    insert into public.audit_log(actor, action, table_name, detail) values (v_actor, 'mail_settings_updated', 'app_settings', jsonb_build_object('url', p_patch ? 'url', 'key', v_key is not null));
  end if;
  return jsonb_build_object('ok', true, 'url', public.setting('mail_webapp_url'), 'key_set', nullif(public.setting('mail_key'), '') is not null,
    'sent_today', (select count(*) from public.signup_verifications where created_at > now() - interval '1 day'));
end $function$
;
revoke all on function public.admin_mail_settings(text, jsonb) from public;
grant execute on function public.admin_mail_settings(text, jsonb) to anon, authenticated;
-- 設定值（含寄信密鑰）只給資料庫內部函式讀
revoke all on function public.setting(text) from public, anon, authenticated;

-- 現金發薪（使用者決定 2026-11-27）：發放方式記在每張薪資單；現金要列印簽收單、拍照上傳，管理員按「已發放」；領現金仍要存摺；不拆分
alter table public.payslips add column if not exists pay_method text not null default 'transfer';
alter table public.payslips drop constraint if exists payslips_pay_method_check;
alter table public.payslips add constraint payslips_pay_method_check check (pay_method in ('transfer', 'cash'));
alter table public.payslips add column if not exists cash_paid_at timestamptz;
alter table public.payslips add column if not exists cash_paid_by text;
create table if not exists public.payout_receipts (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  path text not null unique,
  uploaded_by text not null,
  uploaded_at timestamptz not null default now()
);
create index if not exists payout_receipts_event on public.payout_receipts(event_id);
alter table public.payout_receipts enable row level security;
revoke all on public.payout_receipts from anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_pay_method(p_token text, p_ids uuid[], p_method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 改發放方式（轉帳／現金）；現金已發放的不能改回轉帳。改成現金時「沒有匯款帳號」標為已處理；改回轉帳且仍沒帳號時重新打開
declare v_actor text := public.admin_actor(p_token); v_n int; v_paid int; v_changed uuid[];
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_method is null or p_method not in ('transfer', 'cash') then return jsonb_build_object('ok', false, 'error', 'bad_method'); end if;
  if coalesce(array_length(p_ids, 1), 0) = 0 or array_length(p_ids, 1) > 1000 then return jsonb_build_object('ok', false, 'error', 'bad_ids'); end if;
  select count(*) into v_paid from public.payslips where id = any(p_ids) and cash_paid_at is not null and p_method = 'transfer';
  with u as (
    update public.payslips set pay_method = p_method where id = any(p_ids) and status <> 'void' and pay_method <> p_method and not (cash_paid_at is not null and p_method = 'transfer')
    returning id)
  select coalesce(array_agg(id), '{}') into v_changed from u;
  v_n := coalesce(array_length(v_changed, 1), 0);
  if p_method = 'cash' then
    update public.data_issues set resolved = true where payslip_id = any(v_changed) and code = 'no_bank_account' and not resolved;
  else
    update public.data_issues i set resolved = false from public.payslips s
     where i.payslip_id = s.id and s.id = any(v_changed) and i.code = 'no_bank_account' and i.resolved and s.pay_account is null;
  end if;
  insert into public.audit_log(actor, action, table_name, detail) values (v_actor, 'pay_method_set', 'payslips', jsonb_build_object('method', p_method, 'ids', to_jsonb(p_ids), 'updated', v_n));
  return jsonb_build_object('ok', true, 'updated', v_n, 'skipped_paid', v_paid);
end $function$
;
revoke all on function public.admin_set_pay_method(text, uuid[], text) from public;
grant execute on function public.admin_set_pay_method(text, uuid[], text) to anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_mark_cash_paid(p_token text, p_ids uuid[], p_paid boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 現金已發放／取消：只對已發布、發放方式為現金的薪資單；標記已發放前，該活動要先上傳過簽收單照片
declare v_actor text := public.admin_actor(p_token); v_n int;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_paid is null then return jsonb_build_object('ok', false, 'error', 'bad_value'); end if;
  if coalesce(array_length(p_ids, 1), 0) = 0 or array_length(p_ids, 1) > 1000 then return jsonb_build_object('ok', false, 'error', 'bad_ids'); end if;
  if p_paid then
    if exists (select 1 from public.payslips s where s.id = any(p_ids) and s.pay_method = 'cash' and s.status = 'published' and s.cash_paid_at is null
               and not exists (select 1 from public.payout_receipts r where r.event_id = s.event_id)) then
      return jsonb_build_object('ok', false, 'error', 'no_receipt');
    end if;
    update public.payslips set cash_paid_at = now(), cash_paid_by = v_actor where id = any(p_ids) and pay_method = 'cash' and status = 'published' and cash_paid_at is null;
  else
    update public.payslips set cash_paid_at = null, cash_paid_by = null where id = any(p_ids) and pay_method = 'cash' and status = 'published' and cash_paid_at is not null;
  end if;
  get diagnostics v_n = row_count;
  insert into public.audit_log(actor, action, table_name, detail) values (v_actor, case when p_paid then 'cash_paid' else 'cash_paid_undone' end, 'payslips', jsonb_build_object('ids', to_jsonb(p_ids), 'updated', v_n));
  return jsonb_build_object('ok', true, 'updated', v_n);
end $function$
;
revoke all on function public.admin_mark_cash_paid(text, uuid[], boolean) from public;
grant execute on function public.admin_mark_cash_paid(text, uuid[], boolean) to anon, authenticated;


CREATE OR REPLACE FUNCTION public.admin_payout_receipts(p_token text, p_event uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 發薪步驟顯示已上傳的現金簽收單清單（不含檔案路徑）
declare v_actor text := public.admin_actor(p_token);
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return jsonb_build_object('ok', true, 'receipts', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'uploaded_by', r.uploaded_by, 'uploaded_at', r.uploaded_at) order by r.uploaded_at)
    from public.payout_receipts r where r.event_id = p_event), '[]'::jsonb));
end $function$
;
revoke all on function public.admin_payout_receipts(text, uuid) from public;
grant execute on function public.admin_payout_receipts(text, uuid) to anon, authenticated;

-- 刪除／停用人員（使用者決定 2026-11-27）：沒有薪資單、沒有出勤的人可以永久刪除（含證件檔，檔案由 docs 函式刪）；
-- 有薪資或出勤紀錄的依勞基法要保存，只能「停用」：不能登入、預設不出現在人員名單，紀錄保留，可恢復
alter table public.people add column if not exists disabled_at timestamptz;
alter table public.people add column if not exists disabled_by text;

CREATE OR REPLACE FUNCTION public.admin_delete_person(p_token text, p_id uuid, p_confirm text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 永久刪除：要輸入完整身分證字號確認；有薪資單或出勤就拒絕。回傳要刪的儲存檔路徑給 docs 函式清掉
declare v_actor text := public.admin_actor(p_token); p public.people; v_paths text[];
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into p from public.people where id = p_id for update;
  if p.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if upper(btrim(coalesce(p_confirm, ''))) <> p.national_id then return jsonb_build_object('ok', false, 'error', 'confirm'); end if;
  if exists (select 1 from public.payslips where person_id = p.id) or exists (select 1 from public.attendance where person_id = p.id) then
    return jsonb_build_object('ok', false, 'error', 'has_records');
  end if;
  select coalesce(array_agg(path), '{}') into v_paths from public.people_documents where person_id = p.id and path is not null;
  delete from public.data_issues where person_id = p.id;
  delete from public.people where id = p.id;
  insert into public.audit_log(actor, action, table_name, row_id, detail)
  values (v_actor, 'person_deleted', 'people', p.id, jsonb_build_object('national_id', public.payroll_mask_id(p.national_id), 'files', coalesce(array_length(v_paths, 1), 0)));
  return jsonb_build_object('ok', true, 'paths', to_jsonb(v_paths));
end $function$
;
revoke all on function public.admin_delete_person(text, uuid, text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_person_disabled(p_token text, p_id uuid, p_disabled boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 停用：不能登入（踢掉現有登入）、預設不出現在人員名單；紀錄全部保留。恢復則清掉停用
declare v_actor text := public.admin_actor(p_token); v_n int;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_disabled is null then return jsonb_build_object('ok', false, 'error', 'bad_value'); end if;
  update public.people set disabled_at = case when p_disabled then now() end, disabled_by = case when p_disabled then v_actor end
   where id = p_id and (disabled_at is not null) <> p_disabled;
  get diagnostics v_n = row_count;
  if p_disabled then delete from public.sessions where person_id = p_id; delete from public.line_link_codes where person_id = p_id; end if;
  if v_n > 0 then
    insert into public.audit_log(actor, action, table_name, row_id) values (v_actor, case when p_disabled then 'person_disabled' else 'person_enabled' end, 'people', p_id);
  end if;
  return jsonb_build_object('ok', true, 'updated', v_n);
end $function$
;
revoke all on function public.admin_set_person_disabled(text, uuid, boolean) from public;
grant execute on function public.admin_set_person_disabled(text, uuid, boolean) to anon, authenticated;

grant execute on function public.admin_delete_person(text, uuid, text) to service_role;

CREATE OR REPLACE FUNCTION public.legacy_hd_priority_ids(p_limit integer)
 RETURNS TABLE(drive_file_id text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- 舊證件換清楚版的優先名單：招募中、即將開始或 7 天內結束（未封存）的活動裡有報名或出勤的人，證件仍是 500px 舊縮圖
  select distinct d.drive_file_id from public.people_documents d
  where d.path like '%-lthumb-%' and d.drive_file_id is not null and d.kind in ('id_front','id_back','bankbook')
    and d.person_id in (
      select a.person_id from public.applications a join public.events e on e.id = a.event_id
       where e.archived_at is null and (e.recruiting or coalesce(e.end_date, e.start_date) >= (now() at time zone 'Asia/Taipei')::date - 7)
      union
      select t.person_id from public.attendance t join public.events e on e.id = t.event_id
       where e.archived_at is null and coalesce(e.end_date, e.start_date) >= (now() at time zone 'Asia/Taipei')::date - 7)
  limit greatest(1, least(coalesce(p_limit, 200), 500));
$function$
;
revoke all on function public.legacy_hd_priority_ids(integer) from public, anon, authenticated;
grant execute on function public.legacy_hd_priority_ids(integer) to service_role;

CREATE OR REPLACE FUNCTION public.recruit_mode()
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- 報名方式：pool 名單制／plans 方案制／pick 自選班次（預設）
  select case when public.setting('recruit_mode') in ('pool', 'plans', 'pick') then public.setting('recruit_mode') else 'pick' end
$function$
;

CREATE OR REPLACE FUNCTION public.recruit_need_line()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- 報名前必須綁定 LINE：設定打開、LINE 通知沒關、而且官方帳號已設定才生效
  select coalesce(public.setting('recruit_require_line'), 'false') = 'true' and coalesce(public.setting('line_enabled'), 'true') = 'true'
    and nullif(btrim(coalesce(public.setting('line_basic_id'), '')), '') is not null
$function$
;

CREATE OR REPLACE FUNCTION public.join_target(p_join text, OUT event_id uuid, OUT plan_id uuid)
 RETURNS record
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 報名連結可以是活動的主連結，或方案／專屬連結（已停用的方案連結無效）
declare v text := btrim(coalesce(p_join, ''));
begin
  if v = '' then return; end if;
  select e.id into event_id from public.events e where e.signup_code = v;
  if event_id is not null then return; end if;
  select p.event_id, p.id into event_id, plan_id from public.recruit_plans p where p.code = v and p.disabled_at is null;
  -- 名單制不分方案：方案連結當成這場活動的報名連結
  if public.recruit_mode() = 'pool' then plan_id := null; end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.plan_json(p recruit_plans)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with acc as (select count(*) n from public.applications a where a.plan_id = p.id and a.status = 'active'
    and exists (select 1 from public.application_shifts x where x.application_id = a.id and x.status = 'accepted'))
  select jsonb_build_object('id', p.id, 'name', p.name, 'headcount', p.headcount, 'shift_ids', to_jsonb(p.shift_ids),
    'applied', (select count(*) from public.applications a where a.plan_id = p.id and a.status = 'active'),
    'accepted', (select n from acc),
    -- 額滿：方案名額已滿，或方案裡任何一班已錄取滿額
    'full', (p.headcount is not null and (select n from acc) >= p.headcount)
      or exists (select 1 from public.shifts s where s.id = any(p.shift_ids) and (select count(*) from public.application_shifts x join public.applications a on a.id = x.application_id
          where x.shift_id = s.id and x.status = 'accepted' and a.status = 'active') >= s.headcount))
$function$
;

CREATE OR REPLACE FUNCTION public.recruit_view(p_event uuid, p_plan uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
-- 報名頁要呈現的方式：pool 不列班次／plan 單一方案連結／plans 列出方案單選／pick 自選班次
declare v_mode text := public.recruit_mode(); v_plans jsonb;
begin
  if v_mode = 'pool' then return jsonb_build_object('kind', 'pool', 'plans', '[]'::jsonb); end if;
  if p_plan is not null then
    return jsonb_build_object('kind', 'plan', 'plans', coalesce((select jsonb_agg(public.plan_json(p)) from public.recruit_plans p
      where p.id = p_plan and p.event_id = p_event and p.disabled_at is null), '[]'::jsonb));
  end if;
  if v_mode = 'plans' then
    select jsonb_agg(public.plan_json(p) order by p.created_at) into v_plans from public.recruit_plans p where p.event_id = p_event and p.disabled_at is null;
    if v_plans is not null then return jsonb_build_object('kind', 'plans', 'plans', v_plans); end if;
  end if;
  return jsonb_build_object('kind', 'pick', 'plans', '[]'::jsonb);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_save_plan(p_token text, p_event uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 建立、改名、改名額或停用方案／專屬連結。同一組班次已有啟用中的方案就沿用，不重複產生連結
declare v_actor text := public.admin_actor(p_token); pl public.recruit_plans; v_ids uuid[]; v_name text; v_head int; v_new public.recruit_plans;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if not exists (select 1 from public.events where id = p_event) then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if p_patch ? 'headcount' then
    begin v_head := nullif(btrim(coalesce(p_patch->>'headcount', '')), '')::int; exception when others then return jsonb_build_object('ok', false, 'error', 'bad_headcount'); end;
    if v_head is not null and (v_head < 1 or v_head > 500) then return jsonb_build_object('ok', false, 'error', 'bad_headcount'); end if;
  end if;
  if p_patch ? 'id' then
    begin
      select * into pl from public.recruit_plans where id = (p_patch->>'id')::uuid and event_id = p_event for update;
    exception when others then return jsonb_build_object('ok', false, 'error', 'not_found'); end;
    if pl.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
    if coalesce((p_patch->>'disabled')::boolean, false) then
      update public.recruit_plans set disabled_at = coalesce(disabled_at, now()) where id = pl.id;
      insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'plan_disabled', 'recruit_plans', pl.id, jsonb_build_object('event', p_event));
      return jsonb_build_object('ok', true);
    end if;
    v_name := left(btrim(coalesce(p_patch->>'name', pl.name)), 40);
    if v_name = '' then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
    update public.recruit_plans set name = v_name, headcount = case when p_patch ? 'headcount' then v_head else headcount end where id = pl.id;
    insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'plan_updated', 'recruit_plans', pl.id, jsonb_build_object('name', v_name, 'headcount', v_head));
    return jsonb_build_object('ok', true);
  end if;
  begin
    select coalesce(array_agg(distinct x::uuid order by x::uuid), '{}') into v_ids from jsonb_array_elements_text(coalesce(p_patch->'shift_ids', '[]'::jsonb)) x;
  exception when others then return jsonb_build_object('ok', false, 'error', 'bad_shift'); end;
  if cardinality(v_ids) < 1 or cardinality(v_ids) > 50 then return jsonb_build_object('ok', false, 'error', 'bad_shift'); end if;
  if (select count(*) from public.shifts where id = any(v_ids) and event_id = p_event) <> cardinality(v_ids) then return jsonb_build_object('ok', false, 'error', 'bad_shift'); end if;
  -- 同一組裡時段重疊的班次不能放一起（同一人不能同時上兩班）
  if exists (select 1 from public.shifts a join public.shifts b on a.id < b.id where a.id = any(v_ids) and b.id = any(v_ids)
      and (a.work_date + a.start_time, a.work_date + a.end_time + case when a.end_time <= a.start_time then interval '1 day' else interval '0' end)
          overlaps (b.work_date + b.start_time, b.work_date + b.end_time + case when b.end_time <= b.start_time then interval '1 day' else interval '0' end)) then
    return jsonb_build_object('ok', false, 'error', 'overlap');
  end if;
  select * into pl from public.recruit_plans p where p.event_id = p_event and p.disabled_at is null
    and (select array_agg(x order by x) from unnest(p.shift_ids) x) = v_ids limit 1;
  if pl.id is not null then return jsonb_build_object('ok', true, 'id', pl.id, 'code', pl.code, 'existing', true, 'name', pl.name); end if;
  v_name := left(btrim(coalesce(p_patch->>'name', '')), 40);
  if v_name = '' then
    select left(string_agg(coalesce(nullif(btrim(s.role), ''), to_char(s.start_time, 'HH24:MI')), '＋' order by s.work_date, s.start_time), 40) into v_name
    from public.shifts s where s.id = any(v_ids);
  end if;
  insert into public.recruit_plans(event_id, name, shift_ids, headcount, created_by) values (p_event, v_name, v_ids, v_head, v_actor) returning * into v_new;
  insert into public.audit_log(actor, action, table_name, row_id, detail) values (v_actor, 'plan_created', 'recruit_plans', v_new.id,
    jsonb_build_object('event', p_event, 'shifts', cardinality(v_ids), 'headcount', v_head));
  return jsonb_build_object('ok', true, 'id', v_new.id, 'code', v_new.code, 'name', v_new.name);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_decide_plan(p_token text, p_apps uuid[], p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 方案報名的人整組處理：錄取時方案名額、每一班名額、時段衝突都要過，否則這個人整組都不錄取
declare v_actor text := public.admin_actor(p_token); a public.applications; pl public.recruit_plans; v_items jsonb; v_n int; r jsonb; v_done int := 0;
  full_list jsonb := '[]'::jsonb; clash_list jsonb := '[]'::jsonb; v_name text;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_status not in ('accepted','waitlist','rejected') then return jsonb_build_object('ok', false, 'error', 'bad_status'); end if;
  for a in select * from public.applications where id = any(p_apps) and status = 'active' and plan_id is not null order by id for update loop
    select * into pl from public.recruit_plans where id = a.plan_id for update;
    select name into v_name from public.people where id = a.person_id;
    select jsonb_agg(jsonb_build_object('app', a.id, 'shift', x.shift_id)), count(*) into v_items, v_n
      from public.application_shifts x where x.application_id = a.id and x.status <> p_status;
    if v_items is null then continue; end if;
    if p_status = 'accepted' then
      if pl.headcount is not null and (select count(*) from public.applications a2 where a2.plan_id = pl.id and a2.status = 'active' and a2.id <> a.id
          and exists (select 1 from public.application_shifts x where x.application_id = a2.id and x.status = 'accepted')) >= pl.headcount then
        full_list := full_list || to_jsonb(v_name); continue;
      end if;
      perform 1 from public.shifts where id in (select shift_id from public.application_shifts where application_id = a.id) order by id for update;
      if exists (select 1 from public.application_shifts x join public.shifts s on s.id = x.shift_id where x.application_id = a.id and x.status <> 'accepted'
          and (select count(*) from public.application_shifts y join public.applications ay on ay.id = y.application_id
               where y.shift_id = s.id and y.status = 'accepted' and ay.status = 'active') >= s.headcount) then
        full_list := full_list || to_jsonb(v_name); continue;
      end if;
      if exists (select 1 from public.application_shifts x join public.shifts s on s.id = x.shift_id
          join public.application_shifts x2 on x2.status = 'accepted' join public.applications a2 on a2.id = x2.application_id and a2.status = 'active' and a2.person_id = a.person_id
          join public.shifts s2 on s2.id = x2.shift_id
          where x.application_id = a.id and x.status <> 'accepted' and s2.id <> s.id and s2.work_date between s.work_date - 1 and s.work_date + 1
            and (s2.work_date + s2.start_time, s2.work_date + s2.end_time + case when s2.end_time <= s2.start_time then interval '1 day' else interval '0' end)
                overlaps (s.work_date + s.start_time, s.work_date + s.end_time + case when s.end_time <= s.start_time then interval '1 day' else interval '0' end)) then
        clash_list := clash_list || to_jsonb(v_name); continue;
      end if;
    end if;
    perform set_config('payroll.plan_decide', '1', true);
    r := public.admin_decide(p_token, v_items, p_status);
    perform set_config('payroll.plan_decide', '', true);
    -- 前面檢查都過了，整組一定要全部更新；萬一沒有就整筆取消，不留下只錄取一半的狀態
    if (r->>'updated')::int <> v_n then raise exception 'plan_partial'; end if;
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('ok', true, 'updated', v_done, 'full', full_list, 'clash', clash_list);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_assign(p_token text, p_shift uuid, p_apps uuid[], p_add boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 名單制排班：把報名這場活動的人排入（直接錄取）或移出某個班次；名額、時段衝突沿用 admin_decide 的檢查
declare v_actor text := public.admin_actor(p_token); s public.shifts; v_new uuid[]; v_items jsonb; r jsonb;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_add is null then return jsonb_build_object('ok', false, 'error', 'bad_value'); end if;
  select * into s from public.shifts where id = p_shift;
  if s.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if p_add then
    with ins as (
      insert into public.application_shifts(application_id, shift_id, status)
      select a.id, s.id, 'applied' from public.applications a where a.id = any(p_apps) and a.event_id = s.event_id and a.status = 'active'
      on conflict do nothing returning application_id)
    select coalesce(array_agg(application_id), '{}') into v_new from ins;
    select jsonb_agg(jsonb_build_object('app', a.id, 'shift', s.id)) into v_items from public.applications a where a.id = any(p_apps) and a.event_id = s.event_id and a.status = 'active';
    r := public.admin_decide(p_token, coalesce(v_items, '[]'::jsonb), 'accepted');
    -- 名額滿或時段衝突沒排進去的，不留下「報名」紀錄
    delete from public.application_shifts where shift_id = s.id and application_id = any(v_new) and status = 'applied';
  else
    select jsonb_agg(jsonb_build_object('app', x.application_id, 'shift', s.id)) into v_items
      from public.application_shifts x join public.applications a on a.id = x.application_id
      where x.shift_id = s.id and x.application_id = any(p_apps) and a.event_id = s.event_id;
    r := public.admin_decide(p_token, coalesce(v_items, '[]'::jsonb), 'rejected');
    delete from public.application_shifts x using public.applications a
      where a.id = x.application_id and a.event_id = s.event_id and x.shift_id = s.id and x.application_id = any(p_apps) and x.status = 'rejected';
  end if;
  return r;
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_recruit_settings(p_token text, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 報名方式設定（全站）：p_patch 為 null 只讀取
declare v_actor text := public.admin_actor(p_token); v_mode text; v_line text;
begin
  if v_actor is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_patch is not null then
    v_mode := coalesce(p_patch->>'mode', public.recruit_mode());
    if v_mode not in ('pool', 'plans', 'pick') then return jsonb_build_object('ok', false, 'error', 'bad_mode'); end if;
    v_line := coalesce(p_patch->>'require_line', coalesce(public.setting('recruit_require_line'), 'false'));
    if v_line not in ('true', 'false') then return jsonb_build_object('ok', false, 'error', 'bad_value'); end if;
    if v_line = 'true' and not (nullif(btrim(coalesce(public.setting('line_basic_id'), '')), '') is not null and coalesce(public.setting('line_enabled'), 'true') = 'true') then
      return jsonb_build_object('ok', false, 'error', 'line_not_ready');
    end if;
    insert into public.app_settings(key, value) values ('recruit_mode', v_mode), ('recruit_require_line', v_line)
      on conflict (key) do update set value = excluded.value;
    insert into public.audit_log(actor, action, table_name, detail) values (v_actor, 'recruit_settings', 'app_settings', jsonb_build_object('mode', v_mode, 'require_line', v_line));
  end if;
  return jsonb_build_object('ok', true, 'mode', public.recruit_mode(), 'require_line', coalesce(public.setting('recruit_require_line'), 'false') = 'true', 'require_line_effective', public.recruit_need_line(),
    'line_ready', nullif(btrim(coalesce(public.setting('line_basic_id'), '')), '') is not null and coalesce(public.setting('line_enabled'), 'true') = 'true',
    'mail_ready', nullif(btrim(coalesce(public.setting('mail_webapp_url'), '')), '') is not null and nullif(btrim(coalesce(public.setting('mail_key'), '')), '') is not null,
    'recruiting', (select count(*) from public.events where recruiting and archived_at is null and coalesce(end_date, start_date) >= (now() at time zone 'Asia/Taipei')::date - 1),
    'linked', (select count(*) from public.people where line_user_id is not null and disabled_at is null),
    'with_email', (select count(*) from public.people where coalesce(btrim(email), '') <> '' and disabled_at is null),
    'people', (select count(*) from public.people where disabled_at is null),
    'mail_today', (select count(*) from public.notifications where channel = 'mail' and status = 'sent' and sent_at > now() - interval '24 hours'),
    'mail_pending', (select count(*) from public.notifications where channel = 'mail' and status = 'pending'));
end $function$
;

CREATE OR REPLACE FUNCTION public.mail_flush()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 錄取通知 Email：經 w63068925 的 Apps Script 寄出。Gmail 一天約 100 封；錄取信最多用到 75 封（含建檔驗證信），其餘留給建檔驗證信，超過的隔天再寄
-- 只送 HMAC 簽章，不送密鑰（pg_net 佇列表 PUBLIC 可讀）。簽章：notify|sha256(to)|sha256(subject)|sha256(text)|nonce|ts，各欄位定長或不含分隔符，不能重新切割
-- 送出後先標「sending」，下一輪看 Apps Script 的回應（ok／dup 才算寄出；quota 三小時後重試；其他錯誤重試，滿 3 次轉失敗）
declare v_url text := nullif(btrim(coalesce(public.setting('mail_webapp_url'), '')), ''); v_key text := nullif(btrim(coalesce(public.setting('mail_key'), '')), '');
  v_site text := coalesce(public.setting('site_url'), ''); v_room int; r record; v_lines text; v_text text; v_subject text; v_ts bigint; v_sent int := 0;
  v_req bigint; v_nonce text; v_res text;
begin
  if not pg_try_advisory_xact_lock(hashtext('mail_quota')) then return 0; end if;
  for r in select n.id, n.attempts, n.claimed_at, h.status_code, btrim(coalesce(h.content, '')) as content, h.timed_out, h.error_msg, (h.id is not null) as answered
           from public.notifications n left join net._http_response h on h.id = n.mail_req
           where n.channel = 'mail' and n.status = 'sending' for update of n skip locked loop
    if r.answered and r.status_code = 200 and r.content in ('ok', 'dup') then
      update public.notifications set status = 'sent', sent_at = now(), error = null, claimed_at = null where id = r.id;
    elsif r.answered and r.content = 'quota' then
      update public.notifications set status = 'pending', send_after = now() + interval '3 hours', error = 'quota', claimed_at = null where id = r.id;
    elsif r.answered or r.claimed_at < now() - interval '30 minutes' then
      v_res := left(coalesce(nullif(r.content, ''), r.error_msg, case when r.timed_out then 'timeout' end, 'no_response'), 60);
      update public.notifications set status = case when r.attempts >= 3 then 'failed' else 'pending' end, send_after = now() + interval '15 minutes',
        error = v_res, claimed_at = null where id = r.id;
    end if;
  end loop;
  update public.notifications set status = 'skipped', error = 'expired' where channel = 'mail' and status = 'pending' and created_at < now() - interval '7 days';
  if v_url is null or v_key is null then return 0; end if;
  v_room := 75 - (select count(*) from public.notifications where channel = 'mail' and (status = 'sending' or (status = 'sent' and sent_at > now() - interval '24 hours')))::int
               - (select count(*) from public.signup_verifications where created_at > now() - interval '24 hours')::int;
  if v_room <= 0 then return 0; end if;
  for r in select n.id, n.kind, n.person_id, n.event_id, n.attempts, regexp_replace(coalesce(p.name, ''), '[[:cntrl:]]', ' ', 'g') as name,
             lower(btrim(p.email)) as email, regexp_replace(coalesce(e.name, '活動'), '[[:cntrl:]]', ' ', 'g') as event_name
           from public.notifications n join public.people p on p.id = n.person_id left join public.events e on e.id = n.event_id
           where n.channel = 'mail' and n.status = 'pending' and n.send_after <= now() order by n.created_at limit least(v_room, 20) for update of n skip locked loop
    if r.email is null or length(r.email) > 120 or r.email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then
      update public.notifications set status = 'skipped', error = 'no_email' where id = r.id; continue;
    end if;
    if r.kind <> 'accepted' then update public.notifications set status = 'skipped', error = 'unsupported' where id = r.id; continue; end if;
    select string_agg(to_char(sh.work_date, 'MM/DD') || '（' || (array['日','一','二','三','四','五','六'])[extract(dow from sh.work_date)::int + 1] || '）'
        || to_char(sh.start_time, 'HH24:MI') || '–' || to_char(sh.end_time, 'HH24:MI') || coalesce('　' || regexp_replace(sh.role, '[[:cntrl:]]', ' ', 'g'), ''), E'\n' order by sh.work_date, sh.start_time)
    into v_lines
    from public.application_shifts x join public.applications a on a.id = x.application_id join public.shifts sh on sh.id = x.shift_id
    where a.person_id = r.person_id and a.event_id = r.event_id and a.status = 'active' and x.status = 'accepted';
    if v_lines is null then update public.notifications set status = 'skipped', error = 'no_longer_accepted' where id = r.id; continue; end if;
    v_subject := left('【沃克思】錄取通知：' || r.event_name, 110);
    v_text := r.name || ' 你好：' || E'\n\n' || '你已錄取「' || r.event_name || '」，上班時間：' || E'\n' || v_lines || E'\n\n'
      || case when exists (select 1 from public.applications ca where ca.person_id = r.person_id and ca.event_id = r.event_id and ca.contract_accepted_at is not null) then '勞動契約已確認，可登入查看：' else '請登入確認勞動契約，確認後才算完成排班：' end || E'\n' || v_site || E'\n\n' || '沃克思 WORKS';
    v_ts := floor(extract(epoch from now()))::bigint;
    v_nonce := r.id::text || ':' || (r.attempts + 1);
    v_req := net.http_post(url := v_url, body := jsonb_build_object('type', 'notify', 'to', r.email, 'subject', v_subject, 'text', v_text, 'nonce', v_nonce, 'ts', v_ts,
        'sig', encode(extensions.hmac('notify|' || encode(extensions.digest(r.email, 'sha256'), 'hex') || '|' || encode(extensions.digest(v_subject, 'sha256'), 'hex')
          || '|' || encode(extensions.digest(v_text, 'sha256'), 'hex') || '|' || v_nonce || '|' || v_ts, v_key, 'sha256'), 'hex')),
      headers := '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds := 15000);
    update public.notifications set status = 'sending', claimed_at = now(), mail_req = v_req, body = v_text, attempts = attempts + 1, error = null where id = r.id;
    v_sent := v_sent + 1;
  end loop;
  return v_sent;
end $function$
;

CREATE OR REPLACE FUNCTION public.trg_shift_deleted_plans()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  update public.recruit_plans set disabled_at = now() where old.id = any(shift_ids) and disabled_at is null;
  return old;
end $function$
;
-- 報名方式（2026-11-27）：recruit_plans 表、applications.plan_id、notifications.channel、shifts 刪除觸發 shifts_deleted_plans
revoke all on function public.trg_shift_deleted_plans() from public, anon, authenticated;
revoke all on function public.recruit_mode() from public, anon, authenticated;
revoke all on function public.recruit_need_line() from public, anon, authenticated;
revoke all on function public.join_target(text) from public, anon, authenticated;
revoke all on function public.plan_json(public.recruit_plans) from public, anon, authenticated;
revoke all on function public.recruit_view(uuid, uuid) from public, anon, authenticated;
revoke all on function public.mail_flush() from public, anon, authenticated;
grant execute on function public.admin_save_plan(text, uuid, jsonb) to anon, authenticated, service_role;
grant execute on function public.admin_decide_plan(text, uuid[], text) to anon, authenticated, service_role;
grant execute on function public.admin_assign(text, uuid, uuid[], boolean) to anon, authenticated, service_role;
grant execute on function public.admin_recruit_settings(text, jsonb) to anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.payroll_nda_text()
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select '本人因參與本活動而知悉的未公開資訊，包括合作品牌資訊、活動流程、後台影像、工作群組資料及他人個資，僅限工作使用。未經沃克思國際有限公司同意，不得擅自拍攝、截圖、直播、轉傳或公開。活動結束後，仍須對未公開資訊保密。'
    || E'\n\n' || '若本人因故意或過失違反本條款，造成沃克思國際有限公司或合作品牌方可證明的損失，應依法負賠償責任。公司不得預扣工資作為賠償。本條款不影響本人依法申訴、檢舉或行使勞動權益。'
$function$
;

CREATE OR REPLACE FUNCTION public.payroll_contract_preview(p_token text, p_join text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 報名頁用：依勾選的班次或方案產生勞動契約內容（本人才能看，含本人姓名與遮蔽身分證），以及活動保密條款
declare v_pid uuid := public.payroll_session_person(p_token); e public.events; t record; v_view jsonb; v_kind text; v_ids uuid[]; v_plan uuid; v_text text;
begin
  if v_pid is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into t from public.join_target(p_join);
  select * into e from public.events where id = t.event_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'bad_join'); end if;
  v_view := public.recruit_view(e.id, t.plan_id); v_kind := v_view->>'kind';
  if v_kind = 'pick' then
    begin
      select coalesce(array_agg(x::uuid), '{}') into v_ids from jsonb_array_elements_text(coalesce(p_data->'shift_ids', '[]'::jsonb)) x;
    exception when others then return jsonb_build_object('ok', false, 'error', 'bad_shift'); end;
  elsif v_kind in ('plan', 'plans') then
    begin v_plan := nullif(p_data->>'plan_id', '')::uuid; exception when others then return jsonb_build_object('ok', false, 'error', 'bad_plan'); end;
    if v_plan is not null and exists (select 1 from jsonb_array_elements(v_view->'plans') x where (x->>'id')::uuid = v_plan) then
      select shift_ids into v_ids from public.recruit_plans where id = v_plan;
    end if;
  end if;
  if v_ids is not null and cardinality(v_ids) > 0 then
    v_text := public.payroll_contract_text_for(e.id, v_pid, array(select s.id from public.shifts s where s.id = any(v_ids) and s.event_id = e.id));
  end if;
  return jsonb_build_object('ok', true, 'mode', v_kind, 'text', v_text, 'hash', case when v_text is not null then md5(v_text) end,
    'nda_text', public.payroll_nda_text(), 'nda_hash', md5(public.payroll_nda_text()));
end $function$
;
-- 報名時同意契約與保密條款（2026-11-28）：applications 新增 apply_contract_text／apply_contract_hash／apply_contract_at／nda_accepted_at／nda_hash
revoke all on function public.payroll_contract_text_for(uuid, uuid, uuid[]) from public, anon, authenticated;
revoke all on function public.payroll_nda_text() from public;
grant execute on function public.payroll_nda_text() to anon, authenticated, service_role;
revoke all on function public.payroll_contract_preview(text, text, jsonb) from public;
grant execute on function public.payroll_contract_preview(text, text, jsonb) to anon, authenticated, service_role;
