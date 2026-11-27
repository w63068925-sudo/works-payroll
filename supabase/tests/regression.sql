-- 安全與商業邏輯回歸測試。整段在單一交易內執行，最後一定以例外結束，所有資料都會回滾。
-- 執行：把整份貼進 Supabase SQL Editor（或 execute_sql）。結果訊息以 PASS 或 FAIL 開頭。
-- 限制：單一交易無法測併發（雙連線競態），那部分靠鎖定順序的程式審查。
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  emp uuid; ev uuid; ev2 uuid; ev3 uuid; s1 uuid; s2 uuid; s3 uuid; s_other uuid;
  p1 uuid; p2 uuid; tok1 text := encode(extensions.gen_random_bytes(16), 'hex'); tok2 text := encode(extensions.gen_random_bytes(16), 'hex');
  atok text := encode(extensions.gen_random_bytes(16), 'hex'); ev4 uuid; ev5 uuid; att uuid; a1 uuid; a2 uuid; r jsonb; r2 jsonb; c jsonb; v_code text; v_slip uuid; i int; n int; txt text; nid uuid;
  p3 uuid; tok3 text := encode(extensions.gen_random_bytes(16), 'hex'); sl uuid; base jsonb;
  fails text := '';
begin
  -- 測試用：報名時一併同意保密條款與當下的勞動契約（第 40 組另外測不同意的情況）
  create function pg_temp.tapply(t text, j text, d jsonb) returns jsonb language sql as $f$
    select public.payroll_apply(t, j, d || jsonb_build_object('nda', true, 'contract_hash', public.payroll_contract_preview(t, j, d)->>'hash')) $f$;
  -- 測試以預設報名方式（自選、不須綁 LINE）進行，不受正式設定影響（整段會回滾）
  update public.app_settings set value = 'pick' where key = 'recruit_mode';
  update public.app_settings set value = 'false' where key = 'recruit_require_line';
  -- 隔離既有佇列，避免影響通知測試
  update public.notifications set send_after = now() + interval '1 year' where status = 'pending';
  select id into emp from public.employers order by created_at limit 1;
  insert into public.people(national_id, name, birth_date, password_hash, profile_source) values ('Z999990001', '測試甲', '2000-01-01', extensions.crypt('0890101', extensions.gen_salt('bf', 4)), 'test') returning id into p1;
  insert into public.people(national_id, name, birth_date, password_hash, profile_source) values ('Z999990002', '測試乙', '2000-01-01', extensions.crypt('0890101', extensions.gen_salt('bf', 4)), 'test') returning id into p2;
  insert into public.sessions(token_hash, person_id, expires_at) values (encode(extensions.digest(tok1, 'sha256'), 'hex'), p1, now() + interval '1 hour'), (encode(extensions.digest(tok2, 'sha256'), 'hex'), p2, now() + interval '1 hour');
  insert into public.admins(username, password_hash) values ('regression-admin', 'x');
  insert into public.admin_sessions(token_hash, admin_id, expires_at) select encode(extensions.digest(atok, 'sha256'), 'hex'), id, now() + interval '1 hour' from public.admins where username = 'regression-admin';

  -- 1. 登入失敗不洩漏帳號是否存在
  r := public.payroll_login('Z999990001', 'wrong'); r2 := public.payroll_login('Z999990099', 'wrong');
  if r <> r2 then fails := fails || ' [1 login responses differ]'; end if;
  -- 已鎖定的帳號也回同樣的失敗（不透露帳號存在或被鎖），鎖定中輸入正確也不能登入
  update public.people set locked_until = now() + interval '5 minutes' where id = p1;
  if public.payroll_login('Z999990001', 'wrong') <> r2 or public.payroll_login('Z999990001', '0890101') <> r2 then fails := fails || ' [1b locked response differs]'; end if;
  update public.people set locked_until = null, failed_logins = 0 where id = p1;

  -- 2. LINE 綁定碼：一次性、錯 5 次暫停
  update public.app_settings set value = '@regress' where key = 'line_basic_id';
  v_code := public.payroll_line_code(tok1)->>'code';
  if (public.line_bind(v_code, 'Uregress1')->>'ok')::boolean is not true then fails := fails || ' [2a bind failed]'; end if;
  if (public.line_bind(v_code, 'Uregress2')->>'ok')::boolean then fails := fails || ' [2b code reusable]'; end if;
  for i in 1..5 loop perform public.line_bind('000000', 'Uattacker'); end loop;
  v_code := public.payroll_line_code(tok2)->>'code';
  if public.line_bind(v_code, 'Uattacker')->>'error' is distinct from 'too_many' then fails := fails || ' [2c no rate limit]'; end if;
  perform public.payroll_line_unlink(tok2);
  if exists (select 1 from public.line_link_codes where person_id = p2) then fails := fails || ' [2d unlink kept code]'; end if;

  -- 3. 設定碼只能用一次
  insert into public.admin_setup_codes(code_hash, expires_at) values (encode(extensions.digest('regress-code', 'sha256'), 'hex'), now() + interval '1 hour');
  if (public.admin_setup('regress-code', 'regress-a', '0123456789ab')->>'ok')::boolean is not true then fails := fails || ' [3a setup failed]'; end if;
  if (public.admin_setup('regress-code', 'regress-b', '0123456789ab')->>'ok')::boolean then fails := fails || ' [3b setup code reusable]'; end if;

  -- 4. cron token 不接受空字串
  if public.line_cron_ok('') then fails := fails || ' [4 empty cron token accepted]'; end if;

  -- 準備活動與班次：今天 PT（無班次時薪，用活動預設 200）、今天 PG 250、明天 PG 250
  insert into public.events(employer_id, name, start_date, end_date, default_hourly_rate, location, pay_date) values (emp, '回歸測試', v_today, v_today + 1, 200, '甲地', v_today + 20) returning id into ev;
  insert into public.events(employer_id, name, start_date, end_date) values (emp, '回歸測試二', v_today, v_today) returning id into ev2;
  insert into public.events(employer_id, name, start_date, end_date) values (emp, '回歸測試三', v_today - 3, v_today - 1) returning id into ev3;
  insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount, rate) values (ev, v_today, '10:00', '18:30', 'PT', 1, null) returning id into s1;
  insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount, rate) values (ev, v_today, '12:00', '20:00', 'PG', 1, 250) returning id into s2;
  insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount, rate) values (ev, v_today + 1, '10:00', '18:30', 'PG', 1, 250) returning id into s3;
  update public.events set signup_code = 'regress-join-1' where id = ev;
  update public.events set signup_code = 'regress-join-2', recruiting = true where id = ev2;

  -- 15. 沒上傳身分證正反面與存摺不能報名；補齊後可以
  r := pg_temp.tapply(tok1, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1)));
  if r->>'error' is distinct from 'missing_docs' or jsonb_array_length(r->'missing') <> 3 then fails := fails || ' [15a apply without documents: ' || r::text || ']'; end if;
  insert into public.people_documents(person_id, kind, path) values (p1, 'id_front', p1 || '/id_front-x.jpg'), (p1, 'id_back', p1 || '/id_back-x.jpg');
  r := pg_temp.tapply(tok1, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1)));
  if r->>'error' is distinct from 'missing_docs' or r->'missing' <> '["bankbook"]'::jsonb then fails := fails || ' [15b partial documents: ' || r::text || ']'; end if;
  insert into public.people_documents(person_id, kind, path) values (p1, 'bankbook', p1 || '/bankbook-x.jpg'),
    (p2, 'id_front', p2 || '/id_front-x.jpg'), (p2, 'id_back', p2 || '/id_back-x.jpg'), (p2, 'bankbook', p2 || '/bankbook-x.jpg');

  -- 5. 報名不能夾帶別場活動的班次（即使該場沒有班次）
  insert into public.shifts(event_id, work_date, start_time, end_time, headcount) values (ev, v_today, '21:00', '22:00', 1) returning id into s_other;
  if pg_temp.tapply(tok1, 'regress-join-2', jsonb_build_object('shift_ids', jsonb_build_array(s_other)))->>'error' is distinct from 'bad_shift' then fails := fails || ' [5 cross-event shift accepted]'; end if;

  perform pg_temp.tapply(tok1, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1, s2, s3)));
  perform pg_temp.tapply(tok2, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1)));
  select id into a1 from public.applications where event_id = ev and person_id = p1;
  select id into a2 from public.applications where event_id = ev and person_id = p2;
  if a1 is null or a2 is null then fails := fails || ' [15c apply with documents failed]'; end if;

  -- 6. 未錄取的人不能簽到；活動結束隔天不能簽到
  insert into public.checkin_tickets(ticket_hash, event_id, expires_at) values (encode(extensions.digest('regress-ticket', 'sha256'), 'hex'), ev, now() + interval '10 minutes');
  if public.payroll_clock(tok2, 'regress-ticket', 'in')->>'error' is distinct from 'not_scheduled' then fails := fails || ' [6a unscheduled check-in allowed]'; end if;
  if public.payroll_clock(tok2, 'regress-ticket', 'status')->>'block' is distinct from 'not_scheduled' then fails := fails || ' [6b status does not warn]'; end if;
  insert into public.checkin_tickets(ticket_hash, event_id, expires_at) values (encode(extensions.digest('regress-ticket-3', 'sha256'), 'hex'), ev3, now() + interval '10 minutes');
  if public.payroll_clock(tok1, 'regress-ticket-3', 'in')->>'error' is distinct from 'not_event_day' then fails := fails || ' [6c check-in after event end allowed]'; end if;

  -- 7. 名額與時段重疊
  perform public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a1, 'shift', s1)), 'accepted');
  r := public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a2, 'shift', s1)), 'accepted');
  if jsonb_array_length(r->'full') <> 1 then fails := fails || ' [7a capacity not enforced]'; end if;
  r := public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a1, 'shift', s2)), 'accepted');
  if jsonb_array_length(r->'clash') <> 1 then fails := fails || ' [7b overlap not blocked]'; end if;
  perform public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a1, 'shift', s3)), 'accepted');
  if (select rate from public.event_staff where event_id = ev and person_id = p1) is not null then fails := fails || ' [7c shift rate copied to staff]'; end if;

  -- 8. 修改已錄取班次的時間不可造成重疊
  r := public.admin_save_shifts(atok, ev, s3, jsonb_build_object('work_date', v_today, 'start', '11:00', 'end', '15:00', 'headcount', 1, 'rate', 250));
  if r->>'error' is distinct from 'overlap' then fails := fails || ' [8 edit overlap allowed]'; end if;

  -- 9. 契約：版本比對、重送冪等、只有內容改變才失效、歷史保留
  c := public.payroll_contract(tok1, a1);
  if public.payroll_accept_contract(tok1, a1, 'stale')->>'error' is distinct from 'changed' then fails := fails || ' [9a stale contract accepted]'; end if;
  if (public.payroll_accept_contract(tok1, a1, c->>'hash')->>'ok')::boolean is not true then fails := fails || ' [9b accept failed]'; end if;
  if (public.payroll_accept_contract(tok1, a1, c->>'hash')->>'already')::boolean is not true then fails := fails || ' [9c resend not idempotent]'; end if;
  perform public.admin_save_shifts(atok, ev, s3, jsonb_build_object('work_date', v_today + 1, 'start', '10:00', 'end', '18:30', 'role', 'PG', 'headcount', 2, 'rate', 250, 'note', '新備註'));
  if (select contract_accepted_at from public.applications where id = a1) is null then fails := fails || ' [9d note/headcount edit voided contract]'; end if;
  update public.events set pay_within_days = 15 where id = ev;
  if (select contract_accepted_at from public.applications where id = a1) is null then fails := fails || ' [9e irrelevant field voided contract]'; end if;
  update public.events set location = '乙地' where id = ev;
  if (select contract_accepted_at from public.applications where id = a1) is not null then fails := fails || ' [9f location change kept contract]'; end if;
  if (select count(*) from public.contract_history where application_id = a1 and superseded_at is not null) <> 1 then fails := fails || ' [9g history not kept]'; end if;

  -- 10. 計薪：今天沒有班次時薪 → 活動預設 200；明天班次 250；人員設定 220 會蓋過活動預設但不蓋過班次
  --     休息 30 分不計入工時但照常給薪：另列 paid_break（200×0.5＋250×0.5＝225），不推高加班
  insert into public.attendance(person_id, event_id, work_date, clock_in, clock_out, break_minutes, source) values
    (p1, ev, v_today, (v_today + time '10:00') at time zone 'Asia/Taipei', (v_today + time '18:30') at time zone 'Asia/Taipei', 30, 'manual'),
    (p1, ev, v_today + 1, (v_today + 1 + time '10:00') at time zone 'Asia/Taipei', (v_today + 1 + time '18:30') at time zone 'Asia/Taipei', 30, 'manual');
  c := public.payroll_compute(ev, p1);
  if (c->>'gross')::numeric <> 3825 then fails := fails || ' [10a per-day rates gross=' || (c->>'gross') || ' expected 3825]'; end if;
  if (select sum((it->>'amount')::numeric) from jsonb_array_elements(c->'items') it where it->>'code' = 'paid_break') is distinct from 225
     or exists (select 1 from jsonb_array_elements(c->'items') it where it->>'code' like 'ot_%') then fails := fails || ' [10c paid break ' || (c->'items')::text || ']'; end if;
  update public.event_staff set rate = 220 where event_id = ev and person_id = p1;
  c := public.payroll_compute(ev, p1);
  if (c->>'gross')::numeric <> 3995 then fails := fails || ' [10b staff override gross=' || (c->>'gross') || ' expected 3995]'; end if;

  -- 11. 發布：薪資單本身、或本人在這場活動的「須處理」問題都要擋
  insert into public.payslips(person_id, event_id, gross, net, deductions, status, pay_date) values (p1, ev, 100, 100, 0, 'draft', v_today + 20) returning id into v_slip;
  insert into public.data_issues(event_id, payslip_id, person_id, severity, code, detail) values (ev, v_slip, p1, 'error', 'below_min_wage', 'x');
  r := public.admin_set_status(atok, array[v_slip], 'published');
  if (r->>'updated')::int <> 0 or (r->>'blocked_errors')::int <> 1 then fails := fails || ' [11a slip-level gate]'; end if;
  update public.data_issues set resolved = true where payslip_id = v_slip;
  insert into public.data_issues(event_id, person_id, severity, code, detail) values (ev, p1, 'error', 'minor', '未滿 18 歲');
  r := public.admin_set_status(atok, array[v_slip], 'published');
  if (r->>'updated')::int <> 0 then fails := fails || ' [11b person-level gate]'; end if;
  update public.data_issues set resolved = true where person_id = p1 and code = 'minor';

  -- 12. 通知：指定的薪資單通知只被領取一次、不含金額；只計實際發送；卡住超過 3 次轉失敗
  perform public.admin_set_status(atok, array[v_slip], 'published');
  select id into nid from public.notifications where kind = 'payslip' and ref_id = v_slip;
  if nid is null then fails := fails || ' [12a no payslip notification]'; end if;
  update public.notifications set send_after = now() where person_id = p1 and status = 'pending';
  r := public.notify_batch(50); r2 := public.notify_batch(50);
  if not exists (select 1 from jsonb_array_elements(r) x where (x->>'id')::uuid = nid) then fails := fails || ' [12b payslip notification not claimed]'; end if;
  if exists (select 1 from jsonb_array_elements(r2) x where (x->>'id')::uuid = nid) then fails := fails || ' [12c double claim]'; end if;
  select x->>'text' into txt from jsonb_array_elements(r) x where (x->>'id')::uuid = nid;
  if txt like '%實發%' or txt like '%NT$%' or txt like '%100%' then fails := fails || ' [12d amount in LINE message]'; end if;
  perform public.notify_mark(jsonb_build_array(jsonb_build_object('id', nid, 'claim', (select x->>'claim' from jsonb_array_elements(r) x where (x->>'id')::uuid = nid), 'status', 'release', 'error', 'deferred')));
  if (select status || ':' || attempts from public.notifications where id = nid) <> 'pending:0' then fails := fails || ' [12e release counted as attempt]'; end if;
  perform public.notify_mark(jsonb_build_array(jsonb_build_object('id', nid, 'claim', gen_random_uuid(), 'status', 'sent')));
  if (select status from public.notifications where id = nid) <> 'pending' then fails := fails || ' [12f stale claim overwrote]'; end if;
  update public.notifications set status = 'sending', claimed_at = now() - interval '1 hour', attempts = 3, send_after = now() where id = nid;
  perform public.notify_batch(50);
  if (select status from public.notifications where id = nid) <> 'failed' then fails := fails || ' [12g stuck notification not failed]'; end if;

  -- 13. 匯款清單：沒有帳號的人被擋下
  r := public.admin_payout(atok, ev);
  if (select x->>'hold' from jsonb_array_elements(r->'rows') x where x->>'national_id' = 'Z999990001') is distinct from 'bad_account' then fails := fails || ' [13 payout hold missing]'; end if;

  -- 14. 管理員密碼至少 8 個字（設定碼、新增、重設、自己改）
  insert into public.admin_setup_codes(code_hash, expires_at) values (encode(extensions.digest('regress-code-8', 'sha256'), 'hex'), now() + interval '1 hour');
  if public.admin_setup('regress-code-8', 'regress-c', '1234567')->>'error' is distinct from 'too_short' then fails := fails || ' [14a setup 7 accepted]'; end if;
  if (public.admin_setup('regress-code-8', 'regress-c', '12345678')->>'ok')::boolean is not true then fails := fails || ' [14b setup 8 rejected]'; end if;
  if public.admin_create_admin(atok, 'regress-d', '1234567')->>'error' is distinct from 'too_short' then fails := fails || ' [14c create 7 accepted]'; end if;
  if (public.admin_create_admin(atok, 'regress-d', '12345678')->>'ok')::boolean is not true then fails := fails || ' [14d create 8 rejected]'; end if;
  if public.admin_reset_admin(atok, 'regress-d', '1234567')->>'error' is distinct from 'too_short' then fails := fails || ' [14e reset 7 accepted]'; end if;
  if (public.admin_reset_admin(atok, 'regress-d', '87654321')->>'ok')::boolean is not true then fails := fails || ' [14f reset 8 rejected]'; end if;
  update public.admins set password_hash = extensions.crypt('oldpass99', extensions.gen_salt('bf', 4)) where username = 'regression-admin';
  if public.admin_change_password(atok, 'oldpass99', '1234567')->>'error' is distinct from 'too_short' then fails := fails || ' [14g change 7 accepted]'; end if;
  if (public.admin_change_password(atok, 'oldpass99', '12345678')->>'ok')::boolean is not true then fails := fails || ' [14h change 8 rejected]'; end if;

  -- 16. 發薪方式：指定日期或活動後 N 天內，兩者互斥；日期不能早於活動結束
  r := public.admin_create_event(atok, jsonb_build_object('name', '發薪測試', 'start_date', '2026-12-01', 'end_date', '2026-12-03', 'pay_date', '2026-12-02'));
  if r->>'error' is distinct from 'pay_before_end' then fails := fails || ' [16a pay date before end accepted]'; end if;
  r := public.admin_create_event(atok, jsonb_build_object('name', '發薪測試', 'start_date', '2026-12-01', 'end_date', '2026-12-03', 'pay_date', '2026-12-20', 'pay_within_days', '30'));
  ev2 := (r->>'id')::uuid;
  if (select pay_date from public.events where id = ev2) <> '2026-12-20' or (select pay_within_days from public.events where id = ev2) is not null then fails := fails || ' [16b date mode]'; end if;
  insert into public.payslips(person_id, event_id, gross, net, deductions, status) values (p2, ev2, 100, 100, 0, 'draft');
  r := public.admin_update_event(atok, ev2, jsonb_build_object('pay_date', '', 'pay_within_days', '15', 'apply_to_payslips', true));
  if (select pay_date from public.payslips where event_id = ev2) <> '2026-12-18' or (select pay_date from public.events where id = ev2) is not null then fails := fails || ' [16c days mode]'; end if;
  r := public.admin_update_event(atok, ev2, jsonb_build_object('default_hourly_rate', '210'));
  if (select pay_within_days from public.events where id = ev2) <> 15 then fails := fails || ' [16d other fields changed pay mode]'; end if;
  r := public.admin_update_event(atok, ev2, jsonb_build_object('pay_within_days', '120'));
  if r->>'error' is distinct from 'bad_pay' then fails := fails || ' [16e days out of range accepted]'; end if;

  -- 17. 班表行事曆：只回傳區間內的活動與班次，需要登入，區間上限 62 天
  insert into public.shifts(event_id, work_date, start_time, end_time, headcount) values (ev2, '2026-12-02', '09:00', '17:00', 3);
  r := public.admin_calendar(atok, '2026-11-29', '2027-01-02');
  if not exists (select 1 from jsonb_array_elements(r->'events') x where (x->>'id')::uuid = ev2) then fails := fails || ' [17a event missing]'; end if;
  if not exists (select 1 from jsonb_array_elements(r->'shifts') x where (x->>'event_id')::uuid = ev2 and x->>'work_date' = '2026-12-02' and x ? 'names') then fails := fails || ' [17b shift missing]'; end if;
  r := public.admin_calendar(atok, '2027-02-01', '2027-02-28');
  if exists (select 1 from jsonb_array_elements(r->'shifts') x where (x->>'event_id')::uuid = ev2) then fails := fails || ' [17c out of range shift]'; end if;
  if public.admin_calendar('bad-token', '2026-12-01', '2026-12-31')->>'error' is distinct from 'session' then fails := fails || ' [17d no session]'; end if;
  if public.admin_calendar(atok, '2026-01-01', '2026-12-31')->>'error' is distinct from 'bad_range' then fails := fails || ' [17e range too long]'; end if;

  -- 18. 加保名冊：只限管理員、依狀態與日期篩選、身分證字號檢查；匯出一定留紀錄
  r := public.admin_roster(atok, jsonb_build_object('event_id', ev, 'statuses', jsonb_build_array('accepted')));
  if (select count(*) from jsonb_array_elements(r->'rows') x where (x->>'person_id')::uuid = p1) <> 2 then fails := fails || ' [18a accepted days for p1: ' || coalesce(r->>'total', 'null') || ']'; end if;
  if exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'person_id')::uuid = p2) then fails := fails || ' [18b non-accepted included]'; end if;
  r := public.admin_roster(atok, jsonb_build_object('event_id', ev, 'statuses', jsonb_build_array('accepted'), 'from', v_today + 1, 'to', v_today + 1));
  if (r->>'total')::int <> 1 then fails := fails || ' [18c date filter]'; end if;
  if (select (x->>'id_valid')::boolean from jsonb_array_elements(r->'rows') x limit 1) is not false then fails := fails || ' [18d test ID should be invalid]'; end if;
  if public.admin_roster('bad-token', '{}')->>'error' is distinct from 'session' then fails := fails || ' [18e no session]'; end if;
  if public.admin_roster(atok, '{"from":"not-a-date"}')->>'error' is distinct from 'bad_filter' then fails := fails || ' [18f bad filter]'; end if;
  if public.admin_log_export('bad-token', 'insurance_roster', 1, '{}')->>'error' is distinct from 'session' then fails := fails || ' [18g export log without session]'; end if;
  -- 分兩句：同一個運算式看不到函式內剛寫入的紀錄
  if (public.admin_log_export(atok, 'insurance_roster', 3, '{}')->>'ok')::boolean is not true then fails := fails || ' [18h export log failed]'; end if;
  if not exists (select 1 from public.audit_log where actor = 'regression-admin' and action = 'export_insurance_roster') then fails := fails || ' [18i export not logged]'; end if;

  -- 19. 簽到退提示：提早到從表定時間起算、遲到照實際分鐘、超過表定下班要主管核准才計薪
  -- 班次日期跟著「開始時間」走，半夜 00:00–00:15 或 23:30 後跑也不會跨日誤判
  insert into public.events(employer_id, name, start_date, end_date) values (emp, '提示測試早', v_today - 1, v_today + 1) returning id into ev4;
  insert into public.events(employer_id, name, start_date, end_date) values (emp, '提示測試遲', v_today - 1, v_today + 1) returning id into ev5;
  insert into public.shifts(event_id, work_date, start_time, end_time, headcount) values
    (ev4, ((now() at time zone 'Asia/Taipei') + interval '30 minutes')::date, ((now() at time zone 'Asia/Taipei') + interval '30 minutes')::time(0), ((now() at time zone 'Asia/Taipei') + interval '4 hours 30 minutes')::time(0), 2) returning id into s1;
  insert into public.applications(event_id, person_id, status) values (ev4, p1, 'active') returning id into a1;
  insert into public.application_shifts(application_id, shift_id, status) values (a1, s1, 'accepted');
  insert into public.shifts(event_id, work_date, start_time, end_time, headcount) values
    (ev5, ((now() at time zone 'Asia/Taipei') - interval '15 minutes')::date, ((now() at time zone 'Asia/Taipei') - interval '15 minutes')::time(0), ((now() at time zone 'Asia/Taipei') + interval '3 hours')::time(0), 2) returning id into s2;
  insert into public.applications(event_id, person_id, status) values (ev5, p2, 'active') returning id into a2;
  insert into public.application_shifts(application_id, shift_id, status) values (a2, s2, 'accepted');
  insert into public.checkin_tickets(ticket_hash, event_id, expires_at) values
    (encode(extensions.digest('regress-ticket-4', 'sha256'), 'hex'), ev4, now() + interval '10 minutes'), (encode(extensions.digest('regress-ticket-5', 'sha256'), 'hex'), ev5, now() + interval '10 minutes');
  r := public.payroll_clock(tok1, 'regress-ticket-4', 'in');
  if r->>'error' is distinct from 'need_ack' or r->'notice'->>'kind' is distinct from 'early' then fails := fails || ' [19a early not asked: ' || r::text || ']'; end if;
  if exists (select 1 from public.attendance where event_id = ev4) then fails := fails || ' [19b clocked in without ack]'; end if;
  r := public.payroll_clock(tok1, 'regress-ticket-4', 'in', true);
  select id into att from public.attendance where event_id = ev4 and person_id = p1;
  if att is null or (select in_notice from public.attendance where id = att) is distinct from 'early' or (select in_ack_at from public.attendance where id = att) is null then fails := fails || ' [19c early ack not recorded]'; end if;
  r := public.payroll_clock(tok2, 'regress-ticket-5', 'in');
  if r->>'error' is distinct from 'need_ack' or r->'notice'->>'kind' is distinct from 'late' or (r->'notice'->>'minutes')::int not between 14 and 16 then fails := fails || ' [19d late notice: ' || r::text || ']'; end if;
  -- 計薪工時：提早 30 分不計、超時 25 分待核准不計；核准後才計
  update public.attendance set clock_in = sched_in - interval '30 minutes', clock_out = sched_out + interval '25 minutes', break_minutes = 0, out_notice = 'overtime' where id = att;
  if (select public.att_minutes(a) from public.attendance a where id = att) <> 240 then fails := fails || ' [19e capped minutes ' || (select public.att_minutes(a) from public.attendance a where id = att) || ']'; end if;
  perform public.admin_approve_attendance(atok, att, 'early', true);
  perform public.admin_approve_attendance(atok, att, 'overtime', true);
  if (select public.att_minutes(a) from public.attendance a where id = att) <> 295 then fails := fails || ' [19f approved minutes]'; end if;
  perform public.admin_approve_attendance(atok, att, 'overtime', false);
  if (select public.att_minutes(a) from public.attendance a where id = att) <> 270 then fails := fails || ' [19g revoke overtime]'; end if;
  if public.admin_approve_attendance('bad-token', att, 'early', true)->>'error' is distinct from 'session' then fails := fails || ' [19h approve without session]'; end if;

  -- 20. 工讀生密碼至少 7 個字（與民國生日 7 碼一致）；管理員仍至少 8 個字
  if public.payroll_change_password(tok2, '0890101', '123456')->>'error' is distinct from 'too_short' then fails := fails || ' [20a worker 6 accepted]'; end if;
  if public.payroll_change_password(tok2, 'wrong00', '0730407')->>'error' is distinct from 'invalid' then fails := fails || ' [20d wrong old password accepted]'; end if;
  if (public.payroll_change_password(tok2, '0890101', '0730407')->>'ok')::boolean is not true then fails := fails || ' [20b worker 7 rejected]'; end if;
  if (public.payroll_login('Z999990002', '0730407')->>'ok')::boolean is not true then fails := fails || ' [20c login with new 7]'; end if;
  -- 改密碼時猜舊密碼也算錯誤次數：錯 10 次鎖定，鎖定中輸入正確也拒絕
  for i in 1..10 loop perform public.payroll_change_password(tok2, 'wrong00', '7654321'); end loop;
  if public.payroll_change_password(tok2, '0730407', '7654321')->>'error' is distinct from 'locked' then fails := fails || ' [20e change-password guessing not locked]'; end if;

  -- 21. 登入容忍全形字、小寫與空白；全形密碼猜錯只算一次
  update public.people set failed_logins = 0, locked_until = null where id = p1;
  if (public.payroll_login('Ｚ９９９９９０００１', '0890101')->>'ok')::boolean is not true then fails := fails || ' [21a fullwidth id]'; end if;
  if (public.payroll_login(' z999990001 ', '０８９０１０１')->>'ok')::boolean is not true then fails := fails || ' [21b lowercase id + fullwidth password]'; end if;
  perform public.payroll_login('Z999990001', '０８９０１０２');
  if (select failed_logins from public.people where id = p1) <> 1 then fails := fails || ' [21c wrong fullwidth counted twice]'; end if;

  -- 22. 登入錯 9 次不鎖、錯 10 次鎖 15 分鐘
  update public.people set failed_logins = 0, locked_until = null where id = p1;
  for i in 1..9 loop perform public.payroll_login('Z999990001', 'wrong'); end loop;
  if (select locked_until from public.people where id = p1) is not null then fails := fails || ' [22a locked after 9]'; end if;
  perform public.payroll_login('Z999990001', 'wrong');
  if (select locked_until from public.people where id = p1) is null then fails := fails || ' [22b not locked after 10]'; end if;

  -- 23. 缺生日的人自行開通：核對姓名＋帳號末 5 碼或手機；不符、查無此人、已有密碼回應相同；開通後不能再改生日
  insert into public.people(national_id, name, bank_account, phone, profile_source) values ('Z999990003', '黃測試', '00012345678901', '912345678', 'test') returning id into p3;
  base := public.payroll_claim('Z999990099', '黃測試', '78901', '2001-02-03', true);
  if base->>'error' is distinct from 'mismatch' then fails := fails || ' [23a]'; end if;
  if public.payroll_claim('Z999990001', '測試甲', '78901', '2001-02-03', true) <> base then fails := fails || ' [23b has password differs]'; end if;
  if public.payroll_claim('Z999990003', '黃測試', '78900', '2001-02-03', true) <> base then fails := fails || ' [23c wrong proof differs]'; end if;
  if public.payroll_claim('Z999990003', '王測試', '78901', '2001-02-03', true) <> base then fails := fails || ' [23d wrong name differs]'; end if;
  r := public.payroll_claim('ｚ999990003', '黄 測試', '0912-345-678', '2001-02-03', true);
  if (r->>'ok')::boolean is not true then fails := fails || ' [23e claim ' || r::text || ']'; end if;
  if (public.payroll_login('Z999990003', '0900203')->>'ok')::boolean is not true then fails := fails || ' [23f login after claim]'; end if;
  if public.payroll_claim('Z999990003', '黃測試', '78901', '1999-01-01', true) <> base or (select birth_date from public.people where id = p3) <> '2001-02-03' then fails := fails || ' [23g reclaim]'; end if;
  update public.people set password_hash = null, failed_logins = 0 where id = p3;
  for i in 1..10 loop perform public.payroll_claim('Z999990003', '黃測試', '00000', '2001-02-03', true); end loop;
  if public.payroll_claim('Z999990003', '黃測試', '78901', '2001-02-03', true) <> base then fails := fails || ' [23h locked claim allowed]'; end if;

  -- 24. 缺證件或匯款資料時看不到薪資單；補齊後才看得到（舊表雲端連結的證件也算有）
  update public.people set locked_until = null, password_hash = 'x', bank_code = null, bank_account = null where id = p3;
  insert into public.sessions(token_hash, person_id, expires_at) values (encode(extensions.digest(tok3, 'sha256'), 'hex'), p3, now() + interval '1 hour');
  insert into public.payslips(person_id, event_id, gross, net, deductions, status) values (p3, ev, 100, 100, 0, 'published') returning id into sl;
  r := public.payroll_my_payslips(tok3);
  if r->'incomplete' = 'null'::jsonb or jsonb_array_length(r->'payslips') <> 0 or (r->'incomplete'->>'bank')::boolean is not true then fails := fails || ' [24a gate ' || r::text || ']'; end if;
  if public.payroll_payslip(tok3, sl)->>'error' is distinct from 'incomplete' then fails := fails || ' [24b slip gate]'; end if;
  update public.people set bank_code = '822', bank_account = '123456789012' where id = p3;
  insert into public.people_documents(person_id, kind, path, drive_file_id) values (p3, 'id_front', p3 || '/id_front-1.jpg', null), (p3, 'id_back', p3 || '/id_back-1.jpg', null), (p3, 'bankbook', null, 'DRIVEaaaaaaaaaaaaaaaaaaaaaa');
  r := public.payroll_my_payslips(tok3);
  if r->'incomplete' <> 'null'::jsonb or jsonb_array_length(r->'payslips') <> 1 then fails := fails || ' [24c complete ' || r::text || ']'; end if;
  if (public.payroll_payslip(tok3, sl)->>'ok')::boolean is not true then fails := fails || ' [24d slip]'; end if;

  -- 25. 活動人員資料下載：需要登入、活動要存在、一定留下含人員清單的紀錄
  if public.admin_event_people_export('bad-token', ev)->>'error' is distinct from 'session' then fails := fails || ' [25a no session]'; end if;
  if public.admin_event_people_export(atok, gen_random_uuid())->>'error' is distinct from 'not_found' then fails := fails || ' [25b unknown event]'; end if;
  r := public.admin_event_people_export(atok, ev);
  if not exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'person_id')::uuid = p1) then fails := fails || ' [25c accepted person missing]'; end if;
  if not exists (select 1 from public.audit_log where actor = 'regression-admin' and action = 'export_event_people' and row_id = ev and detail->'people' @> to_jsonb(array[p1::text])) then fails := fails || ' [25d export not audited]'; end if;

  -- 26. AI 匯入：要登入、預覽不寫入、寫入建活動／人員／出勤／薪資草稿、錯的列略過、同一份表不能重複匯入、既有人只補空白
  select x into txt from (select 'Y1' || lpad((floor(random() * 10000000))::int::text, 7, '0') b) q,
    lateral (select q.b || d::text x from generate_series(0, 9) d where public.valid_tw_id(q.b || d::text)) z limit 1;
  base := jsonb_build_object('v', 1, 'source', jsonb_build_object('file_id', 'regressionAiImportFile000001'),
    'event', jsonb_build_object('name', '回歸 AI 匯入', 'start_date', v_today + 30, 'end_date', v_today + 31, 'pay_date', v_today + 60),
    'shifts', jsonb_build_array(jsonb_build_object('work_date', v_today + 30, 'start_time', '10:00', 'end_time', '18:00', 'role', 'PG', 'headcount', 2, 'rate', 200)),
    'people', jsonb_build_array(
      jsonb_build_object('row', 2, 'national_id', txt, 'name', '匯入丙', 'birth_date', '2000-02-03', 'bank_code', '822 中信', 'bank_account', '1234-5678-9012', 'bank_account_name', '匯入丙',
        'role', 'PG', 'days', jsonb_build_array(jsonb_build_object('date', v_today + 30, 'amount', 1800), jsonb_build_object('date', v_today + 31, 'amount', 1800)), 'labor_ins', 20, 'net', 3580,
        'docs', jsonb_build_object('bankbook', 'regressionDriveDocument00001')),
      jsonb_build_object('row', 3, 'national_id', 'A12345', 'name', '壞資料')));
  if public.admin_ai_import('bad-token', base)->>'error' is distinct from 'session' then fails := fails || ' [26a no session]'; end if;
  r := public.admin_ai_import(atok, base);
  if not (r->>'preview')::boolean or r#>>'{people,0,status}' <> 'new' or r#>>'{people,1,status}' <> 'error'
     or exists (select 1 from public.people where national_id = txt) then fails := fails || ' [26b preview wrong or wrote]'; end if;
  r := public.admin_ai_import(atok, base, null, true);
  if (r->>'new_people')::int <> 1 or (r->>'payslips')::int <> 1 or (r->>'skipped')::int <> 1 or (r->>'shifts')::int <> 1 or (r->>'attendance')::int <> 2 then fails := fails || ' [26c commit counts ' || r::text || ']'; end if;
  nid := (r->>'event')::uuid;
  if not exists (select 1 from public.payslips where event_id = nid and gross = 3600 and deductions = 20 and net = 3580 and basis = 'daily_total' and status = 'draft' and not generated and pay_account = '123456789012' and pay_bank_code = '822')
    then fails := fails || ' [26d payslip wrong]'; end if;
  if (select count(*) from public.payslip_items i join public.payslips p on p.id = i.payslip_id where p.event_id = nid and i.code = 'daily_wage') <> 2 then fails := fails || ' [26e day items]'; end if;
  if not exists (select 1 from public.people_documents d join public.people p on p.id = d.person_id where p.national_id = txt and d.kind = 'bankbook' and d.drive_file_id = 'regressionDriveDocument00001')
    then fails := fails || ' [26f doc link]'; end if;
  if (select recruiting from public.events where id = nid) then fails := fails || ' [26g roster import opened recruiting]'; end if;
  if not exists (select 1 from public.audit_log where actor = 'regression-admin' and action = 'ai_import' and row_id = nid) then fails := fails || ' [26h not audited]'; end if;
  if public.admin_ai_import(atok, base, null, true)->>'error' is distinct from 'duplicate_source' then fails := fails || ' [26i duplicate import]'; end if;
  -- 加到既有活動：既有人只補空白、不重複建薪資單、不改姓名
  r := public.admin_ai_import(atok, jsonb_build_object('v', 1, 'people', jsonb_build_array(jsonb_build_object('national_id', txt, 'name', '匯入丙改', 'phone', '0912345678',
    'bank_account', '999', 'days', jsonb_build_array(jsonb_build_object('date', v_today + 30, 'amount', 1)) ))), nid, true);
  if (r->>'new_people')::int <> 0 or (r->>'payslips')::int <> 0 or (r->>'filled')::int <> 1 then fails := fails || ' [26j existing event counts ' || r::text || ']'; end if;
  if not exists (select 1 from public.people where national_id = txt and name = '匯入丙' and phone = '0912345678' and bank_account = '123456789012') then fails := fails || ' [26k overwrote person]'; end if;
  if not exists (select 1 from public.data_issues where event_id = nid and code = 'name_mismatch') then fails := fails || ' [26l name mismatch issue]'; end if;
  if (select count(*) from public.payslips where event_id = nid) <> 1 then fails := fails || ' [26m second payslip]'; end if;
  -- 只有活動與班別（沒有人員）：開放報名
  r := public.admin_ai_import(atok, jsonb_build_object('v', 1, 'event', jsonb_build_object('name', '回歸 AI 新活動', 'start_date', v_today + 40),
    'shifts', jsonb_build_array(jsonb_build_object('work_date', v_today + 40, 'start_time', '09:00', 'end_time', '17:00', 'headcount', 3),
                                jsonb_build_object('work_date', v_today + 50, 'start_time', '09:00', 'end_time', '17:00', 'headcount', 3))), null, true);
  if (r->>'shifts')::int <> 1 or not (select recruiting from public.events where id = (r->>'event')::uuid) then fails := fails || ' [26n event-only import ' || r::text || ']'; end if;

  -- 審查補強：型別錯誤、負實發、重複班別、全部人員有錯但班別可匯入
  if public.admin_ai_import(atok, '{"v":1,"people":{}}'::jsonb)->>'error' is distinct from 'bad_payload' then fails := fails || ' [26o bad payload type]'; end if;
  r := public.admin_ai_import(atok, jsonb_build_object('v', 1, 'people', jsonb_build_array(jsonb_build_object('national_id', txt, 'name', '匯入丙', 'labor_ins', 20,
    'days', jsonb_build_array(jsonb_build_object('date', v_today + 30, 'amount', 10))))), nid);
  if r#>>'{people,0,status}' <> 'error' then fails := fails || ' [26p negative net allowed]'; end if;
  r := public.admin_ai_import(atok, jsonb_build_object('v', 1, 'people', jsonb_build_array(jsonb_build_object('national_id', txt, 'name', '匯入丙', 'gross', 100, 'net', -1))), nid);
  if r#>>'{people,0,status}' <> 'error' then fails := fails || ' [26p2 negative sheet net allowed]'; end if;
  r := public.admin_ai_import(atok, jsonb_build_object('v', 1, 'shifts', base->'shifts'), nid, true);
  if (r->>'shifts')::int <> 0 then fails := fails || ' [26q duplicate shift added]'; end if;
  r := public.admin_ai_import(atok, jsonb_build_object('v', 1, 'event', jsonb_build_object('name', '回歸 AI 只有班別', 'start_date', v_today + 45),
    'shifts', jsonb_build_array(jsonb_build_object('work_date', v_today + 45, 'start_time', '09:00', 'end_time', '17:00', 'headcount', 1)),
    'people', jsonb_build_array(jsonb_build_object('national_id', 'bad', 'name', 'x'))), null, true);
  if not coalesce((r->>'ok')::boolean, false) or (r->>'shifts')::int <> 1 then fails := fails || ' [26r shifts dropped when all people invalid ' || r::text || ']'; end if;

  -- 27. 巡檢第一輪修正：同日兩場出勤警示、發布前標出看不到的人、LINE 補資料提醒（一天一次）、人員參加紀錄
  declare px uuid; e27 uuid; e28 uuid; dd date := v_today - 3;
  begin
    insert into public.people(national_id, name, profile_source, line_user_id) values ('Z999990077', '測試丁', 'test', 'Uregress27') returning id into px;
    insert into public.events(employer_id, name, start_date, end_date, default_hourly_rate, recruiting) values (emp, '回歸27甲', dd, dd, 200, false) returning id into e27;
    insert into public.events(employer_id, name, start_date, end_date, default_hourly_rate, recruiting) values (emp, '回歸27乙', dd, dd, 200, false) returning id into e28;
    insert into public.attendance(person_id, event_id, work_date, clock_in, clock_out, source) values
      (px, e27, dd, (dd + time '09:00') at time zone 'Asia/Taipei', (dd + time '13:00') at time zone 'Asia/Taipei', 'manual'),
      (px, e28, dd, (dd + time '14:00') at time zone 'Asia/Taipei', (dd + time '18:00') at time zone 'Asia/Taipei', 'manual');
    perform public.admin_generate_payslips(atok, e27);
    if not exists (select 1 from public.data_issues where event_id = e27 and person_id = px and code = 'same_day_other_event') then fails := fails || ' [27a same-day warning]'; end if;
    r := public.admin_event(atok, e27);
    if r#>>'{payslips,0,missing}' is null or (r#>>'{payslips,0,has_line}')::boolean is not true then fails := fails || ' [27b missing info]'; end if;
    r := public.admin_remind_incomplete(atok, e27);
    if (r->>'queued')::int <> 1 or (r->>'incomplete')::int <> 1 then fails := fails || ' [27c remind]'; end if;
    if (public.admin_remind_incomplete(atok, e27)->>'queued')::int <> 0 then fails := fails || ' [27d remind dedupe]'; end if;
    perform public.admin_generate_payslips(atok, e28);
    if (public.admin_remind_incomplete(atok, e28)->>'queued')::int <> 1 then fails := fails || ' [27d2 other event not queued]'; end if;
    if public.admin_remind_incomplete('bad-token', e27)->>'error' is distinct from 'session' then fails := fails || ' [27e no session]'; end if;
    if jsonb_array_length(public.admin_person(atok, px)#>'{person,history}') <> 2 then fails := fails || ' [27f history]'; end if;
  end;

  -- 28. 巡檢第二輪：缺資料名單帶電話、匯出種類 missing_docs、登入頁聯絡窗口
  declare e29 uuid;
  begin
    select event_id into e29 from public.payslips where person_id = (select id from public.people where national_id = 'Z999990077') limit 1;
    update public.people set phone = '0911000077' where national_id = 'Z999990077';
    if not exists (select 1 from jsonb_array_elements(public.admin_event(atok, e29)->'payslips') x where x->>'phone' = '0911000077') then fails := fails || ' [28a phone]'; end if;
    r := public.admin_roster(atok, jsonb_build_object('event_id', e29, 'statuses', jsonb_build_array('attended')));
    if (r->>'truncated')::boolean is not false or (r->>'total')::int <> jsonb_array_length(r->'rows') then fails := fails || ' [28j roster total ' || r::text || ']'; end if;
    if (public.admin_log_export(atok, 'missing_docs', 1, '{}'::jsonb)->>'ok')::boolean is not true then fails := fails || ' [28b missing_docs kind]'; end if;
    if public.admin_log_export(atok, 'whatever', 1, '{}'::jsonb)->>'error' is distinct from 'bad_kind' then fails := fails || ' [28c bad kind]'; end if;
    -- 分兩句：同一個運算式看不到函式內剛寫入的設定
    r := public.admin_update_employer(atok, jsonb_build_object('contact', '  LINE @回歸  '));
    if (r->>'ok')::boolean is not true or public.payroll_contact() is distinct from 'LINE @回歸' then fails := fails || ' [28d contact set]'; end if;
    if public.admin_overview(atok)#>>'{employer,contact}' is distinct from 'LINE @回歸' then fails := fails || ' [28e overview contact]'; end if;
    r := public.admin_update_employer(atok, jsonb_build_object('contact', repeat('x', 201), 'legal_name', '不該存進去'));
    if r->>'error' is distinct from 'contact_too_long' or public.payroll_contact() is distinct from 'LINE @回歸' or exists (select 1 from public.employers where legal_name = '不該存進去') then fails := fails || ' [28f contact too long]'; end if;
    if public.admin_update_employer('bad-token', jsonb_build_object('contact', 'x'))->>'error' is distinct from 'session' then fails := fails || ' [28g no session]'; end if;
    perform public.admin_update_employer(atok, jsonb_build_object('contact', ''));
    if public.payroll_contact() is not null then fails := fails || ' [28h contact cleared]'; end if;
    if not has_function_privilege('anon', 'public.payroll_contact()', 'execute') then fails := fails || ' [28i anon contact]'; end if;
  end;

  -- 29. AI 匯入預覽：同名（忽略空白、大小寫）且日期重疊的活動要列在 similar，日期不重疊不列
  declare e30 uuid; v jsonb;
  begin
    select id into e30 from public.events where source_key = 'g:regressionAiImportFile000001';
    v := jsonb_build_object('v', 1, 'event', jsonb_build_object('name', ' 回歸 ai 匯入 ', 'start_date', v_today + 31, 'end_date', v_today + 33), 'people', '[]'::jsonb);
    r := public.admin_ai_import(atok, v);
    if not exists (select 1 from jsonb_array_elements(r#>'{event,similar}') x where (x->>'id')::uuid = e30) then fails := fails || ' [29a similar missing ' || coalesce(r::text, '') || ']'; end if;
    r := public.admin_ai_import(atok, jsonb_set(v, '{event}', jsonb_build_object('name', '回歸 AI 匯入', 'start_date', v_today + 40)));
    if jsonb_array_length(r#>'{event,similar}') <> 0 then fails := fails || ' [29b non-overlap listed]'; end if;
    -- 寫入時伺服器也擋：沒帶 allow_similar 不能另建；帶了才建
    r := public.admin_ai_import(atok, v, null, true);
    if r->>'error' is distinct from 'similar_event' then fails := fails || ' [29c commit not blocked ' || coalesce(r::text, '') || ']'; end if;
    if (select count(*) from public.events where lower(regexp_replace(name, '\s', '', 'g')) = '回歸ai匯入') <> 1 then fails := fails || ' [29d blocked commit created event]'; end if;
    r := public.admin_ai_import(atok, v || '{"allow_similar": true}'::jsonb, null, true);
    if (r->>'ok')::boolean is not true then fails := fails || ' [29e allow_similar commit ' || coalesce(r::text, '') || ']'; end if;
    -- 既有活動沒有結束日：以開始日判斷重疊
    update public.events set end_date = null where id = e30;
    r := public.admin_ai_import(atok, jsonb_set(v, '{event}', jsonb_build_object('name', '回歸AI匯入', 'start_date', v_today + 30)));
    if not exists (select 1 from jsonb_array_elements(r#>'{event,similar}') x where (x->>'id')::uuid = e30) then fails := fails || ' [29f null end_date]'; end if;
  end;

  -- 30. 巡檢第三輪：活動總覽帶 recruiting（活動列表顯示「招募中」）
  if exists (select 1 from jsonb_array_elements(public.admin_overview(atok)->'events') x where not (x ? 'recruiting')) then fails := fails || ' [30a overview recruiting]'; end if;
  update public.events set recruiting = true where name = '回歸27甲';
  if not exists (select 1 from jsonb_array_elements(public.admin_overview(atok)->'events') x join public.events e on e.id = (x->>'id')::uuid where e.name = '回歸27甲' and x->'recruiting' = 'true'::jsonb) then fails := fails || ' [30b recruiting value]'; end if;

  -- 31. 人員清單：證件數只算三種證件（不含照片）、帶報名數（標「證件未齊」「未報名」）
  if exists (select 1 from jsonb_array_elements(public.admin_people(atok)->'people') x where not (x ? 'apps') or (x->>'docs')::int > 3) then fails := fails || ' [31a people docs/apps]'; end if;

  -- 32. 班次要落在活動日期內：超出就擋下並回活動日期
  declare e32 uuid; d32 date;
  begin
    select id, start_date into e32, d32 from public.events where name = '回歸27甲';
    r := public.admin_save_shifts(atok, e32, null, jsonb_build_object('work_date', d32 + 5, 'start', '10:00', 'end', '18:00', 'headcount', 1));
    if r->>'error' is distinct from 'outside_event' or (r->>'start_date')::date <> d32 then fails := fails || ' [32a outside shift ' || coalesce(r::text, '') || ']'; end if;
    r := public.admin_save_shifts(atok, e32, null, jsonb_build_object('work_date', d32, 'until_date', d32 + 1, 'start', '10:00', 'end', '18:00', 'headcount', 1));
    if r->>'error' is distinct from 'outside_event' then fails := fails || ' [32b range past end]'; end if;
    if (public.admin_save_shifts(atok, e32, null, jsonb_build_object('work_date', d32, 'start', '10:00', 'end', '18:00', 'headcount', 1))->>'ok')::boolean is not true then fails := fails || ' [32c inside shift]'; end if;
  end;

  -- 33. 打卡 QR 分享頁：要登入才能產生；連結只存雜湊；可取碼；重新產生舊的失效；停用後失效；封存不給；匿名不能直接讀表
  declare e33 uuid; s1 text; s2 text;
  begin
    select id into e33 from public.events where name = '回歸27甲';
    update public.events set end_date = current_date + 1 where id = e33;
    if public.admin_checkin_share('bad-token', e33, 'create')->>'error' is distinct from 'session' then fails := fails || ' [33a no session]'; end if;
    s1 := public.admin_checkin_share(atok, e33, 'create')->>'share';
    if s1 is null or exists (select 1 from public.checkin_shares where token_hash = s1) then fails := fails || ' [33b token stored raw]'; end if;
    r := public.payroll_share_checkin_code(s1);
    if (r->>'ok')::boolean is not true or (public.payroll_checkin_ticket(r->>'code')->>'ok')::boolean is not true then fails := fails || ' [33c code ' || coalesce(r::text, '') || ']'; end if;
    s2 := public.admin_checkin_share(atok, e33, 'create')->>'share';
    if public.payroll_share_checkin_code(s1)->>'error' is distinct from 'invalid' or (public.payroll_share_checkin_code(s2)->>'ok')::boolean is not true then fails := fails || ' [33d recreate]'; end if;
    if (public.admin_checkin_share(atok, e33, 'status')->>'active')::boolean is not true then fails := fails || ' [33e status]'; end if;
    perform public.admin_checkin_share(atok, e33, 'revoke');
    if public.payroll_share_checkin_code(s2)->>'error' is distinct from 'invalid' then fails := fails || ' [33f revoke]'; end if;
    s1 := public.admin_checkin_share(atok, e33, 'create')->>'share';
    -- 活動日期提前：舊連結跟著失效
    update public.events set start_date = current_date - 5, end_date = current_date - 5 where id = e33;
    if public.payroll_share_checkin_code(s1)->>'error' is distinct from 'expired' or (public.admin_checkin_share(atok, e33, 'status')->>'active')::boolean then fails := fails || ' [33k shortened dates]'; end if;
    update public.events set start_date = current_date, end_date = current_date + 1 where id = e33;
    -- 封存：連結停用，取消封存也不會復活
    perform public.admin_archive_event(atok, e33, true);
    if public.payroll_share_checkin_code(s1)->>'error' is distinct from 'invalid' or public.admin_checkin_share(atok, e33, 'create')->>'error' is distinct from 'archived' then fails := fails || ' [33g archived]'; end if;
    perform public.admin_archive_event(atok, e33, false);
    if public.payroll_share_checkin_code(s1)->>'error' is distinct from 'invalid' then fails := fails || ' [33l revived after unarchive]'; end if;
    update public.events set end_date = current_date - 5, start_date = current_date - 5 where id = e33;
    if public.admin_checkin_share(atok, e33, 'create')->>'error' is distinct from 'ended' then fails := fails || ' [33h ended]'; end if;
    if public.payroll_share_checkin_code('zz')->>'error' is distinct from 'invalid' then fails := fails || ' [33i bad format]'; end if;
    if has_table_privilege('anon', 'public.checkin_shares', 'select') then fails := fails || ' [33j anon table]'; end if;
    if has_function_privilege('anon', 'public.checkin_make_code(uuid,bigint)', 'execute') or has_function_privilege('authenticated', 'public.checkin_make_code(uuid,bigint)', 'execute') then fails := fails || ' [33m make_code exposed]'; end if;
  end;

  -- 34. 新人自行建檔：Email 驗證碼 → 建檔票 → 建檔（票只能用一次、身分證要一致、已存在不能建、次數上限）
  declare n34 text; n34b text; tk text; vid uuid; k int;
  begin
    select x into n34 from (select 'Y2' || lpad((floor(random() * 10000000))::int::text, 7, '0') b) q,
      lateral (select q.b || d::text x from generate_series(0, 9) d where public.valid_tw_id(q.b || d::text)) z limit 1;
    select x into n34b from (select 'Y2' || lpad((floor(random() * 10000000))::int::text, 7, '0') b) q,
      lateral (select q.b || d::text x from generate_series(0, 9) d where public.valid_tw_id(q.b || d::text) and q.b || d::text <> n34) z limit 1;
    update public.app_settings set value = null where key = 'mail_webapp_url';
    if public.payroll_signup_start(n34, 'reg34@example.com')->>'error' is distinct from 'mail_unavailable' then fails := fails || ' [34a mail unavailable]'; end if;
    update public.app_settings set value = 'https://example.invalid/exec' where key = 'mail_webapp_url';
    update public.app_settings set value = 'regression-mail-key' where key = 'mail_key';
    if public.payroll_signup_start('A12345', 'reg34@example.com')->>'error' is distinct from 'bad_national_id' or public.payroll_signup_start(n34, 'not-mail')->>'error' is distinct from 'bad_email' then fails := fails || ' [34b validation]'; end if;
    if (public.payroll_signup_start(n34, ' Reg34@Example.com ')->>'ok')::boolean is not true then fails := fails || ' [34c start]'; end if;
    select id into vid from public.signup_verifications where national_id = n34 order by created_at desc limit 1;
    update public.signup_verifications set code_hash = encode(extensions.digest(id::text || ':123456', 'sha256'), 'hex') where id = vid;
    r := public.payroll_signup_verify(n34, 'reg34@example.com', '000000');
    if r->>'error' is distinct from 'bad_code' or (r->>'left')::int <> 4 then fails := fails || ' [34d bad code ' || coalesce(r::text, '') || ']'; end if;
    tk := public.payroll_signup_verify(n34, 'reg34@example.com', '１２３４５６')->>'ticket';
    if tk is null then fails := fails || ' [34e verify]'; end if;
    if public.payroll_register(null, jsonb_build_object('signup_ticket', tk, 'national_id', n34b, 'name', '建檔測試', 'birth_date', '2000-01-01', 'consent', true))->>'error' is distinct from 'ticket_mismatch' then fails := fails || ' [34f mismatch]'; end if;
    r := public.payroll_register(null, jsonb_build_object('signup_ticket', tk, 'national_id', n34, 'name', '建檔測試', 'birth_date', '2000-01-01', 'consent', true, 'email', 'other@example.com',
      'phone', '0912345034', 'address', '台北市信義區測試里一鄰測試路1號', 'bank_code', '822', 'bank_account', '123456789034', 'bank_account_name', '建檔測試'));
    if (r->>'ok')::boolean is not true or (select email from public.people where national_id = n34) is distinct from 'reg34@example.com'
       or not exists (select 1 from public.data_issues i join public.people p on p.id = i.person_id where p.national_id = n34 and i.code = 'new_registration' and i.event_id is null) then fails := fails || ' [34g register ' || coalesce(r::text, '') || ']'; end if;
    if public.payroll_register(null, jsonb_build_object('signup_ticket', tk, 'national_id', n34b, 'name', '建檔測試', 'birth_date', '2000-01-01', 'consent', true))->>'error' is distinct from 'bad_ticket' then fails := fails || ' [34h ticket reuse]'; end if;
    if public.payroll_register(null, jsonb_build_object('national_id', n34b, 'name', '建檔測試', 'birth_date', '2000-01-01', 'consent', true))->>'error' is distinct from 'bad_ticket' then fails := fails || ' [34i no ticket]'; end if;
    if public.payroll_signup_start(n34, 'reg34@example.com')->>'error' is distinct from 'exists' then fails := fails || ' [34j exists]'; end if;
    perform public.payroll_signup_start(n34b, 'a34@example.com'); perform public.payroll_signup_start(n34b, 'b34@example.com'); perform public.payroll_signup_start(n34b, 'c34@example.com');
    if public.payroll_signup_start(n34b, 'd34@example.com')->>'error' is distinct from 'too_many' then fails := fails || ' [34k rate limit]'; end if;
    if has_table_privilege('anon', 'public.signup_verifications', 'select') then fails := fails || ' [34l anon table]'; end if;
    -- 每個 IP 一小時 10 次（含已存在的查詢）
    perform set_config('request.headers', '{"x-forwarded-for": "203.0.113.34, 10.0.0.1"}', true);
    for k in 1..10 loop perform public.payroll_signup_start(n34, 'reg34@example.com'); end loop;
    if public.payroll_signup_start(n34, 'reg34@example.com')->>'error' is distinct from 'too_many' then fails := fails || ' [34m ip limit]'; end if;
    perform set_config('request.headers', '', true);
    -- 佇列裡的寄信請求不能含密鑰本身（只帶 HMAC 簽章）
    if exists (select 1 from net.http_request_queue q where convert_from(q.body, 'UTF8') like '%regression-mail-key%') then fails := fails || ' [34n mail key in pg_net queue]'; end if;
    if not exists (select 1 from net.http_request_queue q where convert_from(q.body, 'UTF8') like '%"sig"%') then fails := fails || ' [34o no signed request queued]'; end if;
  end;

  -- 35. 巡檢 22:07：沒綁 LINE 的人不排通知；加保名冊沒指定活動時不含已封存活動（指定活動時照列）
  declare e35 uuid; p35 uuid; s35 uuid;
  begin
    select id into e35 from public.events where name = '回歸27乙';
    insert into public.people(national_id, name, profile_source) values ('Z999990035', '測試戊', 'test') returning id into p35;
    insert into public.payslips(person_id, event_id, gross, net, deductions, status) values (p35, e35, 100, 100, 0, 'draft') returning id into s35;
    update public.payslips set status = 'published' where id = s35;
    if exists (select 1 from public.notifications where ref_id = s35) then fails := fails || ' [35a unlinked notified]'; end if;
    insert into public.attendance(person_id, event_id, work_date, source) values (p35, e35, (select start_date from public.events where id = e35), 'manual');
    update public.events set archived_at = now() where id = e35;
    r := public.admin_roster(atok, jsonb_build_object('statuses', jsonb_build_array('attended'), 'q', '回歸27乙'));
    if jsonb_array_length(r->'rows') <> 0 then fails := fails || ' [35b archived in roster]'; end if;
    r := public.admin_roster(atok, jsonb_build_object('event_id', e35, 'statuses', jsonb_build_array('attended')));
    if jsonb_array_length(r->'rows') = 0 then fails := fails || ' [35c explicit archived event]'; end if;
    update public.events set archived_at = null where id = e35;
  end;

  -- 36. 寄信設定：要登入；網址只收 Apps Script /exec；密鑰只寫不讀
  if public.admin_mail_settings('bad-token', null)->>'error' is distinct from 'session' then fails := fails || ' [36a no session]'; end if;
  if public.admin_mail_settings(atok, jsonb_build_object('url', 'https://evil.example.com/exec'))->>'error' is distinct from 'bad_url' then fails := fails || ' [36b bad url]'; end if;
  if public.admin_mail_settings(atok, jsonb_build_object('key', 'short'))->>'error' is distinct from 'bad_key' then fails := fails || ' [36c bad key]'; end if;
  r := public.admin_mail_settings(atok, jsonb_build_object('url', 'https://script.google.com/macros/s/AKfycbRegressionTest000000000/exec', 'key', repeat('ab', 32)));
  if (r->>'key_set')::boolean is not true or r ? 'key' or r::text like '%abababab%' then fails := fails || ' [36d key echoed or unset]'; end if;
  -- 一個欄位錯就整份不寫入
  perform public.admin_mail_settings(atok, jsonb_build_object('url', 'https://script.google.com/macros/s/AKfycbOtherRegression0000000000/exec', 'key', 'bad'));
  if public.setting('mail_webapp_url') <> 'https://script.google.com/macros/s/AKfycbRegressionTest000000000/exec' then fails := fails || ' [36e partial update]'; end if;
  if has_function_privilege('anon', 'public.setting(text)', 'execute') then fails := fails || ' [36f setting exposed]'; end if;

  -- 37. 現金發薪：改發放方式、已發放只對已發布的現金單、已發放不能改回轉帳、匯款清單不含現金、重算保留現金、總覽待發放數
  declare e37 uuid; p37 uuid; s37 uuid;
  begin
    insert into public.events(employer_id, name, start_date, end_date, pay_date) values (emp, '回歸37現金', v_today - 2, v_today - 2, v_today + 5) returning id into e37;
    insert into public.people(national_id, name, profile_source) values ('Z999990037', '測試庚', 'test') returning id into p37;
    insert into public.payslips(person_id, event_id, gross, net, deductions, status, pay_date, relation) values (p37, e37, 1000, 1000, 0, 'draft', v_today + 5, 'employment') returning id into s37;
    insert into public.data_issues(event_id, payslip_id, person_id, severity, code, detail) values (e37, s37, p37, 'warn', 'no_bank_account', '沒有匯款帳號');
    if public.admin_set_pay_method('bad-token', array[s37], 'cash')->>'error' is distinct from 'session' then fails := fails || ' [37a no session]'; end if;
    if public.admin_set_pay_method(atok, array[s37], 'bitcoin')->>'error' is distinct from 'bad_method' then fails := fails || ' [37b bad method]'; end if;
    perform public.admin_set_pay_method(atok, array[s37], 'cash');
    if (select pay_method from public.payslips where id = s37) <> 'cash' or exists (select 1 from public.data_issues where payslip_id = s37 and code = 'no_bank_account' and not resolved) then fails := fails || ' [37c set cash]'; end if;
    if (public.admin_mark_cash_paid(atok, array[s37], true)->>'updated')::int <> 0 then fails := fails || ' [37d draft marked paid]'; end if;
    update public.payslips set status = 'published' where id = s37;
    if (select (x->>'cash_pending')::int from jsonb_array_elements(public.admin_overview(atok)->'events') x where (x->>'id')::uuid = e37) <> 1 then fails := fails || ' [37e overview cash_pending]'; end if;
    r := public.admin_payout(atok, e37);
    if jsonb_array_length(r->'rows') <> 0 or jsonb_array_length(r->'cash_rows') <> 1 then fails := fails || ' [37f payout split ' || r::text || ']'; end if;
    -- 還沒上傳簽收單不能標記已發放
    if public.admin_mark_cash_paid(atok, array[s37], true)->>'error' is distinct from 'no_receipt' then fails := fails || ' [37k no receipt]'; end if;
    insert into public.payout_receipts(event_id, path, uploaded_by) values (e37, 'receipts/' || e37 || '/1700000000000.jpg', 'regression-admin');
    -- 分兩句：同一個運算式看不到函式內剛寫入的資料
    r := public.admin_mark_cash_paid(atok, array[s37], true);
    if (r->>'updated')::int <> 1 or (select cash_paid_by from public.payslips where id = s37) is null then fails := fails || ' [37g mark paid]'; end if;
    r := public.admin_set_pay_method(atok, array[s37], 'transfer');
    if (r->>'skipped_paid')::int <> 1 or (select pay_method from public.payslips where id = s37) <> 'cash' then fails := fails || ' [37h paid switched back]'; end if;
    -- 已發放的不重算（避免重複發放）
    update public.payslips set status = 'draft', generated = true where id = s37;
    if (public.payslip_regenerate(e37, p37)->>'result') is distinct from 'skipped' or (select cash_paid_at from public.payslips where id = s37) is null then fails := fails || ' [37l regen paid]'; end if;
    update public.payslips set status = 'published' where id = s37;
    if public.admin_mark_cash_paid(atok, array[s37], null)->>'error' is distinct from 'bad_value' then fails := fails || ' [37m null paid]'; end if;
    perform public.admin_mark_cash_paid(atok, array[s37], false);
    if (select cash_paid_at from public.payslips where id = s37) is not null then fails := fails || ' [37i undo paid]'; end if;
    -- 改回轉帳且沒帳號：缺帳戶問題重新打開
    perform public.admin_set_pay_method(atok, array[s37], 'transfer');
    if not exists (select 1 from public.data_issues where payslip_id = s37 and code = 'no_bank_account' and not resolved) then fails := fails || ' [37n reopen no account]'; end if;
    if public.admin_payout_receipts('bad-token', e37)->>'error' is distinct from 'session' or has_table_privilege('anon', 'public.payout_receipts', 'select') then fails := fails || ' [37j receipts access]'; end if;
  end;

  -- 38. 刪除／停用人員：有薪資或出勤不能刪；要輸入完整身分證；沒紀錄的可刪（報名一併刪）；停用後不能登入、名單預設不顯示；匿名不能呼叫刪除
  declare p38 uuid; e38 uuid; p38r uuid; n38r text;
  begin
    insert into public.people(national_id, name, profile_source, password_hash) values ('Z999990038', '測試辛', 'test', extensions.crypt('0890101', extensions.gen_salt('bf', 4))) returning id into p38;
    select id into e38 from public.events where name = '回歸27甲';
    insert into public.applications(event_id, person_id, status) values (e38, p38, 'active');
    if public.admin_delete_person('bad-token', p38, 'Z999990038')->>'error' is distinct from 'session' then fails := fails || ' [38a no session]'; end if;
    if public.admin_delete_person(atok, p38, 'Z999990039')->>'error' is distinct from 'confirm' then fails := fails || ' [38b confirm]'; end if;
    select s.person_id, p.national_id into p38r, n38r from public.payslips s join public.people p on p.id = s.person_id limit 1;
    if public.admin_delete_person(atok, p38r, n38r)->>'error' is distinct from 'has_records' then fails := fails || ' [38c has records]'; end if;
    -- 停用
    perform public.admin_set_person_disabled(atok, p38, true);
    if public.payroll_login('Z999990038', '0890101')->>'ok' = 'true' then fails := fails || ' [38d disabled login]'; end if;
    if exists (select 1 from jsonb_array_elements(public.admin_people(atok)->'people') x where (x->>'id')::uuid = p38) then fails := fails || ' [38e disabled in default list]'; end if;
    if not exists (select 1 from jsonb_array_elements(public.admin_people(atok, 'Z999990038')->'people') x where (x->>'id')::uuid = p38 and (x->>'disabled')::boolean) then fails := fails || ' [38f search disabled]'; end if;
    -- 停用後：既有 session 失效、停用前的 LINE 綁定碼失效
    perform public.admin_set_person_disabled(atok, p38, false);
    insert into public.sessions(token_hash, person_id, expires_at) values (encode(extensions.digest('regress-s38', 'sha256'), 'hex'), p38, now() + interval '1 hour');
    insert into public.line_link_codes(code, person_id, expires_at) values ('938038', p38, now() + interval '10 minutes');
    update public.people set disabled_at = now() where id = p38;
    if public.payroll_session_person('regress-s38') is not null then fails := fails || ' [38j disabled session]'; end if;
    if (public.line_bind('938038', 'Uregress38')->>'ok')::boolean then fails := fails || ' [38k disabled line bind]'; end if;
    perform public.admin_set_person_disabled(atok, p38, false);
    if (public.payroll_login('Z999990038', '0890101')->>'ok')::boolean is not true then fails := fails || ' [38g enabled login]'; end if;
    -- 刪除（證件紀錄、登入、綁定碼要一併刪掉；回傳的檔案路徑交給 docs 函式刪）
    insert into public.people_documents(person_id, kind, path) values (p38, 'id_front', p38 || '/id_front-1700000000000.jpg');
    insert into public.line_link_codes(code, person_id, expires_at) values ('938039', p38, now() + interval '10 minutes');
    r := public.admin_delete_person(atok, p38, ' z999990038 ');
    if not (r->'paths') ? (p38 || '/id_front-1700000000000.jpg') then fails := fails || ' [38m paths returned]'; end if;
    if (r->>'ok')::boolean is not true or exists (select 1 from public.people where id = p38) or exists (select 1 from public.applications where person_id = p38) then fails := fails || ' [38h delete ' || coalesce(r::text, '') || ']'; end if;
    if has_function_privilege('anon', 'public.admin_delete_person(text,uuid,text)', 'execute') or has_function_privilege('authenticated', 'public.admin_delete_person(text,uuid,text)', 'execute')
       or not has_function_privilege('service_role', 'public.admin_delete_person(text,uuid,text)', 'execute') then fails := fails || ' [38i delete privileges]'; end if;
    if exists (select 1 from public.sessions where person_id = p38) or exists (select 1 from public.line_link_codes where person_id = p38)
       or exists (select 1 from public.people_documents where person_id = p38) then fails := fails || ' [38l cascade]'; end if;
  end;

  -- 39. 報名方式三種模式：自選＋專屬連結（整組報名）、方案制（只能選方案、方案名額、整組錄取）、名單制（不選班次、管理員排入／移出）、報名前須綁 LINE、錄取同時排 LINE 與 Email 通知
  declare e39 uuid; h1 uuid; h2 uuid; h3 uuid; q1 uuid; q2 uuid; ta text := encode(extensions.gen_random_bytes(16), 'hex'); tb text := encode(extensions.gen_random_bytes(16), 'hex');
    pa uuid; pb uuid; c39 text; aa uuid; ab uuid; dd date := (now() at time zone 'Asia/Taipei')::date + 20; v_mode0 text := public.setting('recruit_mode'); v_line0 text := public.setting('recruit_require_line');
  begin
    insert into public.events(employer_id, name, start_date, end_date, default_hourly_rate, recruiting, signup_code) values (emp, '回歸39', dd, dd, 200, true, 'regress-join-39') returning id into e39;
    insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount) values (e39, dd, '08:00', '09:00', '進場', 1) returning id into h1;
    insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount) values (e39, dd, '10:00', '15:00', 'PT', 3) returning id into h2;
    insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount) values (e39, dd, '16:00', '18:00', '撤場', 5) returning id into h3;
    insert into public.people(national_id, name, birth_date, profile_source, email) values ('Z999990391', '測試三九甲', '2000-01-01', 'test', 'regress39@example.com') returning id into pa;
    insert into public.people(national_id, name, birth_date, profile_source) values ('Z999990392', '測試三九乙', '2000-01-01', 'test') returning id into pb;
    insert into public.people_documents(person_id, kind, path) select x.p, k, x.p || '/' || k || '-x.jpg' from (values (pa), (pb)) x(p) cross join unnest(array['id_front','id_back','bankbook']) k;
    insert into public.sessions(token_hash, person_id, expires_at) values (encode(extensions.digest(ta, 'sha256'), 'hex'), pa, now() + interval '1 hour'), (encode(extensions.digest(tb, 'sha256'), 'hex'), pb, now() + interval '1 hour');
    -- 設定：未登入不能讀寫、模式值檢查
    if public.admin_recruit_settings('bad-token', null)->>'error' is distinct from 'session' then fails := fails || ' [39a settings session]'; end if;
    if public.admin_recruit_settings(atok, '{"mode":"x"}')->>'error' is distinct from 'bad_mode' then fails := fails || ' [39b bad mode]'; end if;
    perform public.admin_recruit_settings(atok, '{"mode":"pick","require_line":"false"}');
    -- 方案／連結：重疊班次不能同組；同一組班次沿用同一條連結；別場活動的班次不收
    if public.admin_save_plan(atok, e39, jsonb_build_object('shift_ids', jsonb_build_array(h1, s1)))->>'error' is distinct from 'bad_shift' then fails := fails || ' [39c cross-event plan]'; end if;
    r := public.admin_save_plan(atok, e39, jsonb_build_object('shift_ids', jsonb_build_array(h1, h3), 'name', '進撤', 'headcount', '1'));
    q1 := (r->>'id')::uuid; c39 := r->>'code';
    if public.admin_save_plan(atok, e39, jsonb_build_object('shift_ids', jsonb_build_array(h3, h1)))->>'code' is distinct from c39 then fails := fails || ' [39d same set new link]'; end if;
    q2 := (public.admin_save_plan(atok, e39, jsonb_build_object('shift_ids', jsonb_build_array(h3)))->>'id')::uuid;
    if (select name from public.recruit_plans where id = q2) <> '撤場' then fails := fails || ' [39e auto name]'; end if;
    -- 自選模式：主連結看得到全部班次；專屬連結只看得到那一組，而且要整組報
    if jsonb_array_length(public.payroll_event_public('regress-join-39')->'shifts') <> 3 or public.payroll_event_public('regress-join-39')->>'mode' <> 'pick' then fails := fails || ' [39f pick main]'; end if;
    if jsonb_array_length(public.payroll_event_public(c39)->'shifts') <> 2 or public.payroll_event_public(c39)->>'mode' <> 'plan' then fails := fails || ' [39g plan link view]'; end if;
    if pg_temp.tapply(ta, c39, jsonb_build_object('plan_id', q2))->>'error' is distinct from 'bad_plan' then fails := fails || ' [39h other plan via link]'; end if;
    r := pg_temp.tapply(ta, c39, jsonb_build_object('plan_id', q1, 'shift_ids', jsonb_build_array(h1)));
    select id into aa from public.applications where event_id = e39 and person_id = pa;
    if (r->>'ok')::boolean is not true or (select count(*) from public.application_shifts where application_id = aa) <> 2 or (select plan_id from public.applications where id = aa) <> q1 then fails := fails || ' [39i bundle apply ' || r::text || ']'; end if;
    -- 方案制：主連結只列方案；沒選方案不收；自選班次的參數被忽略
    perform public.admin_recruit_settings(atok, '{"mode":"plans"}');
    if public.payroll_event_public('regress-join-39')->>'mode' <> 'plans' or jsonb_array_length(public.payroll_event_public('regress-join-39')->'plans') <> 2 then fails := fails || ' [39j plans view]'; end if;
    if pg_temp.tapply(tb, 'regress-join-39', jsonb_build_object('shift_ids', jsonb_build_array(h2)))->>'error' is distinct from 'no_plan' then fails := fails || ' [39k plans needs plan]'; end if;
    perform pg_temp.tapply(tb, 'regress-join-39', jsonb_build_object('plan_id', q1));
    select id into ab from public.applications where event_id = e39 and person_id = pb;
    -- 整組錄取：甲錄取（兩班都錄取）；乙因方案名額 1 人已滿，整組都不錄取
    r := public.admin_decide_plan(atok, array[aa], 'accepted');
    if (select count(*) from public.application_shifts where application_id = aa and status = 'accepted') <> 2 then fails := fails || ' [39l bundle accept ' || r::text || ']'; end if;
    r := public.admin_decide_plan(atok, array[ab], 'accepted');
    if jsonb_array_length(r->'full') <> 1 or exists (select 1 from public.application_shifts where application_id = ab and status = 'accepted') then fails := fails || ' [39m plan quota ' || r::text || ']'; end if;
    if pg_temp.tapply(tb, 'regress-join-39', jsonb_build_object('plan_id', q2))->>'ok' <> 'true' then fails := fails || ' [39n switch plan]'; end if;
    if (select count(*) from public.application_shifts where application_id = ab) <> 1 then fails := fails || ' [39o switch keeps old shifts]'; end if;
    -- 已錄取的人不能改報別的方案；已滿的方案不能新報
    if pg_temp.tapply(ta, 'regress-join-39', jsonb_build_object('plan_id', q2))->>'error' is distinct from 'has_accepted' then fails := fails || ' [39p accepted switch]'; end if;
    -- 錄取通知：有 Email 的排 Email；沒綁 LINE 的不排 LINE
    if not exists (select 1 from public.notifications where person_id = pa and event_id = e39 and kind = 'accepted' and channel = 'mail' and status = 'pending')
       or exists (select 1 from public.notifications where person_id = pa and event_id = e39 and channel = 'line') then fails := fails || ' [39q accept channels]'; end if;
    update public.notifications set send_after = now() where person_id = pa and event_id = e39 and status = 'pending';
    if exists (select 1 from jsonb_array_elements(public.notify_batch(50)) x join public.notifications n on n.id = (x->>'id')::uuid where n.channel = 'mail') then fails := fails || ' [39r line batch took mail]'; end if;
    -- 方案報名的人不能逐班錄取（只能整組）；已錄取的方案報名不能經自選主連結改報
    r := public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', ab, 'shift', h3)), 'accepted');
    if jsonb_array_length(r->'plan') <> 1 or exists (select 1 from public.application_shifts where application_id = ab and status = 'accepted') then fails := fails || ' [39r2 per-shift plan accept ' || r::text || ']'; end if;
    perform public.admin_recruit_settings(atok, '{"mode":"pick"}');
    if pg_temp.tapply(ta, 'regress-join-39', jsonb_build_object('shift_ids', jsonb_build_array(h1, h2, h3)))->>'error' is distinct from 'has_accepted' then fails := fails || ' [39r3 accepted plan via pick]'; end if;
    perform public.admin_recruit_settings(atok, '{"mode":"plans"}');
    -- Email：簽章請求不含密鑰，送出後標「送出中」；Apps Script 回 ok 才算寄出
    update public.app_settings set value = 'https://example.invalid/exec' where key = 'mail_webapp_url';
    update public.app_settings set value = 'regression-mail-key' where key = 'mail_key';
    perform public.mail_flush();
    if (select status from public.notifications where person_id = pa and event_id = e39 and channel = 'mail' order by created_at desc limit 1) <> 'sending' then fails := fails || ' [39r4 mail sending]'; end if;
    if exists (select 1 from net.http_request_queue q where convert_from(q.body, 'UTF8') like '%regression-mail-key%') then fails := fails || ' [39r5 key in queue]'; end if;
    -- 刪掉方案裡的班次：方案自動停用、連結失效；手動停用也失效
    perform public.admin_save_plan(atok, e39, jsonb_build_object('id', q2, 'disabled', true));
    if public.payroll_event_public((select code from public.recruit_plans where id = q2))->>'error' is distinct from 'bad_join' then fails := fails || ' [39s disabled link]'; end if;
    declare h4 uuid; q4 uuid; begin
      insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount) values (e39, dd, '19:00', '20:00', '加班', 1) returning id into h4;
      q4 := (public.admin_save_plan(atok, e39, jsonb_build_object('shift_ids', jsonb_build_array(h4)))->>'id')::uuid;
      delete from public.shifts where id = h4;
      if (select disabled_at from public.recruit_plans where id = q4) is null then fails := fails || ' [39s2 deleted shift plan active]'; end if;
    end;
    -- 名單制：報名不選班次；管理員排入（直接錄取）、名額滿擋下、移出
    perform public.admin_recruit_settings(atok, '{"mode":"pool"}');
    if public.payroll_event_public('regress-join-39')->>'mode' <> 'pool' or jsonb_array_length(public.payroll_event_public('regress-join-39')->'shifts') <> 0 then fails := fails || ' [39t pool view]'; end if;
    if public.payroll_event_public(c39)->>'mode' <> 'pool' then fails := fails || ' [39u plan link in pool]'; end if;
    delete from public.application_shifts where application_id = ab;
    if (pg_temp.tapply(tb, 'regress-join-39', '{}'::jsonb)->>'ok')::boolean is not true or exists (select 1 from public.application_shifts where application_id = ab) then fails := fails || ' [39v pool apply]'; end if;
    r := public.admin_assign(atok, h2, array[ab], true);
    if (select status from public.application_shifts where application_id = ab and shift_id = h2) is distinct from 'accepted' then fails := fails || ' [39w assign ' || r::text || ']'; end if;
    r := public.admin_assign(atok, h1, array[ab], true);
    if jsonb_array_length(r->'full') <> 1 or exists (select 1 from public.application_shifts where application_id = ab and shift_id = h1) then fails := fails || ' [39x assign full ' || r::text || ']'; end if;
    perform public.admin_assign(atok, h2, array[ab], false);
    if exists (select 1 from public.application_shifts where application_id = ab and shift_id = h2) then fails := fails || ' [39y unassign]'; end if;
    if public.admin_assign('bad-token', h2, array[ab], true)->>'error' is distinct from 'session' then fails := fails || ' [39z assign session]'; end if;
    -- 報名前須綁 LINE
    update public.app_settings set value = null where key = 'line_basic_id';
    if public.admin_recruit_settings(atok, '{"require_line":"true"}')->>'error' is distinct from 'line_not_ready' then fails := fails || ' [39z2 line not ready]'; end if;
    update public.app_settings set value = '@regress' where key = 'line_basic_id';
    perform public.admin_recruit_settings(atok, '{"require_line":"true"}');
    if pg_temp.tapply(tb, 'regress-join-39', '{}'::jsonb)->>'error' is distinct from 'need_line' then fails := fails || ' [39za need line]'; end if;
    -- 權限：內部函式匿名不能呼叫、方案表匿名不能讀
    if has_function_privilege('anon', 'public.mail_flush()', 'execute') or has_function_privilege('anon', 'public.join_target(text)', 'execute')
       or has_table_privilege('anon', 'public.recruit_plans', 'select') then fails := fails || ' [39zb privileges]'; end if;
    update public.app_settings set value = coalesce(v_mode0, 'pick') where key = 'recruit_mode';
    update public.app_settings set value = coalesce(v_line0, 'false') where key = 'recruit_require_line';
  end;

  -- 40. 報名時同意勞動契約與保密條款：沒同意保密條款或契約不收；契約內容要和當下一致；錄取的班次一樣就直接生效、只錄取部分要重新確認；取消報名清掉
  declare e40 uuid; k1 uuid; k2 uuid; p40 uuid; t40 text := encode(extensions.gen_random_bytes(16), 'hex'); a40 uuid; h text; dd date := (now() at time zone 'Asia/Taipei')::date + 25; v_mode0 text := public.setting('recruit_mode'); v_line0 text := public.setting('recruit_require_line');
  begin
    perform public.admin_recruit_settings(atok, '{"mode":"pick","require_line":"false"}');
    insert into public.events(employer_id, name, start_date, end_date, default_hourly_rate, recruiting, signup_code) values (emp, '回歸40', dd, dd, 200, true, 'regress-join-40') returning id into e40;
    insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount) values (e40, dd, '09:00', '12:00', '進場', 2) returning id into k1;
    insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount) values (e40, dd, '13:00', '17:00', '撤場', 2) returning id into k2;
    insert into public.people(national_id, name, birth_date, profile_source) values ('Z999990400', '測試四十', '2000-01-01', 'test') returning id into p40;
    insert into public.people_documents(person_id, kind, path) select p40, k, p40 || '/' || k || '-x.jpg' from unnest(array['id_front','id_back','bankbook']) k;
    insert into public.sessions(token_hash, person_id, expires_at) values (encode(extensions.digest(t40, 'sha256'), 'hex'), p40, now() + interval '1 hour');
    if public.payroll_contract_preview('bad', 'regress-join-40', '{}')->>'error' is distinct from 'session' then fails := fails || ' [40a preview session]'; end if;
    r := public.payroll_contract_preview(t40, 'regress-join-40', jsonb_build_object('shift_ids', jsonb_build_array(k1, k2)));
    h := r->>'hash';
    if h is null or r->>'text' not like '%測試四十%' or r->>'nda_text' not like '%保密%' then fails := fails || ' [40b preview]'; end if;
    if public.payroll_apply(t40, 'regress-join-40', jsonb_build_object('shift_ids', jsonb_build_array(k1, k2), 'contract_hash', h))->>'error' is distinct from 'need_nda' then fails := fails || ' [40c need nda]'; end if;
    if public.payroll_apply(t40, 'regress-join-40', jsonb_build_object('shift_ids', jsonb_build_array(k1, k2), 'nda', true))->>'error' is distinct from 'need_contract' then fails := fails || ' [40d need contract]'; end if;
    if public.payroll_apply(t40, 'regress-join-40', jsonb_build_object('shift_ids', jsonb_build_array(k1), 'nda', true, 'contract_hash', h))->>'error' is distinct from 'contract_changed' then fails := fails || ' [40e other shifts hash]'; end if;
    r := public.payroll_apply(t40, 'regress-join-40', jsonb_build_object('shift_ids', jsonb_build_array(k1, k2), 'nda', true, 'contract_hash', h));
    select id into a40 from public.applications where event_id = e40 and person_id = p40;
    if (r->>'ok')::boolean is not true or (select apply_contract_hash from public.applications where id = a40) is distinct from h or (select nda_accepted_at from public.applications where id = a40) is null then fails := fails || ' [40f apply ' || r::text || ']'; end if;
    -- 只錄取一班：契約不同，不會自動生效
    perform public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a40, 'shift', k1)), 'accepted');
    if (select contract_accepted_at from public.applications where id = a40) is not null then fails := fails || ' [40g partial auto accepted]'; end if;
    -- 兩班都錄取：和報名時一樣，直接生效
    perform public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a40, 'shift', k2)), 'accepted');
    if (select contract_accepted_at from public.applications where id = a40) is distinct from (select apply_contract_at from public.applications where id = a40)
       or not exists (select 1 from public.contract_history where application_id = a40 and superseded_at is null and text_hash = h) then fails := fails || ' [40h full auto accept]'; end if;
    -- 之後地點改了：契約失效，要本人重新確認（不會被報名時的同意自動補回）
    update public.events set location = '新地點' where id = e40;
    if (select contract_accepted_at from public.applications where id = a40) is not null then fails := fails || ' [40i material change kept]'; end if;
    if has_function_privilege('anon', 'public.payroll_contract_text_for(uuid,uuid,uuid[])', 'execute') then fails := fails || ' [40j text_for anon]'; end if;
    update public.app_settings set value = coalesce(v_mode0, 'pick') where key = 'recruit_mode';
    update public.app_settings set value = coalesce(v_line0, 'false') where key = 'recruit_require_line';
  end;

  if fails = '' then raise exception 'PASS 全部 40 組測試通過'; else raise exception 'FAIL%', fails; end if;
end $$;
