-- 安全與商業邏輯回歸測試。整段在單一交易內執行，最後一定以例外結束，所有資料都會回滾。
-- 執行：把整份貼進 Supabase SQL Editor（或 execute_sql）。結果訊息以 PASS 或 FAIL 開頭。
-- 限制：單一交易無法測併發（雙連線競態），那部分靠鎖定順序的程式審查。
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  emp uuid; ev uuid; ev2 uuid; ev3 uuid; s1 uuid; s2 uuid; s3 uuid; s_other uuid;
  p1 uuid; p2 uuid; tok1 text := encode(extensions.gen_random_bytes(16), 'hex'); tok2 text := encode(extensions.gen_random_bytes(16), 'hex');
  atok text := encode(extensions.gen_random_bytes(16), 'hex'); ev4 uuid; ev5 uuid; att uuid; a1 uuid; a2 uuid; r jsonb; r2 jsonb; c jsonb; v_code text; v_slip uuid; i int; n int; txt text; nid uuid;
  fails text := '';
begin
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
  r := public.payroll_apply(tok1, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1)));
  if r->>'error' is distinct from 'missing_docs' or jsonb_array_length(r->'missing') <> 3 then fails := fails || ' [15a apply without documents: ' || r::text || ']'; end if;
  insert into public.people_documents(person_id, kind, path) values (p1, 'id_front', p1 || '/id_front-x.jpg'), (p1, 'id_back', p1 || '/id_back-x.jpg');
  r := public.payroll_apply(tok1, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1)));
  if r->>'error' is distinct from 'missing_docs' or r->'missing' <> '["bankbook"]'::jsonb then fails := fails || ' [15b partial documents: ' || r::text || ']'; end if;
  insert into public.people_documents(person_id, kind, path) values (p1, 'bankbook', p1 || '/bankbook-x.jpg'),
    (p2, 'id_front', p2 || '/id_front-x.jpg'), (p2, 'id_back', p2 || '/id_back-x.jpg'), (p2, 'bankbook', p2 || '/bankbook-x.jpg');

  -- 5. 報名不能夾帶別場活動的班次（即使該場沒有班次）
  insert into public.shifts(event_id, work_date, start_time, end_time, headcount) values (ev, v_today, '21:00', '22:00', 1) returning id into s_other;
  if public.payroll_apply(tok1, 'regress-join-2', jsonb_build_object('shift_ids', jsonb_build_array(s_other)))->>'error' is distinct from 'bad_shift' then fails := fails || ' [5 cross-event shift accepted]'; end if;

  perform public.payroll_apply(tok1, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1, s2, s3)));
  perform public.payroll_apply(tok2, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1)));
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
  insert into public.attendance(person_id, event_id, work_date, clock_in, clock_out, break_minutes, source) values
    (p1, ev, v_today, (v_today + time '10:00') at time zone 'Asia/Taipei', (v_today + time '18:30') at time zone 'Asia/Taipei', 30, 'manual'),
    (p1, ev, v_today + 1, (v_today + 1 + time '10:00') at time zone 'Asia/Taipei', (v_today + 1 + time '18:30') at time zone 'Asia/Taipei', 30, 'manual');
  c := public.payroll_compute(ev, p1);
  if (c->>'gross')::numeric <> 3600 then fails := fails || ' [10a per-day rates gross=' || (c->>'gross') || ' expected 3600]'; end if;
  update public.event_staff set rate = 220 where event_id = ev and person_id = p1;
  c := public.payroll_compute(ev, p1);
  if (c->>'gross')::numeric <> 3760 then fails := fails || ' [10b staff override gross=' || (c->>'gross') || ' expected 3760]'; end if;

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
  insert into public.events(employer_id, name, start_date, end_date) values (emp, '提示測試早', v_today, v_today) returning id into ev4;
  insert into public.events(employer_id, name, start_date, end_date) values (emp, '提示測試遲', v_today, v_today) returning id into ev5;
  insert into public.shifts(event_id, work_date, start_time, end_time, headcount) values
    (ev4, v_today, ((now() at time zone 'Asia/Taipei') + interval '30 minutes')::time(0), ((now() at time zone 'Asia/Taipei') + interval '4 hours 30 minutes')::time(0), 2) returning id into s1;
  insert into public.applications(event_id, person_id, status) values (ev4, p1, 'active') returning id into a1;
  insert into public.application_shifts(application_id, shift_id, status) values (a1, s1, 'accepted');
  insert into public.shifts(event_id, work_date, start_time, end_time, headcount) values
    (ev5, v_today, ((now() at time zone 'Asia/Taipei') - interval '15 minutes')::time(0), ((now() at time zone 'Asia/Taipei') + interval '3 hours')::time(0), 2) returning id into s2;
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
  if (public.payroll_change_password(tok2, '0890101', '0730407')->>'ok')::boolean is not true then fails := fails || ' [20b worker 7 rejected]'; end if;
  if (public.payroll_login('Z999990002', '0730407')->>'ok')::boolean is not true then fails := fails || ' [20c login with new 7]'; end if;

  if fails = '' then raise exception 'PASS 全部 20 組測試通過'; else raise exception 'FAIL%', fails; end if;
end $$;
